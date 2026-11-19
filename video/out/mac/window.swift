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

class Window: NSWindow, NSWindowDelegate {
    weak var common: Common! = nil
    var option: OptionHelper { return common.option }
    var input: InputHelper? { return common.input }

    var targetScreen: NSScreen?
    var previousScreen: NSScreen?
    var currentScreen: NSScreen?
    var unfScreen: NSScreen?

    var unfsContentFrame: NSRect = NSRect(x: 0, y: 0, width: 160, height: 90)
    var isInFullscreen: Bool = false
    var isMoving: Bool = false
    var previousStyleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]

    var isAnimating: Bool = false
    let animationLock: NSCondition = NSCondition()

    var unfsContentFramePixel: NSRect { return convertToBacking(unfsContentFrame) }
    @objc var framePixel: NSRect { return convertToBacking(frame) }

    var keepAspect: Bool = true {
        didSet {
            if let contentViewFrame = contentView?.frame, !isInFullscreen {
                unfsContentFrame = convertToScreen(contentViewFrame)
            }

            if keepAspect {
                contentAspectRatio = unfsContentFrame.size
            } else {
                resizeIncrements = NSSize(width: 1.0, height: 1.0)
            }
        }
    }

    var border: Bool = true {
        didSet { if !border { common.titleBar?.hide() } }
    }

    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return true }

    override var styleMask: NSWindow.StyleMask {
        get { return super.styleMask }
        set {
            let responder = firstResponder
            let windowTitle = title
            previousStyleMask = super.styleMask
            super.styleMask = newValue
            makeFirstResponder(responder)
            title = windowTitle
        }
    }

    convenience init(contentRect: NSRect, screen: NSScreen?, view: NSView, common com: Common) {
        self.init(contentRect: contentRect,
                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                  backing: .buffered, defer: false, screen: screen)

        // workaround for an AppKit bug where the NSWindow can't be placed on a
        // none Main screen NSScreen outside the Main screen's frame bounds
        if screen != NSScreen.main {
            let absolutePos = absolutePosition(for: contentRect, screen: screen)

            if absolutePos.origin != self.frame.origin {
                self.setFrameOrigin(absolutePos.origin)
            }
        }

        common = com
        title = com.title
        minSize = NSSize(width: 160, height: 90)
        backgroundColor = .black
        collectionBehavior = .fullScreenPrimary
        ignoresMouseEvents = option.vo.cursor_passthrough
        delegate = self
        unfsContentFrame = contentRect

        if let cView = contentView {
            cView.addSubview(view)
            view.frame = cView.frame
            unfsContentFrame = convertToScreen(cView.frame)
        }

        targetScreen = screen
        currentScreen = screen
        unfScreen = screen

        AppHub.shared.menu?.register(#selector(setHalfWindowSize), key: .itemHalfSize)
        AppHub.shared.menu?.register(#selector(setNormalWindowSize), key: .itemNormalSize)
        AppHub.shared.menu?.register(#selector(setDoubleWindowSize), key: .itemDoubleSize)
        AppHub.shared.menu?.register(#selector(performMiniaturize(_:)), key: .itemMinimize)
        AppHub.shared.menu?.register(#selector(performZoom(_:)), key: .itemZoom)
    }

    override func toggleFullScreen(_ sender: Any?) {
        if pinchSessionActive && !pinchGestureActive {
            finishPinchSession()
        }
        if isAnimating {
            return
        }

        animationLock.lock()
        isAnimating = true
        animationLock.unlock()

        targetScreen = common.getTargetScreen(forFullscreen: !isInFullscreen)
        if targetScreen == nil && previousScreen == nil {
            targetScreen = screen
        } else if targetScreen == nil {
            targetScreen = previousScreen
            previousScreen = nil
        } else {
            previousScreen = screen
        }

        if let contentViewFrame = contentView?.frame, !isInFullscreen {
            unfsContentFrame = convertToScreen(contentViewFrame)
            unfScreen = screen
        }
        // move window to target screen when going to fullscreen
        if let tScreen = targetScreen, !isInFullscreen && (tScreen != screen) {
            let frame = calculateWindowPosition(for: tScreen, withoutBounds: false)
            setFrame(frame, display: true)
        }

        if Bool(option.vo.native_fs) {
            super.toggleFullScreen(sender)
        } else {
            if !isInFullscreen {
                setToFullScreen()
            } else {
                setToWindow()
            }
        }
    }

    func customWindowsToEnterFullScreen(for window: NSWindow) -> [NSWindow]? {
        return [window]
    }

    func customWindowsToExitFullScreen(for window: NSWindow) -> [NSWindow]? {
        return [window]
    }

    func window(_ window: NSWindow, startCustomAnimationToEnterFullScreenWithDuration duration: TimeInterval) {
        guard let tScreen = targetScreen else { return }
        common.view?.layerContentsPlacement = .scaleProportionallyToFit
        common.titleBar?.hide()
        NSAnimationContext.runAnimationGroup({ (context) in
            context.duration = getFsAnimationDuration(duration - 0.05)
            window.animator().setFrame(tScreen.frame, display: true)
        }, completionHandler: nil)
    }

    func window(_ window: NSWindow, startCustomAnimationToExitFullScreenWithDuration duration: TimeInterval) {
        guard let tScreen = targetScreen else { return }
        let newFrame = calculateWindowPosition(for: tScreen, withoutBounds: tScreen == screen)
        common.titleBar?.hide(0.0)
        common.view?.layerContentsPlacement = .scaleProportionallyToFit

        NSAnimationContext.runAnimationGroup({ (context) in
            context.duration = self.getFsAnimationDuration(duration - 0.05)
            self.styleMask.remove(.fullScreen)
            self.titlebarAppearsTransparent = true
            self.common.titleBar?.hide(0.0)
            window.animator().setFrame(newFrame, display: true)
        }, completionHandler: nil)
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        isInFullscreen = true
        option.setOption(fullscreen: isInFullscreen)
        common.updateCursorVisibility()
        endAnimation(frame)
        common.updateCachedWindowGeometry()
        common.titleBar?.show()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        guard let tScreen = targetScreen else { return }
        isInFullscreen = false
        option.setOption(fullscreen: isInFullscreen)
        endAnimation(calculateWindowPosition(for: tScreen, withoutBounds: targetScreen == screen))
        common.updateCachedWindowGeometry()
        common.view?.layerContentsPlacement = .scaleProportionallyToFit
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        guard let tScreen = targetScreen else { return }
        let newFrame = calculateWindowPosition(for: tScreen, withoutBounds: targetScreen == screen)
        setFrame(newFrame, display: true)
        endAnimation()
    }

    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        guard let targetFrame = targetScreen?.frame else { return }
        setFrame(targetFrame, display: true)
        endAnimation()
        common.view?.layerContentsPlacement = .scaleProportionallyToFit
    }

    func endAnimation(_ newFrame: NSRect = NSRect.zero) {
        if pinchSessionActive {
            finishPinchSession(callEndLiveResize: false)
        }
        if newFrame != NSRect.zero && isAnimating {
            NSAnimationContext.runAnimationGroup({ (context) in
                context.duration = 0.01
                self.animator().setFrame(newFrame, display: true)
            }, completionHandler: nil )
        }

        animationLock.lock()
        isAnimating = false
        animationLock.signal()
        animationLock.unlock()
        common.windowDidEndAnimation()
    }

    func setToFullScreen() {
        guard let targetFrame = targetScreen?.frame else { return }

        if #available(macOS 11.0, *) {
            styleMask = .borderless
            hasShadow = false
            common.titleBar?.hide(0.0)
        } else {
            styleMask.insert(.fullScreen)
        }

        NSApp.presentationOptions = [.autoHideMenuBar, .autoHideDock]
        setFrame(targetFrame, display: true)
        endAnimation()
        isInFullscreen = true
        option.setOption(fullscreen: isInFullscreen)
        common.updateCachedWindowGeometry()
        common.windowSetToFullScreen()
    }

    func setToWindow() {
        guard let tScreen = targetScreen else { return }

        if #available(macOS 11.0, *) {
            styleMask = previousStyleMask
            hasShadow = true
            common.titleBar?.hide(0.0)
        } else {
            styleMask.remove(.fullScreen)
        }

        let newFrame = calculateWindowPosition(for: tScreen, withoutBounds: targetScreen == screen)
        NSApp.presentationOptions = []
        setFrame(newFrame, display: true)
        endAnimation()
        isInFullscreen = false
        option.setOption(fullscreen: isInFullscreen)
        common.updateCachedWindowGeometry()
        common.windowSetToWindow()
    }

    func waitForAnimation() {
        animationLock.lock()
        while isAnimating {
            animationLock.wait()
        }
        animationLock.unlock()
    }

    func getFsAnimationDuration(_ def: Double) -> Double {
        let duration = option.mac.macos_fs_animation_duration
        if duration < 0 {
            return def
        } else {
            return Double(duration)/1000
        }
    }

    func setOnTop(_ state: Bool, _ ontopLevel: Int) {
        if state {
            let targetLevel: NSWindow.Level
            switch ontopLevel {
            case -1:
                targetLevel = .floating
            case -2:
                targetLevel = .statusBar + 1
            case -3:
                targetLevel = NSWindow.Level(Int(CGWindowLevelForKey(.desktopWindow)))
            default:
                targetLevel = NSWindow.Level(ontopLevel)
            }
            if level != targetLevel {
                level = targetLevel
            }
            if collectionBehavior.contains(.transient) || !collectionBehavior.contains(.managed) {
                var behavior = collectionBehavior
                behavior.remove(.transient)
                behavior.insert(.managed)
                collectionBehavior = behavior
            }
        } else if level != .normal {
            level = .normal
        }
    }

    func setOnAllWorkspaces(_ state: Bool) {
        if state {
            collectionBehavior.insert(.canJoinAllSpaces)
        } else {
            collectionBehavior.remove(.canJoinAllSpaces)
        }
    }

    func setMinimized(_ stateWanted: Bool) {
        if isMiniaturized == stateWanted { return }

        if stateWanted {
            performMiniaturize(self)
        } else {
            deminiaturize(self)
        }
    }

    func setMaximized(_ stateWanted: Bool) {
        if isZoomed == stateWanted { return }

        zoom(self)
    }

    func startDragging() {
        guard let view = common.view, let event = view.lastMouseDownEvent else { return }
        var pos = view.convert(event.locationInWindow, from: nil)
        pos = convertPointToBacking(pos)

        if input?.draggable(at: pos) ?? true {
            performDrag(with: event)
        }
    }

    func updateFrame(_ rect: NSRect, _ screen: NSScreen? = nil) {
        if rect != frame {
            unfsContentFrame = rect
            if !isInFullscreen {
                let cRect = absolutePosition(for: frameRect(forContentRect: rect), screen: screen)
                setFrame(cRect, display: true)
                common.windowDidUpdateFrame()
            }
        }
    }

    func updateSize(_ size: NSSize) {
        if let currentSize = contentView?.frame.size,
           abs(size.width - currentSize.width) >= 0.5 ||
           abs(size.height - currentSize.height) >= 0.5
        {
            var newContentFrame = centeredContentSize(for: frame, size: size)
            if isPinching { newContentFrame = keepOnScreen(contentRect: newContentFrame) }
            updateFrame(newContentFrame)
        }
    }

    // moves a content rect so the whole window stays within the usable screen area
    func keepOnScreen(contentRect cRect: NSRect) -> NSRect {
        guard let screen = currentScreen ?? screen ?? NSScreen.main else { return cRect }
        let vf = screen.visibleFrame
        let wf = frameRect(forContentRect: cRect)
        var dx: CGFloat = 0
        var dy: CGFloat = 0
        if wf.width <= vf.width {
            if wf.minX < vf.minX { dx = vf.minX - wf.minX }
            if wf.maxX > vf.maxX { dx = vf.maxX - wf.maxX }
        }
        if wf.height <= vf.height {
            if wf.minY < vf.minY { dy = vf.minY - wf.minY }
            if wf.maxY > vf.maxY { dy = vf.maxY - wf.maxY }
        }
        return cRect.offsetBy(dx: dx, dy: dy)
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        if frameRect.width < minSize.width || frameRect.height < minSize.height {
            common.log.verbose("tried to set too small window size: \(frameRect.size)")
            return
        }

        super.setFrame(frameRect, display: flag)

        if keepAspect && !pinchSessionActive { contentAspectRatio = unfsContentFrame.size }
        common.updateCachedWindowGeometry()
    }

    func absolutePosition(for rect: NSRect, screen: NSScreen?) -> NSRect {
        guard let tScreen = screen else { return rect }
        var absolutePosition = rect
        absolutePosition.origin.x += tScreen.frame.origin.x
        absolutePosition.origin.y += tScreen.frame.origin.y
        return absolutePosition
    }

    func centeredContentSize(for rect: NSRect, size sz: NSSize) -> NSRect {
        let cRect = contentRect(forFrameRect: rect)
        let dx = (cRect.size.width  - sz.width)  / 2
        let dy = (cRect.size.height - sz.height) / 2
        return cRect.insetBy(dx: dx, dy: dy)
    }

    func aspectFit(rect r: NSRect, in rTarget: NSRect) -> NSRect {
        var s = rTarget.width / r.width
        if r.height*s > rTarget.height {
            s = rTarget.height / r.height
        }
        let w = r.width * s
        let h = r.height * s
        return NSRect(x: rTarget.midX - w/2, y: rTarget.midY - h/2, width: w, height: h)
    }

    func calculateWindowPosition(for tScreen: NSScreen, withoutBounds: Bool) -> NSRect {
        guard let screen = unfScreen else { return frame }

        var newFrame = frameRect(forContentRect: unfsContentFrame)
        let targetFrame = tScreen.frame
        let targetVisibleFrame = tScreen.visibleFrame
        let unfsScreenFrame = screen.frame
        let visibleWindow = unfsScreenFrame.intersection(newFrame)

        // calculate visible area of every side
        let left = newFrame.origin.x - unfsScreenFrame.origin.x
        let right = unfsScreenFrame.size.width -
            (newFrame.origin.x - unfsScreenFrame.origin.x + newFrame.size.width)
        let bottom = newFrame.origin.y - unfsScreenFrame.origin.y
        let top = unfsScreenFrame.size.height -
            (newFrame.origin.y - unfsScreenFrame.origin.y + newFrame.size.height)

        // normalize visible areas, decide which one to take horizontal/vertical
        var xPer = (unfsScreenFrame.size.width - visibleWindow.size.width)
        var yPer = (unfsScreenFrame.size.height - visibleWindow.size.height)
        if xPer != 0 { xPer = (left >= 0 || right < 0 ? left : right) / xPer }
        if yPer != 0 { yPer = (bottom >= 0 || top < 0 ? bottom : top) / yPer }

        // calculate visible area for every side for target screen
        let xNewLeft = targetFrame.origin.x +
            (targetFrame.size.width - visibleWindow.size.width) * xPer
        let xNewRight = targetFrame.origin.x + targetFrame.size.width -
            (targetFrame.size.width - visibleWindow.size.width) * xPer - newFrame.size.width
        let yNewBottom = targetFrame.origin.y +
            (targetFrame.size.height - visibleWindow.size.height) * yPer
        let yNewTop = targetFrame.origin.y + targetFrame.size.height -
            (targetFrame.size.height - visibleWindow.size.height) * yPer - newFrame.size.height

        // calculate new coordinates, decide which one to take horizontal/vertical
        newFrame.origin.x = left >= 0 || right < 0 ? xNewLeft : xNewRight
        newFrame.origin.y = bottom >= 0 || top < 0 ? yNewBottom : yNewTop

        // don't place new window on top of a visible menubar
        let topMar = targetFrame.size.height -
            (newFrame.origin.y - targetFrame.origin.y + newFrame.size.height)
        let menuBarHeight = targetFrame.size.height -
            (targetVisibleFrame.size.height + targetVisibleFrame.origin.y)
        if topMar < menuBarHeight {
            newFrame.origin.y -= top - menuBarHeight
        }

        if withoutBounds {
            return newFrame
        }

        // screen bounds right and left
        if newFrame.origin.x + newFrame.size.width > targetFrame.origin.x + targetFrame.size.width {
            newFrame.origin.x = targetFrame.origin.x + targetFrame.size.width - newFrame.size.width
        }
        if newFrame.origin.x < targetFrame.origin.x {
            newFrame.origin.x = targetFrame.origin.x
        }

        // screen bounds top and bottom
        if newFrame.origin.y + newFrame.size.height > targetFrame.origin.y + targetFrame.size.height {
            newFrame.origin.y = targetFrame.origin.y + targetFrame.size.height - newFrame.size.height
        }
        if newFrame.origin.y < targetFrame.origin.y {
            newFrame.origin.y = targetFrame.origin.y
        }
        return newFrame
    }

    override func constrainFrameRect(_ frameRect: NSRect, to tScreen: NSScreen?) -> NSRect {
        if (isAnimating && !isInFullscreen) || (!isAnimating && isInFullscreen ||
            level == NSWindow.Level(Int(CGWindowLevelForKey(.desktopWindow)))) {
            return frameRect
        }

        guard let ts: NSScreen = tScreen ?? screen ?? NSScreen.main else {
            return frameRect
        }
        var nf: NSRect = frameRect
        let of: NSRect = frame
        let vf: NSRect = (isAnimating ? (targetScreen ?? ts) : ts).visibleFrame
        let ncf: NSRect = contentRect(forFrameRect: nf)

        // screen bounds top and bottom
        if nf.maxY > vf.maxY {
            nf.origin.y = vf.maxY - nf.height
        }
        if ncf.maxY < vf.minY {
            nf.origin.y = vf.minY + ncf.minY - ncf.maxY
        }

        // screen bounds right and left
        if nf.minX > vf.maxX {
            nf.origin.x = vf.maxX - nf.width
        }
        if nf.maxX < vf.minX {
            nf.origin.x = vf.minX
        }

        if nf.height < vf.height && of.height > vf.height && !isInFullscreen {
            // If the window height is smaller than the visible frame, but it was
            // bigger previously recenter the smaller window vertically. This is
            // needed to counter the 'snap to top' behaviour.
            nf.origin.y = (vf.height - nf.height) / 2
        }
        return nf
    }

    @objc func setNormalWindowSize() { setWindowScale(1.0) }
    @objc func setHalfWindowSize() { setWindowScale(0.5) }
    @objc func setDoubleWindowSize() { setWindowScale(2.0) }

    func setWindowScale(_ scale: Double) {
        input?.command("set window-scale \(scale)")
    }

    func addWindowScale(_ scale: Double) {
        if isInFullscreen || scale == 0 { return }
        if isPinching, let currentSize = contentView?.frame.size,
           let screen = currentScreen ?? screen ?? NSScreen.main
        {
            let maxArea = contentRect(forFrameRect: screen.visibleFrame).size
            let minHeight = screen.frame.height / 4
            if (scale > 0 && (currentSize.width >= maxArea.width - 0.5 ||
                              currentSize.height >= maxArea.height - 0.5)) ||
               (scale < 0 && currentSize.height <= minHeight + 0.5)
            {
                return
            }
        }
        input?.command("no-osd add current-window-scale \(scale)")
    }

    // pinch resize limits. the pinch flag stays set shortly after the gesture ended, since the
    // resulting window size changes are applied asynchronously by the core and VO.
    var isPinching: Bool = false
    var pinchEndWorkItem: DispatchWorkItem?
    var pinchSessionActive: Bool = false
    var pinchGestureActive: Bool = false
    var pinchBaseVideoSize: NSSize?
    var pinchCurrentScale: Double?
    var pinchCurrentVideoSize: NSSize?
    var pinchMinVideoHeight: CGFloat = 0
    var pinchMaxVideoSize: NSSize = .zero
    var pinchAnchorCenter: NSPoint?

    // smooth black-border collapse state (letterbox top/bottom or pillarbox left/right)
    var pinchBorderActive: Bool = false
    var pinchBorderStarted: Bool = false
    var pinchBorderStartTime: CFTimeInterval = 0
    var pinchBorderDuration: CFTimeInterval = 0
    var pinchBorderStartW: CGFloat = 0
    var pinchBorderStartH: CGFloat = 0
    var pinchBorderStartRatioW: CGFloat = 0
    var pinchBorderStartRatioH: CGFloat = 0
    var pinchBorderPrevW: CGFloat = 0
    var pinchBorderPrevH: CGFloat = 0
    var pinchBorderPrevRatioW: CGFloat = 0
    var pinchBorderPrevRatioH: CGFloat = 0
    var pinchBorderFallbackTimer: Timer?

    // automatic smooth aspect-ratio / black-border transition on idle -> video & file switches
    var autoTransitionActive: Bool = false
    var autoTransitionStartSize: NSSize = .zero
    var autoTransitionTargetSize: NSSize = .zero
    var autoTransitionStartTime: CFTimeInterval = 0
    var autoTransitionDuration: CFTimeInterval = 0
    var autoTransitionGen: UInt64 = 0
    var autoTransitionNotifiedActive: Bool = false
    var videoReferenceBox: NSSize?
    var preDragContentSize: NSSize?

    // Critically damped spring ease (zero initial velocity, early smooth glide, silky landing)
    private static func pinchBorderSpringProgress(_ u: Double) -> Double {
        if u <= 0 { return 0 }
        if u >= 1 { return 1 }
        let k = 6.5
        let ku = k * u
        let raw = 1.0 - (1.0 + ku) * exp(-ku)
        let norm = 1.0 - (1.0 + k) * exp(-k)
        return min(max(raw / norm, 0.0), 1.0)
    }

    private func notifyAutoResizeState(_ status: String, gen: UInt64) {
        guard !common.isQuitting else { return }
        input?.command("no-osd set user-data/mac-border-collapse \(status):\(gen)")
    }

    func notifyAutoResizeDone() {
        autoTransitionNotifiedActive = false
        autoTransitionGen &+= 1
        notifyAutoResizeState("done", gen: autoTransitionGen)
    }

    func resetVideoReferenceBox() {
        videoReferenceBox = nil
    }

    private func scaleVideoReferenceBox(by factor: CGFloat) {
        guard factor.isFinite, factor > 0, abs(factor - 1.0) > 0.001 else { return }
        let screen = currentScreen ?? self.screen ?? NSScreen.main
        let maxArea = screen.map { contentRect(forFrameRect: $0.visibleFrame).size }
            ?? NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let minContent = contentRect(forFrameRect: NSRect(origin: .zero, size: minSize)).size
        if let ref = videoReferenceBox {
            let scaledW = min(max(ref.width * factor, minContent.width), maxArea.width)
            let scaledH = min(max(ref.height * factor, minContent.height), maxArea.height)
            videoReferenceBox = NSSize(width: scaledW, height: scaledH)
        } else if let cur = contentView?.frame.size, cur.width > 0, cur.height > 0 {
            videoReferenceBox = cur
        }
    }

    private func startPinchBorderFallbackTimerIfNeeded() {
        guard (pinchBorderActive && pinchBorderStarted) || autoTransitionActive else { return }
        guard !common.hasMainThreadLiveResizeDisplayLink, pinchBorderFallbackTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            self?.stepPinchBorderAnimation()
        }
        RunLoop.main.add(timer, forMode: .common)
        pinchBorderFallbackTimer = timer
    }

    private func stopPinchBorderFallbackTimer() {
        pinchBorderFallbackTimer?.invalidate()
        pinchBorderFallbackTimer = nil
    }

    private func beginPinchSessionIfNeeded() {
        pinchEndWorkItem?.cancel()
        pinchEndWorkItem = nil
        isPinching = true
        if !pinchSessionActive {
            pinchSessionActive = true
            animationLock.lock()
            isAnimating = true
            animationLock.unlock()
            common.setLiveResizeContentsGravity(.resizeAspectFill)
            common.windowWillStartLiveResize()
        }
    }

    private func finishPinchSession(callEndLiveResize: Bool = true, notifyDone: Bool = true) {
        stopPinchBorderFallbackTimer()
        let wasActive = pinchSessionActive
        let shouldNotifyDone = notifyDone && autoTransitionNotifiedActive
        let doneGen = autoTransitionGen
        if let base = pinchBaseVideoSize, let cur = pinchCurrentVideoSize, base.height > 0 {
            scaleVideoReferenceBox(by: cur.height / base.height)
        }
        pinchSessionActive = false
        pinchGestureActive = false
        pinchBaseVideoSize = nil
        pinchCurrentScale = nil
        pinchCurrentVideoSize = nil
        pinchAnchorCenter = nil
        pinchBorderActive = false
        pinchBorderStarted = false
        pinchBorderStartW = 0
        pinchBorderStartH = 0
        pinchBorderStartRatioW = 0
        pinchBorderStartRatioH = 0
        pinchBorderPrevW = 0
        pinchBorderPrevH = 0
        pinchBorderPrevRatioW = 0
        pinchBorderPrevRatioH = 0
        autoTransitionActive = false
        autoTransitionNotifiedActive = false

        if wasActive {
            if let contentViewFrame = contentView?.frame, !isInFullscreen {
                unfsContentFrame = convertToScreen(contentViewFrame)
                if keepAspect {
                    contentAspectRatio = unfsContentFrame.size
                }
            }
            common.updateCachedWindowGeometry()
            animationLock.lock()
            isAnimating = false
            animationLock.broadcast()
            animationLock.unlock()
            updatePinching(.ended)
            if callEndLiveResize {
                common.windowDidEndLiveResize()
            }
        }

        if shouldNotifyDone {
            notifyAutoResizeState("done", gen: doneGen)
        }
    }

    func cancelPinchSession(notifyDone: Bool = true) {
        if pinchSessionActive {
            finishPinchSession(callEndLiveResize: true, notifyDone: notifyDone)
        } else if notifyDone && autoTransitionNotifiedActive {
            notifyAutoResizeDone()
        }
    }

    func startAutoAspectTransition(fromIdle: Bool, suggestedSize: NSSize) {
        guard !isInFullscreen,
              let currentSize = contentView?.frame.size,
              currentSize.width > 0, currentSize.height > 0 else {
            notifyAutoResizeDone()
            return
        }

        let videoSize = common.videoDisplaySizePoints(fallback: currentSize)
        guard videoSize.width > 0, videoSize.height > 0 else {
            notifyAutoResizeDone()
            return
        }
        let aspect = videoSize.width / videoSize.height

        let screen = currentScreen ?? self.screen ?? NSScreen.main
        let maxArea = screen.map { contentRect(forFrameRect: $0.visibleFrame).size } ?? currentSize
        let minContent = contentRect(forFrameRect: NSRect(origin: .zero, size: minSize)).size

        let fitBox: NSSize
        if fromIdle || videoReferenceBox == nil {
            fitBox = currentSize
            videoReferenceBox = currentSize
        } else {
            fitBox = videoReferenceBox!
        }

        var targetH = min(fitBox.width / aspect, fitBox.height)
        var targetW = targetH * aspect

        let minFitScale = max(minContent.width / max(targetW, 1), minContent.height / max(targetH, 1))
        if minFitScale > 1.0 {
            targetW *= minFitScale
            targetH *= minFitScale
        }
        let maxFitScale = min(maxArea.width / max(targetW, 1), maxArea.height / max(targetH, 1))
        if maxFitScale < 1.0 {
            targetW *= maxFitScale
            targetH *= maxFitScale
        }
        targetW = max(targetW, minContent.width)
        targetH = max(targetH, minContent.height)

        let targetSize = NSSize(width: targetW, height: targetH)
        let dw = abs(targetSize.width - currentSize.width)
        let dh = abs(targetSize.height - currentSize.height)

        guard dw >= 0.5 || dh >= 0.5 else {
            if keepAspect {
                contentAspectRatio = unfsContentFrame.size
            }
            notifyAutoResizeDone()
            return
        }

        let changeFraction = Double(max(dw / max(currentSize.width, targetSize.width, 1),
                                        dh / max(currentSize.height, targetSize.height, 1)))
        let duration = min(max(0.20 + 0.22 * sqrt(changeFraction), 0.22), 0.38)

        let cRect = contentRect(forFrameRect: frame)
        beginPinchSessionIfNeeded()
        pinchGestureActive = false
        pinchAnchorCenter = NSPoint(x: cRect.midX, y: cRect.midY)

        autoTransitionActive = true
        autoTransitionStartSize = currentSize
        autoTransitionTargetSize = targetSize
        // Allow ~20ms (~2 vsyncs at 120Hz) for Frame 1 of the new video to paint cleanly
        // into the window before smoothly gliding the black borders away.
        autoTransitionStartTime = CACurrentMediaTime() + 0.02
        autoTransitionDuration = duration
        autoTransitionGen &+= 1
        autoTransitionNotifiedActive = true
        notifyAutoResizeState("active", gen: autoTransitionGen)
        common.titleBar?.hide(0.0)
        startPinchBorderFallbackTimerIfNeeded()
    }

    private func initializePinchGeometry(currentSize: NSSize) {
        let cRect = contentRect(forFrameRect: frame)
        let screen = currentScreen ?? self.screen ?? NSScreen.main
        let maxArea = screen.map { contentRect(forFrameRect: $0.visibleFrame).size } ?? currentSize
        let minContent = contentRect(forFrameRect: NSRect(origin: .zero, size: minSize)).size

        let videoSize = common.videoDisplaySizePoints(fallback: currentSize)
        let aspect: CGFloat
        if Bool(option.vo.keepaspect), videoSize.width > 0, videoSize.height > 0 {
            aspect = videoSize.width / videoSize.height
        } else {
            aspect = currentSize.width / currentSize.height
        }

        // Exact actual displayed video rect inside the current window (aspect-fitted -> zero jump)
        let videoH0 = min(currentSize.width / aspect, currentSize.height)
        let videoW0 = videoH0 * aspect

        let stdMinHeight = max(screen.map { $0.frame.height / 4 } ?? minContent.height,
                               minContent.height,
                               minContent.width / max(aspect, 0.01))

        pinchBaseVideoSize = NSSize(width: videoW0, height: videoH0)
        pinchCurrentVideoSize = NSSize(width: videoW0, height: videoH0)
        pinchCurrentScale = 1.0
        pinchMinVideoHeight = min(stdMinHeight, videoH0)
        pinchMaxVideoSize = NSSize(width: max(maxArea.width, videoW0),
                                   height: max(maxArea.height, videoH0))
        if pinchAnchorCenter == nil {
            pinchAnchorCenter = NSPoint(x: cRect.midX, y: cRect.midY)
        }

        // If a border collapse is already smoothly in progress (e.g. a second pinch begins before
        // the previous settle finished), keep its continuous timeline intact.
        if pinchBorderActive && pinchBorderStarted {
            return
        }

        let extraW0 = max(0, currentSize.width - videoW0)
        let extraH0 = max(0, currentSize.height - videoH0)
        let borderThreshold: CGFloat = 0.5

        if extraW0 >= borderThreshold || extraH0 >= borderThreshold {
            let startW = extraW0 >= borderThreshold ? extraW0 : 0
            let startH = extraH0 >= borderThreshold ? extraH0 : 0
            let ratioW = startW > 0 && videoW0 > 0 ? (startW / videoW0) : 0
            let ratioH = startH > 0 && videoH0 > 0 ? (startH / videoH0) : 0
            let borderFraction = Double(max(extraW0 / max(currentSize.width, 1),
                                            extraH0 / max(currentSize.height, 1)))
            pinchBorderActive = true
            pinchBorderStarted = false
            pinchBorderStartTime = 0
            pinchBorderDuration = min(max(0.18 + 0.24 * sqrt(borderFraction), 0.20), 0.38)
            pinchBorderStartW = startW
            pinchBorderStartH = startH
            pinchBorderStartRatioW = ratioW
            pinchBorderStartRatioH = ratioH
            pinchBorderPrevW = startW
            pinchBorderPrevH = startH
            pinchBorderPrevRatioW = ratioW
            pinchBorderPrevRatioH = ratioH
        } else {
            pinchBorderActive = false
            pinchBorderStarted = false
            pinchBorderStartW = 0
            pinchBorderStartH = 0
            pinchBorderStartRatioW = 0
            pinchBorderStartRatioH = 0
            pinchBorderPrevW = 0
            pinchBorderPrevH = 0
            pinchBorderPrevRatioW = 0
            pinchBorderPrevRatioH = 0
        }
    }

    private func pinchClampedVideoSize(_ size: NSSize) -> NSSize {
        guard let screen = currentScreen ?? self.screen ?? NSScreen.main,
              size.width > 0, size.height > 0 else { return size }

        let maxArea = contentRect(forFrameRect: screen.visibleFrame).size
        let minContent = contentRect(forFrameRect: NSRect(origin: .zero, size: minSize)).size
        let aspect = size.width / size.height

        let stdMinHeight = max(screen.frame.height / 4,
                               minContent.height,
                               minContent.width / max(aspect, 0.01))
        let effectiveMinH = min(pinchMinVideoHeight, stdMinHeight)
        let effectiveMaxW = max(maxArea.width, pinchMaxVideoSize.width)
        let effectiveMaxH = max(maxArea.height, pinchMaxVideoSize.height)

        var newSize = size
        if newSize.height < effectiveMinH {
            newSize = NSSize(width: effectiveMinH * aspect, height: effectiveMinH)
        }

        let fit = min(effectiveMaxW / newSize.width, effectiveMaxH / newSize.height)
        if fit < 1 {
            newSize = NSSize(width: newSize.width * fit, height: newSize.height * fit)
        }

        // Ratchet effective limits smoothly back toward standard bounds as the user scales into range
        if newSize.height > pinchMinVideoHeight {
            pinchMinVideoHeight = min(stdMinHeight, newSize.height)
        }
        if newSize.width < pinchMaxVideoSize.width {
            pinchMaxVideoSize.width = max(maxArea.width, newSize.width)
        }
        if newSize.height < pinchMaxVideoSize.height {
            pinchMaxVideoSize.height = max(maxArea.height, newSize.height)
        }

        return newSize
    }

    private func evaluatePinchBorder(now: CFTimeInterval, videoSize: NSSize) -> (w: CGFloat, h: CGFloat, completed: Bool) {
        guard pinchBorderActive else {
            return (0, 0, true)
        }
        guard pinchBorderStarted else {
            return (pinchBorderPrevW, pinchBorderPrevH, false)
        }

        let elapsed = max(0, now - pinchBorderStartTime)
        let u = pinchBorderDuration > 0 ? min(elapsed / pinchBorderDuration, 1.0) : 1.0
        if u >= 1.0 {
            pinchBorderPrevW = 0
            pinchBorderPrevH = 0
            pinchBorderPrevRatioW = 0
            pinchBorderPrevRatioH = 0
            return (0, 0, true)
        }

        let remaining = CGFloat(1.0 - Window.pinchBorderSpringProgress(u))
        let screen = currentScreen ?? self.screen ?? NSScreen.main
        let maxArea = screen.map { contentRect(forFrameRect: $0.visibleFrame).size }
            ?? NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let curContent = contentView?.frame.size ?? NSSize(width: videoSize.width + pinchBorderPrevW,
                                                           height: videoSize.height + pinchBorderPrevH)

        var bw: CGFloat = 0
        if pinchBorderStartRatioW > 0 {
            let targetRatioW = min(pinchBorderStartRatioW * remaining, pinchBorderPrevRatioW)
            let rawW = min(targetRatioW * videoSize.width, pinchBorderStartW * remaining, pinchBorderPrevW)
            let maxCapW = max(0, max(maxArea.width, curContent.width) - videoSize.width)
            bw = min(rawW, maxCapW)
            pinchBorderPrevW = bw
            pinchBorderPrevRatioW = videoSize.width > 0 ? (bw / videoSize.width) : 0
        }

        var bh: CGFloat = 0
        if pinchBorderStartRatioH > 0 {
            let targetRatioH = min(pinchBorderStartRatioH * remaining, pinchBorderPrevRatioH)
            let rawH = min(targetRatioH * videoSize.height, pinchBorderStartH * remaining, pinchBorderPrevH)
            let maxCapH = max(0, max(maxArea.height, curContent.height) - videoSize.height)
            bh = min(rawH, maxCapH)
            pinchBorderPrevH = bh
            pinchBorderPrevRatioH = videoSize.height > 0 ? (bh / videoSize.height) : 0
        }

        if bw < 0.05 && bh < 0.05 {
            pinchBorderPrevW = 0
            pinchBorderPrevH = 0
            pinchBorderPrevRatioW = 0
            pinchBorderPrevRatioH = 0
            return (0, 0, true)
        }
        return (bw, bh, false)
    }

    private func applyPinchContentSize(_ size: NSSize, force: Bool) {
        guard let currentSize = contentView?.frame.size else { return }
        let pixelStep: CGFloat = 1.0 / max(backingScaleFactor, 1.0)
        let threshold: CGFloat = force ? 0.01 : pixelStep
        guard abs(size.width - currentSize.width) >= threshold ||
              abs(size.height - currentSize.height) >= threshold else {
            return
        }

        let cRect = contentRect(forFrameRect: frame)
        let center = pinchAnchorCenter ?? NSPoint(x: cRect.midX, y: cRect.midY)
        pinchAnchorCenter = center

        var newContentFrame = NSRect(
            x: center.x - size.width * 0.5,
            y: center.y - size.height * 0.5,
            width: size.width,
            height: size.height
        )
        let kept = keepOnScreen(contentRect: newContentFrame)
        if abs(kept.origin.x - newContentFrame.origin.x) > 0.01 ||
           abs(kept.origin.y - newContentFrame.origin.y) > 0.01
        {
            newContentFrame = kept
            pinchAnchorCenter = NSPoint(x: kept.midX, y: kept.midY)
        }

        common.clearPendingUnfsSize()
        updateFrame(newContentFrame)
    }

    func stepPinchBorderAnimation() {
        if autoTransitionActive {
            guard !isInFullscreen else {
                finishPinchSession()
                return
            }
            let now = CACurrentMediaTime()
            if now < autoTransitionStartTime {
                return
            }
            let elapsed = now - autoTransitionStartTime
            let u = autoTransitionDuration > 0 ? min(elapsed / autoTransitionDuration, 1.0) : 1.0
            let p = CGFloat(Window.pinchBorderSpringProgress(u))
            let w = autoTransitionStartSize.width + (autoTransitionTargetSize.width - autoTransitionStartSize.width) * p
            let h = autoTransitionStartSize.height + (autoTransitionTargetSize.height - autoTransitionStartSize.height) * p
            let completed = (u >= 1.0)
            let targetSize = completed ? autoTransitionTargetSize : NSSize(width: w, height: h)
            applyPinchContentSize(targetSize, force: completed)
            if completed {
                finishPinchSession()
            }
            return
        }

        guard pinchSessionActive, pinchBorderActive, pinchBorderStarted else { return }
        guard !isInFullscreen else {
            finishPinchSession()
            return
        }
        guard let videoSize = pinchCurrentVideoSize,
              videoSize.width > 0, videoSize.height > 0 else {
            finishPinchSession()
            return
        }

        let now = CACurrentMediaTime()
        let border = evaluatePinchBorder(now: now, videoSize: videoSize)
        let minContent = contentRect(forFrameRect: NSRect(origin: .zero, size: minSize)).size
        let targetSize = NSSize(
            width: max(videoSize.width + border.w, minContent.width),
            height: max(videoSize.height + border.h, minContent.height)
        )
        applyPinchContentSize(targetSize, force: border.completed)

        if border.completed {
            pinchBorderActive = false
            pinchBorderStarted = false
            stopPinchBorderFallbackTimer()
            if !pinchGestureActive {
                finishPinchSession()
            }
        }
    }

    func pinchResize(by scaleDelta: Double, phase: NSEvent.Phase) {
        if isInFullscreen {
            if pinchSessionActive {
                finishPinchSession()
            }
            return
        }
        let ended = phase == .ended || phase == .cancelled
        guard let currentSize = contentView?.frame.size,
              currentSize.width > 0, currentSize.height > 0 else {
            if ended {
                finishPinchSession()
            }
            return
        }

        if !ended {
            beginPinchSessionIfNeeded()
            if autoTransitionActive {
                autoTransitionActive = false
            }
            pinchGestureActive = true
        } else if !pinchSessionActive {
            return
        }

        if phase == .began || pinchBaseVideoSize == nil || pinchCurrentScale == nil {
            initializePinchGeometry(currentSize: currentSize)
        }

        if scaleDelta != 0, scaleDelta.isFinite,
           let baseVideo = pinchBaseVideoSize, baseVideo.height > 0,
           let curScale = pinchCurrentScale
        {
            let now = CACurrentMediaTime()
            if pinchBorderActive && !pinchBorderStarted {
                pinchBorderStarted = true
                pinchBorderStartTime = now
                startPinchBorderFallbackTimerIfNeeded()
            }

            let factor = exp(min(max(scaleDelta, -4.0), 4.0))
            let nextScale = curScale * factor
            let candidateVideo = NSSize(width: baseVideo.width * CGFloat(nextScale),
                                        height: baseVideo.height * CGFloat(nextScale))
            let clampedVideo = pinchClampedVideoSize(candidateVideo)
            pinchCurrentVideoSize = clampedVideo
            pinchCurrentScale = Double(clampedVideo.height / baseVideo.height)

            let border = evaluatePinchBorder(now: now, videoSize: clampedVideo)
            if border.completed {
                pinchBorderActive = false
                pinchBorderStarted = false
                stopPinchBorderFallbackTimer()
            }

            let minContent = contentRect(forFrameRect: NSRect(origin: .zero, size: minSize)).size
            let targetSize = NSSize(
                width: max(clampedVideo.width + border.w, minContent.width),
                height: max(clampedVideo.height + border.h, minContent.height)
            )
            applyPinchContentSize(targetSize, force: border.completed)
        }

        if ended {
            pinchGestureActive = false
            if pinchBorderActive && pinchBorderStarted {
                startPinchBorderFallbackTimerIfNeeded()
            } else {
                finishPinchSession()
            }
        }
    }

    func updatePinching(_ phase: NSEvent.Phase) {
        pinchEndWorkItem?.cancel()
        pinchEndWorkItem = nil
        if phase == .ended || phase == .cancelled {
            let workItem = DispatchWorkItem { [weak self] in self?.isPinching = false }
            pinchEndWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
        } else {
            isPinching = true
        }
    }

    // clamps a content size (in points) for pinch resizing, keeping its aspect ratio:
    // - minimum: a quarter of the screen height
    // - maximum: the video fills either the full width or the full height of the screen,
    //   whichever is reached first
    func pinchClampedSize(_ size: NSSize) -> NSSize {
        guard let screen = currentScreen ?? screen ?? NSScreen.main,
              size.width > 0, size.height > 0 else { return size }

        // usable screen area for the content, excluding menu bar, dock and title bar
        let maxArea = contentRect(forFrameRect: screen.visibleFrame).size
        let aspect = size.width / size.height
        var newSize = size

        let minHeight = screen.frame.height / 4
        if newSize.height < minHeight {
            newSize = NSSize(width: minHeight * aspect, height: minHeight)
        }

        let fit = min(maxArea.width / newSize.width, maxArea.height / newSize.height)
        if fit < 1 {
            newSize = NSSize(width: newSize.width * fit, height: newSize.height * fit)
        }

        return newSize
    }

    func windowDidChangeScreen(_ notification: Notification) {
        if screen == nil {
            return
        }
        if !isAnimating && (currentScreen != screen) {
            previousScreen = screen
        }
        if currentScreen != screen {
            common.updateDisplaylink()
            common.windowDidChangeScreen()
        }
        currentScreen = screen
        common.updateCachedWindowGeometry()
    }

    func windowDidChangeScreenProfile(_ notification: Notification) {
        common.windowDidChangeScreenProfile()
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        common.updateCachedWindowGeometry()
        common.windowDidChangeBackingProperties()
        common.flagEvents(VO_EVENT_DPI)
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        if pinchSessionActive {
            finishPinchSession()
        }
        preDragContentSize = contentView?.frame.size
        common.windowWillStartLiveResize()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        if let oldSz = preDragContentSize, oldSz.height > 0,
           let newSz = contentView?.frame.size, newSz.height > 0
        {
            scaleVideoReferenceBox(by: newSz.height / oldSz.height)
        }
        preDragContentSize = nil
        if let contentViewFrame = contentView?.frame, !isAnimating && !isInFullscreen {
            unfsContentFrame = convertToScreen(contentViewFrame)
        }
        option.setOption(maximized: isZoomed)
        common.updateCachedWindowGeometry()
        common.windowDidEndLiveResize()
    }

    func windowDidResize(_ notification: Notification) {
        if let contentViewFrame = contentView?.frame, !isAnimating && !isInFullscreen && !inLiveResize {
            unfsContentFrame = convertToScreen(contentViewFrame)
        }
        common.updateCachedWindowGeometry()
        common.windowDidResize()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        input?.put(key: MP_KEY_CLOSE_WIN)
        return false
    }

    func windowDidMiniaturize(_ notification: Notification) {
        common.windowDidMiniaturize()
        option.setOption(minimized: true)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        option.setOption(minimized: false)
    }

    func windowDidResignKey(_ notification: Notification) {
        common.setCursorVisibility(true)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        common.updateCursorVisibility()
    }

    func windowDidBecomeMain(_ notification: Notification) {
        common.windowDidBecomeMain()
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        if occlusionState.contains(.visible) {
            common.windowDidChangeOcclusionState()
            common.updateCursorVisibility()
        }
    }

    func windowWillMove(_ notification: Notification) {
        if pinchSessionActive && !pinchGestureActive {
            finishPinchSession()
        }
        isMoving = true
    }

    func windowDidMove(_ notification: Notification) {
        option.setOption(maximized: isZoomed)
    }
}
