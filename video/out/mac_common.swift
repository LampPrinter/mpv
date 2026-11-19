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

import Cocoa
import QuartzCore

private final class LiveResizeLinkTarget: NSObject {
    weak var common: MacCommon?
    @objc func tick(_ sender: AnyObject) {
        common?.liveResizeDisplayLinkTick()
    }
}

class MacCommon: Common {
    @objc var layer: MetalLayer?

    var presentation: Presentation?
    var timer: PreciseTimer?
    var swapTime: UInt64 = 0
    var swapQuitting: Bool = false
    let swapLock: NSCondition = NSCondition()
    private let liveResizeLinkTarget = LiveResizeLinkTarget()
    private var liveResizeDisplayLink: AnyObject?
    private var isLiveResizeActive: Bool = false
    private var lastLiveResizeSignalNs: Int64 = 0

    @objc init(_ vo: UnsafeMutablePointer<vo>) {
        let log = LogHelper(mp_log_new(vo, vo.pointee.log, "mac"))
        let option = OptionHelper(vo, vo.pointee.global)
        super.init(option, log)
        liveResizeLinkTarget.common = self
        eventsLock.withLock { self.vo = vo }
        input = InputHelper(vo.pointee.input_ctx, option)
        presentation = Presentation(common: self)
        timer = PreciseTimer(common: self)

        DispatchQueue.main.sync {
            layer = MetalLayer(common: self)
            initMisc(vo)
        }
    }

    @objc func config(_ vo: UnsafeMutablePointer<vo>) -> Bool {
        eventsLock.withLock { self.vo = vo }
        let (wasForceWindow, isForceWindow) = updateVideoDisplaySize(vo)

        DispatchQueue.main.sync {
            let previousActiveApp = getActiveApp()
            initApp()

            let (screen, wr, forcePosition) = getInitProperties(vo)
            guard let layer = self.layer else {
                log.error("Something went wrong, no MetalLayer was initialized")
                exit(1)
            }

            let createdWindow = (window == nil)
            if createdWindow {
                initView(vo, layer)
                initWindow(vo, previousActiveApp)
                initWindowState()
            } else {
                window?.cancelPinchSession(notifyDone: false)
            }

            if isForceWindow {
                window?.resetVideoReferenceBox()
                window?.notifyAutoResizeDone()
                if forcePosition {
                    window?.updateFrame(wr, screen)
                } else if !createdWindow && option.vo.auto_window_resize {
                    window?.updateSize(wr.size)
                }
            } else {
                if forcePosition {
                    window?.updateFrame(wr, screen)
                }
                if Bool(option.vo.keepaspect) && !(window?.isInFullscreen ?? false) {
                    let fromIdle = createdWindow || wasForceWindow
                    window?.startAutoAspectTransition(fromIdle: fromIdle, suggestedSize: wr.size)
                } else {
                    if !forcePosition && !createdWindow && option.vo.auto_window_resize {
                        window?.updateSize(wr.size)
                    }
                    window?.notifyAutoResizeDone()
                }
            }

            if option.vo.focus_on == 2 {
                NSApp.activate(ignoringOtherApps: true)
            }

            updateCachedWindowGeometry()
            windowDidResize()
            updateICCProfile()
            _ = updateEDRState()
        }

        return true
    }

    @objc func prepareUninit() {
        layer?.invalidateEDRSync()
        swapLock.lock()
        pacedLiveResize = false
        swapQuitting = true
        swapTime += 1
        swapLock.broadcast()
        swapLock.unlock()
        if Thread.isMainThread {
            prepareForQuit()
            CATransaction.flush()
        } else {
            DispatchQueue.main.sync {
                self.prepareForQuit()
                CATransaction.flush()
            }
        }
        window?.waitForAnimation()
    }

    override func prepareForQuit() {
        stopLiveResizeDisplayLink(invalidate: true)
        layer?.invalidateEDRSync()
        layer?.disableDisplaySyncForQuit()
        swapLock.lock()
        pacedLiveResize = false
        swapQuitting = true
        swapTime += 1
        swapLock.broadcast()
        swapLock.unlock()
        super.prepareForQuit()
    }

    @objc func uninit(_ vo: UnsafeMutablePointer<vo>) {
        window?.waitForAnimation()

        stopDisplaylink()
        timer?.terminate()

        DispatchQueue.main.sync {
            stopLiveResizeDisplayLink(invalidate: true)
            layer?.invalidateEDRSync()
            window?.delegate = nil
            window?.close()

            uninitCommon()
        }
    }

    // pace rendering with the display link during live resize, since display sync of the layer is
    // disabled then and acquiring the next drawable doesn't block until the next vsync anymore
    var pacedLiveResize: Bool = false

    private func startLiveResizeDisplayLink() {
        guard #available(macOS 14.0, *), let win = window else { return }
        let link: CADisplayLink
        if let existing = liveResizeDisplayLink as? CADisplayLink {
            link = existing
        } else {
            let created = win.displayLink(target: liveResizeLinkTarget,
                                          selector: #selector(LiveResizeLinkTarget.tick(_:)))
            created.add(to: .main, forMode: .common)
            liveResizeDisplayLink = created
            link = created
        }
        let maxFps = Float(max(win.screen?.maximumFramesPerSecond ?? 120, 24))
        let minFps: Float = maxFps >= 120 ? 80 : min(60, maxFps)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: minFps,
                                                        maximum: maxFps,
                                                        preferred: maxFps)
        link.isPaused = false
    }

    private func stopLiveResizeDisplayLink(invalidate: Bool) {
        guard #available(macOS 14.0, *) else { return }
        let stopBlock = {
            if let link = self.liveResizeDisplayLink as? CADisplayLink {
                link.isPaused = true
                if invalidate {
                    link.invalidate()
                    self.liveResizeDisplayLink = nil
                }
            }
        }
        if Thread.isMainThread {
            stopBlock()
        } else {
            DispatchQueue.main.async(execute: stopBlock)
        }
    }

    override var hasMainThreadLiveResizeDisplayLink: Bool {
        if #available(macOS 14.0, *) {
            return isLiveResizeActive && liveResizeDisplayLink != nil
        }
        return false
    }

    override func setLiveResizeContentsGravity(_ gravity: CALayerContentsGravity) {
        layer?.liveResizeGravity = gravity
    }

    func liveResizeDisplayLinkTick() {
        window?.stepPinchBorderAnimation()
        signalLiveResizeSwap()
    }

    @objc func isLiveResizing() -> Bool {
        swapLock.lock()
        let active = pacedLiveResize
        swapLock.unlock()
        return active
    }

    @objc func pixelSize() -> CGSize {
        return geometryLock.withLock { cachedFramePixelSize }
    }

    func signalLiveResizeSwap() {
        let fps = max(geometryLock.withLock { nominalDisplayFps }, 60.0)
        let minIntervalNs = Int64(0.65 * 1_000_000_000.0 / fps)
        let now = mp_time_ns()
        swapLock.lock()
        if pacedLiveResize {
            if now - lastLiveResizeSignalNs >= minIntervalNs {
                lastLiveResizeSignalNs = now
                swapTime = 1
                swapLock.signal()
            }
        }
        swapLock.unlock()
    }

    @objc func swapBuffer() {
        let maxWait = 1.25 / max(geometryLock.withLock { nominalDisplayFps }, 60.0)
        swapLock.lock()
        if option.mac.macos_render_timer > RENDER_TIMER_SYSTEM {
            while swapTime < 1 && !swapQuitting &&
                  option.mac.macos_render_timer > RENDER_TIMER_SYSTEM {
                swapLock.wait()
            }
            swapTime = 0
        } else if pacedLiveResize {
            if swapTime < 1 && !swapQuitting {
                _ = swapLock.wait(until: Date(timeIntervalSinceNow: maxWait))
            }
            swapTime = 0
        }
        swapLock.unlock()
    }

    @objc func fillVsync(info: UnsafeMutablePointer<vo_vsync_info>) {
        if option.mac.macos_render_timer != RENDER_TIMER_PRESENTATION_FEEDBACK { return }
        if isLiveResizing() { return }

        let next = presentation?.next()
        info.pointee.vsync_duration = next?.duration ?? -1
        info.pointee.skipped_vsyncs = next?.skipped ?? -1
        info.pointee.last_queue_display_time = next?.time ?? -1
    }

    @objc func isVisible() -> Bool {
        swapLock.lock()
        let quitting = swapQuitting
        swapLock.unlock()
        if quitting { return false }
        return window?.occlusionState.contains(.visible) ?? false ||
               option.vo.force_render ||
               needsInitialDraw
    }

    @objc func update(alpha: Bool) {
        layer?.wantsAlpha = alpha
        DispatchQueue.main.sync {
            window?.isOpaque = !alpha
            window?.backgroundColor = alpha ? NSColor.clear : NSColor.black
        }
    }

    @objc(maxPotentialEDR)
    func maxPotentialEDR() -> Float {
        return edrLock.withLock { cachedMaxPotentialEDR }
    }

    @objc(currentMaxEDR)
    func currentMaxEDR() -> Float {
        return edrLock.withLock { cachedMaxEDR }
    }

    @objc(maxReferenceEDR)
    func maxReferenceEDR() -> Float {
        return edrLock.withLock { cachedMaxRefEDR }
    }

    @objc(isHDRActive)
    func isHDRActive() -> Bool {
        return layer?.isHDRActive() ?? false
    }

    @objc(updateHDRStateWithActive:isHLG:minLuma:maxLuma:)
    func updateHDRState(active: Bool, isHLG: Bool, minLuma: Float, maxLuma: Float) {
        layer?.updateHDRState(active: active, isHLG: isHLG, minLuma: minLuma, maxLuma: maxLuma)
    }

    func signalSwap() {
        swapLock.lock()
        swapTime += 1
        swapLock.signal()
        swapLock.unlock()
    }

    override func displayLinkCallback(_ displayLink: CVDisplayLink,
                                      _ inNow: UnsafePointer<CVTimeStamp>,
                                      _ inOutputTime: UnsafePointer<CVTimeStamp>,
                                      _ flagsIn: CVOptionFlags,
                                      _ flagsOut: UnsafeMutablePointer<CVOptionFlags>) -> CVReturn {
        let signalSwap = { self.signalSwap() }

        if option.mac.macos_render_timer > RENDER_TIMER_SYSTEM {
            if let timer = self.timer, option.mac.macos_render_timer == RENDER_TIMER_PRECISE {
                timer.scheduleAt(time: inOutputTime.pointee.hostTime, closure: signalSwap)
                return kCVReturnSuccess
            }

            signalSwap()
            return kCVReturnSuccess
        }

        let isPaced = isLiveResizing()
        if option.mac.macos_render_timer == RENDER_TIMER_PRESENTATION_FEEDBACK && !isPaced {
            presentation?.add(time: inOutputTime.pointee)
        }

        if isPaced {
            signalLiveResizeSwap()
        }

        return kCVReturnSuccess
    }

    override func startDisplayLink(_ vo: UnsafeMutablePointer<vo>) {
        super.startDisplayLink(vo)
        timer?.updatePolicy(periodSeconds: 1 / currentFps())
    }

    override func updateDisplaylink() {
        super.updateDisplaylink()
        timer?.updatePolicy(periodSeconds: 1 / currentFps())
    }

    override func updateICCProfile() {
        flagEvents(VO_EVENT_ICC_PROFILE_CHANGED)
    }

    override func windowWillStartLiveResize() {
        guard !isLiveResizeActive else { return }
        isLiveResizeActive = true
        startLiveResizeDisplayLink()
        presentation?.reset()
        swapLock.lock()
        lastLiveResizeSignalNs = 0
        swapTime = 0
        pacedLiveResize = true
        swapLock.unlock()
        layer?.inLiveResize = true
    }

    override func windowDidEndLiveResize() {
        guard isLiveResizeActive else { return }
        isLiveResizeActive = false
        stopLiveResizeDisplayLink(invalidate: false)
        presentation?.reset()
        layer?.inLiveResize = false
        swapLock.lock()
        if pacedLiveResize {
            pacedLiveResize = false
            // release a possibly waiting render thread, the display link doesn't signal anymore
            swapTime = 1
            swapLock.broadcast()
        }
        swapLock.unlock()
        updateCachedWindowGeometry()
        windowDidResize()
    }

    override func windowDidResize() {
        flagEvents(VO_EVENT_RESIZE | VO_EVENT_EXPOSE)
    }

    override func windowDidChangeScreen() {
        if !isLiveResizeActive {
            stopLiveResizeDisplayLink(invalidate: true)
        }
        refreshNominalDisplayFps()
        _ = updateEDRState()
        flagEvents(VO_EVENT_WIN_STATE | VO_EVENT_ICC_PROFILE_CHANGED | VO_EVENT_EXPOSE)
    }

    override func windowDidChangeScreenProfile() {
        let ev = updateEDRState()
        if ev != 0 {
            flagEvents(ev)
        }
        updateICCProfile()
    }

    override func windowDidChangeBackingProperties() {
        layer?.contentsScale = window?.backingScaleFactor ?? 1
        windowDidResize()
    }

    override func windowDidChangeOcclusionState() {
        flagEvents(VO_EVENT_EXPOSE)
    }
}
