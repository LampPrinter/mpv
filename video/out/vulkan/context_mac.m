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

#include <math.h>

#import <QuartzCore/QuartzCore.h>

#include "video/out/gpu/context.h"
#include "osdep/mac/swift.h"

#include "common.h"
#include "context.h"
#include "utils.h"

struct priv {
    struct mpvk_ctx vk;
    MacCommon *vo_mac;
};

static void mac_vk_uninit(struct ra_ctx *ctx)
{
    struct priv *p = ctx->priv;

    [p->vo_mac prepareUninit];
    ra_vk_ctx_uninit(ctx);
    mpvk_uninit(&p->vk);
    [p->vo_mac uninit:ctx->vo];
}

static void mac_vk_swap_buffers(struct ra_ctx *ctx)
{
    struct priv *p = ctx->priv;
    [p->vo_mac swapBuffer];
}

static void mac_vk_get_vsync(struct ra_ctx *ctx, struct vo_vsync_info *info)
{
    struct priv *p = ctx->priv;
    [p->vo_mac fillVsyncWithInfo:info];
}

static int mac_vk_color_depth(struct ra_ctx *ctx)
{
    return 0;
}

static bool mac_vk_check_visible(struct ra_ctx *ctx)
{
    struct priv *p = ctx->priv;
    return [p->vo_mac isVisible];
}

static pl_color_space_t mac_vk_preferred_csp(struct ra_ctx *ctx)
{
    struct priv *p = ctx->priv;
    float max_pot_edr = [p->vo_mac maxPotentialEDR];
    if (max_pot_edr > 1.01f) {
        float display_peak = MPMAX(max_pot_edr * 100.0f, PL_COLOR_SDR_WHITE);
        return (pl_color_space_t) {
            .primaries = PL_COLOR_PRIM_BT_2020,
            .transfer  = PL_COLOR_TRC_PQ,
            .hdr = {
                .min_luma = 0.0001f,
                .max_luma = display_peak,
            },
        };
    }
    return (pl_color_space_t) {
        .primaries = PL_COLOR_PRIM_DISPLAY_P3,
        .transfer  = PL_COLOR_TRC_SRGB,
        .hdr = {
            .max_luma = PL_COLOR_SDR_WHITE,
        },
    };
}

static float mac_vk_preferred_ref_luma(struct ra_ctx *ctx)
{
    struct priv *p = ctx->priv;
    if (![p->vo_mac isHDRActive])
        return 0.0f;

    if ([p->vo_mac maxReferenceEDR] > 0.01f)
        return 100.0f;

    float max_pot = [p->vo_mac maxPotentialEDR];
    float cur_max = [p->vo_mac currentMaxEDR];
    if (max_pot <= 1.01f || cur_max <= 0.01f)
        return 206.0f;

    // Estimate current macOS SDR white in nits (e.g. 200 nits at maxEDR=8, 600 nits at maxEDR=2.67)
    // and compensate for CoreAnimation CAEDRMetadata.hdr10's headroom roll-off so SDR UI matches 1.0 SDR white.
    float sdr_ratio = MPCLAMP((max_pot * 100.0f) / (MPMAX(cur_max, 1.0f) * PL_COLOR_SDR_WHITE), 1.0f, 3.0f);
    float luma = 206.0f * powf(sdr_ratio, 0.35f);
    return roundf(luma * 0.1f) * 10.0f;
}

static bool mac_vk_set_color(struct ra_ctx *ctx, struct mp_image_params *params)
{
    struct priv *p = ctx->priv;
    if (!params || !pl_color_transfer_is_hdr(params->color.transfer)) {
        [p->vo_mac updateHDRStateWithActive:NO isHLG:NO minLuma:0.0f maxLuma:0.0f];
        return false;
    }

    float max_pot_edr = [p->vo_mac maxPotentialEDR];
    if (max_pot_edr <= 1.01f) {
        // Current screen is SDR-only: disable EDR and let libplacebo tone-map to Display P3 SDR
        [p->vo_mac updateHDRStateWithActive:NO isHLG:NO minLuma:0.0f maxLuma:0.0f];
        params->color = (struct pl_color_space) {
            .primaries = PL_COLOR_PRIM_DISPLAY_P3,
            .transfer  = PL_COLOR_TRC_SRGB,
            .hdr = {
                .max_luma = PL_COLOR_SDR_WHITE,
            },
        };
        pl_swapchain_colorspace_hint(p->vk.swapchain, &params->color);
        return true;
    }

    // Output flicker-free 10-bit BT.2100 PQ (VK_FORMAT_A2R10G10B10_UNORM_PACK32 +
    // VK_COLOR_SPACE_HDR10_ST2084_EXT -> bgr10a2Unorm + kCGColorSpaceITUR_2100_PQ)
    // with static display peak luminance so libplacebo avoids per-scene 3D-LUT compression.
    float display_peak = MPMAX(max_pot_edr * 100.0f, PL_COLOR_SDR_WHITE);
    if (params->color.transfer == PL_COLOR_TRC_PQ ||
        params->color.transfer == PL_COLOR_TRC_HLG)
    {
        [p->vo_mac updateHDRStateWithActive:YES
                                      isHLG:NO
                                    minLuma:0.0001f
                                    maxLuma:display_peak];

        params->color = (struct pl_color_space) {
            .primaries = PL_COLOR_PRIM_BT_2020,
            .transfer  = PL_COLOR_TRC_PQ,
            .hdr = {
                .min_luma = 0.0001f,
                .max_luma = display_peak,
                .max_cll  = display_peak,
            },
        };
        pl_swapchain_colorspace_hint(p->vk.swapchain, &params->color);
        return true;
    }

    // User explicitly forced another HDR transfer (e.g. scrgb): keep active
    [p->vo_mac updateHDRStateWithActive:YES isHLG:NO minLuma:0.0001f maxLuma:display_peak];
    return false;
}

static bool mac_vk_init(struct ra_ctx *ctx)
{
    struct priv *p = ctx->priv = talloc_zero(ctx, struct priv);
    struct mpvk_ctx *vk = &p->vk;
    int msgl = ctx->opts.probing ? MSGL_V : MSGL_ERR;

    if (!NSApp) {
        MP_ERR(ctx, "Failed to initialize macvk context, no NSApplication initialized.\n");
        goto error;
    }

    if (!mpvk_init(vk, ctx, VK_EXT_METAL_SURFACE_EXTENSION_NAME))
        goto error;

    p->vo_mac = [[MacCommon alloc] init:ctx->vo];
    if (!p->vo_mac)
        goto error;

    VkMetalSurfaceCreateInfoEXT mac_info = {
        .sType = VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT,
        .pNext = NULL,
        .flags = 0,
        .pLayer = p->vo_mac.layer,
    };

    struct ra_ctx_params params = {
        .swap_buffers = mac_vk_swap_buffers,
        .get_vsync = mac_vk_get_vsync,
        .color_depth = mac_vk_color_depth,
        .preferred_csp = mac_vk_preferred_csp,
        .preferred_ref_luma = mac_vk_preferred_ref_luma,
        .set_color = mac_vk_set_color,
        .check_visible = mac_vk_check_visible,
    };

    VkInstance inst = vk->vkinst->instance;
    VkResult res = vkCreateMetalSurfaceEXT(inst, &mac_info, NULL, &vk->surface);
    if (res != VK_SUCCESS) {
        MP_MSG(ctx, msgl, "Failed creating metal surface\n");
        goto error;
    }

    if (!ra_vk_ctx_init(ctx, vk, params, VK_PRESENT_MODE_FIFO_KHR))
        goto error;

    return true;
error:
    if (p->vo_mac)
        [p->vo_mac uninit:ctx->vo];
    return false;
}

static bool resize(struct ra_ctx *ctx)
{
    struct priv *p = ctx->priv;

    if (!p->vo_mac.window) {
        return false;
    }
    CGSize size = [p->vo_mac pixelSize];
    if (size.width < 1 || size.height < 1)
        size = p->vo_mac.window.framePixel.size;

    return ra_vk_ctx_resize(ctx, (int)size.width, (int)size.height);
}

static bool mac_vk_reconfig(struct ra_ctx *ctx)
{
    struct priv *p = ctx->priv;
    if (![p->vo_mac config:ctx->vo])
        return false;

    [p->vo_mac updateWithAlpha:ctx->opts.want_alpha];

    return true;
}

static int mac_vk_control(struct ra_ctx *ctx, int *events, int request, void *arg)
{
    struct priv *p = ctx->priv;
    int ret = [p->vo_mac control:ctx->vo events:events request:request data:arg];

    // let the renderer use cheap settings while the window is being resized
    bool live_resize = [p->vo_mac isLiveResizing];
    if (ctx->vo->live_resize != live_resize) {
        ctx->vo->live_resize = live_resize;
        // render again with the full quality settings once the live resize ended
        if (!live_resize)
            ctx->vo->want_redraw = true;
    }

    if (*events & VO_EVENT_RESIZE) {
        if (!resize(ctx))
            return VO_ERROR;
    }

    return ret;
}

static void mac_vk_update_render_opts(struct ra_ctx *ctx)
{
    struct priv *p = ctx->priv;
    [p->vo_mac updateWithAlpha:ctx->opts.want_alpha];
}

const struct ra_ctx_fns ra_ctx_vulkan_mac = {
    .type               = "vulkan",
    .name               = "macvk",
    .description        = "mac/Vulkan (via Metal)",
    .reconfig           = mac_vk_reconfig,
    .control            = mac_vk_control,
    .update_render_opts = mac_vk_update_render_opts,
    .init               = mac_vk_init,
    .uninit             = mac_vk_uninit,
};
