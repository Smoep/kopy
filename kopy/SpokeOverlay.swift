import AppKit
import SwiftUI

private func roundedSystemFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    if let descriptor = base.fontDescriptor.withDesign(.rounded),
       let rounded = NSFont(descriptor: descriptor, size: size) {
        return rounded
    }
    return base
}

private let overlayPreviewFont = roundedSystemFont(size: 13, weight: .regular)
private let overlaySearchFont = roundedSystemFont(size: 13, weight: .medium)
private let overlaySearchIconSize: CGFloat = 12
private let overlaySearchHorizontalPadding: CGFloat = 10
private let overlaySearchVerticalPadding: CGFloat = 7
private let overlaySearchMinWidth: CGFloat = 74
private let overlaySearchMaxWidth: CGFloat = 320
private let overlaySearchBaseHeight: CGFloat = 31
private let overlaySearchCornerRadius: CGFloat = 10
private let overlayBackdropSyncDelay: TimeInterval = 0.06

private func backdropSpreadCurve(_ raw: CGFloat) -> CGFloat {
    pow(min(max(raw, 0), 1), 1.75)
}

private func backdropIntensityCurve(_ raw: CGFloat) -> CGFloat {
    pow(min(max(raw, 0), 1), 1.15)
}

private func overlayPreviewText(for item: ClipboardItem, previewLength: Int) -> String {
    String(item.text.prefix(previewLength))
        .replacingOccurrences(of: "\n", with: " ")
}

private func overlayFavoritePreviewText(for favorite: FavoriteItem, previewLength: Int) -> String {
    let rawPreview = String(favorite.text.prefix(previewLength))
        .replacingOccurrences(of: "\n", with: " ")
    if favorite.isPrivate && rawPreview.count > 3 {
        return String(rawPreview.prefix(3)) + String(repeating: "•", count: min(rawPreview.count - 3, 12))
    }
    return rawPreview
}

private func overlayMeasuredTextWidth(_ text: String, font: NSFont) -> CGFloat {
    let display = text.isEmpty ? " " : text
    return ceil((display as NSString).size(withAttributes: [.font: font]).width)
}

private func overlayTextPillWidth(preview: String, maxWidth: CGFloat) -> CGFloat {
    min(maxWidth, max(24, overlayMeasuredTextWidth(preview, font: overlayPreviewFont) + 20))
}

private func overlayImagePillWidth(for image: NSImage?, pillHeight: CGFloat, maxWidth: CGFloat) -> CGFloat {
    guard let image else { return min(maxWidth, 52) }
    let contentHeight = max(18, pillHeight - 8)
    let aspectRatio = image.size.height > 0 ? image.size.width / image.size.height : 1
    let contentWidth = max(24, min(maxWidth - 8, ceil(contentHeight * aspectRatio)))
    return min(maxWidth, contentWidth + 8)
}

private func overlayRightPillWidth(for item: ClipboardItem, previewLength: Int, maxWidth: CGFloat, pillHeight: CGFloat) -> CGFloat {
    if item.isImage {
        return overlayImagePillWidth(for: item.nsImage, pillHeight: pillHeight, maxWidth: maxWidth)
    }
    return overlayTextPillWidth(preview: overlayPreviewText(for: item, previewLength: previewLength), maxWidth: maxWidth)
}

private func overlayFavoritePillWidth(for favorite: FavoriteItem, previewLength: Int, maxWidth: CGFloat) -> CGFloat {
    overlayTextPillWidth(preview: overlayFavoritePreviewText(for: favorite, previewLength: previewLength), maxWidth: maxWidth)
}

private func overlaySearchFieldWidth(for searchText: String) -> CGFloat {
    let displayText = searchText.isEmpty ? "..." : searchText
    let chromeWidth = overlaySearchIconSize + 6 + (overlaySearchHorizontalPadding * 2) + 4
    return max(overlaySearchMinWidth, min(overlaySearchMaxWidth, overlayMeasuredTextWidth(displayText, font: overlaySearchFont) + chromeWidth))
}

private func searchInputText(from event: NSEvent) -> String? {
    guard !event.modifierFlags.contains(.command),
          let chars = event.characters,
          !chars.isEmpty else {
        return nil
    }

    let printableScalars = chars.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
    guard !printableScalars.isEmpty else { return nil }
    return String(String.UnicodeScalarView(printableScalars)).lowercased()
}

private func overlaySearchMatches(_ text: String, query: String) -> Bool {
    text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
}

// MARK: - Key-accepting non-activating overlay panel

// Window-server background blur: pure gaussian blur of content behind the
// window's non-transparent pixels — no material tint, unlike NSVisualEffectView.
private typealias CGSConnectionID = UInt32
@_silgen_name("CGSDefaultConnectionForThread")
private func CGSDefaultConnectionForThread() -> CGSConnectionID
@_silgen_name("CGSSetWindowBackgroundBlurRadius")
@discardableResult
private func CGSSetWindowBackgroundBlurRadius(_ connection: CGSConnectionID, _ windowNumber: UInt32, _ radius: UInt32) -> Int32

private func applyWindowBackgroundBlur(_ window: NSWindow, radius: UInt32) {
    guard window.windowNumber > 0 else { return }
    CGSSetWindowBackgroundBlurRadius(CGSDefaultConnectionForThread(), UInt32(window.windowNumber), radius)
}

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Layer-backed overlay root view

private final class GlassOverlayView: NSView {
    override var isOpaque: Bool { false }

    func enableLayerBacking() {
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    /// Fade the overlay in with a single GPU-composited opacity pass.
    func playAppear() {
        guard let layer else { return }
        layer.removeAnimation(forKey: "opacity")
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 0
        anim.toValue = 1
        anim.duration = 0.15
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        anim.fillMode = .backwards
        anim.isRemovedOnCompletion = true
        layer.opacity = 1
        layer.add(anim, forKey: "opacity")
    }

    /// Fade the overlay out, then call `completion` (runs on main thread).
    func playDisappear(then completion: @escaping () -> Void) {
        guard let layer else { completion(); return }
        layer.removeAnimation(forKey: "opacity")
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = layer.presentation()?.opacity ?? 1
        anim.toValue = 0
        anim.duration = 0.10
        anim.timingFunction = CAMediaTimingFunction(name: .easeIn)
        anim.fillMode = .forwards
        anim.isRemovedOnCompletion = false
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        layer.opacity = 0
        layer.add(anim, forKey: "opacity")
        CATransaction.commit()
    }
}

// MARK: - Spoke overlay: right-side arc with de-overlapped preview pills

final class SpokeOverlay {
    static let shared = SpokeOverlay()

    private var overlayWindow: NSWindow?
    private var glassView: GlassOverlayView?
    private var backdropController: OverlayBackdropController?
    private var currentItems: [ClipboardItem] = []
    private var allItems: [ClipboardItem] = []
    private var currentFavorites: [FavoriteItem] = []
    private var globalClickMonitor: Any?
    private var localEventMonitor: Any?
    private var mouseTracker: MouseTracker?
    private var scrollAccumulator: CGFloat = 0
    private var cursorMoved: Bool = false
    private var hitZones: [HitZone] = []
    private var favHitZones: [HitZone] = []
    private var previousApp: NSRunningApplication?
    // Layout params stored for search hit zone recomputation
    private var layoutCenterX: CGFloat = 0
    private var layoutCenterY: CGFloat = 0
    private var layoutWindowHeight: CGFloat = 0
    private var layoutSpokeRadius: CGFloat = 0
    private var layoutDotSize: CGFloat = 26
    private var layoutPreviewGap: CGFloat = 16
    private var layoutPreviewWidth: CGFloat = 160
    private var layoutPreviewLength: Int = 20
    private var layoutFavCount: Int = 0

    private init() {}

    struct HitZone {
        let index: Int
        let dotCenter: CGPoint
        let dotRadius: CGFloat
        let pillRect: CGRect
    }

    func show(items: [ClipboardItem]) {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = front
        }

        let settings = AppSettings.shared
        let maxItems = min(items.count, settings.overlayItemCount)
        let displayItems = Array(items.prefix(maxItems))
        currentItems = displayItems
        self.allItems = Array(items.prefix(settings.historyDepth))
        let allFavs = settings.favorites.sorted { $0.order < $1.order }
        // Window favorites to the same max as clipboard items; the rest are
        // reachable by scrolling on the favorites (left) side.
        let favWindowCount = min(allFavs.count, settings.overlayItemCount)
        let favs = Array(allFavs.prefix(favWindowCount))
        currentFavorites = allFavs
        layoutFavCount = favWindowCount
        hide()

        let spokeRadius = settings.spokeRadius
        let dotSize: CGFloat = 26
        let previewGap: CGFloat = 16
        let textPillHeight: CGFloat = 26
        let imagePillHeight: CGFloat = 60
        let charWidth: CGFloat = 7
        let previewWidth = max(160, min(600, CGFloat(settings.overlayPreviewLength) * charWidth + 20))

        // Per-item pill heights (right side — clipboard items)
        let pillHeights: [CGFloat] = displayItems.map { $0.isImage ? imagePillHeight : textPillHeight }

        // Favorite pill heights (left side — all text)
        let favPillHeights: [CGFloat] = favs.map { _ in textPillHeight }

        struct DotInfo {
            let angle: CGFloat
            let relX: CGFloat
            let relY: CGFloat
        }

        // ── Right side dots (clipboard items) ──
        var dots: [DotInfo] = []
        for i in 0..<displayItems.count {
            let angle = SpokeOverlay.angleForIndex(i, count: displayItems.count, spokeRadius: spokeRadius, dotSize: dotSize)
            dots.append(DotInfo(
                angle: angle,
                relX: spokeRadius * cos(angle),
                relY: -spokeRadius * sin(angle)
            ))
        }

        // ── Left side dots (favorites) ──
        var favDots: [DotInfo] = []
        for i in 0..<favs.count {
            let angle = SpokeOverlay.favAngleForIndex(i, count: favs.count, spokeRadius: spokeRadius, dotSize: dotSize)
            favDots.append(DotInfo(
                angle: angle,
                relX: spokeRadius * cos(angle),
                relY: -spokeRadius * sin(angle)
            ))
        }

        // ── Right side pill Y de-overlap ──
        var pillRelYs = dots.map { $0.relY }
        if pillRelYs.count > 1 {
            for i in 1..<pillRelYs.count {
                let spacing = (pillHeights[i - 1] + pillHeights[i]) / 2 + 6
                if pillRelYs[i] < pillRelYs[i - 1] + spacing {
                    pillRelYs[i] = pillRelYs[i - 1] + spacing
                }
            }
            let naturalMid = (dots.first!.relY + dots.last!.relY) / 2
            let resolvedMid = (pillRelYs.first! + pillRelYs.last!) / 2
            let shift = naturalMid - resolvedMid
            pillRelYs = pillRelYs.map { $0 + shift }
        }

        // ── Left side pill Y de-overlap ──
        var favPillRelYs = favDots.map { $0.relY }
        if favPillRelYs.count > 1 {
            for i in 1..<favPillRelYs.count {
                let spacing = (favPillHeights[i - 1] + favPillHeights[i]) / 2 + 6
                if favPillRelYs[i] < favPillRelYs[i - 1] + spacing {
                    favPillRelYs[i] = favPillRelYs[i - 1] + spacing
                }
            }
            let naturalMid = (favDots.first!.relY + favDots.last!.relY) / 2
            let resolvedMid = (favPillRelYs.first! + favPillRelYs.last!) / 2
            let shift = naturalMid - resolvedMid
            favPillRelYs = favPillRelYs.map { $0 + shift }
        }

        // Pill X follows each dot's X (right side: extends right)
        var pillRelXs: [CGFloat] = []
        for dot in dots {
            pillRelXs.append(dot.relX + dotSize / 2 + previewGap)
        }

        // Fav pills extend LEFT from dot
        var favPillRelXs: [CGFloat] = []
        for dot in favDots {
            favPillRelXs.append(dot.relX - dotSize / 2 - previewGap)
        }

        // ── Window sizing ──
        let paddingOuter: CGFloat = 20
        let paddingVert: CGFloat = 30
        let dotMaxVert = spokeRadius + dotSize / 2
        let pillMaxVert: CGFloat = {
            var mv: CGFloat = 0
            for i in 0..<pillRelYs.count {
                let edge = abs(pillRelYs[i]) + pillHeights[i] / 2
                if edge > mv { mv = edge }
            }
            for i in 0..<favPillRelYs.count {
                let edge = abs(favPillRelYs[i]) + favPillHeights[i] / 2
                if edge > mv { mv = edge }
            }
            return mv
        }()
        // Also account for max 9 search results when sizing the window
        let searchMaxVert: CGFloat = {
            let maxSearchItems = 9
            let searchSpacing: CGFloat = textPillHeight + 6  // 32
            let totalSpan = CGFloat(maxSearchItems - 1) * searchSpacing
            return totalSpan / 2 + textPillHeight / 2
        }()
        let maxVert = max(dotMaxVert, max(pillMaxVert, searchMaxVert))

        let maxPillRight = (pillRelXs.max() ?? (spokeRadius + dotSize / 2 + previewGap)) + previewWidth
        let maxFavPillLeft = abs(favPillRelXs.min() ?? -(spokeRadius + dotSize / 2 + previewGap)) + previewWidth
        let backdropEnabled = settings.overlayBackdropSpread > 0.001 && settings.overlayBackdropIntensity > 0.001
        let spreadCurve = backdropSpreadCurve(CGFloat(settings.overlayBackdropSpread))
        let intensityCurve = backdropIntensityCurve(CGFloat(settings.overlayBackdropIntensity))
        let backdropPaddingX: CGFloat = backdropEnabled
            ? 10 + spreadCurve * 90 + intensityCurve * 8
            : 0
        let backdropPaddingY: CGFloat = backdropEnabled
            ? 8 + spreadCurve * 64 + intensityCurve * 6
            : 0

        let centerX = paddingOuter + backdropPaddingX + maxFavPillLeft
        let windowWidth = centerX + maxPillRight + paddingOuter + backdropPaddingX
        let windowHeight = maxVert * 2 + paddingVert * 2 + backdropPaddingY * 2
        let windowSize = CGSize(width: windowWidth, height: windowHeight)

        let centerY = windowHeight / 2

        // Store layout params for search mode hit zone recomputation
        layoutCenterX = centerX
        layoutCenterY = centerY
        layoutWindowHeight = windowHeight
        layoutSpokeRadius = spokeRadius
        layoutDotSize = dotSize
        layoutPreviewGap = previewGap
        layoutPreviewWidth = previewWidth
        layoutPreviewLength = settings.overlayPreviewLength

        let absPillYs = pillRelYs.map { centerY + $0 }
        let absPillXs = pillRelXs.map { centerX + $0 }
        let absFavPillYs = favPillRelYs.map { centerY + $0 }
        let absFavPillXs = favPillRelXs.map { centerX + $0 }  // these are left edges (negative relative)

        let cursor = NSEvent.mouseLocation

        // Clamp the window origin so the overlay stays fully inside the visible
        // frame of whichever screen the cursor is on (respects menu bar + Dock).
        let screen = NSScreen.screens.first { $0.frame.contains(cursor) } ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(origin: .zero, size: windowSize)
        let rawOrigin = CGPoint(x: cursor.x - centerX, y: cursor.y - centerY)
        let clampedX = min(max(rawOrigin.x, visibleFrame.minX), visibleFrame.maxX - windowSize.width)
        let clampedY = min(max(rawOrigin.y, visibleFrame.minY), visibleFrame.maxY - windowSize.height)
        let origin = CGPoint(x: clampedX, y: clampedY)

        let window = KeyablePanel(
            contentRect: NSRect(origin: origin, size: windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .screenSaver
        window.hasShadow = false
        // Suppress AppKit's _NSWindowTransformAnimation — it holds a block that
        // captures the window and races with our playDisappear completion block,
        // causing EXC_BAD_ACCESS (use-after-free) in CA transaction flush.
        window.animationBehavior = .none
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.becomesKeyOnlyIfNeeded = false

        // ── Right-side hit zones ──
        var zones: [HitZone] = []
        for i in 0..<displayItems.count {
            let dotNSX = centerX + dots[i].relX
            let dotNSY = windowHeight - (centerY + dots[i].relY)
            let pillNSY = windowHeight - absPillYs[i]
            let pillNSX = absPillXs[i]
            let ph = pillHeights[i]
            let pillWidth = overlayRightPillWidth(
                for: displayItems[i],
                previewLength: settings.overlayPreviewLength,
                maxWidth: previewWidth,
                pillHeight: ph
            )
            zones.append(HitZone(
                index: i,
                dotCenter: CGPoint(x: dotNSX, y: dotNSY),
                dotRadius: 22,
                pillRect: CGRect(x: pillNSX, y: pillNSY - ph / 2, width: pillWidth, height: ph)
            ))
        }
        hitZones = zones

        // ── Left-side hit zones (favorites) ──
        var fZones: [HitZone] = []
        for i in 0..<favs.count {
            let dotNSX = centerX + favDots[i].relX
            let dotNSY = windowHeight - (centerY + favDots[i].relY)
            let pillNSY = windowHeight - absFavPillYs[i]
            let ph = favPillHeights[i]
            let pillWidth = overlayFavoritePillWidth(
                for: favs[i],
                previewLength: settings.overlayPreviewLength,
                maxWidth: previewWidth
            )
            let pillNSX = absFavPillXs[i] - pillWidth  // pill extends left
            fZones.append(HitZone(
                index: i,
                dotCenter: CGPoint(x: dotNSX, y: dotNSY),
                dotRadius: 22,
                pillRect: CGRect(x: pillNSX, y: pillNSY - ph / 2, width: pillWidth, height: ph)
            ))
        }
        favHitZones = fZones

        let tracker = MouseTracker()
        tracker.isSearching = true
        tracker.scrollOffset = 0
        tracker.favScrollOffset = 0
        mouseTracker = tracker
        scrollAccumulator = 0
        cursorMoved = false

        let backdropController = OverlayBackdropController()
        self.backdropController = backdropController

        let spokeView = SpokeView(
            items: displayItems,
            allItems: allItems,
            favorites: favs,
            allFavorites: allFavs,
            previewLength: settings.overlayPreviewLength,
            backdropSpread: CGFloat(settings.overlayBackdropSpread),
            backdropIntensity: CGFloat(settings.overlayBackdropIntensity),
            windowSize: windowSize,
            centerX: centerX,
            centerY: centerY,
            spokeRadius: spokeRadius,
            dotSize: dotSize,
            previewGap: previewGap,
            previewWidth: previewWidth,
            pillYPositions: absPillYs,
            pillXPositions: absPillXs,
            pillHeights: pillHeights,
            favPillYPositions: absFavPillYs,
            favPillXPositions: absFavPillXs,
            favPillHeights: favPillHeights,
            rightItemCount: displayItems.count,
            tracker: tracker,
            backdropController: backdropController
        )
        let backdropView = NSVisualEffectView(frame: NSRect(origin: .zero, size: windowSize))
        backdropView.autoresizingMask = [.width, .height]
        backdropController.attach(to: backdropView)

        let hosting = NSHostingView(rootView: spokeView)
        hosting.frame = NSRect(origin: .zero, size: windowSize)
        hosting.autoresizingMask = [.width, .height]

        let glassOverlayView = GlassOverlayView(frame: NSRect(origin: .zero, size: windowSize))
        glassOverlayView.enableLayerBacking()
        glassOverlayView.autoresizingMask = [.width, .height]
        glassOverlayView.addSubview(backdropView)
        glassOverlayView.addSubview(hosting)
        window.contentView = glassOverlayView

        window.makeKeyAndOrderFront(nil)
        // Pure blur behind the overlay's painted pixels (shaped by the backdrop
        // mask + pill/dot content). Intensity setting scales the blur radius.
        let blurRadius = UInt32(10 + backdropIntensityCurve(CGFloat(settings.overlayBackdropIntensity)) * 30)
        applyWindowBackgroundBlur(window, radius: blurRadius)
        overlayWindow = window
        glassView = glassOverlayView
        glassOverlayView.playAppear()

        installEventMonitors()
    }

    func hide() {
        backdropController?.clear()
        backdropController = nil
        glassView = nil
        overlayWindow?.orderOut(nil)
        overlayWindow = nil
        mouseTracker = nil
        hitZones = []
        favHitZones = []
        removeEventMonitors()
        ClipboardEngine.shared.isOverlayVisible = false
    }

    /// Animated hide for user-initiated dismissal (Escape, outside click).
    /// Tears down state immediately so no further events are processed, then
    /// plays a GPU-composited fade-out before ordering the window out.
    private func hideAnimated() {
        guard let gv = glassView, let win = overlayWindow else {
            hide(); return
        }
        backdropController?.clear()
        backdropController = nil
        glassView = nil
        overlayWindow = nil
        mouseTracker = nil
        hitZones = []
        favHitZones = []
        removeEventMonitors()
        ClipboardEngine.shared.isOverlayVisible = false
        gv.playDisappear {
            win.orderOut(nil)
        }
    }

    private func installEventMonitors() {
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .keyDown, .flagsChanged, .scrollWheel]) { [weak self] event in
            guard let self else { return event }

            if event.type == .flagsChanged {
                self.mouseTracker?.shiftHeld = event.modifierFlags.contains(.shift)
                return event
            }

            if event.type == .scrollWheel {
                guard (self.mouseTracker?.searchText ?? "").isEmpty else { return nil }
                let dy = -event.scrollingDeltaY
                // Until the cursor moves, there's no side decision yet → default
                // to clipboard items (right). Once moved, use the true centre
                // split so even a slight move left switches to favorites.
                let onFavSide = self.cursorMoved && event.locationInWindow.x < self.layoutCenterX
                var pendingSteps = 0
                if event.hasPreciseScrollingDeltas {
                    self.scrollAccumulator += dy
                    let threshold: CGFloat = 28
                    if abs(self.scrollAccumulator) >= threshold {
                        pendingSteps = Int(self.scrollAccumulator / threshold)
                        self.scrollAccumulator -= CGFloat(pendingSteps) * threshold
                    }
                } else {
                    pendingSteps = dy > 0 ? -1 : (dy < 0 ? 1 : 0)
                }
                if pendingSteps != 0 {
                    if onFavSide {
                        self.applyFavScrollSteps(pendingSteps)
                    } else {
                        self.applyScrollSteps(pendingSteps)
                    }
                }
                return nil
            }

            if event.type == .mouseMoved {
                self.cursorMoved = true
                let loc = event.locationInWindow
                var hitIndex: Int? = nil
                var hitFavIndex: Int? = nil

                // Check right-side (clipboard) zones
                for zone in self.hitZones {
                    let dx = loc.x - zone.dotCenter.x
                    let dy = loc.y - zone.dotCenter.y
                    if sqrt(dx * dx + dy * dy) <= zone.dotRadius {
                        hitIndex = zone.index; break
                    }
                    if zone.pillRect.contains(loc) {
                        hitIndex = zone.index; break
                    }
                }
                // Check left-side (favorite) zones
                if hitIndex == nil {
                    for zone in self.favHitZones {
                        let dx = loc.x - zone.dotCenter.x
                        let dy = loc.y - zone.dotCenter.y
                        if sqrt(dx * dx + dy * dy) <= zone.dotRadius {
                            hitFavIndex = zone.index; break
                        }
                        if zone.pillRect.contains(loc) {
                            hitFavIndex = zone.index; break
                        }
                    }
                }
                self.mouseTracker?.hoveredIndex = hitIndex
                self.mouseTracker?.hoveredFavIndex = hitFavIndex
                return event
            }

            if event.type == .leftMouseDown {
                let loc = event.locationInWindow
                let hasSearchText = !(self.mouseTracker?.searchText ?? "").isEmpty
                let shift = event.modifierFlags.contains(.shift)
                // Check right-side zones
                for zone in self.hitZones {
                    let dx = loc.x - zone.dotCenter.x
                    let dy = loc.y - zone.dotCenter.y
                    let hitDot = sqrt(dx * dx + dy * dy) <= zone.dotRadius
                    let hitPill = zone.pillRect.contains(loc)
                    if hitDot || hitPill {
                        if hasSearchText {
                            self.selectSearchResult(zone.index, plainText: shift)
                        } else if zone.index < self.currentItems.count {
                            self.selectWithFlash(zone.index, plainText: shift)
                        }
                        return nil
                    }
                }
                // Check left-side (favorite) zones (only when not actively searching)
                if !hasSearchText {
                    for zone in self.favHitZones {
                        let dx = loc.x - zone.dotCenter.x
                        let dy = loc.y - zone.dotCenter.y
                        let hitDot = sqrt(dx * dx + dy * dy) <= zone.dotRadius
                        let hitPill = zone.pillRect.contains(loc)
                        let favOffset = self.mouseTracker?.favScrollOffset ?? 0
                        if (hitDot || hitPill) && favOffset + zone.index < self.currentFavorites.count {
                            self.selectFavWithFlash(zone.index, plainText: shift)
                            return nil
                        }
                    }
                }
                self.hideAnimated()
                return nil
            }

            if event.type == .keyDown {
                if event.keyCode == 53 {
                    // Escape: close overlay
                    self.hideAnimated()
                    return nil
                }

                let shift = event.modifierFlags.contains(.shift)
                let cmd = event.modifierFlags.contains(.command)
                let plainTextShortcut = cmd && shift
                let shortcutChars = (event.charactersIgnoringModifiers ?? event.characters ?? "").lowercased()

                // ⌘+number: directly select clipboard item at that position
                let numMap: [UInt16: Int] = [18:1, 19:2, 20:3, 21:4, 23:5, 22:6, 26:7, 28:8, 25:9]
                if cmd, let num = numMap[event.keyCode] {
                    let index = num - 1
                    let hasSearch = !(self.mouseTracker?.searchText ?? "").isEmpty
                    if hasSearch {
                        let filtered = self.searchFilteredItems()
                        if index < filtered.count {
                            self.selectSearchResult(index, plainText: plainTextShortcut)
                            return nil
                        }
                    } else if index < self.currentItems.count {
                        self.selectWithFlash(index, plainText: plainTextShortcut)
                        return nil
                    }
                }

                // ⌘+letter: directly select favorite with that letter
                if cmd {
                    let lower = shortcutChars
                    if lower.count == 1, lower >= "a", lower <= "z" {
                        if let favIndex = self.currentFavorites.firstIndex(where: { $0.letter == lower }) {
                            self.selectFavByFullIndex(favIndex, plainText: plainTextShortcut)
                            return nil
                        }
                    }
                }

                // Backspace: remove last search char, or close if empty
                if event.keyCode == 51 {
                    if let t = self.mouseTracker?.searchText, !t.isEmpty {
                        self.mouseTracker?.searchText = String(t.dropLast())
                        self.mouseTracker?.hoveredIndex = nil
                        self.updateSearchHitZones()
                    } else {
                        self.hideAnimated()
                    }
                    return nil
                }

                // Return: select highlighted or first result (search or normal)
                if event.keyCode == 36 {
                    let hasSearch = !(self.mouseTracker?.searchText ?? "").isEmpty
                    if hasSearch {
                        let filtered = self.searchFilteredItems()
                        if !filtered.isEmpty {
                            let idx = self.mouseTracker?.hoveredIndex ?? 0
                            self.selectSearchResult(idx, plainText: shift)
                        }
                    } else {
                        // No search text: select first clipboard item
                        let idx = self.mouseTracker?.hoveredIndex ?? 0
                        if idx < self.currentItems.count {
                            self.selectWithFlash(idx, plainText: shift)
                        }
                    }
                    return nil
                }

                // Arrow right/down: move highlight down
                if event.keyCode == 124 || event.keyCode == 125 {
                    let filtered = self.searchFilteredItems()
                    guard !filtered.isEmpty else { return nil }
                    if let cur = self.mouseTracker?.hoveredIndex {
                        let next = min(cur + 1, filtered.count - 1)
                        self.mouseTracker?.hoveredIndex = next
                    } else {
                        self.mouseTracker?.hoveredIndex = 0
                    }
                    return nil
                }

                // Arrow left/up: move highlight up
                if event.keyCode == 123 || event.keyCode == 126 {
                    if let cur = self.mouseTracker?.hoveredIndex, cur > 0 {
                        self.mouseTracker?.hoveredIndex = cur - 1
                    }
                    return nil
                }

                // Append typed character to search
                if let input = searchInputText(from: event) {
                    self.mouseTracker?.searchText = (self.mouseTracker?.searchText ?? "") + input
                    self.mouseTracker?.hoveredIndex = nil
                    self.updateSearchHitZones()
                }
                return nil
            }

            return event
        }

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hideAnimated()
        }
    }

    /// Flash the selected item, then paste after a brief delay
    private func selectWithFlash(_ index: Int, plainText: Bool = false) {
        mouseTracker?.selectedIndex = index
        let offset = mouseTracker?.scrollOffset ?? 0
        let actualIndex = offset + index
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, actualIndex < self.allItems.count else { return }
            self.performSelectAndPaste(self.allItems[actualIndex], plainText: plainText)
        }
    }

    private func applyScrollSteps(_ steps: Int) {
        guard let tracker = mouseTracker, steps != 0 else { return }
        let windowSize = currentItems.count
        let maxOffset = max(0, allItems.count - windowSize)
        tracker.scrollOffset = max(0, min(maxOffset, tracker.scrollOffset + steps))
        // Clear the highlight while scrolling; it feels wrong for a stationary
        // cursor to keep highlighting whatever item scrolls under it. The next
        // mouseMoved recomputes the hover from the cursor's actual position.
        tracker.hoveredIndex = nil
        tracker.selectedIndex = nil
        scrollAccumulator = 0
    }

    private func applyFavScrollSteps(_ steps: Int) {
        guard let tracker = mouseTracker, steps != 0 else { return }
        let maxOffset = max(0, currentFavorites.count - layoutFavCount)
        tracker.favScrollOffset = max(0, min(maxOffset, tracker.favScrollOffset + steps))
        tracker.hoveredFavIndex = nil
        tracker.selectedFavIndex = nil
        scrollAccumulator = 0
    }

    /// Flash a favorite (by on-screen display index), then paste after a brief delay
    private func selectFavWithFlash(_ displayIndex: Int, plainText: Bool = false) {
        mouseTracker?.selectedFavIndex = displayIndex
        let offset = mouseTracker?.favScrollOffset ?? 0
        let actualIndex = offset + displayIndex
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, actualIndex < self.currentFavorites.count else { return }
            self.performFavSelectAndPaste(self.currentFavorites[actualIndex], plainText: plainText)
        }
    }

    /// Select a favorite by its full-list index (⌘+letter shortcut). Flashes the
    /// on-screen dot only if that favorite is within the visible scroll window.
    private func selectFavByFullIndex(_ fullIndex: Int, plainText: Bool = false) {
        guard fullIndex < currentFavorites.count else { return }
        let offset = mouseTracker?.favScrollOffset ?? 0
        let displayIndex = fullIndex - offset
        if displayIndex >= 0 && displayIndex < layoutFavCount {
            mouseTracker?.selectedFavIndex = displayIndex
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, fullIndex < self.currentFavorites.count else { return }
            self.performFavSelectAndPaste(self.currentFavorites[fullIndex], plainText: plainText)
        }
    }

    // MARK: - Search mode helpers

    private func searchFilteredItems() -> [ClipboardItem] {
        let query = mouseTracker?.searchText ?? ""
        guard !query.isEmpty else { return [] }
        return Array(allItems.lazy.filter { overlaySearchMatches($0.text, query: query) }.prefix(9))
    }

    private func selectSearchResult(_ index: Int, plainText: Bool = false) {
        let filtered = searchFilteredItems()
        guard index < filtered.count else { return }
        mouseTracker?.selectedIndex = index
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.performSelectAndPaste(filtered[index], plainText: plainText)
        }
    }

    private func updateSearchHitZones() {
        let filtered = searchFilteredItems()
        let count = filtered.count
        let textPillHeight: CGFloat = 26

        // Recompute right-side hit zones for filtered items
        var relYs: [CGFloat] = (0..<count).map { i in
            let angle = SpokeOverlay.angleForIndex(i, count: count, spokeRadius: layoutSpokeRadius, dotSize: layoutDotSize)
            return -layoutSpokeRadius * sin(angle)
        }
        if relYs.count > 1 {
            for i in 1..<relYs.count {
                let spacing = textPillHeight + 6
                if relYs[i] < relYs[i - 1] + spacing {
                    relYs[i] = relYs[i - 1] + spacing
                }
            }
            let first = -layoutSpokeRadius * sin(SpokeOverlay.angleForIndex(0, count: count, spokeRadius: layoutSpokeRadius, dotSize: layoutDotSize))
            let last = -layoutSpokeRadius * sin(SpokeOverlay.angleForIndex(count - 1, count: count, spokeRadius: layoutSpokeRadius, dotSize: layoutDotSize))
            let shift = (first + last) / 2 - (relYs.first! + relYs.last!) / 2
            relYs = relYs.map { $0 + shift }
        }

        var zones: [HitZone] = []
        for i in 0..<count {
            let angle = SpokeOverlay.angleForIndex(i, count: count, spokeRadius: layoutSpokeRadius, dotSize: layoutDotSize)
            let dotRelX = layoutSpokeRadius * cos(angle)
            let dotRelY = -layoutSpokeRadius * sin(angle)
            let dotNSX = layoutCenterX + dotRelX
            let dotNSY = layoutWindowHeight - (layoutCenterY + dotRelY)
            let pillRelX = dotRelX + layoutDotSize / 2 + layoutPreviewGap
            let pillNSX = layoutCenterX + pillRelX
            let pillRelY = i < relYs.count ? relYs[i] : dotRelY
            let pillNSY = layoutWindowHeight - (layoutCenterY + pillRelY)
            let pillHeight: CGFloat = filtered[i].isImage ? 60 : textPillHeight
            let pillWidth = overlayRightPillWidth(
                for: filtered[i],
                previewLength: layoutPreviewLength,
                maxWidth: layoutPreviewWidth,
                pillHeight: pillHeight
            )
            zones.append(HitZone(
                index: i,
                dotCenter: CGPoint(x: dotNSX, y: dotNSY),
                dotRadius: 22,
                pillRect: CGRect(x: pillNSX, y: pillNSY - pillHeight / 2, width: pillWidth, height: pillHeight)
            ))
        }
        hitZones = zones
        // Hide fav zones when there's search text
        if !(mouseTracker?.searchText ?? "").isEmpty {
            favHitZones = []
        }
    }

    func performSelectAndPaste(_ item: ClipboardItem, plainText: Bool = false) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if plainText {
            // Strip formatting: paste as plain string only
            pb.setString(item.fullText, forType: .string)
        } else if item.isImage, let img = item.nsImage {
            pb.writeObjects([img])
        } else if let rich = item.richData, !rich.isEmpty {
            // Restore all original pasteboard types + plain text
            var types = rich.map { NSPasteboard.PasteboardType($0.key) }
            types.append(.string)
            pb.declareTypes(types, owner: nil)
            for (typeStr, data) in rich {
                pb.setData(data, forType: NSPasteboard.PasteboardType(typeStr))
            }
            pb.setString(item.fullText, forType: .string)
        } else {
            pb.setString(item.fullText, forType: .string)
        }

        ClipboardEngine.shared.didSelectItem(item)

        let prevApp = self.previousApp
        hide()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            prevApp?.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                let src = CGEventSource(stateID: .combinedSessionState)
                let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)
                keyDown?.flags = .maskCommand
                let keyUp = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
                keyUp?.flags = .maskCommand
                keyDown?.post(tap: .cghidEventTap)
                keyUp?.post(tap: .cghidEventTap)
            }
        }
    }

    func performFavSelectAndPaste(_ fav: FavoriteItem, plainText: Bool = false) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(fav.text, forType: .string)

        // Update the engine's change count so it doesn't re-capture this as a new item
        ClipboardEngine.shared.didPasteFavorite(fav)

        let prevApp = self.previousApp
        hide()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            prevApp?.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                let src = CGEventSource(stateID: .combinedSessionState)
                let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)
                keyDown?.flags = .maskCommand
                let keyUp = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
                keyUp?.flags = .maskCommand
                keyDown?.post(tap: .cghidEventTap)
                keyUp?.post(tap: .cghidEventTap)
            }
        }
    }

    private func removeEventMonitors() {
        if let m = globalClickMonitor { NSEvent.removeMonitor(m); globalClickMonitor = nil }
        if let m = localEventMonitor { NSEvent.removeMonitor(m); localEventMonitor = nil }
    }

    /// Angular step: reference step from 10-item arc, but enforced minimum so dots never overlap
    private static func step(spokeRadius: CGFloat, dotSize: CGFloat) -> CGFloat {
        let referenceStep: CGFloat = (.pi * 5 / 6) / CGFloat(10 - 1)
        let minArcDist = dotSize + 4          // 4pt gap between dot edges
        let minStep = minArcDist / spokeRadius
        return max(referenceStep, minStep)
    }

    static func angleForIndex(_ index: Int, count: Int, spokeRadius: CGFloat, dotSize: CGFloat) -> CGFloat {
        guard count > 1 else { return 0 }
        let s = step(spokeRadius: spokeRadius, dotSize: dotSize)
        let totalSpread = s * CGFloat(count - 1)
        let startAngle = totalSpread / 2
        return startAngle - CGFloat(index) * s
    }

    /// Left-side arc: same step, centered on π, index 0 at top
    static func favAngleForIndex(_ index: Int, count: Int, spokeRadius: CGFloat, dotSize: CGFloat) -> CGFloat {
        guard count > 1 else { return .pi }
        let s = step(spokeRadius: spokeRadius, dotSize: dotSize)
        let totalSpread = s * CGFloat(count - 1)
        let startAngle: CGFloat = .pi - totalSpread / 2
        return startAngle + CGFloat(index) * s
    }
}

// MARK: - Observable mouse tracker

@Observable
final class MouseTracker {
    var hoveredIndex: Int? = nil
    var selectedIndex: Int? = nil
    var hoveredFavIndex: Int? = nil
    var selectedFavIndex: Int? = nil
    var shiftHeld: Bool = false
    var isSearching: Bool = false
    var searchText: String = ""
    var scrollOffset: Int = 0
    var favScrollOffset: Int = 0
}

// MARK: - SwiftUI spoke view

// MARK: Glass styling components

/// Layered "glass" background for preview pills: vertical sheen gradient,
/// gradient hairline border (light top → accent bottom), accent glow when highlighted.
private struct GlassPillBackground: View {
    let accent: Color
    let isHighlighted: Bool
    var cornerRadius: CGFloat = 8

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(
                LinearGradient(
                    colors: isHighlighted
                        ? [Color(white: 0.30, opacity: 0.97), Color(white: 0.15, opacity: 0.97)]
                        : [Color(white: 0.20, opacity: 0.93), Color(white: 0.09, opacity: 0.95)],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: isHighlighted
                                ? [.white.opacity(0.60), accent.opacity(0.85)]
                                : [.white.opacity(0.22), accent.opacity(0.32)],
                            startPoint: .top, endPoint: .bottom
                        ),
                        lineWidth: isHighlighted ? 1.5 : 1
                    )
            }
            .shadow(color: isHighlighted ? accent.opacity(0.55) : .black.opacity(0.5),
                    radius: isHighlighted ? 10 : 6, y: 2)
    }
}

/// Glass dot with radial depth, gradient rim and accent glow when highlighted.
private struct GlassDot: View {
    let accent: Color
    let isHighlighted: Bool
    let label: String

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: isHighlighted
                            ? [accent.opacity(0.95), accent.opacity(0.60)]
                            : [Color(white: 0.24, opacity: 0.95), Color(white: 0.07, opacity: 0.95)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .overlay {
                    Circle()
                        .strokeBorder(
                            LinearGradient(
                                colors: isHighlighted
                                    ? [.white.opacity(0.85), accent.opacity(0.9)]
                                    : [.white.opacity(0.30), accent.opacity(0.42)],
                                startPoint: .top, endPoint: .bottom
                            ),
                            lineWidth: 1.5
                        )
                }
                .shadow(color: isHighlighted ? accent.opacity(0.75) : .black.opacity(0.4),
                        radius: isHighlighted ? 12 : 4, y: isHighlighted ? 0 : 2)

            Text(label)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(isHighlighted ? 0.35 : 0), radius: 1, y: 1)
        }
    }
}

private struct BackdropLine: Equatable {
    let start: CGPoint
    let end: CGPoint
    let width: CGFloat
}

private struct BackdropMaskGeometry: Equatable {
    let size: CGSize
    let searchRect: CGRect
    let centerRect: CGRect
    let dotRects: [CGRect]
    let pillRects: [CGRect]
    let lines: [BackdropLine]
}

private func drawBackdropMaskGeometry(_ geometry: BackdropMaskGeometry, in context: GraphicsContext) {
    let fill = GraphicsContext.Shading.color(.white)

    context.fill(
        Path(roundedRect: geometry.searchRect, cornerRadius: geometry.searchRect.height / 2),
        with: fill
    )
    context.fill(Path(ellipseIn: geometry.centerRect), with: fill)

    for line in geometry.lines {
        var path = Path()
        path.move(to: line.start)
        path.addLine(to: line.end)
        context.stroke(
            path,
            with: fill,
            style: StrokeStyle(lineWidth: line.width, lineCap: .round, lineJoin: .round)
        )
    }

    for dotRect in geometry.dotRects {
        context.fill(Path(ellipseIn: dotRect), with: fill)
    }

    for pillRect in geometry.pillRects {
        context.fill(Path(roundedRect: pillRect, cornerRadius: pillRect.height / 2), with: fill)
    }
}

private struct BackdropMaskCanvasView: View {
    let geometry: BackdropMaskGeometry

    var body: some View {
        Canvas { context, _ in
            drawBackdropMaskGeometry(geometry, in: context)
        }
        .frame(width: geometry.size.width, height: geometry.size.height)
    }
}

@MainActor
private final class OverlayBackdropController {
    struct RenderKey: Equatable {
        let material: NSVisualEffectView.Material
        let geometry: BackdropMaskGeometry
        let spread: Int
        let intensity: Int

        init(material: NSVisualEffectView.Material, geometry: BackdropMaskGeometry, spread: CGFloat, intensity: CGFloat) {
            self.material = material
            self.geometry = geometry
            self.spread = Int((spread * 1000).rounded())
            self.intensity = Int((intensity * 1000).rounded())
        }
    }

    private weak var effectView: NSVisualEffectView?
    private var lastKey: RenderKey?

    func attach(to view: NSVisualEffectView) {
        effectView = view
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = false
        view.material = .popover
        // Near-invisible: the view's only job is to paint non-transparent pixels
        // in the mask shape so the window-server blur has a region to act on.
        // Its own material tint is suppressed almost entirely.
        view.alphaValue = 0.07
        clear()
    }

    func update(material: NSVisualEffectView.Material, geometry: BackdropMaskGeometry, spread: CGFloat, intensity: CGFloat) {
        guard let effectView else { return }

        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.isEmphasized = false
        effectView.material = material

        let key = RenderKey(material: material, geometry: geometry, spread: spread, intensity: intensity)
        guard lastKey != key else { return }

        lastKey = key
        let scale = effectView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        effectView.maskImage = makeMaskImage(geometry: geometry, spread: spread, intensity: intensity, scale: scale)
    }

    func clear() {
        guard let effectView else { return }
        lastKey = nil

        let size = effectView.bounds.size
        guard size.width > 0, size.height > 0 else {
            effectView.maskImage = nil
            return
        }

        effectView.maskImage = transparentMask(size: size)
    }

    private func transparentMask(size: CGSize) -> NSImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.clear.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        image.unlockFocus()
        return image
    }

    private func makeMaskImage(geometry: BackdropMaskGeometry, spread: CGFloat, intensity: CGFloat, scale: CGFloat) -> NSImage? {
        let spreadCurve = backdropSpreadCurve(spread)
        let intensityCurve = backdropIntensityCurve(intensity)
        let feather = 2 + spreadCurve * 18
        // Mask must be (nearly) fully opaque inside the shapes: partial alpha
        // weakens the material into a flat tint instead of real blur.
        // Feathering happens only at the shape edges via the blur radius.
        let opacity = 0.88 + intensityCurve * 0.12
        let renderer = ImageRenderer(
            content: BackdropMaskCanvasView(geometry: geometry)
                .compositingGroup()
                .opacity(opacity)
                .blur(radius: feather)
                .frame(width: geometry.size.width, height: geometry.size.height)
        )
        renderer.proposedSize = ProposedViewSize(geometry.size)
        renderer.scale = scale
        return renderer.nsImage
    }
}

private struct SpokeView: View {
    let items: [ClipboardItem]         // initial display items (overlayItemCount)
    let allItems: [ClipboardItem]      // all history items for search
    let favorites: [FavoriteItem]      // window used for layout (favWindowCount)
    let allFavorites: [FavoriteItem]   // full favorites list for scroll windowing
    let previewLength: Int
    let backdropSpread: CGFloat
    let backdropIntensity: CGFloat
    let windowSize: CGSize
    let centerX: CGFloat
    let centerY: CGFloat
    let spokeRadius: CGFloat
    let dotSize: CGFloat
    let previewGap: CGFloat
    let previewWidth: CGFloat
    let pillYPositions: [CGFloat]
    let pillXPositions: [CGFloat]
    let pillHeights: [CGFloat]
    let favPillYPositions: [CGFloat]
    let favPillXPositions: [CGFloat]
    let favPillHeights: [CGFloat]
    let rightItemCount: Int
    @State var tracker: MouseTracker
    let backdropController: OverlayBackdropController

    @State private var revealedCount: Int = 0
    @State private var revealedFavIndices: Set<Int> = []
    @State private var flashedIndex: Int? = nil
    @State private var flashedFavIndex: Int? = nil
    @State private var pendingBackdropSync: DispatchWorkItem? = nil

    private var center: CGPoint {
        CGPoint(x: centerX, y: centerY)
    }

    /// Items currently displayed on the right side (scroll window or search filter)
    private var activeItems: [ClipboardItem] {
        let query = tracker.searchText
        if !query.isEmpty {
            return Array(allItems.lazy.filter { overlaySearchMatches($0.text, query: query) }.prefix(9))
        }
        let offset = tracker.scrollOffset
        let count  = items.count
        let start  = min(offset, allItems.count)
        let end    = min(start + count, allItems.count)
        return Array(allItems[start..<end])
    }

    /// Favorites currently displayed on the left side (scroll window)
    private var activeFavorites: [FavoriteItem] {
        let offset = tracker.favScrollOffset
        let count  = favorites.count
        let start  = min(offset, allFavorites.count)
        let end    = min(start + count, allFavorites.count)
        return Array(allFavorites[start..<end])
    }

    /// Compute de-overlapped pill Y positions for a given set of items
    private func computePillYPositions(for count: Int) -> [CGFloat] {
        guard count > 0 else { return [] }
        let textPillHeight: CGFloat = 26

        var relYs: [CGFloat] = (0..<count).map { i in
            let angle = SpokeOverlay.angleForIndex(i, count: count, spokeRadius: spokeRadius, dotSize: dotSize)
            return -spokeRadius * sin(angle)
        }

        if relYs.count > 1 {
            for i in 1..<relYs.count {
                let spacing = textPillHeight + 6
                if relYs[i] < relYs[i - 1] + spacing {
                    relYs[i] = relYs[i - 1] + spacing
                }
            }
            let naturalMid = (-spokeRadius * sin(SpokeOverlay.angleForIndex(0, count: count, spokeRadius: spokeRadius, dotSize: dotSize))
                            + -spokeRadius * sin(SpokeOverlay.angleForIndex(count - 1, count: count, spokeRadius: spokeRadius, dotSize: dotSize))) / 2
            let resolvedMid = (relYs.first! + relYs.last!) / 2
            let shift = naturalMid - resolvedMid
            relYs = relYs.map { $0 + shift }
        }

        return relYs.map { centerY + $0 }
    }

    private func computePillXPositions(for count: Int) -> [CGFloat] {
        (0..<count).map { i in
            let angle = SpokeOverlay.angleForIndex(i, count: count, spokeRadius: spokeRadius, dotSize: dotSize)
            return centerX + spokeRadius * cos(angle) + dotSize / 2 + previewGap
        }
    }

    var body: some View {
        let hasSearchText = !tracker.searchText.isEmpty
        let displayItems = activeItems
        let dynPillYs = hasSearchText ? computePillYPositions(for: displayItems.count) : pillYPositions
        let dynPillXs = hasSearchText ? computePillXPositions(for: displayItems.count) : pillXPositions
        let searchDisplayText = tracker.searchText.isEmpty ? "..." : tracker.searchText

        ZStack {
            Canvas { context, size in
                drawSpokes(context: context, size: size)
            }
            .allowsHitTesting(false)

            // ── Right side: clipboard items ──
            ForEach(Array(displayItems.enumerated()), id: \.element.id) { index, item in
                let angle = SpokeOverlay.angleForIndex(index, count: displayItems.count, spokeRadius: spokeRadius, dotSize: dotSize)
                let dotX = center.x + spokeRadius * cos(angle)
                let dotY = center.y - spokeRadius * sin(angle)
                let pillY = index < dynPillYs.count ? dynPillYs[index] : dotY
                let pillX = index < dynPillXs.count ? dynPillXs[index] : dotX
                let isHovered = tracker.hoveredIndex == index
                let isSelected = tracker.selectedIndex == index
                let isFlashed = flashedIndex == index
                let isHighlighted = isHovered || isSelected
                let isRevealed = hasSearchText || index < revealedCount

                if isRevealed {
                    let preview = overlayPreviewText(for: item, previewLength: previewLength)
                    let itemPillHeight: CGFloat = index < pillHeights.count ? pillHeights[index] : (item.isImage ? 60 : 26)
                    let visiblePillWidth = overlayRightPillWidth(
                        for: item,
                        previewLength: previewLength,
                        maxWidth: previewWidth,
                        pillHeight: itemPillHeight
                    )

                    // Numbered dot
                    GlassDot(accent: .blue, isHighlighted: isHighlighted, label: "\(tracker.scrollOffset + index + 1)")
                        .frame(width: dotSize, height: dotSize)
                        .scaleEffect(isFlashed ? 1.3 : (isHighlighted ? 1.1 : 1.0))
                        .animation(.easeOut(duration: 0.12), value: isHighlighted)
                        .position(x: dotX, y: dotY)
                        .allowsHitTesting(false)

                    // Preview pill — text or image thumbnail
                    HStack(spacing: 0) {
                        if item.isImage, let nsImg = item.nsImage {
                            Image(nsImage: nsImg)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxHeight: itemPillHeight - 8)
                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                                .padding(4)
                                .background {
                                    GlassPillBackground(accent: .blue, isHighlighted: isHighlighted)
                                }
                                .scaleEffect(isFlashed ? 1.05 : (isHighlighted ? 1.03 : 1.0), anchor: .leading)
                                .animation(.easeOut(duration: 0.12), value: isHighlighted)
                        } else {
                            Text(preview)
                                .font(.system(size: 13, weight: .regular, design: .rounded))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background {
                                    GlassPillBackground(accent: .blue, isHighlighted: isHighlighted)
                                }
                                .scaleEffect(isFlashed ? 1.05 : (isHighlighted ? 1.03 : 1.0), anchor: .leading)
                                .animation(.easeOut(duration: 0.12), value: isHighlighted)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(width: visiblePillWidth, alignment: .leading)
                    .position(x: pillX + visiblePillWidth / 2, y: pillY)
                    .allowsHitTesting(false)
                }
            }

            // ── Left side: favorites (green) — hidden during search ──
            if !hasSearchText {
                ForEach(0..<favorites.count, id: \.self) { index in
                    favItemView(index: index)
                }
            }

            // ── Search box at center (always visible) ──
            HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: overlaySearchIconSize, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                    Text(searchDisplayText)
                        .font(.system(size: overlaySearchFont.pointSize, weight: .medium, design: .rounded))
                        .foregroundStyle(tracker.searchText.isEmpty ? .white.opacity(0.35) : .white)
                }
                .padding(.horizontal, overlaySearchHorizontalPadding)
                .padding(.vertical, overlaySearchVerticalPadding)
                .background {
                    RoundedRectangle(cornerRadius: overlaySearchCornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color(white: 0.22, opacity: 0.95), Color(white: 0.10, opacity: 0.96)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: overlaySearchCornerRadius, style: .continuous)
                                .strokeBorder(
                                    LinearGradient(
                                        colors: hasSearchText
                                            ? [.white.opacity(0.55), .blue.opacity(0.85)]
                                            : [.white.opacity(0.25), .blue.opacity(0.45)],
                                        startPoint: .top, endPoint: .bottom
                                    ),
                                    lineWidth: 1
                                )
                        }
                        .shadow(color: .blue.opacity(hasSearchText ? 0.5 : 0.3), radius: hasSearchText ? 12 : 8)
                }
                .position(x: centerX, y: centerY)
                .allowsHitTesting(false)
        }
        .frame(width: windowSize.width, height: windowSize.height)
        .onAppear {
            syncBackdrop()
            animateReveal()
        }
        .onDisappear {
            cancelScheduledBackdropSync()
            backdropController.clear()
        }
        .onChange(of: tracker.searchText) { _, _ in
            scheduleBackdropSync()
        }
        .onChange(of: tracker.scrollOffset) { _, _ in
            scheduleBackdropSync()
        }
        .onChange(of: tracker.favScrollOffset) { _, _ in
            scheduleBackdropSync()
        }
        .onChange(of: revealedCount) { _, _ in
            scheduleBackdropSync()
        }
        .onChange(of: revealedFavIndices) { _, _ in
            scheduleBackdropSync()
        }
        .onChange(of: tracker.selectedIndex) { _, newValue in
            if let idx = newValue {
                withAnimation(.easeOut(duration: 0.15)) {
                    flashedIndex = idx
                }
            }
        }
        .onChange(of: tracker.selectedFavIndex) { _, newValue in
            if let idx = newValue {
                withAnimation(.easeOut(duration: 0.15)) {
                    flashedFavIndex = idx
                }
            }
        }
    }

    private func scheduleBackdropSync() {
        pendingBackdropSync?.cancel()
        let workItem = DispatchWorkItem {
            syncBackdrop()
        }
        pendingBackdropSync = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + overlayBackdropSyncDelay, execute: workItem)
    }

    private func cancelScheduledBackdropSync() {
        pendingBackdropSync?.cancel()
        pendingBackdropSync = nil
    }

    private func syncBackdrop() {
        pendingBackdropSync = nil
        let spread = min(max(backdropSpread, 0), 1)
        let intensity = min(max(backdropIntensity, 0), 1)
        let hasSearchText = !tracker.searchText.isEmpty
        let displayItems = activeItems
        let dynPillYs = hasSearchText ? computePillYPositions(for: displayItems.count) : pillYPositions
        let dynPillXs = hasSearchText ? computePillXPositions(for: displayItems.count) : pillXPositions

        if spread > 0.001 && intensity > 0.001 {
            backdropController.update(
                material: .popover,
                geometry: backdropMaskGeometry(
                    hasSearchText: hasSearchText,
                    displayItems: displayItems,
                    dynPillYs: dynPillYs,
                    dynPillXs: dynPillXs,
                    spread: spread
                ),
                spread: spread,
                intensity: intensity
            )
        } else {
            backdropController.clear()
        }
    }

    private func backdropMaskGeometry(
        hasSearchText: Bool,
        displayItems: [ClipboardItem],
        dynPillYs: [CGFloat],
        dynPillXs: [CGFloat],
        spread: CGFloat
    ) -> BackdropMaskGeometry {
        let spreadCurve = backdropSpreadCurve(spread)
        let rightVisibleCount = hasSearchText ? displayItems.count : min(displayItems.count, revealedCount)
        let connectorWidth: CGFloat = 10 + spreadCurve * 18
        let dotDiameter: CGFloat = dotSize + 6 + spreadCurve * 14
        let pillPadX: CGFloat = 6 + spreadCurve * 18
        let pillPadY: CGFloat = 4 + spreadCurve * 10
        let pillTail: CGFloat = 6 + spreadCurve * 28
        let searchWidth = overlaySearchFieldWidth(for: tracker.searchText) + 8 + spreadCurve * 18
        let searchHeight: CGFloat = overlaySearchBaseHeight + spreadCurve * 12
        let centerDiameter: CGFloat = dotSize + 8 + spreadCurve * 20
        var dotRects: [CGRect] = []
        var pillRects: [CGRect] = []
        var lines: [BackdropLine] = []

        let searchRect = CGRect(
            x: centerX - searchWidth / 2,
            y: centerY - searchHeight / 2,
            width: searchWidth,
            height: searchHeight
        )

        let centerRect = CGRect(
            x: centerX - centerDiameter / 2,
            y: centerY - centerDiameter / 2,
            width: centerDiameter,
            height: centerDiameter
        )

        for index in 0..<rightVisibleCount {
            let item = displayItems[index]
            let angle = SpokeOverlay.angleForIndex(index, count: displayItems.count, spokeRadius: spokeRadius, dotSize: dotSize)
            let dotX = center.x + spokeRadius * cos(angle)
            let dotY = center.y - spokeRadius * sin(angle)
            let pillY = index < dynPillYs.count ? dynPillYs[index] : dotY
            let pillX = index < dynPillXs.count ? dynPillXs[index] : dotX
            let pillHeight: CGFloat = item.isImage ? 60 : 26
            let visiblePillWidth = overlayRightPillWidth(
                for: item,
                previewLength: previewLength,
                maxWidth: previewWidth,
                pillHeight: pillHeight
            )
            let pillRect = CGRect(
                x: pillX - pillPadX * 0.45,
                y: pillY - (pillHeight + pillPadY) / 2,
                width: visiblePillWidth + pillPadX + pillTail,
                height: pillHeight + pillPadY
            )

            lines.append(BackdropLine(start: center, end: CGPoint(x: dotX, y: dotY), width: connectorWidth))

            let pillTarget = CGPoint(x: pillRect.minX + pillRect.height / 2, y: pillY)
            lines.append(BackdropLine(start: CGPoint(x: dotX, y: dotY), end: pillTarget, width: connectorWidth * 0.9))

            let dotRect = CGRect(x: dotX - dotDiameter / 2, y: dotY - dotDiameter / 2, width: dotDiameter, height: dotDiameter)
            dotRects.append(dotRect)
            pillRects.append(pillRect)
        }

        if !hasSearchText {
            let favWindow = activeFavorites
            for index in 0..<favorites.count where revealedFavIndices.contains(index) {
                let angle = SpokeOverlay.favAngleForIndex(index, count: favorites.count, spokeRadius: spokeRadius, dotSize: dotSize)
                let dotX = center.x + spokeRadius * cos(angle)
                let dotY = center.y - spokeRadius * sin(angle)
                let pillY = favPillYPositions[index]
                let pillX = favPillXPositions[index]
                let pillHeight: CGFloat = 26
                let visiblePillWidth = overlayFavoritePillWidth(
                    for: index < favWindow.count ? favWindow[index] : favorites[index],
                    previewLength: previewLength,
                    maxWidth: previewWidth
                )
                let pillRect = CGRect(
                    x: pillX - visiblePillWidth - pillTail - pillPadX * 0.55,
                    y: pillY - (pillHeight + pillPadY) / 2,
                    width: visiblePillWidth + pillPadX + pillTail,
                    height: pillHeight + pillPadY
                )

                lines.append(BackdropLine(start: center, end: CGPoint(x: dotX, y: dotY), width: connectorWidth))

                let pillTarget = CGPoint(x: pillRect.maxX - pillRect.height / 2, y: pillY)
                lines.append(BackdropLine(start: CGPoint(x: dotX, y: dotY), end: pillTarget, width: connectorWidth * 0.9))

                let dotRect = CGRect(x: dotX - dotDiameter / 2, y: dotY - dotDiameter / 2, width: dotDiameter, height: dotDiameter)
                dotRects.append(dotRect)
                pillRects.append(pillRect)
            }
        }

        return BackdropMaskGeometry(
            size: windowSize,
            searchRect: searchRect,
            centerRect: centerRect,
            dotRects: dotRects,
            pillRects: pillRects,
            lines: lines
        )
    }

    @ViewBuilder
    private func favItemView(index: Int) -> some View {
        let favWindow = activeFavorites
        let fav = index < favWindow.count ? favWindow[index] : favorites[index]
        let angle = SpokeOverlay.favAngleForIndex(index, count: favorites.count, spokeRadius: spokeRadius, dotSize: dotSize)
        let dotX = center.x + spokeRadius * cos(angle)
        let dotY = center.y - spokeRadius * sin(angle)
        let pillY = favPillYPositions[index]
        let pillX = favPillXPositions[index]
        let isHovered = tracker.hoveredFavIndex == index
        let isSelected = tracker.selectedFavIndex == index
        let isFlashed = flashedFavIndex == index
        let isHighlighted = isHovered || isSelected
        let isRevealed = revealedFavIndices.contains(index)

        if isRevealed {
            let preview = overlayFavoritePreviewText(for: fav, previewLength: previewLength)
            let visiblePillWidth = overlayFavoritePillWidth(
                for: fav,
                previewLength: previewLength,
                maxWidth: previewWidth
            )

            // Letter dot (green)
            GlassDot(accent: .green, isHighlighted: isHighlighted, label: fav.letter)
                .frame(width: dotSize, height: dotSize)
                .scaleEffect(isFlashed ? 1.3 : (isHighlighted ? 1.1 : 1.0))
                .animation(.easeOut(duration: 0.12), value: isHighlighted)
                .position(x: dotX, y: dotY)
                .allowsHitTesting(false)

            // Favorite preview pill (right-aligned, extends left)
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Text(preview)
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background {
                        GlassPillBackground(accent: .green, isHighlighted: isHighlighted)
                    }
                    .scaleEffect(isFlashed ? 1.05 : (isHighlighted ? 1.03 : 1.0), anchor: .trailing)
                    .animation(.easeOut(duration: 0.12), value: isHighlighted)
            }
            .frame(width: visiblePillWidth, alignment: .trailing)
            .position(x: pillX - visiblePillWidth / 2, y: pillY)
            .allowsHitTesting(false)
        }
    }

    private func animateReveal() {
        let delay: Double = 0.03
        var step = 0

        // Right side: top to bottom (clockwise from ~1 o'clock to ~5 o'clock)
        for i in 0..<items.count {
            let s = step
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(s) * delay) {
                withAnimation(.spring(response: 0.2, dampingFraction: 0.75)) {
                    self.revealedCount = i + 1
                }
            }
            step += 1
        }

        // Left side: bottom to top (clockwise from ~7 o'clock to ~11 o'clock)
        for i in stride(from: favorites.count - 1, through: 0, by: -1) {
            let idx = i
            let s = step
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(s) * delay) {
                withAnimation(.spring(response: 0.2, dampingFraction: 0.75)) {
                    _ = self.revealedFavIndices.insert(idx)
                }
            }
            step += 1
        }
    }

    private func drawSpokes(context: GraphicsContext, size: CGSize) {
        let c = center
        let hasSearchText = !tracker.searchText.isEmpty
        let displayItems = activeItems
        let dynPillYs = hasSearchText ? computePillYPositions(for: displayItems.count) : pillYPositions
        let dynPillXs = hasSearchText ? computePillXPositions(for: displayItems.count) : pillXPositions
        guard displayItems.count > 0 || favorites.count > 0 else { return }
        let normalLineStyle = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
        let highlightedLineStyle = StrokeStyle(lineWidth: 3.25, lineCap: .round, lineJoin: .round)

        // ── Right side spokes (clipboard items, blue) ──
        let rightCount = hasSearchText ? displayItems.count : min(items.count, revealedCount)
        for i in 0..<rightCount {
            let angle = SpokeOverlay.angleForIndex(i, count: displayItems.count, spokeRadius: spokeRadius, dotSize: dotSize)
            let dotX = c.x + spokeRadius * cos(angle)
            let dotY = c.y - spokeRadius * sin(angle)
            let pillY = i < dynPillYs.count ? dynPillYs[i] : dotY
            let pillX = i < dynPillXs.count ? dynPillXs[i] : dotX
            let isHovered = tracker.hoveredIndex == i
            let isSelected = tracker.selectedIndex == i
            let isHighlighted = isHovered || isSelected

            let lineStyle = isHighlighted ? highlightedLineStyle : normalLineStyle
            let spokeShading = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [
                    Color.blue.opacity(isHighlighted ? 0.20 : 0.08),
                    Color.blue.opacity(isHighlighted ? 0.90 : 0.45)
                ]),
                startPoint: c,
                endPoint: CGPoint(x: dotX, y: dotY)
            )
            let connColor = isHighlighted ? Color.blue.opacity(0.68) : Color.blue.opacity(0.26)

            var spoke = Path()
            spoke.move(to: c)
            spoke.addLine(to: CGPoint(x: dotX, y: dotY))
            context.stroke(spoke, with: spokeShading, style: lineStyle)

            let pillTarget = CGPoint(x: pillX, y: pillY)
            let dx = pillTarget.x - dotX
            let dy = pillTarget.y - dotY
            let dist = sqrt(dx * dx + dy * dy)
            let normX = dist > 0 ? dx / dist : 1
            let normY = dist > 0 ? dy / dist : 0
            let exitX = dotX + normX * dotSize / 2
            let exitY = dotY + normY * dotSize / 2

            var conn = Path()
            conn.move(to: CGPoint(x: exitX, y: exitY))
            conn.addLine(to: pillTarget)
            context.stroke(conn, with: .color(connColor), style: lineStyle)
        }

        // ── Left side spokes (favorites, green) — hidden during search ──
        if !hasSearchText {
        for i in 0..<favorites.count where revealedFavIndices.contains(i) {
            let angle = SpokeOverlay.favAngleForIndex(i, count: favorites.count, spokeRadius: spokeRadius, dotSize: dotSize)
            let dotX = c.x + spokeRadius * cos(angle)
            let dotY = c.y - spokeRadius * sin(angle)
            let pillY = favPillYPositions[i]
            let pillX = favPillXPositions[i]
            let isHovered = tracker.hoveredFavIndex == i
            let isSelected = tracker.selectedFavIndex == i
            let isHighlighted = isHovered || isSelected

            let lineStyle = isHighlighted ? highlightedLineStyle : normalLineStyle
            let spokeShading = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [
                    Color.green.opacity(isHighlighted ? 0.20 : 0.08),
                    Color.green.opacity(isHighlighted ? 0.90 : 0.48)
                ]),
                startPoint: c,
                endPoint: CGPoint(x: dotX, y: dotY)
            )
            let connColor = isHighlighted ? Color.green.opacity(0.68) : Color.green.opacity(0.26)

            var spoke = Path()
            spoke.move(to: c)
            spoke.addLine(to: CGPoint(x: dotX, y: dotY))
            context.stroke(spoke, with: spokeShading, style: lineStyle)

            let pillTarget = CGPoint(x: pillX, y: pillY)
            let dx = pillTarget.x - dotX
            let dy = pillTarget.y - dotY
            let dist = sqrt(dx * dx + dy * dy)
            let normX = dist > 0 ? dx / dist : -1
            let normY = dist > 0 ? dy / dist : 0
            let exitX = dotX + normX * dotSize / 2
            let exitY = dotY + normY * dotSize / 2

            var conn = Path()
            conn.move(to: CGPoint(x: exitX, y: exitY))
            conn.addLine(to: pillTarget)
            context.stroke(conn, with: .color(connColor), style: lineStyle)
        }
        } // end if !hasSearchText

        let shiftActive = tracker.shiftHeld && !hasSearchText
        let r: CGFloat = shiftActive ? 8 : 5
        let anchorRect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)

        // Soft outer glow
        var glow = context
        glow.addFilter(.blur(radius: shiftActive ? 14 : 9))
        glow.fill(Path(ellipseIn: anchorRect.insetBy(dx: -6, dy: -6)), with: .color(.white.opacity(shiftActive ? 0.45 : 0.22)))

        // Halo ring around the hub
        let ringRect = anchorRect.insetBy(dx: -5, dy: -5)
        context.stroke(
            Path(ellipseIn: ringRect),
            with: .color(.white.opacity(shiftActive ? 0.55 : 0.28)),
            style: StrokeStyle(lineWidth: 1)
        )

        // Core dot with subtle vertical sheen
        context.fill(
            Path(ellipseIn: anchorRect),
            with: .linearGradient(
                Gradient(colors: [.white.opacity(shiftActive ? 0.95 : 0.7), .white.opacity(shiftActive ? 0.6 : 0.35)]),
                startPoint: CGPoint(x: c.x, y: anchorRect.minY),
                endPoint: CGPoint(x: c.x, y: anchorRect.maxY)
            )
        )
    }
}
