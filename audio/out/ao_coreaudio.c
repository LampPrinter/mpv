/*
 * This file is part of mpv.
 *
 * mpv is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * mpv is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with mpv.  If not, see <http://www.gnu.org/licenses/>.
 */

#include <stdatomic.h>
#include <stdlib.h>
#include <CoreAudio/HostTime.h>
#include <libavutil/mathematics.h>

#include "ao.h"
#include "internal.h"
#include "audio/format.h"
#include "common/common.h"
#include "osdep/threads.h"
#include "osdep/timer.h"
#include "options/m_option.h"
#include "common/msg.h"
#include "ao_coreaudio_chmap.h"
#include "ao_coreaudio_properties.h"
#include "ao_coreaudio_utils.h"
#include "osdep/mac/compat.h"

// The timeout for stopping the audio unit after being reset. This allows the
// device to sleep after playback paused. The duration is chosen to match the
// behavior of AVFoundation.
#define IDLE_TIME 7 * NSEC_PER_SEC

struct priv {
    // This must be put in the front (ca_change_physical_format_sync casts ao->priv)
    struct coreaudio_cb_sem sem;

    AudioDeviceID device;
    AudioUnit audio_unit;
    mp_mutex au_lock;

    struct mp_chmap req_channels;
    atomic_int_fast64_t hw_latency_ns;

    AudioStreamBasicDescription original_asbd;
    AudioStreamID original_asbd_stream;

    bool change_physical_format;

    // Pre-allocated lock-free SPSC ringbuffer decoupling HALB_IOThread from
    // MPV mutexes, filter graph locks, and talloc allocations.
    char *rb_data;
    char *rb_planes[MP_NUM_CHANNELS];
    int num_planes;
    size_t plane_stride;
    uint32_t rb_cap;        // power-of-2 capacity in sample frames
    uint32_t rb_mask;       // rb_cap - 1
    uint32_t rb_target;     // target buffered frames (~120-200ms)
    _Atomic uint64_t rb_read;
    _Atomic uint64_t rb_write;

    // Seqlock publishing the last AudioTimeStamp end time for rb_read
    _Atomic uint32_t timing_seq;
    uint64_t timing_read_pos;
    int64_t timing_end_ns;

    atomic_bool playing;
    atomic_bool paused;
    atomic_bool cb_mute;
    atomic_bool rebinding;
    atomic_bool cb_saw_empty;
    atomic_bool reloading;
    atomic_bool rebind_pending;
    atomic_bool shutting_down;
    atomic_bool unit_running;
    bool stream_started;
    bool device_listener_registered;
    uint32_t init_out_channels;

    // Blocks executed on p->queue for idle sleep and route-change retry.
    dispatch_block_t idle_work;
    dispatch_block_t retry_work;
    dispatch_queue_t queue;

    int hotplug_cb_registration_times;
    int hotplug_prop_count;
};

static int64_t ca_get_hardware_latency(struct ao *ao, AudioUnit au, AudioDeviceID dev) {
    double audiounit_latency_sec = 0.0;
    uint32_t size = sizeof(audiounit_latency_sec);
    OSStatus err = AudioUnitGetProperty(
            au,
            kAudioUnitProperty_Latency,
            kAudioUnitScope_Global,
            0,
            &audiounit_latency_sec,
            &size);
    CHECK_CA_ERROR("cannot get audio unit latency");

    uint64_t audiounit_latency_ns = MP_TIME_S_TO_NS(audiounit_latency_sec);
    uint64_t device_latency_ns    = ca_get_device_latency_ns(ao, dev);

    MP_VERBOSE(ao, "audiounit latency [ns]: %lld\n", audiounit_latency_ns);
    MP_VERBOSE(ao, "device latency [ns]: %lld\n", device_latency_ns);

    return audiounit_latency_ns + device_latency_ns;

coreaudio_error:
    return 0;
}

static void rb_publish_timing(struct priv *p, uint64_t pos, int64_t end_ns)
{
    uint32_t seq = atomic_load_explicit(&p->timing_seq, memory_order_relaxed);
    while ((seq & 1) || !atomic_compare_exchange_weak_explicit(
               &p->timing_seq, &seq, seq + 1,
               memory_order_acquire, memory_order_relaxed))
        seq &= ~1u;
    atomic_thread_fence(memory_order_release);
    p->timing_read_pos = pos;
    p->timing_end_ns = end_ns;
    atomic_store_explicit(&p->timing_seq, seq + 2, memory_order_release);
}

static void rb_read_timing(struct priv *p, uint64_t *out_pos, int64_t *out_end_ns)
{
    uint32_t s1, s2;
    do {
        s1 = atomic_load_explicit(&p->timing_seq, memory_order_acquire);
        if (s1 & 1)
            continue;
        *out_pos = p->timing_read_pos;
        *out_end_ns = p->timing_end_ns;
        atomic_thread_fence(memory_order_acquire);
        s2 = atomic_load_explicit(&p->timing_seq, memory_order_acquire);
    } while (s1 != s2);
}

static uint64_t rb_advance_read(struct priv *p, uint64_t target)
{
    uint64_t cur = atomic_load_explicit(&p->rb_read, memory_order_acquire);
    while (cur < target &&
           !atomic_compare_exchange_weak_explicit(&p->rb_read, &cur, target,
                                                  memory_order_release,
                                                  memory_order_acquire))
        ;
    return cur < target ? target : cur;
}

static void rb_clear(struct priv *p)
{
    uint64_t w = atomic_load_explicit(&p->rb_write, memory_order_acquire);
    rb_advance_read(p, w);
    atomic_store_explicit(&p->cb_saw_empty, false, memory_order_release);
    rb_publish_timing(p, w, 0);
}

static uint32_t ca_get_output_channels(AudioDeviceID dev)
{
    if (dev == kAudioObjectUnknown)
        return 0;
    AudioObjectPropertyAddress addr = {
        .mSelector = kAudioDevicePropertyStreamConfiguration,
        .mScope    = kAudioObjectPropertyScopeOutput,
        .mElement  = kAudioObjectPropertyElementMain,
    };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(dev, &addr, 0, NULL, &size) != noErr ||
        size < offsetof(AudioBufferList, mBuffers))
        return 0;
    AudioBufferList *list = malloc(size);
    if (!list)
        return 0;
    uint32_t total = 0;
    if (AudioObjectGetPropertyData(dev, &addr, 0, NULL, &size, list) == noErr) {
        for (UInt32 i = 0; i < list->mNumberBuffers; i++)
            total += list->mBuffers[i].mNumberChannels;
    }
    free(list);
    return total;
}

static OSStatus render_cb_lpcm(void *ctx, AudioUnitRenderActionFlags *aflags,
                               const AudioTimeStamp *ts, UInt32 bus,
                               UInt32 frames, AudioBufferList *buffer_list)
{
    struct ao *ao  = ctx;
    struct priv *p = ao->priv;
    int nplanes    = MPMIN(p->num_planes, (int)buffer_list->mNumberBuffers);
    size_t stride  = p->plane_stride;

    bool active = atomic_load_explicit(&p->playing, memory_order_acquire);
    bool paused = atomic_load_explicit(&p->paused, memory_order_acquire);
    bool muted  = atomic_load_explicit(&p->cb_mute, memory_order_acquire);
    if (!active || paused || muted || !p->rb_data) {
        for (int n = 0; n < nplanes; n++)
            af_fill_silence(buffer_list->mBuffers[n].mData, frames * stride, ao->format);
        return noErr;
    }

    int64_t hw_lat = atomic_load_explicit(&p->hw_latency_ns, memory_order_relaxed);
    int64_t ts_lat = (ts->mFlags & kAudioTimeStampHostTimeValid) ? ca_get_latency(ts) : 0;
    int64_t ear_ns = mp_time_ns() + hw_lat + ts_lat;
    uint64_t r     = atomic_load_explicit(&p->rb_read, memory_order_acquire);
    uint64_t w     = atomic_load_explicit(&p->rb_write, memory_order_acquire);
    uint32_t lead  = 0;

    if (atomic_load_explicit(&p->rebinding, memory_order_acquire)) {
        uint64_t t_pos = 0;
        int64_t t_end  = 0;
        rb_read_timing(p, &t_pos, &t_end);
        if (t_end > 0) {
            int64_t dt_ns = ear_ns - t_end;
            int64_t want  = (int64_t)t_pos + av_rescale(dt_ns, ao->samplerate, 1000000000LL);
            if (want < (int64_t)r) {
                uint64_t wait_frames = (uint64_t)((int64_t)r - want);
                if (wait_frames >= frames) {
                    for (int n = 0; n < nplanes; n++)
                        af_fill_silence(buffer_list->mBuffers[n].mData, frames * stride, ao->format);
                    return noErr;
                }
                lead = (uint32_t)wait_frames;
            } else if ((uint64_t)want > r) {
                if ((uint64_t)want >= w) {
                    rb_advance_read(p, w);
                    rb_publish_timing(p, w, ear_ns);
                    atomic_store_explicit(&p->rebinding, false, memory_order_release);
                    atomic_store_explicit(&p->cb_saw_empty, true, memory_order_release);
                    for (int n = 0; n < nplanes; n++)
                        af_fill_silence(buffer_list->mBuffers[n].mData, frames * stride, ao->format);
                    return noErr;
                }
                r = (uint64_t)want;
            }
        }
        atomic_store_explicit(&p->rebinding, false, memory_order_release);
        uint64_t cur_r = rb_advance_read(p, r);
        if (cur_r > r) {
            uint64_t shift = cur_r - r;
            lead = shift >= frames - lead ? frames : lead + (uint32_t)shift;
            r = cur_r;
        }
        w = atomic_load_explicit(&p->rb_write, memory_order_acquire);
    }

    uint64_t avail = w > r ? w - r : 0;
    uint32_t need  = frames - lead;
    uint32_t copy  = (uint32_t)MPMIN(avail, (uint64_t)need);

    if (copy > 0) {
        uint32_t idx    = (uint32_t)r & p->rb_mask;
        uint32_t first  = MPMIN(copy, p->rb_cap - idx);
        uint32_t second = copy - first;

        for (int n = 0; n < nplanes; n++) {
            char *dst = buffer_list->mBuffers[n].mData;
            if (lead > 0)
                af_fill_silence(dst, lead * stride, ao->format);
            memcpy(dst + (size_t)lead * stride,
                   p->rb_planes[n] + (size_t)idx * stride, first * stride);
            if (second > 0)
                memcpy(dst + (size_t)(lead + first) * stride,
                       p->rb_planes[n], second * stride);
            if (lead + copy < frames)
                af_fill_silence(dst + (size_t)(lead + copy) * stride,
                                (frames - lead - copy) * stride, ao->format);
        }

        uint64_t new_r = rb_advance_read(p, r + copy);
        int64_t end    = ear_ns + ca_frames_to_ns(ao, lead + copy);
        rb_publish_timing(p, new_r, end);

        if (copy < need)
            atomic_store_explicit(&p->cb_saw_empty, true, memory_order_release);
    } else {
        for (int n = 0; n < nplanes; n++)
            af_fill_silence(buffer_list->mBuffers[n].mData, frames * stride, ao->format);
        atomic_store_explicit(&p->cb_saw_empty, true, memory_order_release);
    }

    return noErr;
}

static int get_volume(struct ao *ao, float *vol) {
    struct priv *p = ao->priv;
    float auvol;
    mp_mutex_lock(&p->au_lock);
    OSStatus err = p->audio_unit ?
        AudioUnitGetParameter(p->audio_unit, kHALOutputParam_Volume,
                              kAudioUnitScope_Global, 0, &auvol)
        : kAudioUnitErr_Uninitialized;
    mp_mutex_unlock(&p->au_lock);

    CHECK_CA_ERROR("could not get HAL output volume");
    *vol = auvol * 100.0;
    return CONTROL_TRUE;
coreaudio_error:
    return CONTROL_ERROR;
}

static int set_volume(struct ao *ao, float *vol) {
    struct priv *p = ao->priv;
    float auvol = *vol / 100.0;
    mp_mutex_lock(&p->au_lock);
    OSStatus err = p->audio_unit ?
        AudioUnitSetParameter(p->audio_unit, kHALOutputParam_Volume,
                              kAudioUnitScope_Global, 0, auvol, 0)
        : kAudioUnitErr_Uninitialized;
    mp_mutex_unlock(&p->au_lock);
    CHECK_CA_ERROR("could not set HAL output volume");
    return CONTROL_TRUE;
coreaudio_error:
    return CONTROL_ERROR;
}

static void _prewarm(void *_ao);

static int control(struct ao *ao, enum aocontrol cmd, void *arg)
{
    switch (cmd) {
    case AOCONTROL_GET_VOLUME:
        return get_volume(ao, arg);
    case AOCONTROL_SET_VOLUME:
        return set_volume(ao, arg);
    case AOCONTROL_PREWARM: {
        struct priv *p = ao->priv;
        if (!atomic_load_explicit(&p->shutting_down, memory_order_acquire) &&
            p->rb_data && p->queue &&
            !atomic_load_explicit(&p->unit_running, memory_order_acquire))
        {
            dispatch_async_f(p->queue, ao, &_prewarm);
        }
        return CONTROL_OK;
    }
    }
    return CONTROL_UNKNOWN;
}

static bool init_audiounit(struct ao *ao, AudioStreamBasicDescription asbd,
                           AudioDeviceID dev, AudioUnit *out_au);
static void init_physical_format(struct ao *ao);
static void reinit_latency(struct ao *ao);
static bool register_hotplug_cb(struct ao *ao);
static void unregister_hotplug_cb(struct ao *ao);
static void register_device_cb(struct ao *ao);
static void unregister_device_cb(struct ao *ao);
static void uninit(struct ao *ao);

static bool reinit_device(struct ao *ao) {
    struct priv *p = ao->priv;

    OSStatus err = ca_select_device(ao, ao->device, &p->device);
    CHECK_CA_ERROR("failed to select device");

    return true;

coreaudio_error:
    return false;
}

static int init(struct ao *ao)
{
    struct priv *p = ao->priv;

    if (!af_fmt_is_pcm(ao->format) || (ao->init_flags & AO_INIT_EXCLUSIVE)) {
        MP_VERBOSE(ao, "redirecting to coreaudio_exclusive\n");
        ao->redirect = "coreaudio_exclusive";
        return CONTROL_ERROR;
    }

    if (!reinit_device(ao))
        goto coreaudio_error;

    if (p->change_physical_format)
        init_physical_format(ao);

    p->req_channels = ao->channels;
    if (!ca_init_chmap(ao, p->device))
        goto coreaudio_error;

    AudioStreamBasicDescription asbd;
    ca_fill_asbd(ao, &asbd);

    if (!init_audiounit(ao, asbd, p->device, &p->audio_unit))
        goto coreaudio_error;

    reinit_latency(ao);

    // ao.c computes ao->num_planes and ao->sstride after init() returns.
    bool planar = af_fmt_is_planar(ao->format);
    p->num_planes = planar ? ao->channels.num : 1;
    p->plane_stride = (size_t)af_fmt_to_bytes(ao->format) * (planar ? 1 : ao->channels.num);

    int64_t hw_lat = atomic_load_explicit(&p->hw_latency_ns, memory_order_relaxed);
    int64_t target_ns = MPCLAMP(hw_lat * 2, MP_TIME_MS_TO_NS(340), MP_TIME_MS_TO_NS(400));
    uint32_t target_frames = MPMAX((uint32_t)av_rescale(target_ns, ao->samplerate, 1000000000), 2048);
    uint32_t cap = 65536;
    while (cap < target_frames * 2)
        cap <<= 1;

    p->rb_target = target_frames;
    p->rb_cap    = cap;
    p->rb_mask   = cap - 1;
    p->rb_data   = talloc_size(ao, (size_t)p->num_planes * cap * p->plane_stride);
    if (!p->rb_data)
        goto coreaudio_error;
    for (int n = 0; n < p->num_planes; n++)
        p->rb_planes[n] = p->rb_data + (size_t)n * cap * p->plane_stride;
    rb_clear(p);

    ao->device_buffer = p->rb_target;

    p->queue = dispatch_queue_create("io.mpv.coreaudio_stop_during_idle",
                                     DISPATCH_QUEUE_SERIAL);

    if (!register_hotplug_cb(ao))
        goto coreaudio_error;

    p->init_out_channels = ca_get_output_channels(p->device);
    register_device_cb(ao);

    return CONTROL_OK;

coreaudio_error:
    uninit(ao);
    return CONTROL_ERROR;
}

static void init_physical_format(struct ao *ao)
{
    struct priv *p = ao->priv;
    OSErr err;

    void *tmp = talloc_new(NULL);

    AudioStreamBasicDescription asbd;
    ca_fill_asbd(ao, &asbd);

    AudioStreamID *streams;
    size_t n_streams;

    err = CA_GET_ARY_O(p->device, kAudioDevicePropertyStreams,
                       &streams, &n_streams);
    CHECK_CA_ERROR("could not get number of streams");

    talloc_steal(tmp, streams);

    MP_VERBOSE(ao, "Found %zd substream(s).\n", n_streams);

    for (int i = 0; i < n_streams; i++) {
        AudioStreamRangedDescription *formats;
        size_t n_formats;

        MP_VERBOSE(ao, "Looking at formats in substream %d...\n", i);

        err = CA_GET_ARY(streams[i], kAudioStreamPropertyAvailablePhysicalFormats,
                         &formats, &n_formats);

        if (!CHECK_CA_WARN("could not get number of stream formats"))
            continue; // try next one

        talloc_steal(tmp, formats);

        uint32_t direction;
        err = CA_GET(streams[i], kAudioStreamPropertyDirection, &direction);
        CHECK_CA_ERROR("could not get stream direction");
        if (direction != 0) {
            MP_VERBOSE(ao, "Not an output stream.\n");
            continue;
        }

        AudioStreamBasicDescription best_asbd = {0};

        for (int j = 0; j < n_formats; j++) {
            AudioStreamBasicDescription *stream_asbd = &formats[j].mFormat;

            ca_print_asbd(ao, "- ", stream_asbd);

            if (!best_asbd.mFormatID || ca_asbd_is_better(&asbd, &best_asbd,
                                                          stream_asbd))
                best_asbd = *stream_asbd;
        }

        if (best_asbd.mFormatID) {
            p->original_asbd_stream = streams[i];
            err = CA_GET(p->original_asbd_stream,
                         kAudioStreamPropertyPhysicalFormat,
                         &p->original_asbd);
            CHECK_CA_WARN("could not get current physical stream format");

            if (ca_asbd_equals(&p->original_asbd, &best_asbd)) {
                MP_VERBOSE(ao, "Requested format already set, not changing.\n");
                p->original_asbd.mFormatID = 0;
                break;
            }

            if (!ca_change_physical_format_sync(ao, streams[i], best_asbd))
                p->original_asbd = (AudioStreamBasicDescription){0};
            break;
        }
    }

coreaudio_error:
    talloc_free(tmp);
}

static void log_default_channel_map(struct ao *ao, AudioUnit au)
{
    UInt32 size = 0;
    Boolean writable = false;
    OSStatus err = AudioUnitGetPropertyInfo(au,
                                            kAudioOutputUnitProperty_ChannelMap,
                                            kAudioUnitScope_Output, 0, &size,
                                            &writable);

    if (!CHECK_CA_WARN("unable to query the default channel map")) {
        return;
    }

    SInt32 *map = talloc_size(NULL, size);
    err = AudioUnitGetProperty(au, kAudioOutputUnitProperty_ChannelMap,
                               kAudioUnitScope_Output, 0, map, &size);

    if (CHECK_CA_WARN("unable to read the default channel map")) {
        char *str = talloc_strdup(map, "");
        for (size_t i = 0; i < size / sizeof(SInt32); i++)
            str = talloc_asprintf_append(str, "%s%d", i ? "," : "", map[i]);
        MP_VERBOSE(ao, "default channel map of the audio unit: [%s]\n", str);
    }
    talloc_free(map);
}

static bool init_audiounit(struct ao *ao, AudioStreamBasicDescription asbd,
                           AudioDeviceID dev, AudioUnit *out_au)
{
    OSStatus err;
    uint32_t size;
    AudioUnit au = NULL;

    AudioComponentDescription desc = (AudioComponentDescription) {
        .componentType         = kAudioUnitType_Output,
        .componentSubType      = (ao->device) ?
                                    kAudioUnitSubType_HALOutput :
                                    kAudioUnitSubType_DefaultOutput,
        .componentManufacturer = kAudioUnitManufacturer_Apple,
        .componentFlags        = 0,
        .componentFlagsMask    = 0,
    };

    AudioComponent comp = AudioComponentFindNext(NULL, &desc);
    if (comp == NULL) {
        MP_ERR(ao, "unable to find audio component\n");
        goto coreaudio_error;
    }

    err = AudioComponentInstanceNew(comp, &au);
    CHECK_CA_ERROR("unable to open audio component");

    err = AudioUnitInitialize(au);
    CHECK_CA_ERROR_L(coreaudio_error_component,
                     "unable to initialize audio unit");

    size = sizeof(AudioStreamBasicDescription);
    err = AudioUnitSetProperty(au,
                               kAudioUnitProperty_StreamFormat,
                               kAudioUnitScope_Input, 0, &asbd, size);

    CHECK_CA_ERROR_L(coreaudio_error_audiounit,
                     "unable to set the input format on the audio unit");

    err = AudioUnitSetProperty(au,
                               kAudioOutputUnitProperty_CurrentDevice,
                               kAudioUnitScope_Global, 0, &dev,
                               sizeof(dev));
    CHECK_CA_ERROR_L(coreaudio_error_audiounit,
                     "can't link audio unit to selected device");

    log_default_channel_map(ao, au);

    AURenderCallbackStruct render_cb = (AURenderCallbackStruct) {
        .inputProc       = render_cb_lpcm,
        .inputProcRefCon = ao,
    };

    err = AudioUnitSetProperty(au,
                               kAudioUnitProperty_SetRenderCallback,
                               kAudioUnitScope_Input, 0, &render_cb,
                               sizeof(AURenderCallbackStruct));

    CHECK_CA_ERROR_L(coreaudio_error_audiounit,
                     "unable to set render callback on audio unit");

    *out_au = au;
    return true;

coreaudio_error_audiounit:
    AudioUnitUninitialize(au);
coreaudio_error_component:
    AudioComponentInstanceDispose(au);
coreaudio_error:
    return false;
}

static void reinit_latency(struct ao *ao)
{
    struct priv *p = ao->priv;

    atomic_store_explicit(&p->hw_latency_ns,
                          ca_get_hardware_latency(ao, p->audio_unit, p->device),
                          memory_order_release);
}

static void stop(struct ao *ao)
{
    struct priv *p = ao->priv;
    if (atomic_load_explicit(&p->shutting_down, memory_order_acquire) || !p->audio_unit)
        return;
    if (!atomic_load_explicit(&p->unit_running, memory_order_acquire))
        return;
    OSStatus err = AudioOutputUnitStop(p->audio_unit);
    CHECK_CA_WARN("can't stop audio unit");
    atomic_store_explicit(&p->unit_running, false, memory_order_release);
}

static void cancel_and_release_block(dispatch_block_t *blk)
{
    if (!*blk)
        return;

    dispatch_block_cancel(*blk);
    Block_release(*blk);
    *blk = NULL;
}

static void stop_after_idle_time(struct ao *ao)
{
    struct priv *p = ao->priv;

    cancel_and_release_block(&p->idle_work);
    if (atomic_load_explicit(&p->shutting_down, memory_order_acquire))
        return;

    p->idle_work = dispatch_block_create(0, ^{
        MP_VERBOSE(ao, "Stopping audio unit due to idle timeout\n");
        stop(ao);
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, IDLE_TIME),
                   p->queue, p->idle_work);
}

static void _reset(void *_ao)
{
    struct ao *ao = (struct ao *)_ao;
    struct priv *p = ao->priv;
    if (atomic_load_explicit(&p->shutting_down, memory_order_acquire) || !p->audio_unit)
        return;
    if (atomic_load_explicit(&p->playing, memory_order_acquire) &&
        !atomic_load_explicit(&p->paused, memory_order_acquire))
        return;
    OSStatus err = AudioUnitReset(p->audio_unit, kAudioUnitScope_Global, 0);
    CHECK_CA_WARN("can't reset audio unit");

    // Until the audio unit is stopped the macOS daemon coreaudiod continues to
    // consume CPU and prevent macOS from sleeping. Immediately stopping the
    // audio unit would be disruptive for short pause/resume cycles as
    // restarting the audio unit takes a noticeable amount of time when a
    // wireless audio device is being used. Instead the audio unit is stopped
    // after a delay if it remains idle.
    stop_after_idle_time(ao);
}

static void _idle_stop(void *_ao)
{
    struct ao *ao = (struct ao *)_ao;
    struct priv *p = ao->priv;
    if (atomic_load_explicit(&p->shutting_down, memory_order_acquire) || !p->audio_unit)
        return;
    if (atomic_load_explicit(&p->playing, memory_order_acquire) &&
        !atomic_load_explicit(&p->paused, memory_order_acquire))
        return;
    stop_after_idle_time(ao);
}

static void reset(struct ao *ao)
{
    struct priv *p = ao->priv;
    p->stream_started = false;
    atomic_store_explicit(&p->playing, false, memory_order_release);
    atomic_store_explicit(&p->paused, false, memory_order_release);
    atomic_store_explicit(&p->rebinding, false, memory_order_release);
    rb_clear(p);
    // Must dispatch to serialize reset, start and stop operations.
    dispatch_async_f(p->queue, ao, &_reset);
}

static void _prewarm(void *_ao)
{
    struct ao *ao = (struct ao *)_ao;
    struct priv *p = ao->priv;

    if (atomic_load_explicit(&p->shutting_down, memory_order_acquire) || !p->audio_unit)
        return;

    if (!atomic_load_explicit(&p->unit_running, memory_order_acquire)) {
        MP_VERBOSE(ao, "Pre-warming audio unit on app focus\n");
        OSStatus err = AudioOutputUnitStart(p->audio_unit);
        if (!CHECK_CA_WARN("can't pre-warm audio unit"))
            return;
        atomic_store_explicit(&p->unit_running, true, memory_order_release);
    }

    if (!atomic_load_explicit(&p->playing, memory_order_acquire) ||
        atomic_load_explicit(&p->paused, memory_order_acquire))
        stop_after_idle_time(ao);
}

static void _start(void *_ao)
{
    struct ao *ao = (struct ao *)_ao;
    struct priv *p = ao->priv;

    cancel_and_release_block(&p->idle_work);
    if (atomic_load_explicit(&p->shutting_down, memory_order_acquire) ||
        !p->audio_unit ||
        !atomic_load_explicit(&p->playing, memory_order_acquire) ||
        atomic_load_explicit(&p->paused, memory_order_acquire))
        return;

    if (!atomic_load_explicit(&p->unit_running, memory_order_acquire)) {
        OSStatus err = AudioOutputUnitStart(p->audio_unit);
        if (!CHECK_CA_WARN("can't start audio unit")) {
            atomic_store_explicit(&p->rebinding, false, memory_order_release);
            return;
        }
        atomic_store_explicit(&p->unit_running, true, memory_order_release);
    }
    ao_wakeup(ao);
}

static void start(struct ao *ao)
{
    struct priv *p = ao->priv;
    p->stream_started = true;
    atomic_store_explicit(&p->cb_saw_empty, false, memory_order_relaxed);
    if (!atomic_load_explicit(&p->unit_running, memory_order_acquire)) {
        uint64_t r0 = atomic_load_explicit(&p->rb_read, memory_order_acquire);
        int64_t hw_lat = atomic_load_explicit(&p->hw_latency_ns, memory_order_relaxed);
        rb_publish_timing(p, r0, mp_time_ns() + hw_lat);
        atomic_store_explicit(&p->rebinding, true, memory_order_release);
    }
    atomic_store_explicit(&p->paused, false, memory_order_release);
    atomic_store_explicit(&p->playing, true, memory_order_release);
    // Must dispatch to serialize reset, start and stop operations.
    dispatch_async_f(p->queue, ao, &_start);
}

static bool set_pause(struct ao *ao, bool paused)
{
    struct priv *p = ao->priv;
    if (paused) {
        atomic_store_explicit(&p->paused, true, memory_order_release);
        atomic_store_explicit(&p->rebinding, false, memory_order_release);
        rb_publish_timing(p, atomic_load_explicit(&p->rb_read, memory_order_acquire), 0);
        // Reset hardware buffers immediately and sleep unit after IDLE_TIME,
        // while keeping unread samples intact in the ringbuffer.
        dispatch_async_f(p->queue, ao, &_reset);
    } else {
        atomic_store_explicit(&p->cb_saw_empty, false, memory_order_relaxed);
        if (!atomic_load_explicit(&p->unit_running, memory_order_acquire)) {
            uint64_t r0 = atomic_load_explicit(&p->rb_read, memory_order_acquire);
            int64_t hw_lat = atomic_load_explicit(&p->hw_latency_ns, memory_order_relaxed);
            rb_publish_timing(p, r0, mp_time_ns() + hw_lat);
            atomic_store_explicit(&p->rebinding, true, memory_order_release);
        }
        atomic_store_explicit(&p->paused, false, memory_order_release);
        dispatch_async_f(p->queue, ao, &_start);
    }
    return true;
}

static bool audio_write(struct ao *ao, void **data, int samples)
{
    struct priv *p = ao->priv;
    if (!p->rb_data || samples <= 0)
        return true;

    uint64_t r     = atomic_load_explicit(&p->rb_read, memory_order_acquire);
    uint64_t w     = atomic_load_explicit(&p->rb_write, memory_order_relaxed);
    uint64_t used  = w > r ? w - r : 0;
    uint64_t free_ = used < p->rb_cap ? p->rb_cap - used : 0;
    uint32_t copy  = (uint32_t)MPMIN((uint64_t)samples, free_);

    if (copy > 0) {
        uint32_t idx    = (uint32_t)w & p->rb_mask;
        uint32_t first  = MPMIN(copy, p->rb_cap - idx);
        uint32_t second = copy - first;
        size_t stride   = p->plane_stride;

        for (int n = 0; n < p->num_planes; n++) {
            const char *src = data[n];
            memcpy(p->rb_planes[n] + (size_t)idx * stride, src, first * stride);
            if (second > 0)
                memcpy(p->rb_planes[n], src + first * stride, second * stride);
        }

        atomic_store_explicit(&p->rb_write, w + copy, memory_order_release);
        atomic_store_explicit(&p->cb_saw_empty, false, memory_order_release);
    }

    return true;
}

static void get_state(struct ao *ao, struct mp_pcm_state *state)
{
    struct priv *p = ao->priv;
    uint64_t w     = atomic_load_explicit(&p->rb_write, memory_order_relaxed);
    uint64_t r     = atomic_load_explicit(&p->rb_read, memory_order_acquire);

    uint64_t t_pos = 0;
    int64_t t_end  = 0;
    rb_read_timing(p, &t_pos, &t_end);
    int64_t now = mp_time_ns();

    if (p->stream_started && t_end > 0 && now > t_end &&
        atomic_load_explicit(&p->rebinding, memory_order_acquire) &&
        !atomic_load_explicit(&p->paused, memory_order_acquire))
    {
        uint64_t exp = t_pos + (uint64_t)av_rescale(now - t_end, ao->samplerate, 1000000000LL);
        r = rb_advance_read(p, MPMIN(w, exp));
    }

    uint64_t used = w > r ? w - r : 0;
    state->queued_samples = (int)used;
    state->free_samples   = used < p->rb_target ? (int)(p->rb_target - used) : 0;

    if (t_end > 0) {
        int64_t extra_ns = av_rescale((int64_t)w - (int64_t)t_pos, 1000000000LL, ao->samplerate);
        int64_t rem_ns   = (t_end + extra_ns) - now;
        state->delay     = rem_ns > 0 ? MP_TIME_NS_TO_S(rem_ns) : 0.0;
    } else {
        int64_t hw_lat = atomic_load_explicit(&p->hw_latency_ns, memory_order_relaxed);
        state->delay   = MP_TIME_NS_TO_S(hw_lat) + used / (double)ao->samplerate;
    }

    if (p->stream_started && used == 0 &&
        !atomic_load_explicit(&p->rebinding, memory_order_acquire) &&
        atomic_load_explicit(&p->cb_saw_empty, memory_order_acquire) &&
        (t_end == 0 || now >= t_end))
    {
        p->stream_started = false;
        atomic_store_explicit(&p->playing, false, memory_order_release);
        if (p->queue && !atomic_load_explicit(&p->shutting_down, memory_order_acquire))
            dispatch_async_f(p->queue, ao, &_idle_stop);
    }

    state->playing = p->stream_started;
}

static void uninit(struct ao *ao)
{
    struct priv *p = ao->priv;

    mp_mutex_lock(&p->au_lock);
    atomic_store_explicit(&p->shutting_down, true, memory_order_release);
    dispatch_queue_t q = p->queue;
    mp_mutex_unlock(&p->au_lock);

    atomic_store_explicit(&p->cb_mute, true, memory_order_release);
    atomic_store_explicit(&p->playing, false, memory_order_release);

    unregister_hotplug_cb(ao);

    if (q) {
        dispatch_sync(q, ^{
            cancel_and_release_block(&p->idle_work);
            cancel_and_release_block(&p->retry_work);
            unregister_device_cb(ao);
        });
        p->queue = NULL;
        dispatch_release(q);
    } else {
        unregister_device_cb(ao);
    }

    mp_mutex_lock(&p->au_lock);
    AudioUnit au = p->audio_unit;
    p->audio_unit = NULL;
    atomic_store_explicit(&p->unit_running, false, memory_order_release);
    mp_mutex_unlock(&p->au_lock);

    if (au) {
        AudioOutputUnitStop(au);
        AudioUnitUninitialize(au);
        AudioComponentInstanceDispose(au);
    }

    if (p->original_asbd.mFormatID) {
        OSStatus err = CA_SET(p->original_asbd_stream,
                              kAudioStreamPropertyPhysicalFormat,
                              &p->original_asbd);
        CHECK_CA_WARN("could not restore physical stream format");
    }

    TA_FREEP(&p->rb_data);
}

static void request_reload_once(struct ao *ao)
{
    struct priv *p = ao->priv;
    if (!atomic_exchange(&p->reloading, true))
        ao_request_reload(ao);
}

static void rebind_device_cb(void *_ao);

static void schedule_rebind_retry(struct ao *ao)
{
    struct priv *p = ao->priv;
    if (atomic_load_explicit(&p->shutting_down, memory_order_acquire) || !p->queue)
        return;

    cancel_and_release_block(&p->retry_work);
    p->retry_work = dispatch_block_create(0, ^{
        if (!atomic_load_explicit(&p->shutting_down, memory_order_acquire))
            rebind_device_cb(ao);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC),
                   p->queue, p->retry_work);
}

static void rebind_device_cb(void *_ao)
{
    struct ao *ao = _ao;
    struct priv *p = ao->priv;

    atomic_store_explicit(&p->rebind_pending, false, memory_order_release);
    cancel_and_release_block(&p->retry_work);

    if (atomic_load_explicit(&p->shutting_down, memory_order_acquire))
        return;

    AudioDeviceID cur_device = kAudioObjectUnknown;
    if (ca_select_device(ao, ao->device, &cur_device) != noErr ||
        cur_device == kAudioObjectUnknown)
    {
        if (ao->device && ao->device[0])
            request_reload_once(ao);
        else
            schedule_rebind_retry(ao);
        return;
    }

    uint32_t alive = 1;
    if (CA_GET(cur_device, kAudioDevicePropertyDeviceIsAlive, &alive) != noErr || !alive) {
        if (ao->device && ao->device[0])
            request_reload_once(ao);
        else
            schedule_rebind_retry(ao);
        return;
    }

    uint32_t channels = ca_get_output_channels(cur_device);
    if (p->audio_unit && cur_device == p->device &&
        (!p->init_out_channels || !channels || channels == p->init_out_channels))
    {
        reinit_latency(ao);
        return;
    }

    if (p->change_physical_format) {
        request_reload_once(ao);
        return;
    }

    struct ao probe = *ao;
    probe.channels = p->req_channels;
    if (!ca_init_chmap(&probe, cur_device) ||
        !mp_chmap_equals(&probe.channels, &ao->channels))
    {
        MP_VERBOSE(ao, "Audio route format changed (%u -> %u), reloading\n",
                   (unsigned)p->device, (unsigned)cur_device);
        request_reload_once(ao);
        return;
    }

    MP_VERBOSE(ao, "Rebinding audio route (%u -> %u) in background\n",
               (unsigned)p->device, (unsigned)cur_device);

    atomic_store_explicit(&p->cb_mute, true, memory_order_release);
    atomic_store_explicit(&p->rebinding, true, memory_order_release);
    atomic_store_explicit(&p->cb_saw_empty, false, memory_order_release);
    ao_wakeup(ao);

    cancel_and_release_block(&p->idle_work);
    unregister_device_cb(ao);

    float saved_vol = 1.0f;
    bool has_vol = false;
    mp_mutex_lock(&p->au_lock);
    AudioUnit old_au = p->audio_unit;
    if (old_au &&
        AudioUnitGetParameter(old_au, kHALOutputParam_Volume,
                              kAudioUnitScope_Global, 0, &saved_vol) == noErr)
    {
        has_vol = true;
    }
    p->audio_unit = NULL;
    atomic_store_explicit(&p->unit_running, false, memory_order_release);
    mp_mutex_unlock(&p->au_lock);

    if (old_au) {
        AudioOutputUnitStop(old_au);
        AudioUnitUninitialize(old_au);
        AudioComponentInstanceDispose(old_au);
    }

    if (atomic_load_explicit(&p->shutting_down, memory_order_acquire)) {
        atomic_store_explicit(&p->rebinding, false, memory_order_release);
        return;
    }

    AudioStreamBasicDescription asbd;
    ca_fill_asbd(ao, &asbd);

    AudioUnit new_au = NULL;
    if (!init_audiounit(ao, asbd, cur_device, &new_au)) {
        atomic_store_explicit(&p->rebinding, false, memory_order_release);
        request_reload_once(ao);
        return;
    }

    if (has_vol) {
        AudioUnitSetParameter(new_au, kHALOutputParam_Volume,
                              kAudioUnitScope_Global, 0, saved_vol, 0);
    }

    p->device = cur_device;
    p->init_out_channels = channels;
    atomic_store_explicit(&p->hw_latency_ns,
                          ca_get_hardware_latency(ao, new_au, cur_device),
                          memory_order_release);
    register_device_cb(ao);

    mp_mutex_lock(&p->au_lock);
    p->audio_unit = new_au;
    mp_mutex_unlock(&p->au_lock);

    atomic_store_explicit(&p->cb_mute, false, memory_order_release);

    if (atomic_load_explicit(&p->playing, memory_order_acquire) &&
        !atomic_load_explicit(&p->paused, memory_order_acquire))
    {
        OSStatus err = AudioOutputUnitStart(new_au);
        if (!CHECK_CA_WARN("can't start rebound audio unit"))
            atomic_store_explicit(&p->rebinding, false, memory_order_release);
        else
            atomic_store_explicit(&p->unit_running, true, memory_order_release);
        ao_wakeup(ao);
    } else {
        atomic_store_explicit(&p->rebinding, false, memory_order_release);
        stop_after_idle_time(ao);
    }
}

static void hotplug_debounce_cb(void *_ao)
{
    struct ao *ao = _ao;
    struct priv *p = ao->priv;

    atomic_store_explicit(&p->rebind_pending, false, memory_order_release);
    if (atomic_load_explicit(&p->shutting_down, memory_order_acquire))
        return;

    cancel_and_release_block(&p->retry_work);
    p->retry_work = dispatch_block_create(0, ^{
        if (!atomic_load_explicit(&p->shutting_down, memory_order_acquire))
            ao_hotplug_event(ao);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 800 * NSEC_PER_MSEC),
                   p->queue, p->retry_work);
}

static void schedule_queue_work(struct ao *ao, dispatch_function_t fn)
{
    struct priv *p = ao->priv;
    mp_mutex_lock(&p->au_lock);
    if (!atomic_load_explicit(&p->shutting_down, memory_order_acquire) &&
        p->queue && !atomic_exchange(&p->rebind_pending, true))
        dispatch_async_f(p->queue, ao, fn);
    mp_mutex_unlock(&p->au_lock);
}

static OSStatus hotplug_cb(AudioObjectID id, UInt32 naddr,
                           const AudioObjectPropertyAddress addr[],
                           void *ctx)
{
    struct ao *ao = ctx;
    struct priv *p = ao->priv;
    if (atomic_load_explicit(&p->shutting_down, memory_order_acquire))
        return noErr;
    MP_VERBOSE(ao, "Handling potential hotplug event...\n");
    if (p->rb_data)
        schedule_queue_work(ao, &rebind_device_cb);
    else
        schedule_queue_work(ao, &hotplug_debounce_cb);
    return noErr;
}

static const AudioObjectPropertyAddress device_properties[] = {
    { kAudioDevicePropertyDeviceIsAlive,
      kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
    { kAudioDevicePropertyStreamConfiguration,
      kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain },
    { kAudioDevicePropertyNominalSampleRate,
      kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
};

static OSStatus device_listener_cb(AudioObjectID id, UInt32 naddr,
                                   const AudioObjectPropertyAddress addr[],
                                   void *ctx)
{
    struct ao *ao = ctx;
    struct priv *p = ao->priv;
    if (id != p->device || atomic_load_explicit(&p->shutting_down, memory_order_acquire))
        return noErr;

    schedule_queue_work(ao, &rebind_device_cb);
    return noErr;
}

static void register_device_cb(struct ao *ao)
{
    struct priv *p = ao->priv;
    if (p->device == kAudioObjectUnknown || p->device_listener_registered)
        return;

    for (int i = 0; i < MP_ARRAY_SIZE(device_properties); i++) {
        AudioObjectAddPropertyListener(
            p->device, &device_properties[i], device_listener_cb, (void *)ao);
    }
    p->device_listener_registered = true;
}

static void unregister_device_cb(struct ao *ao)
{
    struct priv *p = ao->priv;
    if (!p->device_listener_registered)
        return;

    for (int i = 0; i < MP_ARRAY_SIZE(device_properties); i++) {
        AudioObjectRemovePropertyListener(
            p->device, &device_properties[i], device_listener_cb, (void *)ao);
    }
    p->device_listener_registered = false;
}

static uint32_t hotplug_properties[] = {
    kAudioHardwarePropertyDevices,
    kAudioHardwarePropertyDefaultOutputDevice
};

static void hotplug_uninit(struct ao *ao)
{
    struct priv *p = ao->priv;
    mp_mutex_lock(&p->au_lock);
    atomic_store_explicit(&p->shutting_down, true, memory_order_release);
    dispatch_queue_t q = p->queue;
    mp_mutex_unlock(&p->au_lock);

    unregister_hotplug_cb(ao);

    if (q) {
        dispatch_sync(q, ^{
            cancel_and_release_block(&p->retry_work);
        });
        p->queue = NULL;
        dispatch_release(q);
    }
}

static int hotplug_init(struct ao *ao)
{
    struct priv *p = ao->priv;
    p->queue = dispatch_queue_create("io.mpv.coreaudio_hotplug",
                                     DISPATCH_QUEUE_SERIAL);
    if (!p->queue || !register_hotplug_cb(ao)) {
        hotplug_uninit(ao);
        return -1;
    }

    return 0;
}

static bool register_hotplug_cb(struct ao *ao)
{
    struct priv *p = ao->priv;

    if (p->hotplug_cb_registration_times++)
        return true;

    int count = p->rb_data ? MP_ARRAY_SIZE(hotplug_properties) : 1;
    p->hotplug_prop_count = 0;

    OSStatus err = noErr;
    for (int i = 0; i < count; i++) {
        AudioObjectPropertyAddress addr = {
            hotplug_properties[i],
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        };
        err = AudioObjectAddPropertyListener(
            kAudioObjectSystemObject, &addr, hotplug_cb, (void *)ao);
        if (err != noErr) {
            char *c1 = mp_tag_str(hotplug_properties[i]);
            char *c2 = mp_tag_str(err);
            MP_ERR(ao, "failed to set device listener %s (%s)", c1, c2);
            goto coreaudio_error;
        }
        p->hotplug_prop_count = i + 1;
    }

    return true;

coreaudio_error:
    return false;
}

static void unregister_hotplug_cb(struct ao *ao)
{
    struct priv *p = ao->priv;

    if (p->hotplug_cb_registration_times <= 0 || --p->hotplug_cb_registration_times)
        return;

    OSStatus err = noErr;
    for (int i = 0; i < p->hotplug_prop_count; i++) {
        AudioObjectPropertyAddress addr = {
            hotplug_properties[i],
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        };
        err = AudioObjectRemovePropertyListener(
            kAudioObjectSystemObject, &addr, hotplug_cb, (void *)ao);
        if (err != noErr) {
            char *c1 = mp_tag_str(hotplug_properties[i]);
            char *c2 = mp_tag_str(err);
            MP_ERR(ao, "failed to set device listener %s (%s)", c1, c2);
        }
    }
    p->hotplug_prop_count = 0;
}

#define OPT_BASE_STRUCT struct priv

const struct ao_driver audio_out_coreaudio = {
    .description    = "CoreAudio AudioUnit",
    .name           = "coreaudio",
    .uninit         = uninit,
    .init           = init,
    .control        = control,
    .reset          = reset,
    .start          = start,
    .set_pause      = set_pause,
    .write          = audio_write,
    .get_state      = get_state,
    .hotplug_init   = hotplug_init,
    .hotplug_uninit = hotplug_uninit,
    .list_devs      = ca_get_device_list,
    .priv_size      = sizeof(struct priv),
    .priv_defaults  = &(const struct priv){
        .sem = (struct coreaudio_cb_sem){
            .mutex = MP_STATIC_MUTEX_INITIALIZER,
            .cond = MP_STATIC_COND_INITIALIZER,
        },
        .au_lock = MP_STATIC_MUTEX_INITIALIZER,
    },
    .options = (const struct m_option[]){
        {"change-physical-format", OPT_BOOL(change_physical_format)},
        {0}
    },
    .options_prefix = "coreaudio",
};
