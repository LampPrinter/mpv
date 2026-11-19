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

class MetalLayer: CAMetalLayer {
    weak var common: MacCommon?
    var log: LogHelper? { return common?.log }

    // workaround for a MoltenVK workaround that sets the drawableSize to 1x1 to forcefully complete
    // the presentation, this causes flicker and the drawableSize possibly staying at 1x1
    override var drawableSize: CGSize {
        get { return super.drawableSize }
        set {
            if Int(newValue.width) > 1 && Int(newValue.height) > 1 {
                super.drawableSize = newValue
                if !inLiveResize {
                    flushBackgroundTransactionIfNeeded()
                }
            }
        }
    }

    private struct EDRCacheKey: Equatable {
        let isHLG: Bool
        let minLuma: Float
        let maxLuma: Float
        let scale: Float
    }

    let hdrLock = NSLock()
    var hdrActiveWanted: Bool = false
    var hdrIsHLG: Bool = false
    var hdrMinLuma: Float = 0.005
    var hdrMaxLuma: Float = 1000.0
    private var requestedWantsEDR: Bool = false
    private var requestedColorspace: CGColorSpace?
    private var requestedPixelFormat: MTLPixelFormat = .rgba16Float
    private var cachedEDRKey: EDRCacheKey?
    private var cachedEDRMetadata: CAEDRMetadata?
    private var mainEDRSyncPending: Bool = false
    private var edrRampGeneration: UInt64 = 0
    private var isInvalidated: Bool = false

    func invalidateEDRSync() {
        hdrLock.withLock {
            isInvalidated = true
            mainEDRSyncPending = false
            edrRampGeneration &+= 1
        }
    }

    func updateHDRState(active: Bool, isHLG: Bool, minLuma: Float, maxLuma: Float) {
        var stateChanged = false
        var edrChanged = false
        var metaChanged = false
        hdrLock.withLock {
            stateChanged = hdrActiveWanted != active ||
                           hdrIsHLG != isHLG ||
                           abs(hdrMinLuma - minLuma) > 0.0005 ||
                           abs(hdrMaxLuma - maxLuma) > 1.0
            hdrActiveWanted = active
            hdrIsHLG = isHLG
            hdrMinLuma = minLuma
            hdrMaxLuma = maxLuma
            if stateChanged {
                let effective = requestedWantsEDR && active
                if super.wantsExtendedDynamicRangeContent != effective {
                    super.wantsExtendedDynamicRangeContent = effective
                    edrChanged = true
                }
                metaChanged = syncSuperEDRMetadataLocked()
            }
        }
        if stateChanged {
            if edrChanged {
                logState(property: "HDR")
            }
            if metaChanged {
                logState(property: "HDR metadata")
            }
            flushBackgroundTransactionIfNeeded()
            scheduleMainThreadEDRSync()
        }
    }

    func isHDRActive() -> Bool {
        return hdrLock.withLock { hdrActiveWanted }
    }

    // Must be called while holding hdrLock.
    private func desiredEDRMetadataLocked(fallback: CAEDRMetadata? = nil) -> CAEDRMetadata? {
        guard requestedWantsEDR && hdrActiveWanted else { return nil }
        let csName = requestedColorspace?.name as String?
        if hdrIsHLG || csName == (CGColorSpace.displayP3_HLG as String) ||
           ({ if #available(macOS 11.0, *) { return csName == (CGColorSpace.itur_2100_HLG as String) }; return false }())
        {
            return CAEDRMetadata.hlg
        }
        let scale: Float?
        switch requestedPixelFormat {
        case .rgba16Float:
            // Extended linear sRGB / Display P3 / BT.2020 uses 1.0 = SDR white directly in EDR.
            return nil
        case .bgr10a2Unorm:
            scale = 10000.0
        default:
            scale = nil
        }
        guard let scale else {
            return fallback
        }
        let safeMin = max(hdrMinLuma, 0.0001)
        let safeMax = max(hdrMaxLuma, 100.0)
        let key = EDRCacheKey(isHLG: false, minLuma: safeMin, maxLuma: safeMax, scale: scale)
        if cachedEDRKey == key, let cached = cachedEDRMetadata {
            return cached
        }
        let meta = CAEDRMetadata.hdr10(minLuminance: safeMin,
                                       maxLuminance: safeMax,
                                       opticalOutputScale: scale)
        cachedEDRKey = key
        cachedEDRMetadata = meta
        return meta
    }

    // Must be called while holding hdrLock.
    private func syncSuperEDRMetadataLocked(fallback: CAEDRMetadata? = nil) -> Bool {
        let fb = hdrActiveWanted ? (fallback ?? super.edrMetadata) : nil
        let target = desiredEDRMetadataLocked(fallback: fb)
        if super.edrMetadata !== target {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            super.edrMetadata = target
            CATransaction.commit()
            return true
        }
        return false
    }

    private func flushBackgroundTransactionIfNeeded() {
        if !Thread.isMainThread {
            CATransaction.flush()
        }
    }

    private func scheduleMainThreadEDRSync() {
        let shouldSchedule: Bool = hdrLock.withLock {
            if isInvalidated || mainEDRSyncPending { return false }
            mainEDRSyncPending = true
            return true
        }
        guard shouldSchedule else { return }

        DispatchQueue.main.async { [weak self] in
            self?.performMainThreadEDRSync()
        }
    }

    private func performMainThreadEDRSync() {
        var gen: UInt64 = 0
        var shouldProceed = false

        // Serialize reading requested* and committing super.* under hdrLock so main-thread
        // WindowServer promotion never overwrites a concurrent MoltenVK swapchain update.
        hdrLock.withLock {
            mainEDRSyncPending = false
            guard !isInvalidated else { return }
            edrRampGeneration &+= 1
            gen = edrRampGeneration
            shouldProceed = true

            let active = requestedWantsEDR && hdrActiveWanted
            let cs = requestedColorspace
            let targetMeta = desiredEDRMetadataLocked(fallback: hdrActiveWanted ? super.edrMetadata : nil)

            // Force a dirty commit on the Main Thread's CATransaction so WindowServer and AppKit's
            // NSWindow/NSView layer-hosting machinery immediately promote/demote EDR backing without
            // needing a window resize. Toggling false->true inside a single disabled-actions
            // CATransaction sets CA::Layer's main-thread dirty flag while only sending the final
            // state (true + targetMeta) to CARenderServer upon commit/flush (zero flicker).
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if active {
                super.wantsExtendedDynamicRangeContent = false
                super.wantsExtendedDynamicRangeContent = true
            } else {
                super.wantsExtendedDynamicRangeContent = false
            }
            super.colorspace = cs
            super.edrMetadata = targetMeta
            CATransaction.commit()
        }

        guard shouldProceed, let common = self.common else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.setNeedsLayout()
        self.setNeedsDisplay()
        common.view?.needsLayout = true
        common.view?.needsDisplay = true
        CATransaction.commit()
        CATransaction.flush()

        common.window?.displayIfNeeded()
        let ev = common.updateEDRState()
        if ev != 0 {
            common.flagEvents(ev)
        }

        // macOS ramps NSScreen.maximumExtendedDynamicRangeColorComponentValue shortly after
        // WindowServer activates EDR; poll twice so cachedMaxEDR updates even if macOS coalesces
        // didChangeScreenParametersNotification.
        for delay in [0.12, 0.35] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self else { return }
                let valid = self.hdrLock.withLock {
                    !self.isInvalidated && self.edrRampGeneration == gen
                }
                guard valid, let common = self.common else { return }
                let ev = common.updateEDRState()
                if ev != 0 {
                    common.flagEvents(ev)
                }
            }
        }
    }

    override var pixelFormat: MTLPixelFormat {
        get { return super.pixelFormat }
        set {
            var fmtChanged = false
            var metaChanged = false
            hdrLock.withLock {
                fmtChanged = super.pixelFormat != newValue
                requestedPixelFormat = newValue
                super.pixelFormat = newValue
                if fmtChanged && requestedWantsEDR {
                    metaChanged = syncSuperEDRMetadataLocked()
                }
            }
            if fmtChanged {
                logState(property: "pixel format")
                if metaChanged {
                    logState(property: "HDR metadata")
                }
                flushBackgroundTransactionIfNeeded()
                scheduleMainThreadEDRSync()
            }
        }
    }

    override var colorspace: CGColorSpace? {
        get { return super.colorspace }
        set {
            var csChanged = false
            var metaChanged = false
            hdrLock.withLock {
                csChanged = requestedColorspace !== newValue && requestedColorspace != newValue
                requestedColorspace = newValue
                super.colorspace = newValue
                if csChanged && requestedWantsEDR {
                    metaChanged = syncSuperEDRMetadataLocked()
                }
            }
            if csChanged {
                logState(property: "colorspace")
                if metaChanged {
                    logState(property: "HDR metadata")
                }
                flushBackgroundTransactionIfNeeded()
                scheduleMainThreadEDRSync()
            }
        }
    }

    override var edrMetadata: CAEDRMetadata? {
        get { return super.edrMetadata }
        set {
            let changed: Bool = hdrLock.withLock {
                syncSuperEDRMetadataLocked(fallback: newValue)
            }
            if changed {
                logState(property: "HDR metadata")
                flushBackgroundTransactionIfNeeded()
                scheduleMainThreadEDRSync()
            }
        }
    }

    override var wantsExtendedDynamicRangeContent: Bool {
        get { return super.wantsExtendedDynamicRangeContent }
        set {
            var edrChanged = false
            var metaChanged = false
            hdrLock.withLock {
                let effective = newValue && hdrActiveWanted
                edrChanged = super.wantsExtendedDynamicRangeContent != effective
                requestedWantsEDR = newValue
                super.wantsExtendedDynamicRangeContent = effective
                metaChanged = syncSuperEDRMetadataLocked()
            }
            if edrChanged || metaChanged {
                if edrChanged {
                    logState(property: "HDR")
                }
                if metaChanged {
                    logState(property: "HDR metadata")
                }
                flushBackgroundTransactionIfNeeded()
                scheduleMainThreadEDRSync()
            }
        }
    }

    // display sync is disabled during live resize, so frames with the new size are handed to the
    // compositor immediately instead of waiting for their own vsync slot. windowed content is
    // always composited, so this doesn't cause tearing. MoltenVK sets this on every swapchain
    // (re)creation, remember the requested value and apply it after the live resize ended.
    var requestedDisplaySync: Bool = true
    private let displaySyncLock = NSLock()
    private var _inLiveResize: Bool = false

    override var displaySyncEnabled: Bool {
        get { return super.displaySyncEnabled }
        set {
            let value: Bool = displaySyncLock.withLock {
                requestedDisplaySync = newValue
                return _inLiveResize ? false : requestedDisplaySync
            }
            if super.displaySyncEnabled != value {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                super.displaySyncEnabled = value
                CATransaction.commit()
                logState(property: "display sync")
            }
        }
    }

    func applyDisplaySync() {
        let value: Bool = displaySyncLock.withLock {
            _inLiveResize ? false : requestedDisplaySync
        }
        if super.displaySyncEnabled != value {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            super.displaySyncEnabled = value
            CATransaction.commit()
            logState(property: "display sync")
        }
    }

    func disableDisplaySyncForQuit() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displaySyncLock.withLock { requestedDisplaySync = false }
        if super.displaySyncEnabled {
            super.displaySyncEnabled = false
        }
        CATransaction.commit()
    }

    // workaround for MoltenVK problem setting this to false even when no transparent content is rendered
    var wantsAlpha: Bool = false { didSet { isOpaque = !wantsAlpha } }
    var opaqueForced: Bool = false
    override var isOpaque: Bool {
        get { return super.isOpaque }
        set {
            opaqueForced = newValue == wantsAlpha
            let desired = !wantsAlpha
            if super.isOpaque != desired {
                super.isOpaque = desired
                backgroundColor = (wantsAlpha ? NSColor.clear : NSColor.black).cgColor
                logState(property: "opaque")
                flushBackgroundTransactionIfNeeded()
            }
        }
    }

    // live resizing: prevent distortion of frames that lag behind the window size by keeping
    // their aspect ratio instead of stretching them to the new layer bounds, and present frames
    // without display sync to minimise the latency between window frame and content updates.
    // the renderer also uses cheap scalers during live resize, see vo->live_resize.
    var previousContentsGravity: CALayerContentsGravity = .resizeAspect
    var liveResizeGravity: CALayerContentsGravity = .resizeAspect {
        didSet {
            guard oldValue != liveResizeGravity, inLiveResize else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            contentsGravity = liveResizeGravity
            CATransaction.commit()
        }
    }
    @objc var inLiveResize: Bool {
        get { return displaySyncLock.withLock { _inLiveResize } }
        set {
            let changed: Bool = displaySyncLock.withLock {
                if _inLiveResize == newValue { return false }
                _inLiveResize = newValue
                return true
            }
            if !changed { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if newValue {
                previousContentsGravity = contentsGravity
                contentsGravity = liveResizeGravity
            } else {
                contentsGravity = previousContentsGravity
                liveResizeGravity = .resizeAspect
            }
            CATransaction.commit()
            applyDisplaySync()
            log?.verbose("Live resize \(newValue ? "started" : "ended")")
        }
    }

    init(common com: MacCommon) {
        common = com
        super.init()

        let initialCS = super.colorspace
        hdrLock.withLock {
            requestedPixelFormat = .rgba16Float
            requestedColorspace = initialCS
            requestedWantsEDR = false
            super.pixelFormat = .rgba16Float
        }
        contentsGravity = .resizeAspect
        backgroundColor = NSColor.black.cgColor
        logState(property: "pixel format")
    }

    // necessary for when the layer containing window changes the screen
    override init(layer: Any) {
        guard let oldLayer = layer as? MetalLayer else {
            fatalError("init(layer: Any) passed an invalid layer")
        }
        common = oldLayer.common
        previousContentsGravity = oldLayer.previousContentsGravity
        liveResizeGravity = oldLayer.liveResizeGravity
        (hdrActiveWanted, hdrIsHLG, hdrMinLuma, hdrMaxLuma,
         requestedWantsEDR, requestedColorspace, requestedPixelFormat,
         cachedEDRKey, cachedEDRMetadata, isInvalidated) = oldLayer.hdrLock.withLock {
            (oldLayer.hdrActiveWanted, oldLayer.hdrIsHLG, oldLayer.hdrMinLuma, oldLayer.hdrMaxLuma,
             oldLayer.requestedWantsEDR, oldLayer.requestedColorspace, oldLayer.requestedPixelFormat,
             oldLayer.cachedEDRKey, oldLayer.cachedEDRMetadata, oldLayer.isInvalidated)
        }
        super.init()
        contentsGravity = oldLayer.contentsGravity
        backgroundColor = oldLayer.backgroundColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func logState(property: String) {
        let dtdPixelFormats: [MTLPixelFormat] = [
            .bgra8Unorm,
            .rgba16Float,
            .bgr10a2Unorm
        ]
        let dtdPossible = isOpaque && dtdPixelFormats.contains(pixelFormat)

        log?.verbose("""
        Metal layer state changed (\(property))
        Pixel Format: \(pixelFormat.name) - Opaque: \(isOpaque) \(opaqueForced ? "(forced)" : "")
        Colorspace: \(colorspace?.longName ?? "nil")
        HDR: \(wantsExtendedDynamicRangeContent ? "active" : "inactive") - Metadata: \(edrMetadata?.description ?? "nil")
        Direct-to-Display: \(dtdPossible ? "possible" : "inactive") - Display Sync: \(displaySyncEnabled ? "active" : "inactive")
        """)
    }
}
