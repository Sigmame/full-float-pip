import Cocoa
import WebKit
import QuartzCore
import Vision
import Speech
import AVFoundation

// MARK: - Appearance tokens
//
// One source of truth for colour, radius, spacing and type. The chrome used to
// spell every value out at the call site — three different corner radii, six
// font sizes, and a different "on" colour for each toggle (green, blue, purple,
// red) — which is what made the surface read as unfinished rather than designed.
// Everything the user sees is now built from here, so a new control lands
// looking like the rest of them.
private enum VibeTheme {
    /// One accent carries "on", selection and progress.
    static let accent = NSColor(srgbRed: 1.00, green: 0.231, blue: 0.361, alpha: 1.0)

    static let chrome = NSColor(white: 0.07, alpha: 0.62)
    static let chromeStrong = NSColor(white: 0.06, alpha: 0.86)
    static let stroke = NSColor(white: 1.0, alpha: 0.14)
    static let strokeStrong = NSColor(white: 1.0, alpha: 0.16)

    static let icon = NSColor(white: 0.96, alpha: 1.0)
    static let iconMuted = NSColor(white: 0.96, alpha: 0.60)
    /// Text/ink that sits on the accent or on the white primary button.
    static let onAccent = NSColor(white: 1.0, alpha: 1.0)
    static let onWhite = NSColor(white: 0.08, alpha: 1.0)

    static let hover = NSColor(white: 1.0, alpha: 0.13)
    static let pressed = NSColor(white: 1.0, alpha: 0.22)
    static let chipIdle = NSColor(white: 1.0, alpha: 0.10)
    static let chipHover = NSColor(white: 1.0, alpha: 0.18)

    static let track = NSColor(white: 1.0, alpha: 0.20)
    static let knob = NSColor.white

    /// Destructive tint for the close affordance on the control strip.
    static let close = NSColor(srgbRed: 1.00, green: 0.55, blue: 0.50, alpha: 1.0)

    /// The four title-bar dots. The colour is the identifier, the way the macOS
    /// traffic lights work, so they stay literal here instead of borrowing the
    /// accent.
    enum Dot {
        static let close = NSColor(srgbRed: 1.00, green: 0.38, blue: 0.35, alpha: 1.0)
        static let dim = NSColor(srgbRed: 1.00, green: 0.82, blue: 0.28, alpha: 1.0)
        static let pin = NSColor(srgbRed: 0.27, green: 0.85, blue: 0.46, alpha: 1.0)
        static let ghost = NSColor(srgbRed: 0.68, green: 0.45, blue: 0.98, alpha: 1.0)
        /// Ink of the glyph that fades in on hover, and the dot's own edge.
        static let ink = NSColor(white: 0, alpha: 0.62)
        static let hairline = NSColor(white: 0, alpha: 0.20)
    }

    enum Radius {
        static let sm: CGFloat = 7
        static let md: CGFloat = 9
        static let lg: CGFloat = 14
    }

    /// 4-point grid, so gaps line up instead of drifting by a pixel per control.
    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
    }

    enum Font {
        static let playerTitle = NSFont.systemFont(ofSize: 13, weight: .semibold)
        static let title = NSFont.systemFont(ofSize: 12, weight: .semibold)
        static let label = NSFont.systemFont(ofSize: 11, weight: .semibold)
        static let chip = NSFont.systemFont(ofSize: 11, weight: .semibold)
        static let hud = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        static let time = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        static let badge = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
    }
}

// MARK: - LoadingOverlayView — Loading overlay (auto-centered spinner)

private final class PlaybackToast: NSView {
    let iconView = NSImageView()
    let textField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = VibeTheme.chromeStrong.cgColor
        layer?.borderColor = VibeTheme.strokeStrong.cgColor
        layer?.borderWidth = 0.6
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.28
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -1)

        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = VibeTheme.accent
        addSubview(iconView)

        textField.isEditable = false
        textField.isBordered = false
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.textColor = VibeTheme.icon
        textField.font = VibeTheme.Font.hud
        textField.maximumNumberOfLines = 4
        textField.lineBreakMode = .byWordWrapping
        textField.cell?.wraps = true
        textField.cell?.isScrollable = false
        textField.alignment = .left
        addSubview(textField)
    }

    required init?(coder: NSCoder) { fatalError() }

    func present(_ message: String, symbol: String, maxWidth: CGFloat) {
        textField.stringValue = message
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            iconView.image = image
            iconView.isHidden = false
        } else {
            iconView.isHidden = true
        }
        let font = textField.font ?? VibeTheme.Font.hud
        let iconSide: CGFloat = iconView.isHidden ? 0 : 14
        let gap: CGFloat = iconView.isHidden ? 0 : 7
        let textMax = max(96, maxWidth - 28 - iconSide - gap)
        let measured = (message as NSString).boundingRect(
            with: NSSize(width: textMax, height: 200),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        let textW = min(textMax, ceil(measured.width) + 4)
        let textH = ceil(measured.height) + 4
        let height = max(32, textH + 14)
        let width = min(maxWidth, textW + 24 + iconSide + gap)
        iconView.frame = NSRect(x: 12, y: (height - iconSide) / 2, width: iconSide, height: iconSide)
        textField.frame = NSRect(x: 12 + iconSide + gap, y: (height - textH) / 2, width: textW, height: textH)
        frame.size = NSSize(width: width, height: height)
        layer?.cornerRadius = min(VibeTheme.Radius.lg, height / 2)
    }
}

private class LoadingOverlayView: NSView {
    var spinnerLayer: CALayer?
    var retryAction: (() -> Void)?
    private let retryButton = NSButton(title: "Thử tải lại", target: nil, action: nil)
    /// "Đang tải…" under the spinner: a bare arc on a black field reads as a
    /// hang, and a word is cheaper than a HUD for the same information.
    let caption = NSTextField(labelWithString: "Đang tải…")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        caption.isEditable = false
        caption.isBordered = false
        caption.drawsBackground = false
        caption.textColor = VibeTheme.iconMuted
        caption.font = VibeTheme.Font.label
        caption.alignment = .center
        caption.lineBreakMode = .byWordWrapping
        caption.maximumNumberOfLines = 2
        addSubview(caption)
        retryButton.target = self
        retryButton.action = #selector(retryLoading)
        retryButton.bezelStyle = .rounded
        retryButton.font = VibeTheme.Font.label
        retryButton.bezelColor = VibeTheme.accent
        retryButton.contentTintColor = VibeTheme.onAccent
        retryButton.isHidden = true
        addSubview(retryButton)
    }

    func showError() {
        spinnerLayer?.isHidden = true
        caption.stringValue = "Không tải được video. Kiểm tra mạng rồi thử lại."
        caption.textColor = VibeTheme.icon
        retryButton.isHidden = false
        needsLayout = true
    }

    @objc private func retryLoading() {
        caption.stringValue = "Đang tải…"
        caption.textColor = VibeTheme.iconMuted
        retryButton.isHidden = true
        spinnerLayer?.isHidden = false
        retryAction?()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        if let spinner = spinnerLayer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            spinner.position = CGPoint(x: bounds.width / 2, y: bounds.height / 2 + 14)
            CATransaction.commit()
        }
        caption.frame = NSRect(x: VibeTheme.Space.lg,
                               y: bounds.height / 2 - 36,
                               width: max(0, bounds.width - VibeTheme.Space.lg * 2),
                               height: 32)
        retryButton.frame = NSRect(x: max(0, (bounds.width - 120) / 2),
                                   y: bounds.height / 2 - 70,
                                   width: min(120, bounds.width), height: 32)
    }
}

// MARK: - DraggableTitleBar — Title bar that supports drag-to-move window

private final class ControlBarView: NSView {
    static let edgeWidth: CGFloat = 10

    static func isInteractive(_ view: NSView) -> Bool {
        view is NSButton || view is NSSlider || view is ModernScrubberView
    }

    override func resetCursorRects() {
        discardCursorRects()
        let movable = (window as? ControlStripPanel)?.owner?.isPinned == false
        addCursorRect(bounds, cursor: movable ? .openHand : .arrow)
        for sub in subviews where !sub.isHidden && sub.alphaValue > 0.01 {
            if Self.isInteractive(sub) {
                addCursorRect(sub.frame, cursor: .pointingHand)
            }
        }
        let b = Self.edgeWidth
        addCursorRect(NSRect(x: 0, y: 0, width: b, height: bounds.height), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: bounds.width - b, y: 0, width: b, height: bounds.height), cursor: .resizeLeftRight)
    }
}

/// A one-point divider that never takes a click. A plain `NSView` would win the
/// hit test inside its own frame — a 1 pt band of the title bar would stop being
/// draggable, and the same band on the strip would stop counting as a control.
private final class HairlineView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Transparent border above the video so the resize cursor shows on the edges
/// even while another app is frontmost. The center passes hits through.
private final class ResizeEdgeView: NSView {
    var border: CGFloat = 16

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        return isEdge(local) ? self : nil
    }

    override func resetCursorRects() {
        let b = border
        let w = bounds.width
        let h = bounds.height
        guard w > b * 2, h > b * 2 else { return }
        addCursorRect(NSRect(x: 0, y: b, width: b, height: h - b * 2), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: w - b, y: b, width: b, height: h - b * 2), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: b, y: 0, width: w - b * 2, height: b), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: b, y: h - b, width: w - b * 2, height: b), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: 0, y: 0, width: b, height: b), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: w - b, y: 0, width: b, height: b), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: 0, y: h - b, width: b, height: b), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: w - b, y: h - b, width: b, height: b), cursor: .resizeLeftRight)
    }

    private func isEdge(_ local: NSPoint) -> Bool {
        let b = border
        return local.x < b || local.x > bounds.width - b || local.y < b || local.y > bounds.height - b
    }
}

private final class ControlStripPanel: NSPanel {
    weak var owner: FloatWindow?
    static let resizeEdgeWidth: CGFloat = ControlBarView.edgeWidth

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Intercept edge presses before subviews so L/R resize stays solid.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            let point = event.locationInWindow
            let width = contentView?.bounds.width ?? frame.width
            let edge = Self.resizeEdgeWidth
            if point.x < edge || point.x > width - edge {
                owner?.noteStripInteraction()
                owner?.trackResizeFromStrip()
                return
            }
        }
        super.sendEvent(event)
    }

    override func mouseDown(with event: NSEvent) {
        guard let owner = owner else {
            super.mouseDown(with: event)
            return
        }
        owner.noteStripInteraction()
        let point = event.locationInWindow
        let width = contentView?.bounds.width ?? frame.width
        let edge = Self.resizeEdgeWidth
        // Pin only blocks auto-dock — manual edge resize must always work.
        if point.x < edge || point.x > width - edge {
            owner.trackResizeFromStrip()
            return
        }
        if hitIsControl(point) {
            super.mouseDown(with: event)
            return
        }
        owner.trackMoveFromStrip()
    }

    override func mouseMoved(with event: NSEvent) {
        owner?.noteStripInteraction()
        super.mouseMoved(with: event)
        let point = event.locationInWindow
        let width = contentView?.bounds.width ?? frame.width
        let edge = Self.resizeEdgeWidth
        if point.x < edge || point.x > width - edge {
            NSCursor.resizeLeftRight.set()
        } else {
            owner?.updateStripPointerFeedback()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        owner?.noteStripInteraction()
        super.mouseEntered(with: event)
        owner?.updateStripPointerFeedback()
    }

    override func mouseExited(with event: NSEvent) {
        // Defer hide to FloatWindow's idle timer — never thrash on strip exit.
        owner?.noteStripPointerExited()
        super.mouseExited(with: event)
    }

    private func hitIsControl(_ point: NSPoint) -> Bool {
        // Edge grips win over buttons so resize stays discoverable.
        let width = contentView?.bounds.width ?? frame.width
        let edge = Self.resizeEdgeWidth
        if point.x < edge || point.x > width - edge { return false }
        guard let hit = contentView?.hitTest(point) else { return false }
        var view: NSView? = hit
        while let current = view, current !== contentView {
            if ControlBarView.isInteractive(current) { return true }
            view = current.superview
        }
        return false
    }
}

private class DraggableTitleBar: NSView {
    var isLocked = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        if isHidden || alphaValue < 0.05 { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        let float = window as? FloatWindow
        if isLocked || float?.isPinned == true { return }
        float?.autoDockPaused = true
        window?.performDrag(with: event)
        float?.autoDockPaused = false
        float?.vibeDock.noteUserDidPlace()
    }
}

// MARK: - ModernScrubberView — Apple-grade video timeline scrubber bar

private class ModernScrubberView: NSView {
    var onSeek: ((Double) -> Void)?
    var onHover: ((Double?) -> Void)?
    var canSeek = false
    var isPreviewing: Bool { canSeek && (isDragging || isHovered) }
    /// Live position while the pointer is down. The video seeks once, on release.
    var onPreview: ((Double) -> Void)?
    var isDragging = false

    private let trackBg = NSView()
    private let trackProgress = NSView()
    private let knobView = NSView()
    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    private let normalTrackHeight: CGFloat = 5.0
    private let hoverTrackHeight: CGFloat = 7.0
    private let normalKnobSize: CGFloat = 13.0
    private let hoverKnobSize: CGFloat = 16.0

    private var currentProgress: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        wantsLayer = true

        // Background track (subtle translucent gray)
        trackBg.wantsLayer = true
        trackBg.layer?.backgroundColor = VibeTheme.track.cgColor
        trackBg.layer?.cornerRadius = normalTrackHeight / 2
        addSubview(trackBg)

        // Played track (accent)
        trackProgress.wantsLayer = true
        trackProgress.layer?.backgroundColor = VibeTheme.accent.cgColor
        trackProgress.layer?.cornerRadius = normalTrackHeight / 2
        addSubview(trackProgress)

        // Scrubber Knob (white circle with drop shadow)
        knobView.wantsLayer = true
        knobView.layer?.backgroundColor = VibeTheme.knob.cgColor
        knobView.layer?.cornerRadius = normalKnobSize / 2
        knobView.layer?.shadowColor = NSColor.black.cgColor
        knobView.layer?.shadowOpacity = 0.55
        knobView.layer?.shadowRadius = 3
        knobView.layer?.shadowOffset = CGSize(width: 0, height: -1)
        addSubview(knobView)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        if let ta = trackingArea {
            addTrackingArea(ta)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        mouseMoved(with: event)
        animateTrack(expand: true)
    }

    override func mouseMoved(with event: NSEvent) {
        guard canSeek else { return }
        let x = convert(event.locationInWindow, from: nil).x
        onHover?(max(0, min(1, Double(x / max(bounds.width, 1)))))
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        if !isDragging {
            onHover?(nil)
            animateTrack(expand: false)
        }
    }

    private func animateTrack(expand: Bool) {
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reduced ? 0 : 0.12
            self.layoutSublayers(expanded: expand)
        }
    }

    override func layout() {
        super.layout()
        layoutSublayers(expanded: isHovered || isDragging)
    }

    private func layoutSublayers(expanded: Bool) {
        let th = expanded ? hoverTrackHeight : normalTrackHeight
        let ks = expanded ? hoverKnobSize : normalKnobSize
        let trackY = (bounds.height - th) / 2

        trackBg.frame = NSRect(x: 0, y: trackY, width: bounds.width, height: th)
        trackBg.layer?.cornerRadius = th / 2

        let pw = max(0, min(bounds.width, bounds.width * currentProgress))
        trackProgress.frame = NSRect(x: 0, y: trackY, width: pw, height: th)
        trackProgress.layer?.cornerRadius = th / 2

        let knobX = max(0, min(bounds.width - ks, pw - ks / 2))
        let knobY = (bounds.height - ks) / 2
        knobView.frame = NSRect(x: knobX, y: knobY, width: ks, height: ks)
        knobView.layer?.cornerRadius = ks / 2
    }

    func setProgress(_ fraction: CGFloat) {
        guard !isDragging else { return }
        currentProgress = max(0, min(1.0, fraction))
        needsLayout = true
    }

    override func mouseDown(with event: NSEvent) {
        guard canSeek else { return }
        isDragging = true
        animateTrack(expand: true)
        preview(event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        preview(event)
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        let percent = preview(event)
        isDragging = false
        onSeek?(percent)
        if !isHovered {
            animateTrack(expand: false)
        }
    }

    @discardableResult
    private func preview(_ event: NSEvent) -> Double {
        let loc = convert(event.locationInWindow, from: nil)
        let percent = max(0, min(1.0, Double(loc.x / max(bounds.width, 1))))
        currentProgress = CGFloat(percent)
        needsLayout = true
        onPreview?(percent)
        return percent
    }
}

private final class StripIconButton: NSButton {
    /// What the button shows when the pointer is elsewhere and nothing is
    /// pressed. Opt-in: the white play disc and a size chip (whose fill follows
    /// the selection) would have their own background overwritten.
    enum Wash {
        /// Bare glyph on the translucent bar.
        case glyph
        /// A chip that owns an idle fill; hover and press deepen it instead of
        /// erasing it.
        case chip(NSColor)
    }

    var wash: Wash?
    private var hoverArea: NSTrackingArea?
    private var isHovered = false

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            let shown: CGFloat = isHighlighted ? 0.5 : 1
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                alphaValue = shown
            } else {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.08
                    animator().alphaValue = shown
                }
            }
            updateWash()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard wash != nil else { return }
        if let area = hoverArea { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateWash()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateWash()
    }

    /// Site-specific buttons are hidden and shown by `layoutControlBar`, and a
    /// hidden view never gets `mouseExited` — so drop the hover state on hide or
    /// the button comes back already lit.
    override var isHidden: Bool {
        didSet {
            guard isHidden, isHidden != oldValue else { return }
            isHovered = false
            updateWash()
        }
    }

    /// The wash is the only affordance that says a glyph is a button. Without it
    /// the strip read as a static legend rather than a control surface.
    private func updateWash() {
        guard let wash = wash else { return }
        switch wash {
        case .glyph:
            let color: NSColor = isHighlighted ? VibeTheme.pressed
                : (isHovered ? VibeTheme.hover : .clear)
            layer?.backgroundColor = color.cgColor
        case .chip(let idle):
            layer?.backgroundColor = ((isHighlighted || isHovered) ? VibeTheme.chipHover : idle).cgColor
        }
    }
}

/// One of the four title-bar dots. The colour names the action the way the
/// macOS traffic lights do, and a glyph fades in on hover so the dot explains
/// itself without waiting for a tooltip.
private final class TitleCircleButton: NSButton {
    private let glyph = NSImageView()
    private var tracking: NSTrackingArea?

    init(frame: NSRect, color: NSColor, glyphName: String) {
        super.init(frame: frame)
        isBordered = false
        bezelStyle = .circular
        title = ""
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
        layer?.cornerRadius = frame.width / 2
        // A hairline stops the dot from looking pasted onto the dark bar.
        layer?.borderColor = VibeTheme.Dot.hairline.cgColor
        layer?.borderWidth = 0.5

        if let image = NSImage(systemSymbolName: glyphName, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)) {
            glyph.image = image
            glyph.contentTintColor = VibeTheme.Dot.ink
            glyph.imageScaling = .scaleProportionallyDown
            glyph.frame = bounds.insetBy(dx: 5, dy: 5)
            glyph.autoresizingMask = [.width, .height]
            glyph.alphaValue = 0
            addSubview(glyph)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The glyph must never swallow the click, or the dot stops closing the
    /// window exactly where the glyph invites the press.
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = tracking { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { fadeGlyph(1) }
    override func mouseExited(with event: NSEvent) { fadeGlyph(0) }

    private func fadeGlyph(_ alpha: CGFloat) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            glyph.alphaValue = alpha
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.10
            glyph.animator().alphaValue = alpha
        }
    }
}

// MARK: - Movie playlist context (continue-watching / episode nav)

struct MovieEpisodeItem {
    let name: String
    let slug: String
    let linkM3u8: String
    let linkEmbed: String

    init?(dict: [String: Any]) {
        let name = dict["name"] as? String ?? ""
        let slug = dict["slug"] as? String ?? ""
        let m3u8 = dict["linkM3u8"] as? String ?? ""
        let embed = dict["linkEmbed"] as? String ?? ""
        guard !name.isEmpty || !slug.isEmpty || !m3u8.isEmpty || !embed.isEmpty else { return nil }
        self.name = name.isEmpty ? (slug.isEmpty ? "Tập" : slug) : name
        self.slug = slug
        self.linkM3u8 = m3u8
        self.linkEmbed = embed
    }
}

struct MovieServerItem {
    let name: String
    let items: [MovieEpisodeItem]

    init?(dict: [String: Any]) {
        let name = dict["name"] as? String ?? "Server"
        let rawItems = dict["items"] as? [[String: Any]] ?? []
        let items = rawItems.compactMap { MovieEpisodeItem(dict: $0) }
        guard !items.isEmpty else { return nil }
        self.name = name
        self.items = items
    }
}

struct MovieContext {
    var slug: String
    var name: String
    var source: String
    var poster: String
    var serverIdx: Int
    var epIdx: Int
    var servers: [MovieServerItem]

    init?(dict: [String: Any]) {
        let slug = dict["slug"] as? String ?? ""
        guard !slug.isEmpty else { return nil }
        self.slug = slug
        self.name = dict["name"] as? String ?? slug
        self.source = dict["source"] as? String ?? ""
        self.poster = dict["poster"] as? String ?? ""
        self.serverIdx = dict["serverIdx"] as? Int ?? (dict["serverIdx"] as? NSNumber)?.intValue ?? 0
        self.epIdx = dict["epIdx"] as? Int ?? (dict["epIdx"] as? NSNumber)?.intValue ?? 0
        let rawServers = dict["servers"] as? [[String: Any]] ?? []
        self.servers = rawServers.compactMap { MovieServerItem(dict: $0) }
        if self.serverIdx < 0 || self.serverIdx >= self.servers.count {
            self.serverIdx = 0
        }
        if let server = self.servers[safe: self.serverIdx] {
            if self.epIdx < 0 || self.epIdx >= server.items.count {
                self.epIdx = 0
            }
        } else {
            self.epIdx = 0
        }
    }

    var currentEpisode: MovieEpisodeItem? {
        guard let server = servers[safe: serverIdx] else { return nil }
        return server.items[safe: epIdx]
    }

    var hasPlaylist: Bool {
        (servers.first?.items.count ?? 0) > 1 || servers.count > 1
    }

    mutating func moveEpisode(by delta: Int) -> MovieEpisodeItem? {
        guard let server = servers[safe: serverIdx], !server.items.isEmpty else { return nil }
        let next = epIdx + delta
        guard next >= 0, next < server.items.count else { return nil }
        epIdx = next
        return server.items[epIdx]
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard index >= 0, index < count else { return nil }
        return self[index]
    }
}

// MARK: - FloatWindow — Always-on-top floating video window

/// How far a film's track is lifted above its own level.
///
/// This has to go through Web Audio: `HTMLMediaElement.volume` is clamped to
/// 1.0 by the spec, so there is no "loud" setting on the element itself. A film
/// mixed for headphones and watched on a laptop often needs the extra 6-9 dB,
/// and the gain node is the only place to get it.
private enum AudioBoostLevel: Int, CaseIterable {
    case off = 0
    case light = 1
    case medium = 2
    case strong = 3

    var factor: Double {
        switch self {
        case .off: return 1.0
        case .light: return 1.4
        case .medium: return 2.0
        case .strong: return 2.8
        }
    }

    var menuTitle: String {
        switch self {
        case .off: return "Không"
        case .light: return "Nhẹ (+40%)"
        case .medium: return "Vừa (x2)"
        case .strong: return "Mạnh (x2.8)"
        }
    }

    var hudTitle: String {
        switch self {
        case .off: return "Tăng âm thanh: Tắt"
        default: return "Tăng âm thanh: \(menuTitle)"
        }
    }
}

class FloatWindow: NSPanel, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, AVAudioPlayerDelegate {

    private var webView: WKWebView!
    private var titleBarView: NSView!
    private var titleLabel: NSTextField!
    private var controlBarView: NSView!
    private var scrubberView: ModernScrubberView!
    private var playPauseButton: NSButton!
    private var rewindButton: NSButton!
    private var skipButton: NSButton!
    private var volumeButton: NSButton!
    private var volumeSlider: NSSlider!
    private var speedButton: NSButton!
    private var maximizeButton: NSButton!
    private var sizeDownButton: NSButton?
    private var sizeUpButton: NSButton?
    private var sizePresetMiniButton: NSButton?
    private var sizePresetStandardButton: NSButton?
    private var sizePresetWideButton: NSButton?
    private var selectedSizePreset: SizePreset = .standard
    private var isWindowFullScreen = false
    private var preFullScreenFrame: NSRect = .zero
    private var presetHoldWorkItem: DispatchWorkItem?
    private var volumeApplyWork: DispatchWorkItem?
    private var embedVisualScans = 0
    private var stripAutoNextButton: NSButton?
    private var stripSkipIntroButton: NSButton?
    /// Per-episode: auto-skip intro already fired / user seeked manually.
    private var didAutoSkipIntroThisEpisode = false
    private var userSeekedThisEpisode = false
    private var didAutoAdvanceThisEpisode = false
    private var lastPlaybackSample: Double = 0
    /// Last watch-assist verdict, so each change is logged exactly once.
    private var lastWatchAssistReason: WatchAssistReason?
    /// Bumped on every load so a poll of the episode we just left cannot
    /// drive auto-next or a stream-error fallback for the new one.
    private var loadGeneration = 0
    /// True from the start of a load until the new document has actually started.
    private var suppressWatchAssist = false
    private var hasTriedDirectEmbedFallback = false
    private let interstitialQueue = DispatchQueue(label: "floatvideo.adscan")
    private var interstitialScanBusy = false
    private var interstitialSkipBusy = false
    private var lastVisualAdAt: Date?
    private var lastAdDetectionAt: Date?
    private var lastEmbedAdScanAt = Date.distantPast
    private var directFrameUnreadable = false
    /// Whether the page is currently showing the native-driven ad cover.
    private var adCoverOn = false
    private var letterboxTop: Double?
    private var letterboxBottom: Double?
    private var letterboxCandidateTop: Double?
    private var letterboxCandidateBottom: Double?
    private var letterboxHits = 0
    private var embedAudioMonitor: AnyObject?
    private var didShowCaptureHUD = false
    private var lastEmbedAudioTranscript = ""
    private var lastEmbedAudioDetectionAt = Date.distantPast
    private var audioScanBusy = false
    /// Last boost state reported by the page, so the log says why it did not
    /// apply instead of the feature silently doing nothing.
    private var lastAudioBoostStatus = ""
    private var lastAudioBoostPushAt = Date.distantPast
    private var audioScanToken = 0
    private var didWarnSpeech = false
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "vi-VN"))
    private var interstitialSkipOrigin: Double?
    private var didAnnounceInterstitialSkip = false
    private var timeLabel: NSTextField!
    private var resizeIndicator: NSTextField?
    private var updateTimer: Timer?
    private var pinButton: NSButton?
    private var stripCloseButton: NSButton?
    private var stripGhostButton: NSButton?
    private var stripPinButton: NSButton?
    private var stripDuckButton: NSButton?
    private var stripPrevEpisodeButton: NSButton?
    private var stripNextEpisodeButton: NSButton?
    private var stripMoreButton: NSButton?
    /// Loudness lift for films. Only shown when the page is a movie player.
    private var stripAudioBoostButton: NSButton?
    /// Real-time AI dubbing from subtitles. Shown on movie players.
    private var stripDubButton: NSButton?
    private let offlineDubSession = OfflineDubSession()
    private var isOfflineDubEnabled = false
    private var offlineDubPlaybackAuthorized = false
    private var offlineDubChangedVolume = false
    private static let aiDubPrefKey = "vibe_ai_dubbing_enabled"
    static var preferredAIDubEnabled: Bool {
        get {
            // Live dubbing is retired. Keep the old preference key readable
            // for migration, but never re-enable the old live path.
            return false
        }
        set {
            UserDefaults.standard.set(false, forKey: aiDubPrefKey)
        }
    }

    private var isAIDubEnabled: Bool = FloatWindow.preferredAIDubEnabled
    var isAIDubbingEnabled: Bool { return isOfflineDubEnabled || isAIDubEnabled }
    struct DubItem {
        let text: String
        let normalized: String
        let audioURL: URL
        let createdAt: Date
        let cueDuration: Double
    }
    private var dubQueue: [DubItem] = []
    private var currentPlayingItem: DubItem?
    private var dubGeneration = 0
    private var latestDubSequence = 0
    private var lastRequestedDubSource = ""
    private var lastRequestedDubAt = Date.distantPast
    private let dubDeduplicator = SubtitleDeduplicator(windowSeconds: 12.0)
    private var lastTextTrackDubbedAt: Date = Date.distantPast
    private var edgeAudioPlayer: AVAudioPlayer?
    private var lastDubbedText: String = ""
    private var lastDubbedNorm: String = ""
    private var lastDubbedTime: Date = Date.distantPast
    private var isAudioDuckedByDubbing: Bool = false
    private let subtitleQueue = DispatchQueue(label: "com.vibefloat.subtitles", qos: .userInitiated)
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var subtitleScanBusy = false
    private var lastSubtitleScanAt = Date.distantPast
    private var lastSeenSubtitleAt = Date.distantPast
    /// Hairline splitting the strip's timeline row from its control row.
    private var controlBarRule: NSView?
    /// Visible L/R resize affordances on the external strip (non-interactive views).
    private var stripLeftGrip: NSView?
    private var stripRightGrip: NSView?
    private var controlStrip: NSPanel?
    private var hudToast: PlaybackToast?
    private var offlineDubProgressLabel: NSTextField?
    private var offlineDubProgressBar: NSProgressIndicator?
    private var offlineDubTimelineSignature: String?
    private var offlineDubOCR: OfflineSubtitleOCR?
    private var offlineDubUsedOCR = false
    private var currentOfflineVideoURL: URL?
    private var offlineDubProgressTimer: Timer?
    private var offlineDubProgressDismissWorkItem: DispatchWorkItem?
    private var offlineDubProgressMessage = ""
    private var offlineDubLastProgressAt = Date.distantPast
    private var resizeEdgeView: ResizeEdgeView?
    private var hudHideWorkItem: DispatchWorkItem?
    var isPinned = false
    private var lockedOrigin: NSPoint?
    var autoDockPaused = false
    var isResizeActive: Bool { isResizing }
    let vibeDock = VibeDock()
    private(set) var playbackElapsed: Double = 0
    private(set) var playbackDuration: Double = 0
    var playbackRate: Double { playbackRates[currentRateIndex] }
    var videoTitle: String
    var isPlaying = false
    private var userWantsMute = false
    private var videoAspectRatio: CGFloat = 16.0 / 9.0
    var isGhostMode = false
    private var preGhostAlpha: CGFloat = 1.0
    private var preDuckVolume: Double = 1.0
    private var isDucked = false
    private var isCodingSafeMode = false
    private var preSafeFrame: NSRect = .zero
    private var preSafeAlpha: CGFloat = 1.0
    private var pausedForBoss = false
    var isWindowVisible = true
    var currentVolume: Double { return volumeSlider?.doubleValue ?? 1.0 }
    private var currentEmbedUrl: String?
    private var hasTriedIframeEmbedFallback = false
    private var isMaximized = false
    private var preMaximizeFrame: NSRect = .zero
    private let playbackRates: [Double] = [1.0, 1.25, 1.5, 1.75, 2.0, 0.75]
    private var currentRateIndex = 0
    private var lastMouseLocation: NSPoint = .zero
    private var mouseIdleTicks = 0
    private var movieContext: MovieContext?
    private var lastProgressSentAt: Date = .distantPast
    private let progressHeartbeatInterval: TimeInterval = 20
    /// Emits continue-watching PROGRESS payloads to Chrome via Native Messaging.
    var onProgress: (([String: Any]) -> Void)?

    /// Set by AppDelegate: (re)registers or releases the global hotkeys. Returns
    /// the state actually in effect, so the menu reflects reality rather than the
    /// request.
    var onToggleHotkeys: (() -> Bool)?

    private static let hotkeysEnabledDefaultsKey = "vibefloat.globalHotkeysEnabled"

    /// Whether the global hotkeys should be registered. Persisted so a user who
    /// turned them off does not get them silently back on the next float.
    static var preferredHotkeysEnabled: Bool {
        get { UserDefaults.standard.object(forKey: hotkeysEnabledDefaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: hotkeysEnabledDefaultsKey) }
    }

    private static let hugVideoFrameDefaultsKey = "vibefloat.hugVideoFrame"

    /// Whether the window reshapes itself to the video's own aspect ratio. On by
    /// default: the window exists to show the video, so letterbox bars are waste.
    static var preferredHugVideoFrame: Bool {
        get { UserDefaults.standard.object(forKey: hugVideoFrameDefaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: hugVideoFrameDefaultsKey) }
    }

    private static let audioBoostDefaultsKey = "vibefloat.audioBoost"

    /// Chosen loudness lift for films. Off by default: it changes what the
    /// viewer hears, so it is theirs to turn on, and the choice carries over.
    static fileprivate var preferredAudioBoost: AudioBoostLevel {
        get {
            guard UserDefaults.standard.object(forKey: audioBoostDefaultsKey) != nil else { return .off }
            return AudioBoostLevel(rawValue: UserDefaults.standard.integer(forKey: audioBoostDefaultsKey)) ?? .off
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: audioBoostDefaultsKey) }
    }

    private static let positionLockedDefaultsKey = "vibefloat.positionLocked"

    /// Whether the floating player should keep its current screen position across launches.
    static var preferredPositionLocked: Bool {
        get { UserDefaults.standard.object(forKey: positionLockedDefaultsKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: positionLockedDefaultsKey) }
    }

    /// A manual resize or an explicit size preset outranks the automatic fit:
    /// once the user has chosen a size, the window stops resizing itself.
    private var userLockedSize = false
    private var preservesPresetSize = false

    // Video loading parameters (used by WKNavigationDelegate callbacks)
    private var currentSite: String = "generic"
    private var currentVideoTime: Double = 0
    private var hasInjectedJS = false
    /// Ticks towards the "is our injection still in this document?" probe. The
    /// page can replace its own document (locale switch, a login round trip, a
    /// plain link on a non-SPA site) at any time, and the CSS and layout loop we
    /// injected leave with the old document.
    private var injectionProbeTicks = 0
    private var hasInjectedAdSkip = false
    private var lastAdSkipCount = 0
    private var lastAdFFCount = 0
    private var isPostingSyntheticClick = false
    private var playerPrefs: [String: Any]?
    private var preferYouTubeEmbed = false

    func setPreferYouTubeEmbed(_ enabled: Bool) {
        preferYouTubeEmbed = enabled
    }
    private var prefsApplyDeadline: Date?
    private var lastPrefsStatus = "never-ran"
    private var currentPageURL: String = ""
    // Queried lazily: the local HTTP server starts asynchronously and its port
    // is still 0 when the open message arrives, so a snapshot taken in
    // loadVideo would permanently disable the YouTube embed fallback.
    private var httpServerPortProvider: (() -> UInt16)?
    private var httpServerPlayCapabilityProvider: (() -> String?)?
    private var loadingOverlay: NSView?
    private var hasTriedYouTubeEmbedFallback = false
    private var youtubeEmbedFallbackURL: URL?
    private var youtubeFallbackWorkItem: DispatchWorkItem?
    private var reinjectLayoutWorkItem: DispatchWorkItem?

    private enum LoadingStrategy {
        case directVideo, youtubeEmbed, siteEmbed, fullPageInject
    }
    private var loadingStrategy: LoadingStrategy = .fullPageInject

    private static let frameKey = "FloatVideoWindowFrame"
    /// Native controls execute in the top document. The movie's media element
    /// may be inside an inaccessible iframe, so install the relay in all frames.
    private static let embeddedMediaControlJavaScript = #"""
    (function() {
        if (window.__floatControlEmbeddedMedia) return;
        window.__floatControlEmbeddedMedia = function(action) {
            if (action !== 'play' && action !== 'pause') return;
            window.__floatOfflineDubHold = action === 'pause';
            document.querySelectorAll('video').forEach(function(video) {
                try {
                    if (action === 'pause') video.pause();
                    else video.play().catch(function() {});
                } catch (e) {}
            });
            try {
                if (typeof window.jwplayer === 'function') {
                    var jw = window.jwplayer();
                    if (action === 'pause') jw.pause();
                    else if (jw.getState() !== 'playing') jw.play();
                }
            } catch (e) {}
            try {
                if (window.playerCommand) window.playerCommand(action);
            } catch (e) {}
            document.querySelectorAll('iframe').forEach(function(frame) {
                try {
                    frame.contentWindow.postMessage({ __floatMediaControl: action }, '*');
                } catch (e) {}
            });
        };
        window.addEventListener('message', function(event) {
            if (!event.data || (event.data.__floatMediaControl !== 'play' &&
                                event.data.__floatMediaControl !== 'pause')) return;
            if (event.source !== window.parent) return;
            window.__floatControlEmbeddedMedia(event.data.__floatMediaControl);
        });
    })();
    """#
    // Ignore the legacy preference, which could have been enabled by Lofi automatically.
    private static var keepControlsVisible: Bool {
        get { UserDefaults.standard.bool(forKey: "FloatVideoKeepControlsVisible") }
        set { UserDefaults.standard.set(newValue, forKey: "FloatVideoKeepControlsVisible") }
    }
    private let stripTitleLabel = NSTextField(labelWithString: "")
    private let stripStateLabel = NSTextField(labelWithString: "Đang tải")

    static let ghostPrefKey = "FloatVideoGhostPreferredV2"
    private static let opacityPrefKey = "FloatVideoCodingOpacity"
    private static let sizePresetKey = "FloatVideoSizePreset"
    static let autoNextEpisodePrefKey = "FloatVideoAutoNextEpisode"
    static let autoSkipIntroPrefKey = "FloatVideoAutoSkipIntro"
    private static let introEndBySlugKey = "FloatVideoIntroEndBySlug"

    typealias SizePreset = FloatingPlayerSizePreset

    static var savedSizePreset: SizePreset {
        let raw = UserDefaults.standard.string(forKey: sizePresetKey) ?? ""
        return SizePreset(rawValue: raw) ?? .standard
    }

    static func persistSizePreset(_ preset: SizePreset) {
        UserDefaults.standard.set(preset.rawValue, forKey: sizePresetKey)
    }

    /// Default ON when never set (series benefit from binge-watch).
    static var preferredAutoNextEpisode: Bool {
        if UserDefaults.standard.object(forKey: autoNextEpisodePrefKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: autoNextEpisodePrefKey)
    }

    @discardableResult
    static func setPreferredAutoNextEpisode(_ enabled: Bool) -> Bool {
        UserDefaults.standard.set(enabled, forKey: autoNextEpisodePrefKey)
        return enabled
    }

    static var preferredAutoSkipIntro: Bool {
        if UserDefaults.standard.object(forKey: autoSkipIntroPrefKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: autoSkipIntroPrefKey)
    }

    @discardableResult
    static func setPreferredAutoSkipIntro(_ enabled: Bool) -> Bool {
        UserDefaults.standard.set(enabled, forKey: autoSkipIntroPrefKey)
        return enabled
    }

    private static func rememberedIntroEnd(forSlug slug: String) -> Double? {
        guard !slug.isEmpty,
              let dict = UserDefaults.standard.dictionary(forKey: introEndBySlugKey) as? [String: Double],
              let value = dict[slug], value > 10 else { return nil }
        return value
    }

    private static func rememberIntroEnd(_ seconds: Double, forSlug slug: String) {
        guard !slug.isEmpty, seconds > 10 else { return }
        var dict = (UserDefaults.standard.dictionary(forKey: introEndBySlugKey) as? [String: Double]) ?? [:]
        dict[slug] = seconds
        UserDefaults.standard.set(dict, forKey: introEndBySlugKey)
    }

    /// Preferred click-through state. Defaults OFF so a newly opened player is
    /// fully visible; enabling it only changes mouse handling, not brightness.
    /// Used by status/toggle even when no float window is open yet.
    static var preferredGhostMode: Bool {
        if UserDefaults.standard.object(forKey: ghostPrefKey) == nil { return false }
        return UserDefaults.standard.bool(forKey: ghostPrefKey)
    }

    @discardableResult
    static func setPreferredGhostMode(_ enabled: Bool) -> Bool {
        UserDefaults.standard.set(enabled, forKey: ghostPrefKey)
        return enabled
    }

    @discardableResult
    static func togglePreferredGhostMode() -> Bool {
        setPreferredGhostMode(!preferredGhostMode)
    }

    var onClose: (() -> Void)?

    func applyMovieContext(_ context: MovieContext?) {
        movieContext = context
        if let ep = context?.currentEpisode {
            videoTitle = context?.name.isEmpty == false
                ? "\(context!.name) — \(ep.name)"
                : ep.name
            titleLabel?.stringValue = videoTitle
        }
        resetEpisodeWatchAssistState()
        updateEpisodeButtons()
        refreshWatchAssistButtonStyles()
        layoutControlBar()
    }

    // For hover show/hide chrome (title + external control strip)
    private var isHovering = false
    private var hideTimer: DispatchWorkItem?
    private var cursorPollTimer: Timer?
    /// Only while the pointer is over the player. The rest of the time the
    /// IDE keeps the cursor and this timer stays off.
    private var cursorFastTimer: Timer?
    private var cursorEventMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var cursorWasInside = false
    private var hoverTip: NSPanel?
    private var hoverTipLabel: NSTextField?
    private var hoverTipAnchor: NSView?
    private var hoverTipSince: Date?
    /// Idle delay before PiP chrome auto-hides when the cursor leaves the player/strip.
    private static let chromeHideDelay: TimeInterval = 2.5

    // For window resize dragging
    private var initialMouseLocation: NSPoint = .zero
    private var initialWindowFrame: NSRect = .zero

    // For window resizing
    private var isResizing = false
    private var resizeEdge: ResizeEdge = .none
    private let resizeBorderWidth: CGFloat = 16

    enum ResizeEdge {
        case none
        case left, right, top, bottom
        case topLeft, topRight, bottomLeft, bottomRight
    }

    init(videoWidth: CGFloat, videoHeight: CGFloat, videoTitle: String) {
        self.videoTitle = videoTitle

        let titleBarHeight: CGFloat = 36
        let windowWidth = max(videoWidth, 380)
        let windowHeight = max(videoHeight, 214)

        self.videoAspectRatio = windowWidth / windowHeight

        let contentRect = NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight)

        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )

        isPinned = Self.preferredPositionLocked
        self.contentAspectRatio = NSSize(width: windowWidth, height: windowHeight)
        configureWindow()
        setupUI(width: windowWidth, height: windowHeight, titleBarHeight: titleBarHeight)
        positionWindow()
        if isPinned { lockedOrigin = frame.origin }
    }

    // MARK: - Window Configuration

    private func configureWindow() {
        // Key setting 1: Very high window level -- overlay fullscreen apps
        self.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)) + 1)

        // Key setting 2: Collection behavior -- visible on all Spaces/desktops
        self.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
        ]

        // Save position after drag ends (performDrag does not trigger mouseUp)
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification,
            object: self, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.enforcePinnedOrigin()
            self.saveWindowFrame()
            self.syncControlStrip(animated: false)
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification,
            object: self, queue: .main) { [weak self] _ in
            self?.enforcePinnedOrigin()
            self?.scheduleInjectedLayoutRefresh()
            self?.layoutVideoChrome()
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            self?.recoverPinnedWindowIfOffscreen()
        }

        // Key setting 3: Floating panel properties
        self.isFloatingPanel = true
        self.hidesOnDeactivate = false
        self.isMovableByWindowBackground = false
        self.hasShadow = true
        self.isOpaque = false
        self.backgroundColor = .clear

        applySizeConstraints()
    }

    /// Window size limits, derived from the current aspect ratio. Recomputed
    /// whenever the ratio changes (see `adoptVideoAspectRatio`) so `minSize`/
    /// `maxSize` never contradict the shape the window is being fit into.
    private func applySizeConstraints() {
        // Prevent a wide window from collapsing to an unusable height, and a
        // vertical one from running off the screen edge.
        let minW: CGFloat = (videoAspectRatio < 1.0) ? 280 : 380
        let maxW: CGFloat = (videoAspectRatio < 1.0) ? 540 : 1920
        self.minSize = NSSize(width: minW, height: minW / videoAspectRatio)
        self.maxSize = NSSize(width: maxW, height: maxW / videoAspectRatio)
    }

    // MARK: - UI Setup

    private func setupUI(width: CGFloat, height: CGFloat, titleBarHeight: CGFloat) {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.masksToBounds = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        container.layer?.borderColor = VibeTheme.stroke.cgColor
        container.layer?.borderWidth = 0.5

        // Title bar (using DraggableTitleBar for drag support)
        titleBarView = DraggableTitleBar(frame: NSRect(
            x: 0, y: height - titleBarHeight,
            width: width, height: titleBarHeight
        ))
        titleBarView.wantsLayer = true
        titleBarView.layer?.backgroundColor = VibeTheme.chromeStrong.cgColor
        titleBarView.autoresizingMask = [.width, .minYMargin]
        // Hairline on the bottom edge. The bar floats over moving video, so it
        // needs an edge of its own to read as chrome instead of a smudge.
        let titleRule = HairlineView(frame: NSRect(x: 0, y: 0, width: width, height: 1))
        titleRule.wantsLayer = true
        titleRule.layer?.backgroundColor = VibeTheme.stroke.cgColor
        titleRule.autoresizingMask = [.width, .maxYMargin]
        titleBarView.addSubview(titleRule)

        let titleEffect = NSVisualEffectView(frame: titleBarView.bounds)
        titleEffect.autoresizingMask = [.width, .height]
        titleEffect.material = .hudWindow
        titleEffect.blendingMode = .withinWindow
        titleEffect.state = .active
        titleEffect.appearance = NSAppearance(named: .darkAqua)
        titleBarView.addSubview(titleEffect, positioned: .below, relativeTo: nil)

        // Close button (red)
        let closeBtn = createCircleButton(
            frame: NSRect(x: 10, y: 8, width: 20, height: 20),
            color: VibeTheme.Dot.close,
            glyph: "xmark",
            action: #selector(closeWindow)
        )
        titleBarView.addSubview(closeBtn)

        // Opacity button (yellow)
        let miniBtn = createCircleButton(
            frame: NSRect(x: 38, y: 8, width: 20, height: 20),
            color: VibeTheme.Dot.dim,
            glyph: "circle.lefthalf.filled",
            action: #selector(toggleOpacity)
        )
        titleBarView.addSubview(miniBtn)

        // Pin (green) — locks position and pauses auto-dock
        let zoomBtn = createCircleButton(
            frame: NSRect(x: 66, y: 8, width: 20, height: 20),
            color: VibeTheme.Dot.pin,
            glyph: "pin",
            action: #selector(togglePin)
        )
        zoomBtn.toolTip = "Khóa vị trí trên màn hình"
        pinButton = zoomBtn as? NSButton
        titleBarView.addSubview(zoomBtn)
        applyPositionLockState()

        // Ghost Mode button (purple / click-through)
        let ghostBtn = createCircleButton(
            frame: NSRect(x: 94, y: 8, width: 20, height: 20),
            color: VibeTheme.Dot.ghost,
            glyph: "eye",
            action: #selector(toggleGhostMode)
        )
        ghostBtn.toolTip = "Xuyên chuột — bấm xuyên phim để gõ code. Thanh điều khiển vẫn bấm được."
        titleBarView.addSubview(ghostBtn)
        closeBtn.toolTip = "Đóng"
        miniBtn.toolTip = "Độ mờ"

        // Title text
        titleLabel = NSTextField(frame: NSRect(
            x: 126, y: 8,
            width: max(60, width - 138), height: 20
        ))
        titleLabel.stringValue = videoTitle
        titleLabel.isEditable = false
        titleLabel.isBordered = false
        titleLabel.drawsBackground = false
        titleLabel.backgroundColor = .clear
        titleLabel.textColor = VibeTheme.icon
        titleLabel.font = VibeTheme.Font.title
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.maximumNumberOfLines = 1
        titleLabel.autoresizingMask = [.width]
        titleBarView.addSubview(titleLabel)

        // WKWebView (fills entire window, title bar overlays on top)
        let webConfig = WKWebViewConfiguration()
        webConfig.mediaTypesRequiringUserActionForPlayback = []
        webConfig.userContentController.add(self, name: "adWatch")
        webConfig.userContentController.add(self, name: "adAudio")
        webConfig.userContentController.add(self, name: "adSkip")
        webConfig.userContentController.add(self, name: "aiDub")
        let aiDubScript = WKUserScript(source: Self.aiDubbingJavaScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        webConfig.userContentController.addUserScript(aiDubScript)
        webConfig.userContentController.addUserScript(WKUserScript(
            source: Self.embeddedMediaControlJavaScript,
            injectionTime: .atDocumentStart, forMainFrameOnly: false))
        setupAIDubbing()

        let webFrame = NSRect(x: 0, y: 0, width: width, height: height)
        webView = WKWebView(frame: webFrame, configuration: webConfig)
        webView.autoresizingMask = []
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = self
        webView.uiDelegate = self

        // Use native Safari User-Agent to avoid JS engine fingerprint mismatch triggering YouTube's "fake browser" bot detection
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.3 Safari/605.1.15"
        installGamblingContentRules()

        container.addSubview(webView)
        let edges = ResizeEdgeView(frame: container.bounds)
        edges.border = resizeBorderWidth
        edges.autoresizingMask = [.width, .height]
        container.addSubview(edges)
        resizeEdgeView = edges

        // Loading overlay (covers webView during loading)
        let overlay = LoadingOverlayView(frame: webFrame)
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.black.cgColor
        overlay.autoresizingMask = [.width, .height]

        let spinnerSize: CGFloat = 36.0
        let spinnerContainer = CALayer()
        spinnerContainer.bounds = CGRect(x: 0, y: 0, width: spinnerSize, height: spinnerSize)
        spinnerContainer.position = CGPoint(x: webFrame.width / 2, y: webFrame.height / 2)

        let arcPath = CGMutablePath()
        arcPath.addArc(
            center: CGPoint(x: spinnerSize / 2, y: spinnerSize / 2),
            radius: spinnerSize / 2 - 2,
            startAngle: 0,
            endAngle: .pi * 1.5,
            clockwise: false
        )
        // Faint full ring behind the moving arc, so the spinner has a body.
        let ringPath = CGMutablePath()
        ringPath.addArc(
            center: CGPoint(x: spinnerSize / 2, y: spinnerSize / 2),
            radius: spinnerSize / 2 - 2,
            startAngle: 0,
            endAngle: .pi * 2,
            clockwise: false
        )
        let ringLayer = CAShapeLayer()
        ringLayer.frame = spinnerContainer.bounds
        ringLayer.path = ringPath
        ringLayer.strokeColor = VibeTheme.stroke.cgColor
        ringLayer.fillColor = nil
        ringLayer.lineWidth = 2.5
        spinnerContainer.addSublayer(ringLayer)

        let arcLayer = CAShapeLayer()
        arcLayer.frame = spinnerContainer.bounds
        arcLayer.path = arcPath
        arcLayer.strokeColor = VibeTheme.accent.cgColor
        arcLayer.fillColor = nil
        arcLayer.lineWidth = 2.5
        arcLayer.lineCap = .round
        spinnerContainer.addSublayer(arcLayer)

        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = 2 * Double.pi
        rotation.duration = 1.0
        rotation.repeatCount = .infinity
        spinnerContainer.add(rotation, forKey: "spin")

        overlay.layer?.addSublayer(spinnerContainer)
        overlay.spinnerLayer = spinnerContainer
        container.addSubview(overlay)
        self.loadingOverlay = overlay

        // Title bar (overlays on top of webView and overlay, shown on hover)
        container.addSubview(titleBarView)

        // Bottom control bar (shown on hover, modern Apple PiP style)
        let barH: CGFloat = VibePlacer.stripHeight
        controlBarView = ControlBarView(frame: NSRect(x: 0, y: 0, width: width, height: barH))
        controlBarView.wantsLayer = true
        controlBarView.layer?.backgroundColor = VibeTheme.chrome.cgColor
        controlBarView.layer?.cornerRadius = VibeTheme.Radius.lg
        controlBarView.layer?.masksToBounds = true
        controlBarView.layer?.borderColor = VibeTheme.stroke.cgColor
        controlBarView.layer?.borderWidth = 0.5
        controlBarView.autoresizingMask = [.width, .maxYMargin]
        controlBarView.alphaValue = 0

        let controlEffect = NSVisualEffectView(frame: controlBarView.bounds)
        controlEffect.autoresizingMask = [.width, .height]
        controlEffect.material = .hudWindow
        controlEffect.blendingMode = .withinWindow
        controlEffect.state = .active
        controlEffect.appearance = NSAppearance(named: .darkAqua)
        controlBarView.addSubview(controlEffect, positioned: .below, relativeTo: nil)

        for label in [stripTitleLabel, stripStateLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.textColor = VibeTheme.icon
            controlBarView.addSubview(label)
        }
        stripTitleLabel.font = VibeTheme.Font.playerTitle
        stripStateLabel.font = VibeTheme.Font.label
        stripStateLabel.textColor = VibeTheme.iconMuted
        stripStateLabel.alignment = .right

        // Separate seeking from transport controls without adding visual weight.
        let barRule = HairlineView(frame: NSRect(x: 0, y: 0, width: width, height: 1))
        barRule.wantsLayer = true
        barRule.layer?.backgroundColor = VibeTheme.stroke.cgColor
        barRule.autoresizingMask = [.width]
        controlBarView.addSubview(barRule)
        controlBarRule = barRule

        // Modern Scrubber (timeline track + knob)
        scrubberView = ModernScrubberView(frame: NSRect(x: 14, y: barH - 18, width: max(50, width - 28), height: 16))
        scrubberView.onPreview = { [weak self] percent in
            guard let self = self, self.playbackDuration > 1 else { return }
            let seconds = self.playbackDuration * percent
            self.timeLabel?.stringValue = "\(self.formatTime(seconds)) / \(self.formatTime(self.playbackDuration))"
        }
        scrubberView.onHover = { [weak self] percent in
            guard let self = self else { return }
            if let percent = percent, self.playbackDuration > 1 {
                self.timeLabel?.stringValue = "\(self.formatTime(self.playbackDuration * percent)) / \(self.formatTime(self.playbackDuration))"
            } else {
                self.refreshPlaybackClock()
            }
        }
        scrubberView.onSeek = { [weak self] percent in
            self?.userSeekedThisEpisode = true
            self?.seekTo(percent: percent)
        }
        controlBarView.addSubview(scrubberView)

        // Rewind 10s
        let rewBtn = makeControlButton(symbolName: "gobackward.10", action: #selector(skipBackward))
        self.rewindButton = rewBtn
        controlBarView.addSubview(rewBtn)

        // Play/Pause (prominent primary circular button)
        let ppBtn = makePrimaryPlayButton(action: #selector(togglePlayPause))
        self.playPauseButton = ppBtn
        controlBarView.addSubview(ppBtn)

        let prevEpBtn = makeControlButton(symbolName: "backward.end.fill", action: #selector(prevEpisode))
        prevEpBtn.toolTip = "Tập trước"
        prevEpBtn.isHidden = true
        controlBarView.addSubview(prevEpBtn)
        stripPrevEpisodeButton = prevEpBtn

        let nextEpBtn = makeControlButton(symbolName: "forward.end.fill", action: #selector(nextEpisode))
        nextEpBtn.toolTip = "Tập sau"
        nextEpBtn.isHidden = true
        controlBarView.addSubview(nextEpBtn)
        stripNextEpisodeButton = nextEpBtn

        // Skip forward 10s
        let fwdBtn = makeControlButton(symbolName: "goforward.10", action: #selector(skipForward))
        self.skipButton = fwdBtn
        controlBarView.addSubview(fwdBtn)

        // Volume Mute toggle
        let volBtn = makeControlButton(symbolName: "speaker.wave.2.fill", action: #selector(toggleMute))
        self.volumeButton = volBtn
        controlBarView.addSubview(volBtn)

        // Volume slider
        let slider = NSSlider(frame: NSRect(x: 0, y: 11, width: 48, height: 20))
        slider.minValue = 0
        slider.maxValue = 1
        slider.doubleValue = 1
        slider.target = self
        slider.action = #selector(volumeChanged(_:))
        slider.isContinuous = true
        slider.controlSize = .small
        controlBarView.addSubview(slider)
        self.volumeSlider = slider

        // Speed badge / button (1.0x -> 1.25x -> 1.5x -> 2.0x -> 0.75x)
        let sBtn = StripIconButton(frame: NSRect(x: 0, y: 10, width: 38, height: 22))
        sBtn.bezelStyle = .inline
        sBtn.isBordered = false
        sBtn.wantsLayer = true
        sBtn.wash = .chip(VibeTheme.chipIdle)
        sBtn.layer?.backgroundColor = VibeTheme.chipIdle.cgColor
        sBtn.layer?.cornerRadius = VibeTheme.Radius.sm
        sBtn.title = "1.0x"
        sBtn.font = VibeTheme.Font.badge
        sBtn.contentTintColor = VibeTheme.icon
        sBtn.target = self
        sBtn.action = #selector(cyclePlaybackRate)
        controlBarView.addSubview(sBtn)
        self.speedButton = sBtn

        // Maximize / Restore button
        let maxBtn = makeControlButton(symbolName: "arrow.up.left.and.arrow.down.right", action: #selector(toggleMaximize))
        maxBtn.toolTip = "Phóng tối đa / Khôi phục kích thước (F)"
        controlBarView.addSubview(maxBtn)
        self.maximizeButton = maxBtn

        let smallerBtn = makeControlButton(symbolName: "minus.magnifyingglass", action: #selector(shrinkWindow))
        smallerBtn.toolTip = "Thu nhỏ cửa sổ (⌃⌥-)"
        controlBarView.addSubview(smallerBtn)
        sizeDownButton = smallerBtn

        let largerBtn = makeControlButton(symbolName: "plus.magnifyingglass", action: #selector(growWindow))
        largerBtn.toolTip = "Phóng to cửa sổ (⌃⌥=)"
        controlBarView.addSubview(largerBtn)
        sizeUpButton = largerBtn

        // Time label
        let tLabel = NSTextField(frame: NSRect(x: 0, y: 9, width: 90, height: 20))
        tLabel.stringValue = "--:--"
        tLabel.isEditable = false
        tLabel.isBordered = false
        tLabel.drawsBackground = false
        tLabel.textColor = VibeTheme.icon
        tLabel.font = VibeTheme.Font.time
        tLabel.alignment = .right
        tLabel.toolTip = "Thời gian"
        tLabel.lineBreakMode = .byClipping
        self.timeLabel = tLabel
        controlBarView.addSubview(tLabel)

        let presetMini = makeSizePresetChip(.mini)
        controlBarView.addSubview(presetMini)
        sizePresetMiniButton = presetMini
        let presetStandard = makeSizePresetChip(.standard)
        controlBarView.addSubview(presetStandard)
        sizePresetStandardButton = presetStandard
        let presetWide = makeSizePresetChip(.wide)
        controlBarView.addSubview(presetWide)
        sizePresetWideButton = presetWide
        selectedSizePreset = Self.savedSizePreset
        refreshSizePresetChipStyles()

        let closeOnStrip = makeControlButton(symbolName: "xmark", action: #selector(closeWindow), pointSize: 11)
        closeOnStrip.contentTintColor = VibeTheme.close
        closeOnStrip.toolTip = "Đóng"
        controlBarView.addSubview(closeOnStrip)
        stripCloseButton = closeOnStrip

        let ghostOnStrip = makeControlButton(symbolName: "eye", action: #selector(toggleGhostMode))
        ghostOnStrip.toolTip = "Xuyên chuột"
        controlBarView.addSubview(ghostOnStrip)
        stripGhostButton = ghostOnStrip

        let pinOnStrip = makeControlButton(symbolName: "pin", action: #selector(togglePin))
        controlBarView.addSubview(pinOnStrip)
        stripPinButton = pinOnStrip
        applyPositionLockState()

        let duckOnStrip = makeControlButton(symbolName: "ear", action: #selector(toggleDuck))
        duckOnStrip.toolTip = "Hạ tiếng"
        controlBarView.addSubview(duckOnStrip)
        stripDuckButton = duckOnStrip

        let autoNextBtn = makeControlButton(symbolName: "forward.end.alt.fill", action: #selector(toggleAutoNextEpisode), pointSize: 11)
        autoNextBtn.toolTip = "Tự động chuyển tập khi hết tập"
        controlBarView.addSubview(autoNextBtn)
        stripAutoNextButton = autoNextBtn

        let skipIntroBtn = makeControlButton(symbolName: "forward.fill", action: #selector(manualSkipIntro), pointSize: 11)
        skipIntroBtn.toolTip = "Bỏ qua giới thiệu (~90s) — giữ ⌥ để bật/tắt tự động"
        controlBarView.addSubview(skipIntroBtn)
        stripSkipIntroButton = skipIntroBtn

        // Films are mixed for headphones; this lifts the whole track through
        // Web Audio (element volume is capped at 1.0). Only meaningful on a
        // movie player, so layoutControlBar() shows it on movieContext only.
        let boostOnStrip = makeControlButton(symbolName: "speaker.wave.2", action: #selector(cycleAudioBoost), pointSize: 12)
        boostOnStrip.toolTip = "Tăng âm thanh cho phim"
        boostOnStrip.isHidden = true
        controlBarView.addSubview(boostOnStrip)
        stripAudioBoostButton = boostOnStrip
        refreshAudioBoostButtonStyle()

        let dubOnStrip = makeControlButton(symbolName: "waveform.badge.plus", action: #selector(toggleOfflineDubbing), pointSize: 12)
        dubOnStrip.toolTip = "Offline Dub — dựng audio trước rồi phát"
        dubOnStrip.isHidden = true
        controlBarView.addSubview(dubOnStrip)
        stripDubButton = dubOnStrip
        refreshAIDubButtonStyle()

        let moreOnStrip = makeControlButton(symbolName: "ellipsis", action: #selector(showOverflowMenu))
        moreOnStrip.toolTip = "Thêm"
        moreOnStrip.isHidden = true
        controlBarView.addSubview(moreOnStrip)
        stripMoreButton = moreOnStrip

        playPauseButton?.toolTip = "Phát hoặc dừng"
        rewindButton?.toolTip = "Tua −10 giây"
        skipButton?.toolTip = "Tua +10 giây"
        volumeButton?.toolTip = "Tắt tiếng"
        volumeSlider?.toolTip = "Âm lượng"
        scrubberView?.toolTip = "Tua đến vị trí"
        speedButton?.toolTip = "Tốc độ phát"
        maximizeButton?.toolTip = "Phóng hết màn hình"
        refreshWatchAssistButtonStyles()

        container.addSubview(controlBarView, positioned: .above, relativeTo: webView)
        layoutVideoChrome()

        let hud = PlaybackToast(frame: NSRect(x: 12, y: height - 72, width: 160, height: 30))
        hud.alphaValue = 0
        hud.isHidden = true
        hud.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
        container.addSubview(hud)
        hudToast = hud

        let offlineProgress = NSTextField(labelWithString: "")
        offlineProgress.isEditable = false
        offlineProgress.isBordered = false
        offlineProgress.drawsBackground = false
        offlineProgress.textColor = VibeTheme.icon
        offlineProgress.font = VibeTheme.Font.label
        offlineProgress.alignment = .left
        offlineProgress.lineBreakMode = .byTruncatingTail
        offlineProgress.wantsLayer = true
        offlineProgress.layer?.backgroundColor = VibeTheme.chromeStrong.cgColor
        offlineProgress.layer?.borderColor = VibeTheme.strokeStrong.cgColor
        offlineProgress.layer?.borderWidth = 0.6
        offlineProgress.layer?.cornerRadius = 10
        offlineProgress.isHidden = true
        offlineProgress.frame = NSRect(x: 14, y: max(52, height - 64), width: 300, height: 24)
        container.addSubview(offlineProgress)
        offlineDubProgressLabel = offlineProgress

        let offlineProgressBar = NSProgressIndicator(frame: NSRect(
            x: 14, y: max(42, height - 75), width: 300, height: 7
        ))
        offlineProgressBar.style = .bar
        offlineProgressBar.controlSize = .small
        offlineProgressBar.minValue = 0
        offlineProgressBar.maxValue = 1
        offlineProgressBar.doubleValue = 0
        offlineProgressBar.isIndeterminate = false
        offlineProgressBar.isDisplayedWhenStopped = false
        offlineProgressBar.isHidden = true
        container.addSubview(offlineProgressBar)
        offlineDubProgressBar = offlineProgressBar

        // Hide title bar by default (PiP-style: shown on hover)
        titleBarView.alphaValue = 0

        // Corner resize grip — visible while hovering so size changes are discoverable
        let resizeIndicator = NSTextField(frame: NSRect(
            x: width - 22, y: 4, width: 18, height: 16
        ))
        resizeIndicator.stringValue = "⟋"
        resizeIndicator.isEditable = false
        resizeIndicator.isBordered = false
        resizeIndicator.drawsBackground = false
        resizeIndicator.textColor = VibeTheme.iconMuted
        resizeIndicator.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        resizeIndicator.autoresizingMask = [.minXMargin, .maxYMargin]
        resizeIndicator.alphaValue = 0
        resizeIndicator.isHidden = false
        container.addSubview(resizeIndicator)
        self.resizeIndicator = resizeIndicator

        self.contentView = container

        // Add tracking area for the entire window (for setting resize cursors)
        let trackingArea = NSTrackingArea(
            rect: container.bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        container.addTrackingArea(trackingArea)
    }

    private func createCircleButton(frame: NSRect, color: NSColor, glyph: String,
                                    action: Selector?) -> NSView {
        let btn = TitleCircleButton(frame: frame, color: color, glyphName: glyph)
        if let action = action {
            btn.target = self
            btn.action = action
        }
        return btn
    }

    // MARK: - Window Positioning

    private func positionWindow() {
        // Restore last size; placement vs code windows happens in show()/placeAwayFromCode().
        if let dict = UserDefaults.standard.dictionary(forKey: Self.frameKey),
           let w = dict["w"] as? CGFloat, dict["h"] is CGFloat {
            let restoredW = max(w, self.minSize.width)
            let savedH = restoredW / videoAspectRatio
            if let x = dict["x"] as? CGFloat, let y = dict["y"] as? CGFloat {
                let savedFrame = NSRect(x: x, y: y, width: restoredW, height: savedH)
                if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(savedFrame) }) {
                    self.setFrame(savedFrame, display: false)
                    return
                }
            }
            // Size only — park top-right until placer runs.
            guard let screen = NSScreen.main else { return }
            let screenFrame = screen.visibleFrame
            let frame = NSRect(
                x: screenFrame.maxX - restoredW - 20,
                y: screenFrame.maxY - savedH - 20,
                width: restoredW,
                height: savedH
            )
            self.setFrame(frame, display: false)
            return
        }
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.maxX - self.frame.width - 20
        let y = screenFrame.maxY - self.frame.height - 20
        self.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Prefer a clear pocket away from coding/input; fall back to coding-safe mode.
    func placeAwayFromCode() {
        guard !isPinned else { return }
        vibeDock.placeImmediately(self)
    }

    private func keepingLockedOrigin(_ proposed: NSRect) -> NSRect {
        guard isPinned, let lockedOrigin else { return proposed }
        var result = proposed
        result.origin = lockedOrigin
        return result
    }

    /// Put the window back on the origin captured when the user pinned it.
    /// Resize may change the size; auto-dock and AppKit adjustments may not
    /// change the corner.
    private func enforcePinnedOrigin() {
        guard isPinned else { return }
        if lockedOrigin == nil { lockedOrigin = frame.origin }
        guard let lockedOrigin else { return }
        guard abs(frame.origin.x - lockedOrigin.x) > 0.5
                || abs(frame.origin.y - lockedOrigin.y) > 0.5 else { return }
        var fixed = frame
        fixed.origin = lockedOrigin
        setFrame(fixed, display: true)
        syncControlStrip(animated: false)
    }

    /// A pinned window stays put while its display exists. If that display is
    /// gone, park it on a visible screen and pin the new corner.
    private func recoverPinnedWindowIfOffscreen() {
        guard isPinned else { return }
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        if screens.contains(where: { $0.frame.intersects(frame.insetBy(dx: 8, dy: 8)) }) { return }
        let screen = NSScreen.main ?? screens[0]
        let vis = screen.visibleFrame
        var next = frame
        next.size.width = min(max(next.width, minSize.width), max(minSize.width, vis.width - 16))
        next.size.height = next.size.width / max(videoAspectRatio, 0.2)
        next.origin.x = vis.maxX - next.width - 20
        next.origin.y = vis.maxY - next.height - 20
        lockedOrigin = next.origin
        setFrame(next, display: true)
        syncControlStrip(animated: false)
        saveWindowFrame()
        showHUD("Đã đưa cửa sổ về màn hình")
    }

    private func saveWindowFrame() {
        // Never persist transient coding-safe shrunk frames as the user's permanent default.
        guard !isCodingSafeMode else { return }
        let frame = self.frame
        let dict: [String: CGFloat] = [
            "x": frame.origin.x, "y": frame.origin.y,
            "w": frame.size.width, "h": frame.size.height
        ]
        UserDefaults.standard.set(dict, forKey: Self.frameKey)
    }

    // MARK: - Untrusted Input Handling

    /// Domains the float window is willing to navigate to as an embed. The
    /// message carrying these URLs comes from another process — and, in the
    /// worst case, from a page that scripted it — so the URL is checked here,
    /// not trusted. Subdomains of these domains are accepted; adding a new
    /// provider means adding its domain here.
    private static let allowedEmbedDomains: [String] = [
        "phimapi.com", "nguonc.com", "ophim1.com", "streamc.xyz",
        "kkphimplayer.com", "kkphimplayer6.com", "kkphim.com", "ophim.com",
    ]

    /// Only movie providers may become documents inspected by the app.
    private static let allowedTopLevelDomains = allowedEmbedDomains

    /// Loopback hosts allowed to keep plain `http` (the local player server).
    private static let plainHTTPHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]

    private static let allowedDirectMediaDomains: [String] = allowedEmbedDomains + [
        "akamaized.net", "cloudfront.net", "fastly.net",
    ]

    /// Schemes that are never valid for a media/document URL: `javascript:`
    /// executes, `data:`/`blob:` carry attacker-authored documents, `file:`
    /// reaches the local disk.
    private static let forbiddenSchemes: Set<String> = [
        "javascript", "data", "blob", "file", "filesystem", "about", "vbscript",
    ]

    /// Hosts whose session cookies the float window mirrors into its WebView.
    /// They must never become the origin our inline player page runs in, or that
    /// page could read the mirrored session through `document.cookie`.
    private static let cookieBearingHosts: [String] = ["youtube.com", "google.com", "youtu.be"]

    /// Parses a URL only from a string that is plausibly one. `URL(string:)`
    /// tolerates quotes, angle brackets and whitespace, all of which would then
    /// flow into markup or a document origin; this refuses them up front.
    private static func sanitizedURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let forbidden: Set<Character> = ["\"", "'", "<", ">", "`", "\\", " "]
        guard !trimmed.contains(where: { forbidden.contains($0) || $0.isNewline }) else { return nil }
        guard !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return URL(string: trimmed)
    }

    /// Returns only the origin for diagnostics. Query strings and fragments may
    /// contain signed media URLs or capability values and must never reach logs.
    private static func loggableURL(_ raw: String) -> String {
        guard let url = URL(string: raw),
              let scheme = url.scheme,
              let host = url.host else { return "<invalid-url>" }
        return "\(scheme)://\(host)"
    }

    private static func hostMatches(_ host: String, anyOf domains: [String]) -> Bool {
        let h = host.lowercased()
        return domains.contains { h == $0 || h.hasSuffix("." + $0) }
    }

    static let curatedYouTubeMovieIDs: Set<String> = ["4bjvj11fdV4", "VcVNNDxbMGM", "dk540-a-h-I", "_WcFyejYtZM", "iZbKjlIU6Fo", "Z40GTe-gsNo", "XwDI36fOAXQ", "YMVvVM4eGEY", "-fi7M_sA7l8", "4uh1SexAXPU", "wwqcuiyeckk", "rnikYJGo3j4", "SMZulU8vVdg", "bE0-VBWutqY", "6_UuGLoAnnU"]

    static func curatedYouTubeMovieID(_ raw: String) -> String? {
        guard let url = sanitizedURL(raw), url.scheme == "https",
              url.user == nil, url.password == nil, url.port == nil,
              let host = url.host?.lowercased() else { return nil }
        let id: String?
        if ["youtube.com", "www.youtube.com"].contains(host), url.path == "/watch" {
            id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "v" }?.value
        } else if ["www.youtube.com", "www.youtube-nocookie.com"].contains(host),
                  url.path.hasPrefix("/embed/") {
            id = String(url.path.dropFirst("/embed/".count))
        } else { return nil }
        guard let id, curatedYouTubeMovieIDs.contains(id) else { return nil }
        return id
    }

    /// Validation for a URL that will become a navigation target: scheme must be
    /// `https` (plain `http` only for loopback), and the host must be one of the
    /// providers this app embeds. Returns nil when the URL is not acceptable.
    static func validateMediaURL(_ raw: String) -> URL? {
        guard let url = sanitizedURL(raw),
              let scheme = url.scheme?.lowercased(), !forbiddenSchemes.contains(scheme),
              let host = url.host, !host.isEmpty else { return nil }
        if scheme == "https" {
            return hostMatches(host, anyOf: Self.allowedEmbedDomains) ? url : nil
        }
        if scheme == "http" {
            return Self.plainHTTPHosts.contains(host.lowercased()) ? url : nil
        }
        return nil
    }

    /// `loadHTMLString(_:baseURL:)` makes baseURL the loaded document's origin.
    /// Using the stream URL's own origin keeps relative references and Referer
    /// behaviour intact, but an origin we hold session cookies for would let the
    /// inline page read them, so that case degrades to nil (a valid argument).
    static func documentBaseURL(for raw: String) -> URL? {
        guard let url = Self.validateMediaURL(raw), let host = url.host else { return nil }
        guard !Self.hostMatches(host, anyOf: Self.cookieBearingHosts) else {
            NSLog("[FloatVideo] Not using cookie-bearing origin as document base: \(host)")
            return nil
        }
        return url
    }

    /// Gate for the media `<video>` source. Direct streams use the same
    /// controlled provider/CDN host set as top-level navigation; the value is
    /// also JS-escaped before interpolation.
    static func isSafeMediaSource(_ raw: String) -> Bool {
        guard let url = Self.sanitizedURL(raw), let scheme = url.scheme?.lowercased(), let host = url.host else { return false }
        if scheme == "http" { return Self.plainHTTPHosts.contains(host.lowercased()) }
        return scheme == "https" && Self.hostMatches(host, anyOf: Self.allowedDirectMediaDomains)
    }

    /// HTML-context escape for values interpolated into markup (attribute or
    /// text), covering `& < > " '`.
    static func escapeHTML(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        for ch in value {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(ch)
            }
        }
        return out
    }

    /// Escape for a value interpolated into a JavaScript string literal inside a
    /// `<script>` block: the closing quote, backslashes, line terminators, the
    /// `U+2028`/`U+2029` separators (literal newlines in JS), and `<`/`>`/`&`
    /// (encoded so the literal cannot close the script element).
    static func escapeJSString(_ value: String, quote: Character = "'") -> String {
        var out = ""
        out.reserveCapacity(value.count)
        for ch in value {
            switch ch {
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\u{2028}": out += "\\u2028"
            case "\u{2029}": out += "\\u2029"
            case "<": out += "\\u003c"
            case ">": out += "\\u003e"
            case "&": out += "\\u0026"
            case quote: out += "\\\(ch)"
            default: out.append(ch)
            }
        }
        return out
    }

    // MARK: - Video Loading

    func loadVideo(url: String, videoSrc: String?, embedUrl: String?,
                   currentTime: Double, site: String,
                   httpServerPortProvider: (() -> UInt16)? = nil,
                   httpServerPlayCapabilityProvider: (() -> String?)? = nil,
                   cookies: [[String: Any]] = [],
                   playerPrefs: [String: Any]? = nil) {
        if site == "youtube", Self.curatedYouTubeMovieID(url) == nil {
            showHUD("Chỉ phát phim YouTube trong danh sách đã chọn")
            return
        }
        stopEmbedAudioMonitor()
        // Save parameters for NavigationDelegate use
        self.currentSite = site
        self.currentVideoTime = currentTime
        self.currentPageURL = url
        self.httpServerPortProvider = httpServerPortProvider
        self.httpServerPlayCapabilityProvider = httpServerPlayCapabilityProvider
        self.playerPrefs = playerPrefs
        self.hasInjectedJS = false
        self.injectionProbeTicks = 0
        self.loadingStrategy = .fullPageInject
        self.loadGeneration += 1
        self.directFrameUnreadable = false
        self.adCoverOn = false
        self.letterboxTop = nil
        self.letterboxBottom = nil
        self.letterboxCandidateTop = nil
        self.letterboxCandidateBottom = nil
        self.letterboxHits = 0
        self.didShowCaptureHUD = false
        self.suppressWatchAssist = true
        self.hasTriedDirectEmbedFallback = false
        self.interstitialSkipOrigin = nil
        self.didAnnounceInterstitialSkip = false
        self.interstitialSkipBusy = false
        self.interstitialScanBusy = false
        self.audioScanBusy = false
        self.audioScanToken += 1
        self.lastVisualAdAt = nil
        self.lastAdDetectionAt = nil
        self.lastEmbedAdScanAt = .distantPast
        self.lastEmbedAudioTranscript = ""
        self.lastEmbedAudioDetectionAt = .distantPast
        self.lastAudioBoostStatus = ""
        self.lastAudioBoostPushAt = .distantPast
        self.currentEmbedUrl = embedUrl?.isEmpty == false ? embedUrl : nil
        self.currentOfflineVideoURL = videoSrc.flatMap { Self.isSafeMediaSource($0) ? URL(string: $0) : nil }
        self.offlineDubOCR?.cancel()
        self.offlineDubOCR = nil
        self.offlineDubUsedOCR = false
        self.offlineDubTimelineSignature = nil
        self.offlineDubSession.stop()
        if isOfflineDubEnabled { offlineDubPlaybackAuthorized = false }
        resetYouTubeFallbackState()
        installPlayerPrefsSeedScript()
        installGamblingAdBypassScript()
        installMovieEmbedAdScript()

        refreshAudioBoostButtonStyle()
        layoutControlBar()

        // Lofi / live channels ask for the embed path so signed-out WKWebView
        // never hits the youtube.com/watch bot wall.
        if site == "youtube" && preferYouTubeEmbed {
            loadPreferredYouTubeEmbed(pageURL: url, currentTime: currentTime)
            return
        }

        if site == "youtube" {
            // One-line capture summary so caption problems are attributable at
            // a glance: was the track (incl. translation) captured at all?
            var trackDesc = "none"
            if let track = playerPrefs?["captionTrack"] as? [String: Any],
               let lang = track["languageCode"] as? String {
                if let tl = track["translationLanguage"] as? [String: Any],
                   let tlang = tl["languageCode"] as? String {
                    trackDesc = "\(lang)->\(tlang)"
                } else {
                    trackDesc = lang
                }
            }
            let lsCount = (playerPrefs?["localStorage"] as? [String: Any])?.count ?? 0
            let rate = (playerPrefs?["playbackRate"] as? NSNumber)?.doubleValue ?? 1.0
            NSLog("[FloatVideo] playerPrefs received: track=\(trackDesc) lsKeys=\(lsCount) rate=\(rate)")
        }

        // Suspend while the next document boots. The overlay only exists for the
        // first load; later episodes (next/prev) must still be unsuspended or
        // the new <video> stays paused forever.
        webView.setAllMediaPlaybackSuspended(true, completionHandler: nil)
        scheduleResumeIfOverlayAlreadyGone()

        // Priority 1: Direct video source URL. The source must at least be a
        // real http(s) URL: a `javascript:`/`data:` source has no business
        // reaching the player page, and a source carrying markup characters
        // means the payload was crafted, not captured.
        if let videoSrc = videoSrc, !videoSrc.isEmpty, Self.isSafeMediaSource(videoSrc) {
            self.loadingStrategy = .directVideo
            let html = buildVideoHTML(videoSrc: videoSrc, currentTime: currentTime)
            webView.loadHTMLString(html, baseURL: Self.documentBaseURL(for: videoSrc))
            NSLog("[FloatVideo] Loading direct video host: \(Self.loggableURL(videoSrc))")
            return
        }

        // Priority 2: YouTube -- prefer watch page + JS injection, keep embed as fallback
        if site == "youtube" {
            refreshYouTubeEmbedFallbackURLIfNeeded()

            if !url.isEmpty, let pageURL = URL(string: url) {
                let loadPage = { [weak self] in
                    self?.loadingStrategy = .fullPageInject
                    self?.webView.load(URLRequest(url: pageURL))
                    NSLog("[FloatVideo] Loading YouTube full page host: \(Self.loggableURL(url))")
                }

                if !cookies.isEmpty {
                    injectCookies(cookies) {
                        loadPage()
                    }
                } else {
                    loadPage()
                }
                return
            }

            if startYouTubeEmbedFallback(reason: "missing-full-page-url") {
                return
            }
        }

        // Priority 3: Embed URL -- load directly in WKWebView with Referer
        if let embedUrl = embedUrl, !embedUrl.isEmpty {
            if let targetURL = Self.validateMediaURL(embedUrl) {
                self.loadingStrategy = .siteEmbed
                self.currentEmbedUrl = embedUrl
                self.hasTriedIframeEmbedFallback = false
                var request = URLRequest(url: targetURL)
                if !url.isEmpty, let _ = URL(string: url) {
                    request.setValue(url, forHTTPHeaderField: "Referer")
                } else if embedUrl.contains("streamc.xyz") {
                    request.setValue("https://phim.nguonc.com/", forHTTPHeaderField: "Referer")
                }
                webView.load(request)
                NSLog("[FloatVideo] Loading embed host: \(Self.loggableURL(embedUrl))")
                return
            }
            NSLog("[FloatVideo] Refused embed host outside the allowlist: \(Self.loggableURL(embedUrl))")
        }

        // Priority 4: Load full page and inject JS
        if !url.isEmpty, let pageURL = Self.validateMediaURL(url) {
            webView.load(URLRequest(url: pageURL))
            NSLog("[FloatVideo] Loading full page host: \(Self.loggableURL(url))")
        }
    }

    // MARK: - Cookie Injection

    /// Cookies the extension is allowed to mirror into the float window. The
    /// names are re-checked here on purpose: the payload is JSON from another
    /// process, so it must not decide *which* cookies exist. Domain and path are
    /// pinned for the same reason — they used to be read from the message, which
    /// let a payload plant cookies on any origin the WebView visited.
    private static let mirrorableCookieNames: Set<String> = [
        "SID", "HSID", "SSID", "APISID", "SAPISID", "SIDCC", "LOGIN_INFO",
        "__Secure-1PSID", "__Secure-3PSID",
        "__Secure-1PAPISID", "__Secure-3PAPISID",
        "__Secure-1PSIDTS", "__Secure-3PSIDTS",
        "__Secure-1PSIDCC", "__Secure-3PSIDCC",
    ]
    private static let mirroredCookieDomain = ".youtube.com"
    private static let mirroredCookiePath = "/"

    private func injectCookies(_ cookies: [[String: Any]], completion: @escaping () -> Void) {
        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        let group = DispatchGroup()
        var injected = 0
        var skipped = 0

        for cookieData in cookies {
            guard let name = cookieData["name"] as? String,
                  let value = cookieData["value"] as? String,
                  Self.mirrorableCookieNames.contains(name) else {
                skipped += 1
                continue
            }

            let secure = (cookieData["secure"] as? Bool) ?? false || name.hasPrefix("__Secure-")
            var setCookie = "\(name)=\(value); Domain=\(Self.mirroredCookieDomain); Path=/; HttpOnly"
            if secure { setCookie += "; Secure" }
            let cookieURL = URL(string: "https://www.youtube.com/")!
            let properties = HTTPCookie.cookies(
                withResponseHeaderFields: ["Set-Cookie": setCookie],
                for: cookieURL
            )

            if let cookie = properties.first, cookie.isHTTPOnly {
                injected += 1
                group.enter()
                cookieStore.setCookie(cookie) {
                    group.leave()
                }
            } else {
                skipped += 1
            }
        }

        group.notify(queue: .main) {
            NSLog("[FloatVideo] Injected \(injected) session cookies (skipped \(skipped))")
            completion()
        }
    }

    /// Cinema Lofi path. A direct nocookie iframe paints without waiting for the
    /// local HTTP server or the widget API. The local /play page is only a fallback.
    private func loadPreferredYouTubeEmbed(pageURL: String, currentTime: Double, attempt: Int = 0) {
        if let videoId = extractYouTubeVideoId(from: pageURL),
           videoId.range(of: #"^[A-Za-z0-9_-]{6,16}$"#, options: .regularExpression) != nil {
            var components = URLComponents()
            components.scheme = "https"
            components.host = "www.youtube-nocookie.com"
            components.path = "/embed/\(videoId)"
            var items = [
                URLQueryItem(name: "autoplay", value: "1"),
                URLQueryItem(name: "rel", value: "0"),
                URLQueryItem(name: "playsinline", value: "1"),
                URLQueryItem(name: "modestbranding", value: "1"),
            ]
            let start = Int(currentTime)
            if start > 0 {
                items.append(URLQueryItem(name: "start", value: String(start)))
            }
            components.queryItems = items
            if components.url != nil {
                preferYouTubeEmbed = true
                loadingStrategy = .youtubeEmbed
                hasTriedYouTubeEmbedFallback = true
                // A top-level WKWebView navigation sends no Referer, and YouTube
                // answers that with Error 153. loadHTMLString only attaches a
                // Referer when baseURL is the embedding app's own https origin
                // (YouTube's required-minimum-functionality rule). The IFrame
                // Player API then creates the embed from that page.
                let origin = "https://com.aspect.floatvideo"
                let html = """
                <!DOCTYPE html>
                <html><head>
                <meta charset="utf-8">
                <meta name="referrer" content="strict-origin-when-cross-origin">
                <style>
                    html, body, #player { margin: 0; width: 100%; height: 100%; background: #000; overflow: hidden; }
                </style>
                </head><body>
                <div id="player"></div>
                <script>
                window.__floatYt = 'pending';
                var tag = document.createElement('script');
                tag.src = 'https://www.youtube.com/iframe_api';
                document.head.appendChild(tag);
                function onYouTubeIframeAPIReady() {
                    window.player = new YT.Player('player', {
                        width: '100%',
                        height: '100%',
                        videoId: '\(videoId)',
                        playerVars: {
                            autoplay: 1,
                            rel: 0,
                            playsinline: 1,
                            modestbranding: 1,
                            start: \(start),
                            origin: '\(origin)'
                        },
                        events: {
                            onReady: function(e) {
                                window.__floatYt = 'ready';
                                try { e.target.playVideo(); } catch (err) {}
                            },
                            onError: function(ev) {
                                window.__floatYt = 'error:' + ev.data;
                            }
                        }
                    });
                }
                window.getPlayerState = function() {
                    var p = window.player;
                    if (!p || typeof p.getPlayerState !== 'function') return null;
                    return {
                        ct: p.getCurrentTime() || 0, dur: p.getDuration() || 0,
                        durSrc: 'clock', vol: (p.getVolume() || 0) / 100,
                        muted: p.isMuted(), paused: p.getPlayerState() !== YT.PlayerState.PLAYING,
                        ended: p.getPlayerState() === YT.PlayerState.ENDED
                    };
                };
                window.playerCommand = function(command, value) {
                    var p = window.player;
                    if (!p || typeof p.playVideo !== 'function') return;
                    if (command === 'play') p.playVideo();
                    if (command === 'pause') p.pauseVideo();
                    if (command === 'seek') p.seekTo(value, true);
                    if (command === 'volume') p.setVolume(value * 100);
                    if (command === 'mute') p.mute();
                    if (command === 'unmute') p.unMute();
                };
                </script>
                </body></html>
                """
                webView.loadHTMLString(html, baseURL: URL(string: origin + "/")!)
                NSLog("[FloatVideo] Loading preferred YouTube embed: \(videoId) referer=\(origin)/")
                schedulePreferredEmbedHealthCheck()
                return
            }
        }

        refreshYouTubeEmbedFallbackURLIfNeeded()
        if startYouTubeEmbedFallback(reason: "prefer-embed") {
            return
        }
        if attempt >= 25 {
            NSLog("[FloatVideo] preferEmbed gave up; no video id and no HTTP port")
            showEmbedFailure("Không mở được Lofi. Thử lại sau vài giây.")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.loadPreferredYouTubeEmbed(pageURL: pageURL, currentTime: currentTime, attempt: attempt + 1)
        }
    }

    private func schedulePreferredEmbedHealthCheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self = self, self.preferYouTubeEmbed, self.loadingStrategy == .youtubeEmbed else { return }
            let js = """
            (function() {
                var st = window.__floatYt || '';
                if (st === 'ready') return 'ok';
                if (st.indexOf('error:') === 0) return st;
                var text = (document.body && document.body.innerText || '').slice(0, 240);
                if (/unavailable|private video|sign in|bot|confirm you.re not a bot|error 153/i.test(text)) return 'blocked:' + text;
                if (!document.querySelector('iframe') && st !== 'pending') return 'empty';
                return 'pending';
            })();
            """
            self.webView.evaluateJavaScript(js) { result, _ in
                let status = result as? String ?? "pending"
                if status == "ok" || status == "pending" { return }
                NSLog("[FloatVideo] Preferred embed unhealthy: \(status)")
                self.showEmbedFailure("YouTube không phát được trong cửa sổ này.")
            }
        }
    }

    private func showEmbedFailure(_ message: String) {
        let escaped = Self.escapeJSString(message, quote: "'")
        let js = """
        (function() {
            if (document.getElementById('float-embed-error')) return;
            var el = document.createElement('div');
            el.id = 'float-embed-error';
            el.textContent = '\(escaped)';
            el.style.cssText = 'position:fixed;inset:0;display:flex;align-items:center;justify-content:center;padding:24px;background:#111;color:#f4f4f5;font:14px -apple-system,sans-serif;text-align:center;z-index:9;';
            document.body.appendChild(el);
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    private func extractYouTubeVideoId(from url: String) -> String? {
        // youtube.com/watch?v=VIDEO_ID
        if let range = url.range(of: "v=") {
            let start = range.upperBound
            let remaining = String(url[start...])
            let videoId = remaining.components(separatedBy: CharacterSet(charactersIn: "&# ")).first
            if let id = videoId, !id.isEmpty { return id }
        }
        // youtube.com/embed/VIDEO_ID and youtu.be/VIDEO_ID
        for marker in ["/embed/", "youtu.be/"] {
            if let range = url.range(of: marker) {
                let start = range.upperBound
                let remaining = String(url[start...])
                let videoId = remaining.components(separatedBy: CharacterSet(charactersIn: "?&# /")).first
                if let id = videoId, !id.isEmpty { return id }
            }
        }
        // youtube.com/shorts/VIDEO_ID
        if let range = url.range(of: "/shorts/") {
            let start = range.upperBound
            let remaining = String(url[start...])
            let videoId = remaining.components(separatedBy: CharacterSet(charactersIn: "?&# /")).first
            if let id = videoId, !id.isEmpty { return id }
        }
        return nil
    }

    private func buildYouTubeEmbedFallbackURL(pageURL: String, currentTime: Double,
                                              httpServerPort: UInt16) -> URL? {
        guard httpServerPort > 0,
              let videoId = extractYouTubeVideoId(from: pageURL) else {
            return nil
        }

        let startSeconds = Int(currentTime)
        let safeViewport = youtubeSafeViewportSize()
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(httpServerPort)
        components.path = "/play"
        components.queryItems = [
            URLQueryItem(name: "cap", value: httpServerPlayCapabilityProvider?()),
            URLQueryItem(name: "v", value: videoId),
            URLQueryItem(name: "site", value: "youtube"),
            URLQueryItem(name: "t", value: String(startSeconds)),
            URLQueryItem(name: "w", value: String(Int(safeViewport.width))),
            URLQueryItem(name: "h", value: String(Int(safeViewport.height))),
        ]
        components.queryItems = components.queryItems?.filter { $0.value != nil }
        return components.url
    }

    private func youtubeSafeViewportSize() -> NSSize {
        let ratio = max(videoAspectRatio, 0.1)
        let minViewport: CGFloat = 200
        let recommendedLongEdge: CGFloat = 480
        let recommendedShortEdge: CGFloat = 270

        if ratio >= 1 {
            let height = max(recommendedShortEdge, recommendedLongEdge / ratio, minViewport)
            let width = max(height * ratio, recommendedLongEdge, minViewport)
            return NSSize(width: ceil(width), height: ceil(height))
        }

        let width = max(recommendedShortEdge, recommendedLongEdge * ratio, minViewport)
        let height = max(width / ratio, recommendedLongEdge, minViewport)
        return NSSize(width: ceil(width), height: ceil(height))
    }

    private func resetYouTubeFallbackState() {
        youtubeFallbackWorkItem?.cancel()
        youtubeFallbackWorkItem = nil
        reinjectLayoutWorkItem?.cancel()
        reinjectLayoutWorkItem = nil
        youtubeEmbedFallbackURL = nil
        hasTriedYouTubeEmbedFallback = false
    }

    /// Builds the embed fallback URL if it couldn't be built earlier. The HTTP
    /// server usually isn't ready yet when loadVideo runs (port still 0), so
    /// callers that need the fallback URL retry here with the live port.
    private func refreshYouTubeEmbedFallbackURLIfNeeded() {
        guard currentSite == "youtube", youtubeEmbedFallbackURL == nil else { return }
        youtubeEmbedFallbackURL = buildYouTubeEmbedFallbackURL(
            pageURL: currentPageURL,
            currentTime: currentVideoTime,
            httpServerPort: httpServerPortProvider?() ?? 0
        )
    }

    private func shouldUseYouTubeFullPagePrimary() -> Bool {
        currentSite == "youtube"
            && loadingStrategy == .fullPageInject
            && youtubeEmbedFallbackURL != nil
    }

    /// Mirrors the Chrome tab's `yt-player-*` localStorage (caption stickiness,
    /// quality, playback rate, volume) into this fresh WKWebView session BEFORE
    /// YouTube's code boots, so the floating player starts with the same player
    /// settings the user had in the browser tab.
    private func installPlayerPrefsSeedScript() {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        guard currentSite == "youtube",
              let raw = playerPrefs?["localStorage"] as? [String: Any] else { return }
        let ls = raw.compactMapValues { $0 as? String }
        guard !ls.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: ls) else { return }
        let b64 = data.base64EncodedString()
        let source = """
        try {
            var d = JSON.parse(atob('\(b64)'));
            for (var k in d) { try { localStorage.setItem(k, d[k]); } catch (e) {} }
        } catch (e) {}
        """
        controller.addUserScript(WKUserScript(source: source,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true))
    }

    /// Runs in every frame before the player boots. JW's own skipAd() drops a
    /// VAST/IMA gambling spot without screen-recording permission. A separate
    /// 8–75s media file is the preroll itself, so it is played out immediately.
    private static let gamblingAdBypassJavaScript = #"""
    (function() {
        if (window.__floatGamblingBypass) return;
        window.__floatGamblingBypass = true;
        function arm(player) {
            if (!player || player.__floatAdArmed) return player;
            player.__floatAdArmed = true;
            if (typeof player.setup === 'function') {
                var setup = player.setup.bind(player);
                player.setup = function(config) {
                    if (config && config.advertising) config.advertising.skipoffset = 0;
                    return setup(config);
                };
            }
            function kick() {
                try { if (typeof player.skipAd === 'function') player.skipAd(); } catch (e) {}
            }
            ['adImpression', 'adPlay', 'adStarted', 'adTime', 'adBreakStart'].forEach(function(name) {
                try { player.on(name, kick); } catch (e) {}
            });
            return player;
        }
        window.__floatBypassGamblingAd = function() {
            var player = null;
            try { if (typeof window.jwplayer === 'function') player = arm(window.jwplayer()); } catch (e) {}
            var root = document.querySelector('.jwplayer, .jw-wrapper');
            var adMode = !!(root && root.classList && (root.classList.contains('jw-flag-ads') || root.classList.contains('jw-flag-ads-vpaid')));
            var adLayer = document.querySelector('.jw-ad, .jw-ad-container');
            if (adLayer && adLayer.getBoundingClientRect) {
                var box = adLayer.getBoundingClientRect();
                if (box.width > 20 && box.height > 12) adMode = true;
            }
            if (adMode && player && typeof player.skipAd === 'function') {
                try { player.skipAd(); } catch (e) {}
            }
            var video = document.querySelector('video');
            var label = '';
            try {
                var node = document.querySelector('.jwplayer') || document.body;
                label = ((node && (node.innerText || node.textContent)) || '').slice(0, 300).toLowerCase();
            } catch (e) {}
            if (video && label.indexOf('9922') >= 0 && isFinite(video.duration) && video.duration > 120) {
                var pos = video.currentTime || 0;
                if (window.__floatBrandOrigin == null || pos < window.__floatBrandOrigin - 2)
                    window.__floatBrandOrigin = pos;
                var stamp = Date.now();
                if (pos - window.__floatBrandOrigin < 150 && pos + 8 < video.duration &&
                    (!window.__floatBrandSeekAt || stamp - window.__floatBrandSeekAt > 700)) {
                    window.__floatBrandSeekAt = stamp;
                    try { video.currentTime = pos + 12; } catch (e) {}
                }
            }
            if (!video) return false;
            var duration = video.duration;
            if (!isFinite(duration) || duration < 8 || duration > 75) return adMode;
            if ((video.currentTime || 0) > duration - 1.25) return true;
            try { video.currentTime = duration - 0.3; } catch (e) { return false; }
            return true;
        };
    })();
    """#

    private func installGamblingAdBypassScript() {
        guard movieContext != nil, currentEmbedUrl != nil else { return }
        let source = Self.gamblingAdBypassJavaScript
        webView.configuration.userContentController.addUserScript(
            WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )
    }

    /// The movie provider can put its player in a cross-origin iframe. A script
    /// in the top page cannot reach that frame's Skip button, so WebKit installs
    /// this small, self-contained guard inside each frame at document end.
    private func installMovieEmbedAdScript() {
        guard movieContext != nil, currentEmbedUrl != nil else { return }
        let source = """
        \(Self.smartFillJavaScript)
        (function() {
            if (window.__floatVideoEmbedAdSkipInstalled) return;
            window.__floatVideoEmbedAdSkipInstalled = true;
            // VibeFloat owns the transport controls. Keep the provider's ad
            // overlays and captions, but remove its ordinary playback bar.
            var style = document.createElement('style');
            style.textContent =
                'video::-webkit-media-controls, video::-webkit-media-controls-enclosure, ' +
                'video::-webkit-media-controls-timeline { display: none !important; } ' +
                '.jwplayer .jw-controlbar, .jw-controlbar, .jw-slider-time, ' +
                '.vjs-control-bar, .vjs-progress-control, .plyr__controls, .plyr__progress, ' +
                '.dplayer-controller, .dplayer-bar-wrap, .art-controls, .art-progress, ' +
                '.xgplayer-controls, .xgplayer-progress, #resumeModal, .rz-card, #loading ' +
                '{ display: none !important; visibility: hidden !important; height: 0 !important; ' +
                'pointer-events: none !important; }';
            (document.head || document.documentElement).appendChild(style);
            function hideForeignTransport() {
                if (!document.querySelectorAll) return;
                var bars = document.querySelectorAll(
                    '.jw-controlbar, .jw-slider-time, .vjs-control-bar, .vjs-progress-control, ' +
                    '.plyr__controls, .plyr__progress, .dplayer-controller, .dplayer-bar-wrap, ' +
                    '.art-controls, .art-progress, .xgplayer-controls, .xgplayer-progress'
                );
                for (var i = 0; i < bars.length; i++) {
                    bars[i].style.setProperty('display', 'none', 'important');
                    bars[i].style.setProperty('visibility', 'hidden', 'important');
                    bars[i].style.setProperty('pointer-events', 'none', 'important');
                }
            }
            // The real player may be created after documentEnd or replaced at
            // the next episode. Keep discovering it in every frame.
            function publishContentClock() {
                var video = document.querySelector('video');
                var root = document.querySelector('.jwplayer');
                var ad = !!(root && root.classList && (
                    root.classList.contains('jw-flag-ads') ||
                    root.classList.contains('jw-flag-ads-vpaid')));
                var jw = null;
                try { if (typeof window.jwplayer === 'function') jw = window.jwplayer(); } catch (e) {}
                var contentDur = 0;
                try {
                    var item = jw && jw.getPlaylistItem && jw.getPlaylistItem();
                    if (item && isFinite(item.duration) && item.duration > 90) contentDur = item.duration;
                } catch (e) {}
                if (!(contentDur > 90)) {
                    try {
                        var reported = jw && jw.getDuration && jw.getDuration();
                        if (!ad && isFinite(reported) && reported > 90) contentDur = reported;
                    } catch (e) {}
                }
                var mediaDur = video && isFinite(video.duration) ? video.duration : 0;
                var position = video ? (video.currentTime || 0) : 0;
                if (!ad && contentDur > 90) {
                    try {
                        if (jw && typeof jw.getPosition === 'function') position = jw.getPosition() || position;
                    } catch (e) {}
                    window.__floatContentTime = position;
                    window.__floatContentDur = Math.max(contentDur, mediaDur);
                } else if (!ad && mediaDur > 90) {
                    window.__floatContentTime = position;
                    window.__floatContentDur = mediaDur;
                } else if (contentDur > 90) {
                    window.__floatContentDur = contentDur;
                }
                var paused = video ? !!video.paused : true;
                try {
                    var state = jw && jw.getState && jw.getState();
                    if (state === 'playing' || state === 'buffering') paused = false;
                } catch (e) {}
                var clock = {
                    __floatClock: true,
                    ad: ad,
                    ct: ad ? (window.__floatContentTime || 0) : position,
                    dur: Math.max(window.__floatContentDur || 0, ad ? 0 : mediaDur, contentDur || 0),
                    paused: paused
                };
                window.__floatClock = clock;
                try { if (window.parent && window.parent !== window) window.parent.postMessage(clock, '*'); } catch (e) {}
            }
            window.addEventListener('message', function(event) {
                if (!event.data || event.data.__floatClock !== true) return;
                window.__floatClock = event.data;
            });
            setInterval(function() {
                hideForeignTransport();
                publishContentClock();
                var video = document.querySelector('video');
                if (video) {
                    video.controls = false;
                    video.removeAttribute('controls');
                    if (!video.__floatControlsObserver) {
                        video.__floatControlsObserver = new MutationObserver(function() {
                            if (video.controls) {
                                video.controls = false;
                                video.removeAttribute('controls');
                            }
                        });
                        video.__floatControlsObserver.observe(video, {
                            attributes: true, attributeFilter: ['controls']
                        });
                    }
                    window.__floatInstallSmartFill(video);
                    window.__floatInstallAdBlur(video);
                }
            }, 1000);
            function findSkipButton() {
                var button = document.querySelector(
                    '.jw-skip, .jw-ad-skip, .jw-skip-ad, .skip-ad, .video-ad-skip, .vjs-ad-skip-button,' +
                    'button[aria-label*="Skip Ad" i], button[title*="Skip Ad" i], ' +
                    'button[aria-label*="Bỏ qua" i], button[title*="Bỏ qua" i]'
                );
                if (button) return button;
                if (!document.querySelectorAll) return null;
                var nodes = document.querySelectorAll('button, [role="button"]');
                for (var i = 0; i < nodes.length; i++) {
                    var label = ((nodes[i].innerText || '') + ' ' +
                        (nodes[i].getAttribute('aria-label') || '')).toLowerCase();
                    if (label.indexOf('bỏ qua') >= 0 || label.indexOf('skip ad') >= 0 ||
                        label.replace(/\\s+/g, ' ').trim() === 'skip') return nodes[i];
                }
                return null;
            }
            function activateSkipButton(button) {
                var rect = button.getBoundingClientRect();
                if (rect.width && rect.height && window.webkit && window.webkit.messageHandlers &&
                    window.webkit.messageHandlers.adSkip) {
                    try {
                        window.webkit.messageHandlers.adSkip.postMessage({
                            x: rect.left + rect.width / 2,
                            y: rect.top + rect.height / 2
                        });
                    } catch (e) {}
                }
                try { button.click(); } catch (e) {}
            }
            \(Self.gamblingAdBypassJavaScript)
            \(Self.bannerBlurJavaScript)
            \(Self.audioBoostJavaScript)
            // Re-applied per load: the page may not have its <video> yet, and
            // the in-page `playing` listener retries once it does.
            window.__floatSetAudioBoost(\(Self.preferredAudioBoost.factor));
            \(Self.adAudioTapJavaScript)
            \(Self.aiDubbingJavaScript)
            var lastClick = 0;
            setInterval(function() {
                if (window.__floatBypassGamblingAd) window.__floatBypassGamblingAd();
                var rzModal = document.getElementById('resumeModal');
                if (rzModal) {
                    var rzBtn = rzModal.querySelector('.rz-go');
                    if (rzBtn) { try { rzBtn.click(); } catch (e) {} }
                    rzModal.style.setProperty('display', 'none', 'important');
                }
                var button = findSkipButton();
                if (!button || button.disabled || button.getAttribute('aria-disabled') === 'true') return;
                var rect = button.getBoundingClientRect();
                if (!rect.width || !rect.height) return;
                var now = Date.now();
                if (now - lastClick < 500) return;
                lastClick = now;
                activateSkipButton(button);
            }, 250);

            // The native screenshot sees cross-origin frames, but evaluateJavaScript
            // runs in the main frame. Relay each bounded seek to child players.
            var lastAdSeek = 0;
            var adSeekOrigin = null;
            function seekAdStep() {
                var video = document.querySelector('video');
                var jw = null;
                try { if (window.jwplayer) jw = window.jwplayer(); } catch (e) {}
                if (!video && !jw) return false;
                var duration = video ? video.duration : NaN;
                if ((!isFinite(duration) || duration < 30) && video) {
                    try {
                        if (video.seekable && video.seekable.length)
                            duration = video.seekable.end(video.seekable.length - 1);
                    } catch (e) {}
                }
                if ((!isFinite(duration) || duration < 30) && jw) {
                    try { duration = jw.getDuration(); } catch (e) {}
                }
                var position = video ? video.currentTime : NaN;
                if (!isFinite(position) && jw) {
                    try { position = jw.getPosition(); } catch (e) {}
                }
                if (!isFinite(position)) return false;
                // HLS ads often report an infinite duration and an empty seekable
                // range. Step forward anyway; the 90-second cap still applies.
                if (!isFinite(duration) || duration < 30) duration = position + 120;
                var now = Date.now();
                if (now - lastAdSeek < 450 || position + 2 >= duration) return false;
                if (now - lastAdSeek > 3000 || adSeekOrigin === null || position < adSeekOrigin - 2)
                    adSeekOrigin = position;
                // Opening spots run longer than a mid-roll. Later in the episode
                // the cap stays short so a false match cannot eat the story.
                var budget = adSeekOrigin < 25 ? 150 : 90;
                if (position - adSeekOrigin >= budget) return false;
                lastAdSeek = now;
                var next = Math.min(position + 10, duration - 1.5);
                try {
                    var wasPaused = video && video.paused;
                    if (video) video.currentTime = next;
                    else jw.seek(next);
                    if (video && !wasPaused) video.play().catch(function() {});
                    return true;
                } catch (e) {
                    try { if (jw) { jw.seek(next); return true; } } catch (ignored) {}
                    return false;
                }
            }
            function relayAdSeek() {
                var frames = document.querySelectorAll('iframe');
                var sent = false;
                for (var i = 0; i < frames.length; i++) {
                    try {
                        frames[i].contentWindow.postMessage({ __floatVideoAdSeek: true }, '*');
                        sent = true;
                    }
                    catch (e) {}
                }
                return sent;
            }
            window.__floatSkipEmbedAd = function() {
                var viaApi = false;
                try {
                    var jw = window.jwplayer && window.jwplayer();
                    if (jw && typeof jw.skipAd === 'function') { jw.skipAd(); viaApi = true; }
                } catch (e) {}
                if (window.__floatBypassGamblingAd) window.__floatBypassGamblingAd();
                var skipped = seekAdStep();
                return relayAdSeek() || skipped || viaApi;
            };
            window.addEventListener('message', function(event) {
                if (!event.data || event.data.__floatVideoAdSeek !== true) return;
                if (event.source !== window.parent) return;
                seekAdStep();
                relayAdSeek();
            });
        })();
        """
        webView.configuration.userContentController.addUserScript(
            WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
        )
    }

    /// Re-applies the exact per-video player state captured from the Chrome tab
    /// at float time: the active caption track (including auto-translate target
    /// language) and the playback rate. Retries until YouTube's player + caption
    /// module are ready; the localStorage seed above already covers the sticky
    /// defaults, this covers the current video's explicit selection.
    private func scheduleApplyPlayerPrefs() {
        guard currentSite == "youtube", loadingStrategy == .fullPageInject,
              playerPrefs != nil else { return }
        // Deadline, not a retry count: a pre-roll ad (or a re-serve loop) can
        // occupy the player for tens of seconds, during which the caption
        // tracklist is the AD's (empty) one. Attempts during ads don't count.
        prefsApplyDeadline = Date().addingTimeInterval(60)
        attemptApplyPlayerPrefs(after: 2.0)
    }

    private func attemptApplyPlayerPrefs(after delay: TimeInterval) {
        guard let deadline = prefsApplyDeadline else { return }
        guard Date() < deadline else {
            NSLog("[FloatVideo] Player prefs give-up after 60s (last status: \(lastPrefsStatus))")
            prefsApplyDeadline = nil
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            var trackB64 = ""
            if let track = self.playerPrefs?["captionTrack"] as? [String: Any],
               let data = try? JSONSerialization.data(withJSONObject: track) {
                trackB64 = data.base64EncodedString()
            }
            let rate = (self.playerPrefs?["playbackRate"] as? NSNumber)?.doubleValue ?? 1.0
            let js = """
            (function() {
                if (window.__floatVideoPrefsApplied) return 'done';
                var p = document.getElementById('movie_player') || document.querySelector('.html5-video-player');
                if (!p) return 'retry';
                // While an ad plays, the player exposes the ad's (empty)
                // tracklist — applying now would misfire. Report distinctly so
                // the native side keeps waiting without burning the deadline.
                if (p.classList.contains('ad-showing') || p.classList.contains('ad-interrupting')) {
                    return 'ad';
                }
                var rate = \(rate);
                if (rate > 0 && rate !== 1 && typeof p.setPlaybackRate === 'function') {
                    try { p.setPlaybackRate(rate); } catch (e) {}
                }
                var trackB64 = '\(trackB64)';
                if (!trackB64) { window.__floatVideoPrefsApplied = true; return 'applied'; }
                if (typeof p.setOption !== 'function' || typeof p.getOption !== 'function') return 'retry';
                // The captions module may be unloaded when CC starts off.
                try { if (typeof p.loadModule === 'function') p.loadModule('captions'); } catch (e) {}
                var list = null;
                try { list = p.getOption('captions', 'tracklist'); } catch (e) { return 'retry'; }
                if (!list || !list.length) return 'retry';
                try {
                    var track = JSON.parse(atob(trackB64));
                    p.setOption('captions', 'track', track);
                    // Verify it took — setOption silently no-ops while the
                    // module is mid-initialization.
                    var cur = p.getOption('captions', 'track');
                    if (!cur || !cur.languageCode) return 'retry';
                    window.__floatVideoPrefsApplied = true;
                    return 'applied';
                } catch (e) { return 'retry'; }
            })();
            """
            self.webView.evaluateJavaScript(js) { [weak self] result, _ in
                guard let self = self else { return }
                let status = result as? String ?? "retry"
                self.lastPrefsStatus = status
                switch status {
                case "applied":
                    NSLog("[FloatVideo] Player prefs applied (captions/rate)")
                    self.prefsApplyDeadline = nil
                case "ad":
                    // Ad occupying the player: extend patience past the ad
                    // without counting against the deadline meaningfully.
                    self.prefsApplyDeadline = max(self.prefsApplyDeadline ?? Date(),
                                                  Date().addingTimeInterval(30))
                    self.attemptApplyPlayerPrefs(after: 1.5)
                case "retry":
                    self.attemptApplyPlayerPrefs(after: 1.5)
                default:
                    self.prefsApplyDeadline = nil // 'done' or unexpected
                }
            }
        }
    }

    private func scheduleInjectedLayoutRefresh(after delay: TimeInterval = 0.05) {
        guard hasInjectedJS, loadingStrategy == .fullPageInject else { return }
        reinjectLayoutWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.refreshInjectedLayout()
        }
        reinjectLayoutWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func refreshInjectedLayout() {
        guard hasInjectedJS, loadingStrategy == .fullPageInject else { return }
        let js = "if (window.__floatVideoApplyLayout) { window.__floatVideoApplyLayout(); true } else { false }"
        webView.evaluateJavaScript(js) { [weak self] result, error in
            if let error = error {
                NSLog("[FloatVideo] Layout refresh JS error: \(error)")
                return
            }
            if let ok = result as? Bool, !ok {
                self?.injectVideoMaximize(site: self?.currentSite ?? "generic",
                                          currentTime: self?.currentVideoTime ?? 0)
            }
        }
    }

    private func scheduleYouTubeEmbedFallbackCheck(after delay: TimeInterval) {
        guard shouldUseYouTubeFullPagePrimary() else { return }
        youtubeFallbackWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self,
                  self.shouldUseYouTubeFullPagePrimary(),
                  !self.hasInjectedJS else { return }
            _ = self.startYouTubeEmbedFallback(reason: "inject-timeout")
        }
        youtubeFallbackWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    @discardableResult
    private func startYouTubeEmbedFallback(reason: String) -> Bool {
        guard !hasTriedYouTubeEmbedFallback,
              let fallbackURL = youtubeEmbedFallbackURL else {
            return false
        }

        hasTriedYouTubeEmbedFallback = true
        youtubeFallbackWorkItem?.cancel()
        youtubeFallbackWorkItem = nil
        loadingStrategy = .youtubeEmbed
        hasInjectedJS = false
        webView.load(URLRequest(url: fallbackURL))
        NSLog("[FloatVideo] Switching YouTube to embed fallback (\(reason)), host: \(Self.loggableURL(fallbackURL.absoluteString))")
        return true
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // The ad guard only needs the document; installing it here lets its
        // interval see a pre-roll before the full watch page finishes loading.
        // didFinish retries if WebKit was not ready to evaluate JavaScript yet.
        if currentSite == "youtube", loadingStrategy == .fullPageInject {
            injectAdSkip()
        }
    }

    /// Navigation policy. Escaping (Phase 2) stops a crafted payload from
    /// *executing* inside the player page; this stops it from *leaving*: with
    /// both in place a script that somehow ran cannot pivot the window onto an
    /// origin of its choosing.
    ///
    /// Every remote document, including iframes, is restricted to movie
    /// providers. Media subresources can still load from the provider's CDNs.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        let scheme = url.scheme?.lowercased() ?? ""

        // Our inline player pages report about:blank, and the loopback player
        // server is generated by us. Both are trusted by construction.
        if scheme == "about" {
            decisionHandler(.allow)
            return
        }
        if let host = url.host?.lowercased(), Self.plainHTTPHosts.contains(host) {
            decisionHandler(.allow)
            return
        }

        // YouTube is an exception only for the curated movie's embed. No watch
        // page, search, channel, or unrelated video may become a document.
        if currentSite == "youtube", preferYouTubeEmbed,
           let movieID = Self.curatedYouTubeMovieID(currentPageURL) {
            if url.path.hasPrefix("/embed/"), Self.curatedYouTubeMovieID(url.absoluteString) == movieID {
                decisionHandler(.allow)
                return
            }
            // WebKit can normalize the synthetic document's trailing slash
            // away. Both root forms identify our inline player, never a web page.
            if navigationAction.targetFrame?.isMainFrame == true,
               scheme == "https", url.host == "com.aspect.floatvideo",
               ["", "/"].contains(url.path), url.user == nil, url.password == nil,
               url.port == nil, url.query == nil, url.fragment == nil {
                decisionHandler(.allow)
                return
            }
        }

        if Self.forbiddenSchemes.contains(scheme) {
            NSLog("[FloatVideo] Blocked navigation with scheme '\(scheme)' host: \(Self.loggableURL(url.absoluteString))")
            decisionHandler(.cancel)
            return
        }

        // No target frame means a new window/tab request. The window itself is
        // never created (createWebViewWith returns nil), so cancel the load too
        // rather than let a "blank" popup navigate elsewhere.
        guard navigationAction.targetFrame != nil else {
            NSLog("[FloatVideo] Blocked popup navigation host: \(Self.loggableURL(url.absoluteString))")
            decisionHandler(.cancel)
            return
        }

        // Apply the document allowlist to iframe navigations too: injected
        // player scripts must never inspect unrelated third-party pages.

        guard scheme == "https", let host = url.host,
              Self.hostMatches(host, anyOf: Self.allowedTopLevelDomains) else {
            NSLog("[FloatVideo] Blocked top-level navigation outside allowlist, host: \(Self.loggableURL(url.absoluteString))")
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        NSLog("[FloatVideo] Page loaded (strategy: \(loadingStrategy), site: \(currentSite)), webView: \(webView.frame), container: \(self.contentView?.frame ?? .zero)")

        // Sync the native preference after every navigation; setAIDubEnabled
        // may have run before this document existed.
        let dubState = isAIDubEnabled ? "true" : "false"
        webView.evaluateJavaScript("if (window.__floatToggleAIDub) { window.__floatToggleAIDub(\(dubState)); }", completionHandler: nil)
        if isOfflineDubEnabled {
            // The native message can arrive before the first document exists.
            // Re-apply the offline pause/request after navigation so the video
            // cannot start and the newly installed timeline script is queried.
            forcePauseForOfflineDubbing()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self, self.isOfflineDubEnabled else { return }
                if self.offlineDubTimelineSignature == nil && self.offlineDubOCR == nil {
                    self.updateOfflineDubProgress("Offline Dub • Đang lấy timeline phụ đề…",
                                                  indeterminate: true, active: true)
                }
                self.webView?.evaluateJavaScript("if (window.__floatRequestOfflineTimeline) { window.__floatRequestOfflineTimeline(); }", completionHandler: nil)
                self.requestOfflineTimelineFromWebView(after: 0.45)
            }
        }

        if loadingStrategy == .fullPageInject {
            // Full page load + JS inject: delay removing overlay after injection to let DOM operations complete
            guard !hasInjectedJS else { return }
            refreshYouTubeEmbedFallbackURLIfNeeded()
            injectVideoMaximize(site: currentSite, currentTime: currentVideoTime)
            // Auto-skip YouTube ads. Idempotent in-page guard (installs a single
            // interval); safe to call alongside the injection retries below.
            // Deliberately NOT gated on shouldUseYouTubeFullPagePrimary(): the
            // guard has no dependency on the embed fallback URL.
            if currentSite == "youtube" {
                injectAdSkip()
                scheduleApplyPlayerPrefs()
            }
            for delay in [1.5, 3.0, 5.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self = self, !self.hasInjectedJS else { return }
                    self.injectVideoMaximize(site: self.currentSite,
                                             currentTime: self.currentVideoTime)
                }
            }
            if shouldUseYouTubeFullPagePrimary() {
                scheduleYouTubeEmbedFallbackCheck(after: 5.5)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self = self, self.loadingStrategy == .fullPageInject else { return }
                    self.hideLoadingOverlay()
                }
            }
        } else if loadingStrategy == .siteEmbed {
            // Site embed: inject player automation, auto-play triggers, and hide overlay
            injectEmbedPlayerAutomation()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.hideLoadingOverlay()
            }
        } else {
            // Other strategies (direct video, YouTube embed) have built-in autoplay, remove overlay directly
            hideLoadingOverlay()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        NSLog("[FloatVideo] Page load failed: \(error)")
        refreshYouTubeEmbedFallbackURLIfNeeded()
        if shouldUseYouTubeFullPagePrimary() && startYouTubeEmbedFallback(reason: "didFail") {
            return
        }
        if loadingStrategy == .siteEmbed, !hasTriedIframeEmbedFallback,
           let embedUrl = currentEmbedUrl, let safeEmbed = Self.validateMediaURL(embedUrl) {
            hasTriedIframeEmbedFallback = true
            let html = buildEmbedHTML(embedUrl: safeEmbed.absoluteString)
            webView.loadHTMLString(html, baseURL: nil)
            NSLog("[FloatVideo] Direct embed failed, falling back to iframe embed host: \(Self.loggableURL(safeEmbed.absoluteString))")
            return
        }
        showNavigationError(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        NSLog("[FloatVideo] Provisional page load failed: \(error)")
        refreshYouTubeEmbedFallbackURLIfNeeded()
        if shouldUseYouTubeFullPagePrimary() && startYouTubeEmbedFallback(reason: "didFailProvisional") {
            return
        }
        if loadingStrategy == .siteEmbed, !hasTriedIframeEmbedFallback,
           let embedUrl = currentEmbedUrl, let safeEmbed = Self.validateMediaURL(embedUrl) {
            hasTriedIframeEmbedFallback = true
            let html = buildEmbedHTML(embedUrl: safeEmbed.absoluteString)
            webView.loadHTMLString(html, baseURL: nil)
            NSLog("[FloatVideo] Direct embed provisional failed, falling back to iframe embed host: \(Self.loggableURL(safeEmbed.absoluteString))")
            return
        }
        showNavigationError(error)
    }

    private func showNavigationError(_ error: Error) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        let overlay: LoadingOverlayView
        if let existing = loadingOverlay as? LoadingOverlayView {
            overlay = existing
        } else {
            overlay = LoadingOverlayView(frame: webView.frame)
            overlay.wantsLayer = true
            overlay.layer?.backgroundColor = NSColor.black.cgColor
            overlay.autoresizingMask = [.width, .height]
            contentView?.addSubview(overlay, positioned: .above, relativeTo: webView)
            loadingOverlay = overlay
        }
        overlay.alphaValue = 1
        overlay.retryAction = { [weak self] in _ = self?.webView.reload() }
        overlay.showError()
    }

    /// Direct m3u8/mp4 failed (expired token, 403). The embed page is the
    /// same episode and is what the catalog stored alongside the stream.
    private func fallbackToEmbedIfDirectFailed() {
        guard loadingStrategy == .directVideo,
              !hasTriedDirectEmbedFallback,
              let embed = currentEmbedUrl, !embed.isEmpty else { return }
        guard let targetURL = Self.validateMediaURL(embed) else {
            NSLog("[FloatVideo] Refused direct-embed fallback outside the allowlist: \(embed)")
            return
        }
        hasTriedDirectEmbedFallback = true
        loadingStrategy = .siteEmbed
        hasTriedIframeEmbedFallback = false
        suppressWatchAssist = true
        var request = URLRequest(url: targetURL)
        if embed.contains("streamc.xyz") || embed.contains("nguonc.com") {
            request.setValue("https://phim.nguonc.com/", forHTTPHeaderField: "Referer")
        } else if !currentPageURL.isEmpty {
            request.setValue(currentPageURL, forHTTPHeaderField: "Referer")
        }
        NSLog("[FloatVideo] Direct stream failed, falling back to embed: \(embed)")
        showHUD("Đang đổi nguồn phát")
        webView.load(request)
    }

    /// Shared by our direct player, full-page movie player, and movie iframes.
    /// Detects bars encoded in the video pixels; CSS object-fit alone cannot
    /// remove those. Reading pixels can fail for cross-origin protected media.
    private static let smartFillJavaScript = #"""
    (function() {
        if (window.__floatInstallSmartFill) return;
        var state = null;
        var canvas = document.createElement('canvas');
        canvas.width = 96;
        canvas.height = 72;
        var context = canvas.getContext('2d', { willReadFrequently: true });

        function paint(video, top, bottom) {
            var width = video.clientWidth || window.innerWidth;
            var height = video.clientHeight || window.innerHeight;
            if (!width || !height || !video.videoWidth || !video.videoHeight) return;
            var drawnHeight = Math.min(height, width * video.videoHeight / video.videoWidth);
            var contentHeight = drawnHeight * (bottom - top);
            if (contentHeight <= 0) return;
            var scale = height / contentHeight;
            var contentCenter = (height - drawnHeight) / 2 + drawnHeight * (top + bottom) / 2;
            var shift = scale * (height / 2 - contentCenter) / height * 100;
            video.style.setProperty('object-fit', 'contain', 'important');
            video.style.setProperty('object-position', 'center center', 'important');
            video.style.setProperty('transform-origin', 'center center', 'important');
            video.style.setProperty('transform',
                'translateY(' + shift.toFixed(3) + '%) scale(' + scale.toFixed(4) + ')', 'important');
            window.__floatContentTop = top;
        }

        function reset(video) {
            if (!state || state.video !== video) return;
            state.top = null;
            state.bottom = null;
            state.candidateTop = null;
            state.candidateBottom = null;
            state.hits = 0;
            state.source = video.currentSrc || '';
            state.width = video.videoWidth;
            state.height = video.videoHeight;
            video.style.setProperty('transform', 'none', 'important');
            window.__floatContentTop = 0;
        }

        function sample() {
            if (!state || !state.video.isConnected || state.video.paused || state.video.readyState < 2) return;
            var video = state.video;
            if (state.source !== (video.currentSrc || '') ||
                state.width !== video.videoWidth || state.height !== video.videoHeight) reset(video);
            try {
                context.drawImage(video, 0, 0, 96, 72);
                var pixels = context.getImageData(0, 0, 96, 72).data;
                video.__floatCanvasReadable = true;
            } catch (error) {
                // A tainted canvas stays tainted. The native snapshot crop
                // takes over until a later episode can be read directly.
                video.__floatCanvasReadable = false;
                canvas = document.createElement('canvas');
                canvas.width = 96;
                canvas.height = 72;
                context = canvas.getContext('2d', { willReadFrequently: true });
                return;
            }
            // Ratio of near-black pixels in the row. A sponsor line or channel
            // logo is burned into the middle of the black bar, so demanding a
            // fully dark row let one text line stop the scan early (top never
            // reached 3 rows) and the bars were left uncropped. A row still
            // counts as bar when the *majority* of it is black, which survives
            // the burned-in ink while a real picture row stays well under half.
            function darkRatio(y) {
                var darkPixels = 0;
                for (var x = 8; x < 88; x++) {
                    var i = (y * 96 + x) * 4;
                    var light = pixels[i] * 0.2126 + pixels[i + 1] * 0.7152 + pixels[i + 2] * 0.0722;
                    if (light < 22) darkPixels++;
                }
                return darkPixels / 80;
            }
            function barRow(y) { return darkRatio(y) >= 0.5; }
            function barRun(start) {
                var y = start;
                while (y < 18 && barRow(y)) y++;
                return y;
            }
            function barRunUp(start) {
                var y = start;
                while (y > 53 && barRow(y)) y--;
                return y;
            }
            // One bright row at the very edge (a window or video border) must not
            // stop the scan before it starts, so the thickest bar run within the
            // first few rows wins. Measured on the reported frame: the old scan
            // died on row 0 there and the bars were never cropped.
            var top = 0;
            for (var lead = 0; lead < 3; lead++) {
                var leadEnd = barRun(lead);
                if (leadEnd - lead >= 3 && leadEnd > top) top = leadEnd;
            }
            var bottom = 71;
            for (var trail = 0; trail < 3; trail++) {
                var trailEnd = barRunUp(71 - trail);
                if ((71 - trail) - trailEnd >= 3 && trailEnd < bottom) bottom = trailEnd;
            }
            var upper = top / 72;
            var lower = (bottom + 1) / 72;
            // A bar on *either* edge counts, not both. Measured on the reported
            // stream: the top band was there and picture ran to the last row, so
            // the old two-sided test never fired and the bar was left on screen.
            // The picture still has to sit roughly centred — that is what keeps a
            // dark scene or a fade-to-black frame from being zoomed.
            var picture = !barRow(28) || !barRow(36) || !barRow(44);
            if (!picture) return;
            var centred = Math.abs((upper + lower) / 2 - 0.5) <= 0.12;
            var hasBars = (top >= 3 || bottom <= 68) && centred && lower - upper >= 0.55;
            var candidate = hasBars ? [upper, lower] : [0, 1];
            var sameBand = state.candidateTop !== null &&
                Math.abs(state.candidateTop - candidate[0]) <= 2 / 72 &&
                Math.abs(state.candidateBottom - candidate[1]) <= 2 / 72;
            state.hits = sameBand ? state.hits + 1 : 1;
            if (!sameBand) {
                state.candidateTop = candidate[0];
                state.candidateBottom = candidate[1];
            }
            if (state.hits < 3) return;
            if (state.top !== null &&
                Math.abs(state.top - state.candidateTop) <= 1 / 72 &&
                Math.abs(state.bottom - state.candidateBottom) <= 1 / 72) {
                paint(video, state.top, state.bottom);
                return;
            }
            state.top = state.candidateTop;
            state.bottom = state.candidateBottom;
            paint(video, state.top, state.bottom);
        }

        window.__floatInstallSmartFill = function(video) {
            if (!video || !video.videoWidth) return;
            if (state && state.video === video) {
                if (state.source !== (video.currentSrc || '') ||
                    state.width !== video.videoWidth || state.height !== video.videoHeight) reset(video);
                if (state.top !== null) paint(video, state.top, state.bottom);
                return;
            }
            if (state && state.timer) clearInterval(state.timer);
            state = { video: video, top: null, bottom: null,
                candidateTop: null, candidateBottom: null, hits: 0, timer: null,
                source: video.currentSrc || '', width: video.videoWidth, height: video.videoHeight };
            state.timer = setInterval(sample, 800);
            video.addEventListener('loadeddata', function() { reset(video); sample(); });
            video.addEventListener('seeked', sample);
            video.addEventListener('playing', sample);
            sample();
        };
        window.__floatPaintLetterbox = function(video, top, bottom) {
            paint(video, top, bottom);
        };
        // Used when the provider frame cannot be read (cross-origin media).
        // The parent page crops its iframe; a same-document player crops the video.
        window.__floatApplyHostLetterbox = function(top, bottom) {
            var span = bottom - top;
            if (!(span >= 0.5 && span <= 1.001)) return false;
            var video = document.querySelector('video');
            if (video && video.videoWidth) {
                // The pixel scanner already owns a readable video. Applying the
                // snapshot crop as well clears and redraws the same frame.
                if (video.__floatCanvasReadable !== false) return false;
                paint(video, top, bottom);
                return true;
            }
            var frame = document.querySelector('iframe');
            if (!frame) return false;
            frame.style.position = 'fixed';
            frame.style.left = '0';
            frame.style.width = '100vw';
            if (span > 0.985) {
                frame.style.top = '0px';
                frame.style.height = '100vh';
                return true;
            }
            var scale = 1 / span;
            frame.style.height = (scale * 100).toFixed(3) + 'vh';
            frame.style.top = (-top * scale * 100).toFixed(3) + 'vh';
            return true;
        };
    })();
    """#

    /// Blurs the sponsor line pirate streams burn across the top of the
    /// picture (the `9922.com` banner). It is part of the source pixels, so no
    /// amount of skipping removes it — cropping only removes it when it happens
    /// to sit inside the letterbox bar. The overlay is painted above the video
    /// and blurs whatever is behind it, and it is installed by every strategy
    /// (direct file, embed frame, full page) so the banner is covered wherever
    /// the provider puts it.
    ///
    /// The video itself is pinned at `z-index: 2147483647` by the full-page
    /// layout, so the overlay uses the same value and wins the tie by being the
    /// later node — hence the re-append when the page inserts anything after it.
    private static let bannerBlurJavaScript = #"""
    (function() {
        if (window.__floatInstallAdBlur) return;
        var state = { video: null, timer: null, hits: 0, misses: 0, visible: false,
                      forced: null, forcedUntil: 0 };
        var canvas = null;
        // Only the top band needs to cover a burned-in sponsor line; a detected
        // splash covers the whole frame so the spot is never readable.
        var BAND = { height: 'calc(38px + 16%)', background: 'rgba(0, 0, 0, 0.42)',
                     filter: 'blur(28px) saturate(0.75)',
                     mask: 'linear-gradient(to bottom, #000 82%, transparent)' };
        var FULL = { height: '100%', background: 'rgba(0, 0, 0, 0.5)',
                     filter: 'blur(32px) saturate(0.6)', mask: 'none' };

        function overlay() {
            var el = document.getElementById('float-ad-blur');
            if (!el) {
                el = document.createElement('div');
                el.id = 'float-ad-blur';
                el.setAttribute('aria-hidden', 'true');
                var style = el.style;
                style.position = 'fixed';
                style.left = '0';
                style.right = '0';
                style.top = '0';
                style.pointerEvents = 'none';
                style.opacity = '0';
                style.transition = 'opacity 0.18s linear';
                style.zIndex = '2147483647';
                style.transform = 'translateZ(1px)';
                style.willChange = 'opacity, backdrop-filter';
            }
            var body = document.body;
            if (!body) return el;
            if (el.parentNode !== body || body.lastElementChild !== el) {
                body.appendChild(el);
            }
            return el;
        }

        function styleOverlay(el, mode) {
            var spec = mode === 'full' ? FULL : BAND;
            el.style.height = spec.height;
            el.style.background = spec.background;
            el.style.webkitBackdropFilter = spec.filter;
            el.style.backdropFilter = spec.filter;
            el.style.webkitMaskImage = spec.mask;
            el.style.maskImage = spec.mask;
            el.style.opacity = mode === 'off' ? '0' : '1';
        }

        // White, outlined type running the whole width is the signature of the
        // gambling line. It must be dense in all three horizontal thirds, so a
        // centred title card or a lone subtitle does not trigger the blur.
        function looksLikeBanner(video) {
            if (!video || !video.videoWidth || video.readyState < 2) return false;
            var sw = 180, sh = 32;
            if (!canvas) {
                canvas = document.createElement('canvas');
                canvas.width = sw;
                canvas.height = sh;
            }
            var ctx = canvas.getContext('2d', { willReadFrequently: true });
            if (!ctx) return false;
            // When smart fill already cropped the bar away the banner starts at
            // the top of the picture, which `__floatContentTop` tracks.
            var topFrac = window.__floatContentTop || 0;
            var y0 = Math.min(video.videoHeight - 8, Math.round(video.videoHeight * topFrac));
            var srcH = Math.max(8, Math.round(video.videoHeight * 0.12));
            var data;
            try {
                ctx.drawImage(video, 0, y0, video.videoWidth, srcH, 0, 0, sw, sh);
                data = ctx.getImageData(0, 0, sw, sh).data;
            } catch (e) {
                return false;
            }
            var textRows = 0;
            for (var y = 1; y < sh - 1; y++) {
                var edges = [0, 0, 0];
                var bright = 0;
                var prev = 0;
                for (var x = 1; x < sw; x++) {
                    var i = (y * sw + x) * 4;
                    var luma = data[i] * 0.2126 + data[i + 1] * 0.7152 + data[i + 2] * 0.0722;
                    var j = ((y - 1) * sw + x) * 4;
                    var up = data[j] * 0.2126 + data[j + 1] * 0.7152 + data[j + 2] * 0.0722;
                    if (Math.abs(luma - prev) > 48) edges[x < sw / 3 ? 0 : (x < (sw * 2) / 3 ? 1 : 2)]++;
                    if (luma > 195 && up < 90) bright++;
                    prev = luma;
                }
                if (edges[0] > 4 && edges[1] > 4 && edges[2] > 4 && bright > 6) textRows++;
            }
            return textRows >= 3;
        }

        window.__floatInstallAdBlur = function(video) {
            var target = video || window.__floatVideoMainVideo || document.querySelector('video');
            if (!target) return;
            state.video = target;
            styleOverlay(overlay(), state.forced || 'off');
            if (state.timer) return;
            state.timer = setInterval(function() {
                var el = overlay();
                var mode = 'off';
                if (state.forced && Date.now() <= state.forcedUntil) {
                    mode = state.forced;
                } else {
                    state.forced = null;
                    var v = state.video;
                    if (v && v.isConnected && !v.paused && v.readyState >= 2) {
                        if (looksLikeBanner(v)) {
                            state.hits++;
                            state.misses = 0;
                        } else {
                            state.misses++;
                            state.hits = 0;
                        }
                        // Hysteresis: the banner is continuous, so the fade in
                        // must be quicker than the fade out or it would flicker.
                        if (!state.visible && state.hits >= 2) state.visible = true;
                        else if (state.visible && state.misses >= 4) state.visible = false;
                        if (state.visible) mode = 'band';
                    }
                }
                styleOverlay(el, mode);
            }, 450);
        };

        // Native owns the decision when the ad is drawn by the page (or served
        // from a cross-origin frame) rather than being part of the video's own
        // pixels, which is the only thing `looksLikeBanner` can read. Native
        // re-asserts this on every scan; the deadline is the safety net that
        // lifts the cover if the scans stop mid-ad.
        window.__floatForceAdCover = function(on, full, permanent) {
            state.forced = on ? (full ? 'full' : 'band') : null;
            state.forcedUntil = permanent ? (Date.now() + 86400000) : (Date.now() + 3500);
            styleOverlay(overlay(), state.forced || 'off');
        };
    })();
    """#

    /// Loudness lift for films, built on one Web Audio graph per `<video>`.
    ///
    /// `video.volume` is clamped to 1.0 by the HTML spec, so the only way past
    /// 100% is a gain node. Installed by every strategy (direct file, embed
    /// frame, full page) and relayed down the frame tree, because on a provider
    /// page the `<video>` can sit behind a cross-origin boundary from the frame
    /// native can talk to.
    ///
    /// The one rule that matters here: **`createMediaElementSource` moves the
    /// element's audio into the graph**, and audio routed into a *suspended*
    /// graph is silence with no way back. So the element is never captured
    /// until the AudioContext reports `running`; until then the track simply
    /// plays normally and the level is retried. The ad audio tap in
    /// `buildVideoHTML` shares this graph — a second
    /// `createMediaElementSource` on the same element throws.
    private static let audioBoostJavaScript = #"""
    (function() {
        if (window.__floatSetAudioBoost) return;
        var level = 1.0;
        var graph = null;
        var status = 'off';

        function mainVideo() {
            return window.__floatVideoMainVideo || document.querySelector('video');
        }

        function context() {
            if (window.__floatAudioContext) return window.__floatAudioContext;
            var AC = window.AudioContext || window.webkitAudioContext;
            if (!AC) return null;
            try { window.__floatAudioContext = new AC(); } catch (e) { return null; }
            return window.__floatAudioContext;
        }

        function report(next) {
            status = next;
            window.__floatAudioBoostStatus = status;
            window.__floatAudioBoostLevel = level;
            return status;
        }

        // Shared with the ad audio tap. Returns null when the graph must not be
        // built yet, so callers can leave the element untouched.
        window.__floatEnsureAudioGraph = function(video) {
            if (!video) return null;
            if (graph && graph.video === video && graph.ctx.state === 'running') return graph;
            if (video.__floatAudioGraph && video.__floatAudioGraph.ctx.state === 'running') {
                graph = video.__floatAudioGraph;
                return graph;
            }
            var ctx = context();
            if (!ctx) return (report('unsupported'), null);
            if (ctx.state !== 'running') {
                try {
                    var resumed = ctx.resume();
                    if (resumed && resumed.then) {
                        resumed.then(function() {
                            if (level > 1 && status === 'pending') window.__floatSetAudioBoost(level);
                        }, function() { report('blocked'); });
                    }
                } catch (e) {}
                if (ctx.state !== 'running') return (report('pending'), null);
            }
            var source, gain, limiter, analyser;
            try {
                source = ctx.createMediaElementSource(video);
                gain = ctx.createGain();
                limiter = ctx.createDynamicsCompressor();
                analyser = ctx.createAnalyser();
            } catch (e) {
                return (report('unsupported'), null);
            }
            // Gain first, then a limiter. Lifting a film by 2-3x without one
            // clips on every explosion and gunshot; threshold just under 0 dBFS
            // with a hard ratio holds the peaks down without pumping dialogue.
            limiter.threshold.value = -6;
            limiter.knee.value = 6;
            limiter.ratio.value = 12;
            limiter.attack.value = 0.003;
            limiter.release.value = 0.25;
            analyser.fftSize = 2048;
            gain.gain.value = level;
            try {
                source.connect(gain);
                gain.connect(limiter);
                limiter.connect(analyser);
                analyser.connect(ctx.destination);
            } catch (e) {
                return (report('unsupported'), null);
            }
            graph = { ctx: ctx, video: video, source: source, gain: gain,
                      limiter: limiter, analyser: analyser };
            video.__floatAudioGraph = graph;
            return graph;
        };

        function apply(factor) {
            level = (typeof factor === 'number' && isFinite(factor) && factor > 1) ? factor : 1;
            if (level <= 1) {
                // Leaving the graph wired at unity keeps the ad audio tap alive
                // and makes switching back instant.
                if (graph) { try { graph.gain.gain.value = 1; } catch (e) {} }
                return report('off');
            }
            var video = mainVideo();
            if (!video) return report('no-video');
            var g = window.__floatEnsureAudioGraph(video);
            if (!g) return report(status);
            try {
                var now = g.ctx.currentTime;
                g.gain.gain.cancelScheduledValues(now);
                g.gain.gain.setTargetAtTime(level, now, 0.03);
            } catch (e) {
                try { g.gain.gain.value = level; } catch (ignored) {}
            }
            return report('on');
        }

        window.__floatSetAudioBoost = function(factor) { return apply(factor); };
        report('off');

        // A new episode, a late provider player, or the first playback WebKit
        // allows: re-check on every play. apply() is idempotent and cheap.
        document.addEventListener('playing', function(event) {
            var target = event.target;
            if (!target || target.tagName !== 'VIDEO') return;
            if (!window.__floatVideoMainVideo) window.__floatVideoMainVideo = target;
            if (level > 1) apply(level);
        }, true);

        // The player's video can be a frame away from the one native can reach,
        // so the level is relayed down the frame tree.
        window.addEventListener('message', function(event) {
            var data = event.data;
            if (!data || typeof data.__floatAudioBoost !== 'number') return;
            apply(data.__floatAudioBoost);
            var frames = document.querySelectorAll('iframe');
            for (var i = 0; i < frames.length; i++) {
                try { frames[i].contentWindow.postMessage(data, '*'); } catch (e) {}
            }
        });
    })();
    """#

    /// One second of 16 kHz mono PCM from the `<video>`, posted to native so a
    /// spot can be *heard* instead of seen.
    ///
    /// This is the only ad signal that does not depend on the creative having
    /// readable text or a distinctive palette — which is exactly what a wordless
    /// video spot looks like, and why one slipped past the frame detectors.
    ///
    /// It lives here rather than in the direct player's page because the
    /// provider's own frame is where its `<video>` is. `hearAdvertisement`
    /// already had a `.siteEmbed` branch, but the tap was only ever installed in
    /// the page this app builds, so that branch could never fire.
    private static let adAudioTapJavaScript = #"""
    (function() {
        if (window.__floatInstallAdAudioTap) return;

        window.__floatInstallAdAudioTap = function(video) {
            if (window.__floatAudioTap) return;
            var v = video || window.__floatVideoMainVideo || document.querySelector('video');
            if (!v) return;
            if (!window.webkit || !window.webkit.messageHandlers || !window.webkit.messageHandlers.adAudio) return;
            // Null while the audio context may not run yet: capturing the element
            // into a suspended graph is silence, so it is left alone instead.
            var graph = window.__floatEnsureAudioGraph ? window.__floatEnsureAudioGraph(v) : null;
            if (!graph) return;
            var actx = graph.ctx;
            var analyser = graph.analyser;
            window.__floatAudioTap = true;
            var wave = new Float32Array(analyser.fftSize);
            var pcm = [];
            function flush() { pcm = []; }
            function pump() {
                if (!v.paused && v.readyState >= 2) {
                    if (actx.state === 'suspended') actx.resume();
                    analyser.getFloatTimeDomainData(wave);
                    var rate = actx.sampleRate || 44100;
                    var step = Math.max(1, Math.round(rate / 16000));
                    var energy = 0;
                    for (var i = 0; i < wave.length; i += step) {
                        var s = wave[i];
                        energy += s * s;
                        var q = s < -1 ? -1 : (s > 1 ? 1 : s);
                        pcm.push((q * 32767) | 0);
                    }
                    if (pcm.length >= 16000) {
                        // A silent stretch is not worth recognising; it only
                        // costs an authorization-checked round trip.
                        if (energy / (wave.length / step) > 0.0004) {
                            var count = pcm.length;
                            var bytes = new Uint8Array(count * 2);
                            for (var n = 0; n < count; n++) {
                                var v16 = pcm[n];
                                bytes[n * 2] = v16 & 255;
                                bytes[n * 2 + 1] = (v16 >> 8) & 255;
                            }
                            var bin = '';
                            for (var o = 0; o < bytes.length; o += 4096) {
                                bin += String.fromCharCode.apply(null, bytes.subarray(o, Math.min(bytes.length, o + 4096)));
                            }
                            try { window.webkit.messageHandlers.adAudio.postMessage(btoa(bin)); } catch (e) {}
                        }
                        flush();
                    }
                }
                setTimeout(pump, 45);
            }
            v.addEventListener('play', function() { actx.resume(); });
            v.addEventListener('playing', function() { actx.resume(); window.__floatInstallAdAudioTap(v); });
            // A seek splices unrelated audio into one "second", so drop the
            // partial chunk instead of handing the recogniser a seam.
            v.addEventListener('seeked', flush);
            v.addEventListener('loadeddata', flush);
            actx.resume();
            pump();
        };

        // A provider page can build its player late, so keep looking.
        window.__floatInstallAdAudioTap();
        document.addEventListener('playing', function(event) {
            var target = event.target;
            if (target && target.tagName === 'VIDEO') window.__floatInstallAdAudioTap(target);
        }, true);
        setInterval(function() { window.__floatInstallAdAudioTap(); }, 2000);
    })();
    """#

    private static let aiDubbingJavaScript = #"""
    (function() {
        if (window.__floatAIDubInstalled) return;
        window.__floatAIDubInstalled = true;

        var state = {
            enabled: false,
            voiceGender: 'female',
            baseRate: 1.20,
            duckingRatio: 0.30,
            preDuckVolume: 1.0,
            isDucked: false,
            duckTimer: null,
            lastText: '',
            lastTime: 0,
            hasActiveTextTracks: false,
            lastTextTrackTime: 0,
            domDebounceTimer: null,
            recentHistory: [],
            timelineCues: [],
            ingestedUrls: {},
            lastPrefetchTime: 0,
            lastTimelineSpokenTime: 0,
            lastOfflineTimelineCount: 0,
            generation: 0
        };

        function cleanDialogueText(raw) {
            if (!raw) return '';
            return raw
                .replace(/<[^>]*>/g, '')
                .replace(/\[[^\]]*\]/g, '')
                .replace(/\([^\)]*\)/g, '')
                .replace(/^[A-Z0-9\s_-]+:\s*/, '')
                .replace(/^["'“”—\-\s]+/, '')
                .replace(/["'”\s]+$/, '')
                .replace(/\s+/g, ' ')
                .trim();
        }

        function normalizeText(s) {
            if (!s) return '';
            return s.toLowerCase()
                .replace(/[^\p{L}\p{N}\s]/gu, '')
                .replace(/\s+/g, ' ')
                .trim();
        }

        function similarity(s1, s2) {
            if (s1 === s2) return 1.0;
            var n = s1.length, m = s2.length;
            if (n === 0 || m === 0) return 0.0;
            if (Math.abs(n - m) > Math.max(n, m) / 2) return 0.0;
            var prev = [];
            for (var j = 0; j <= m; j++) prev[j] = j;
            for (var i = 1; i <= n; i++) {
                var curr = [i];
                var c1 = s1.charAt(i - 1);
                for (var j = 1; j <= m; j++) {
                    var cost = (c1 === s2.charAt(j - 1)) ? 0 : 1;
                    curr[j] = Math.min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost);
                }
                prev = curr;
            }
            var dist = prev[m];
            var maxLen = Math.max(n, m);
            return Math.max(0.0, 1.0 - (dist / maxLen));
        }

        function isNearDuplicate(newText, prevText, threshold) {
            threshold = threshold || 0.82;
            var n1 = normalizeText(newText);
            var n2 = normalizeText(prevText);
            if (!n1 || !n2) return false;
            if (n1 === n2) return true;
            if (n1.indexOf(n2) !== -1 || n2.indexOf(n1) !== -1) {
                var minLen = Math.min(n1.length, n2.length);
                var maxLen = Math.max(n1.length, n2.length);
                if (minLen / maxLen >= 0.75) return true;
            }
            return similarity(n1, n2) >= threshold;
        }

        function shouldSpeak(cleanText) {
            var now = Date.now();
            var norm = normalizeText(cleanText);
            if (!norm) return false;

            state.recentHistory = state.recentHistory.filter(function(item) {
                return (now - item.time) < 12000;
            });

            for (var i = 0; i < state.recentHistory.length; i++) {
                var item = state.recentHistory[i];
                var age = now - item.time;
                if (cleanText === item.text || norm === item.norm) return false;
                if (age < 7500) {
                    if (isNearDuplicate(cleanText, item.text, 0.80)) return false;
                    if (item.norm.indexOf(norm) !== -1 && norm.length <= item.norm.length) return false;
                }
            }

            state.recentHistory.push({ text: cleanText, norm: norm, time: now });
            return true;
        }

        var VI_DIACRITICS = /[àáảãạăắằẳẵặâấầẩẫậèéẻẽẹêếềểễệìíỉĩịòóỏõọôốồổỗộơớờởỡợùúủũụưứừửữựỳýỷỹỵđ]/i;
        var VI_WORDS = /\b(anh|em|toi|ta|minh|ong|ba|co|chu|bac|khong|la|mot|hai|ba|nguoi|nay|trong|da|duoc|cho|voi|cua|gi|sao|the|nhung|phai|biet|di|ve|o|ra|len|xuong|lai|ma|thi|neu|vi|nen|hay|dung|chua|se|dang|cung|de|roi|ca|den|dau|muon|thay|noi|nghe|lam|ay|day|gio|luc|viec|chuyen|nha|tien|troi|song|chet)\b/i;
        var EN_STOP = /\b(the|and|of|to|in|is|you|that|it|he|was|for|on|are|as|with|his|they|at|be|this|from|have|or|by|one|had|not|but|what|all|were|when|we|there|can|an|your|which|their|if|do|will|each|about|how|up|out|them|then|she|many|some|so|these|would|other|into|has|more|her|like|him|see|time|could|no|make|than|first|been|its|who|now|people|my|over|did|down|only|way|find|use|may|water|long|little|very|after|words|just|where|most|get|through|back|much|go|good|new|write|our|me|too|any|day|same|right|look|think|also|around|another|came|come|work|three|must|because|does|part|even|place|well|such|here|take|why|help|put|away|again|off|went|old|great|tell|say|small|every|found|still|between|name|should|home|big|give|air|line|set|own|under|read|last|never|us|left|end|while|might|next|sound|below|saw|something|thought|both|few|those|always|show|large|often|together|asked|house|world|going|want|school|until|quiet|isolation|drifts|rhythms|college|secrets|shifting|circle|classmates|bleed|nights|subtle|academia|entangled|lives|kindle|rate|book)\b/ig;
        var AD_KEYWORDS = /kindle|rate this book|goodreads|amazon|shopee|lazada|tiki|want to read|chapter|edition|subscription|price|review|rating|sign in|subscribe|subtitles by|kkphim|ophim|nguonc|phimmoi|phimapi|resume|loading|tiếp tục xem|bạn đang xem dở/i;

        function isLikelyVietnamese(t) {
            if (!t || t.length < 2 || t.length > 220) return false;
            if (/[\$€£¥]|\b\d+\.\d{2}\b|\*{3,}|https?:\/\/|\.com\b|\.net\b|www\./i.test(t)) return false;
            if (AD_KEYWORDS.test(t)) return false;
            var enMatches = t.match(EN_STOP);
            if (enMatches && enMatches.length >= 2) {
                var words = t.split(/\s+/).filter(Boolean);
                if (words.length > 0 && (enMatches.length / words.length) >= 0.20) return false;
            }
            return VI_DIACRITICS.test(t) || VI_WORDS.test(t);
        }

        function parseTimestamp(s) {
            if (!s) return 0;
            var parts = s.trim().replace(',', '.').split(':');
            if (parts.length === 3) {
                return (parseFloat(parts[0]) || 0) * 3600 + (parseFloat(parts[1]) || 0) * 60 + (parseFloat(parts[2]) || 0);
            } else if (parts.length === 2) {
                return (parseFloat(parts[0]) || 0) * 60 + (parseFloat(parts[1]) || 0);
            }
            return parseFloat(s) || 0;
        }

        function parseVTTorSRT(text) {
            var cues = [];
            var blocks = text.replace(/\r\n/g, '\n').replace(/\r/g, '\n').split(/\n\n+/);
            var timeRegex = /((?:\d{1,2}:)?\d{2}:\d{2}[\.,]\d{3})\s*-->\s*((?:\d{1,2}:)?\d{2}:\d{2}[\.,]\d{3})/;
            for (var i = 0; i < blocks.length; i++) {
                var lines = blocks[i].trim().split('\n');
                var timeIdx = -1;
                for (var j = 0; j < lines.length; j++) {
                    if (timeRegex.test(lines[j])) {
                        timeIdx = j;
                        break;
                    }
                }
                if (timeIdx !== -1) {
                    var m = lines[timeIdx].match(timeRegex);
                    var start = parseTimestamp(m[1]);
                    var end = parseTimestamp(m[2]);
                    var rawText = lines.slice(timeIdx + 1).join(' ');
                    var clean = cleanDialogueText(rawText);
                    if (clean && clean.length >= 2 && end > start) {
                        cues.push({ start: start, end: end, text: clean });
                    }
                }
            }
            return cues;
        }

        function parseYouTubeTimedText(text) {
            var cues = [];
            var trimmed = text.trim();
            if (trimmed.indexOf('{') === 0) {
                try {
                    var data = JSON.parse(trimmed);
                    if (data.events && Array.isArray(data.events)) {
                        for (var i = 0; i < data.events.length; i++) {
                            var ev = data.events[i];
                            if (ev.tStartMs != null && ev.segs) {
                                var s = ev.tStartMs / 1000.0;
                                var dur = (ev.dDurationMs || 2000) / 1000.0;
                                var txt = ev.segs.map(function(seg) { return seg.utf8 || ''; }).join('').replace(/\n/g, ' ');
                                var clean = cleanDialogueText(txt);
                                if (clean && clean.length >= 2) {
                                    cues.push({ start: s, end: s + dur, text: clean });
                                }
                            }
                        }
                    }
                } catch(e) {}
            } else if (trimmed.indexOf('<transcript') !== -1 || trimmed.indexOf('<timedtext') !== -1 || trimmed.indexOf('<text') !== -1 || trimmed.indexOf('<p ') !== -1) {
                var textTagRegex = /<text\s+start="([\d\.]+)"(?:\s+dur="([\d\.]+)")?[^>]*>([\s\S]*?)<\/text>/gi;
                var match;
                while ((match = textTagRegex.exec(trimmed)) !== null) {
                    var s = parseFloat(match[1]) || 0;
                    var dur = parseFloat(match[2]) || 2.0;
                    var txt = match[3].replace(/<[^>]*>/g, '').replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'");
                    var clean = cleanDialogueText(txt);
                    if (clean && clean.length >= 2) {
                        cues.push({ start: s, end: s + dur, text: clean });
                    }
                }
                if (cues.length === 0) {
                    var pTagRegex = /<p\s+t="(\d+)"(?:\s+d="(\d+)")?[^>]*>([\s\S]*?)<\/p>/gi;
                    while ((match = pTagRegex.exec(trimmed)) !== null) {
                        var s = (parseInt(match[1], 10) || 0) / 1000.0;
                        var dur = (parseInt(match[2], 10) || 2000) / 1000.0;
                        var txt = match[3].replace(/<[^>]*>/g, '').replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'");
                        var clean = cleanDialogueText(txt);
                        if (clean && clean.length >= 2) {
                            cues.push({ start: s, end: s + dur, text: clean });
                        }
                    }
                }
            }
            return cues;
        }

        function ingestSubtitleContent(text, sourceUrl) {
            if (!text || typeof text !== 'string' || text.length < 20) return;
            var parsed = [];
            if (text.indexOf('WEBVTT') !== -1 || /-->/.test(text)) {
                parsed = parseVTTorSRT(text);
            } else if (text.indexOf('{') === 0 || text.indexOf('<transcript') !== -1 || text.indexOf('<timedtext') !== -1) {
                parsed = parseYouTubeTimedText(text);
            }
            if (!parsed || parsed.length === 0) return;

            var existingStarts = {};
            for (var i = 0; i < state.timelineCues.length; i++) {
                existingStarts[state.timelineCues[i].start.toFixed(2)] = true;
            }

            for (var j = 0; j < parsed.length; j++) {
                var c = parsed[j];
                var key = c.start.toFixed(2);
                if (!existingStarts[key]) {
                    existingStarts[key] = true;
                    state.timelineCues.push({
                        start: c.start,
                        end: c.end,
                        text: c.text,
                        viText: null,
                        prefetched: false,
                        spoken: false
                    });
                }
            }

            state.timelineCues.sort(function(a, b) { return a.start - b.start; });
            postOfflineTimeline();
            pollChunkAhead();
        }

        function postOfflineTimeline() {
            if (!window.webkit || !window.webkit.messageHandlers || !window.webkit.messageHandlers.aiDub) return;
            if (state.timelineCues.length === state.lastOfflineTimelineCount) return;
            state.lastOfflineTimelineCount = state.timelineCues.length;
            var cues = state.timelineCues.map(function(c) {
                return { start: c.start, end: c.end, text: c.text };
            });
            window.webkit.messageHandlers.aiDub.postMessage({ action: 'offlineTimeline', cues: cues });
        }

        window.__floatRequestOfflineTimeline = function() {
            state.lastOfflineTimelineCount = 0;
            var v = window.__floatVideoMainVideo || document.querySelector('video');
            if (v && window.__floatInstallAIDub) window.__floatInstallAIDub(v);
            // Offline mode must not depend on which track the player happens
            // to mark as showing. Read every loaded text track once, then
            // deduplicate by timestamp; the user can choose the language in
            // the player before starting Offline Dub.
            if (v && v.textTracks) {
                for (var ti = 0; ti < v.textTracks.length; ti++) {
                    var track = v.textTracks[ti];
                    if (!track.cues) continue;
                    for (var ci = 0; ci < track.cues.length; ci++) {
                        var raw = track.cues[ci].text || '';
                        var clean = cleanDialogueText(raw);
                        if (!clean || clean.length < 2) continue;
                        var start = track.cues[ci].startTime;
                        var end = track.cues[ci].endTime || (start + 2.5);
                        var exists = state.timelineCues.some(function(item) {
                            return Math.abs(item.start - start) < 0.25;
                        });
                        if (!exists) state.timelineCues.push({ start: start, end: end, text: clean, viText: null, prefetched: false, spoken: false });
                    }
                }
                state.timelineCues.sort(function(a, b) { return a.start - b.start; });
            }
            extractTextTrackCues(v);
            scanDomTracks();
            postOfflineTimeline();
        };
        window.__floatGetOfflineTimeline = function() {
            return state.timelineCues.map(function(c) {
                return { start: c.start, end: c.end, text: c.text };
            });
        };

        var SUB_URL_REGEX = /\.(vtt|srt|ass)(\?|$)|timedtext|subtitle|caption|\/sub\//i;
        var MEDIA_IGNORE_REGEX = /\.(m3u8|ts|m4s|mp4|webm|mp3|aac|png|jpg|jpeg|gif|webp|woff2?)(\?|$)/i;

        function isSubtitleUrl(url) {
            if (!url || typeof url !== 'string') return false;
            if (MEDIA_IGNORE_REGEX.test(url)) return false;
            return SUB_URL_REGEX.test(url);
        }

        function looksLikeSubtitlePayload(text, contentType) {
            if (!text || typeof text !== 'string' || text.length < 20 || text.length > 2 * 1024 * 1024) return false;
            var type = String(contentType || '').toLowerCase();
            if (/text\/vtt|subrip|subtitle|caption/.test(type)) return true;
            var head = text.slice(0, 1200).trim();
            if (/^webvtt\b/i.test(head) || /\d{1,2}:\d{2}(?::\d{2})?[,.]\d{3}\s+-->/.test(text)) return true;
            return /\b(timedtext|transcript|events|segs|start|dur)\b/i.test(head) && /^\s*[<{[]/.test(head);
        }

        // Intercept network fetch
        if (typeof window.fetch === 'function') {
            var _origFetch = window.fetch;
            window.fetch = function() {
                var args = arguments;
                var promise = _origFetch.apply(this, args);
                try {
                    var url = (typeof args[0] === 'string') ? args[0] : (args[0] && args[0].url ? args[0].url : '');
                    if (!state.ingestedUrls[url]) {
                        promise.then(function(res) {
                            try {
                                var contentType = res.headers.get('content-type') || '';
                                res.clone().text().then(function(txt) {
                                    if (isSubtitleUrl(url) || looksLikeSubtitlePayload(txt, contentType)) {
                                        state.ingestedUrls[url] = true;
                                        ingestSubtitleContent(txt, url);
                                    }
                                }).catch(function(){});
                            } catch(e) {}
                        }).catch(function(){});
                    }
                } catch(e) {}
                return promise;
            };
        }

        // Intercept XMLHttpRequest
        if (typeof window.XMLHttpRequest === 'function') {
            var _origOpen = XMLHttpRequest.prototype.open;
            var _origSend = XMLHttpRequest.prototype.send;
            XMLHttpRequest.prototype.open = function(method, url) {
                this.__floatSubUrl = url;
                return _origOpen.apply(this, arguments);
            };
            XMLHttpRequest.prototype.send = function() {
                var self = this;
                if (self.__floatSubUrl && !state.ingestedUrls[self.__floatSubUrl]) {
                    self.addEventListener('load', function() {
                        try {
                            var contentType = self.getResponseHeader ? self.getResponseHeader('content-type') : '';
                            if (isSubtitleUrl(self.__floatSubUrl) || looksLikeSubtitlePayload(self.responseText, contentType)) {
                                state.ingestedUrls[self.__floatSubUrl] = true;
                                ingestSubtitleContent(self.responseText, self.__floatSubUrl);
                            }
                        } catch(e) {}
                    });
                }
                return _origSend.apply(this, arguments);
            };
        }

        // Cross-frame relay: listen for cues from embedded iframes
        window.addEventListener('message', function(e) {
            if (e.data && e.data.type === '__floatAIDubRelay') {
                if (e.data.action === 'stop') {
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.aiDub) {
                        window.webkit.messageHandlers.aiDub.postMessage({ action: 'stop' });
                    }
                } else if (e.data.action === 'prefetch' && e.data.text) {
                    prefetch(e.data.text);
                } else if (e.data.action === 'speak' && e.data.text) {
                    speak(e.data.text, e.data.duration || 0);
                }
            }
        });

        function duck(video) {
            clearTimeout(state.duckTimer);
            var v = video || window.__floatVideoMainVideo || document.querySelector('video');
            if (!v) return;
            if (!state.isDucked) {
                state.preDuckVolume = v.volume || 1.0;
                v.volume = Math.max(0.08, state.preDuckVolume * state.duckingRatio);
                state.isDucked = true;
            }
        }

        function unduck(video) {
            clearTimeout(state.duckTimer);
            state.duckTimer = setTimeout(function() {
                var v = video || window.__floatVideoMainVideo || document.querySelector('video');
                if (state.isDucked && v) {
                    v.volume = state.preDuckVolume;
                    state.isDucked = false;
                }
            }, 220);
        }

        function speak(text, duration, video) {
            if (!state.enabled || !text) return;
            var clean = cleanDialogueText(text);
            if (!clean || clean.length < 2) return;

            var now = Date.now();
            if (!shouldSpeak(clean)) return;
            state.lastText = clean;
            state.lastTime = now;

            var effDuration = (duration && duration > 0) ? duration : Math.max(1.4, clean.length / 12.0);

            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.aiDub) {
                window.webkit.messageHandlers.aiDub.postMessage({
                    action: 'speak',
                    text: clean,
                    duration: effDuration
                });
                return;
            }

            // Cross-frame support: relay to parent window
            if (window.parent && window.parent !== window) {
                try {
                    window.parent.postMessage({
                        type: '__floatAIDubRelay',
                        action: 'speak',
                        text: clean,
                        duration: effDuration
                    }, '*');
                } catch(e) {}
            }
        }

        function prefetch(text) {
            if (!state.enabled || !text) return;
            var clean = cleanDialogueText(text);
            if (!clean || clean.length < 2) return;

            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.aiDub) {
                window.webkit.messageHandlers.aiDub.postMessage({
                    action: 'prefetch',
                    text: clean
                });
                return;
            }

            if (window.parent && window.parent !== window) {
                try {
                    window.parent.postMessage({
                        type: '__floatAIDubRelay',
                        action: 'prefetch',
                        text: clean
                    }, '*');
                } catch(e) {}
            }
        }

        function selectedTrack(v) {
            if (!v || !v.textTracks) return null;
            var tracks = [];
            for (var i = 0; i < v.textTracks.length; i++) {
                var track = v.textTracks[i];
                if (track.kind === 'subtitles' || track.kind === 'captions') tracks.push(track);
            }
            var selected = tracks.find(function(t) { return t.mode === 'showing'; })
                || tracks.find(function(t) { return t.mode === 'hidden'; })
                || tracks.find(function(t) { return /^vi(-|$)/i.test(t.language || ''); })
                || tracks.find(function(t) { return /^en(-|$)/i.test(t.language || ''); })
                || tracks[0];
            if (selected && selected.mode === 'disabled') selected.mode = 'hidden';
            return selected || null;
        }

        function scanDomTracks() {
            var v = window.__floatVideoMainVideo || document.querySelector('video');
            if (!v) return;
            var selected = selectedTrack(v);
            var tracks = v.querySelectorAll('track[src]');
            for (var i = 0; i < tracks.length; i++) {
                if (tracks[i].track !== selected) continue;
                var src = tracks[i].src;
                if (src && !state.ingestedUrls[src]) {
                    state.ingestedUrls[src] = true;
                    (function(s) {
                        try {
                            var xhr = new XMLHttpRequest();
                            xhr.open('GET', s, true);
                            xhr.onload = function() {
                                if (xhr.responseText) ingestSubtitleContent(xhr.responseText, s);
                            };
                            xhr.send();
                        } catch(e) {}
                    })(src);
                }
            }
        }

        function extractTextTrackCues(v) {
            if (!v || !v.textTracks) return;
            var selected = selectedTrack(v);
            if (!selected) return;
            var addedAny = false;
            for (var i = 0; i < v.textTracks.length; i++) {
                var t = v.textTracks[i];
                if (t !== selected) continue;
                if (!t.cues || t.cues.length === 0) continue;
                for (var j = 0; j < t.cues.length; j++) {
                    var cue = t.cues[j];
                    var txt = cue.text || (cue.getCueAsHTML && cue.getCueAsHTML().textContent) || '';
                    var clean = cleanDialogueText(txt);
                    if (clean && clean.length >= 2) {
                        var start = cue.startTime;
                        var end = cue.endTime || (start + 2.5);
                        var exists = state.timelineCues.some(function(item) {
                            return Math.abs(item.start - start) < 0.25;
                        });
                        if (!exists) {
                            state.timelineCues.push({
                                start: start,
                                end: end,
                                text: clean,
                                viText: null,
                                prefetched: false,
                                spoken: false
                            });
                            addedAny = true;
                        }
                    }
                }
            }
            if (addedAny) {
                state.timelineCues.sort(function(a, b) { return a.start - b.start; });
                postOfflineTimeline();
                pollChunkAhead(v);
            }
        }

        function pollChunkAhead(video) {
            if (!state.enabled) return;
            var v = video || window.__floatVideoMainVideo || document.querySelector('video');
            if (!v) return;
            var cur = v.currentTime || 0;
            var lookAheadLimit = cur + 12.0;

            var uncachedTexts = [];
            var considered = 0;
            for (var i = 0; i < state.timelineCues.length; i++) {
                var cue = state.timelineCues[i];
                if (cue.start >= (cur - 0.5) && cue.start <= lookAheadLimit) {
                    if (++considered > 8) break;
                    if (!cue.prefetched) {
                        cue.prefetched = true;
                        if (isLikelyVietnamese(cue.text)) {
                            cue.viText = cue.text;
                            prefetch(cue.text);
                        } else {
                            uncachedTexts.push(cue.text);
                        }
                    }
                } else if (cue.start > lookAheadLimit) {
                    break;
                }
            }

            if (uncachedTexts.length > 0) {
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.aiDub) {
                    window.webkit.messageHandlers.aiDub.postMessage({
                        action: 'prefetchBatch',
                        texts: uncachedTexts
                    });
                }
            }
        }

        function checkTimeline(video) {
            if (!state.enabled) return;
            var v = video || window.__floatVideoMainVideo || document.querySelector('video');
            if (!v || v.paused || v.seeking) return;
            var cur = v.currentTime || 0;

            for (var i = 0; i < state.timelineCues.length; i++) {
                var cue = state.timelineCues[i];
                if (cur >= (cue.start - 0.15) && cur < cue.end) {
                    if (!cue.spoken) {
                        cue.spoken = true;
                        state.lastTimelineSpokenTime = Date.now();
                        var dur = (cue.end > cur) ? (cue.end - cur) : 0;
                        var txtToSpeak = cue.viText || cue.text;
                        speak(txtToSpeak, dur, v);
                    }
                } else if (cue.start > cur + 1.2) {
                    break;
                }
            }
        }

        window.__floatToggleAIDub = function(explicit) {
            state.enabled = explicit !== undefined ? !!explicit : !state.enabled;
            if (!state.enabled) {
                state.generation++;
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.aiDub) {
                    window.webkit.messageHandlers.aiDub.postMessage({ action: 'stop' });
                }
                unduck();
            } else {
                pollChunkAhead();
            }
            return state.enabled;
        };

        window.__floatIsAIDubEnabled = function() {
            return state.enabled;
        };

        window.__floatInstallAIDub = function(video) {
            var v = video || window.__floatVideoMainVideo || document.querySelector('video');
            if (!v || v.__floatAIDubHooked) return;
            v.__floatAIDubHooked = true;

            function hookTracks() {
                if (!v.textTracks) return;
                var selected = selectedTrack(v);
                for (var i = 0; i < v.textTracks.length; i++) {
                    var t = v.textTracks[i];
                    t.removeEventListener('cuechange', onCue);
                    if (t === selected) t.addEventListener('cuechange', onCue);
                }
                extractTextTrackCues(v);
                pollChunkAhead(v);
            }

            function onCue(e) {
                if (!state.enabled) return;
                var t = e.target;
                if (!t || !t.activeCues) return;
                state.hasActiveTextTracks = true;
                state.lastTextTrackTime = Date.now();
                extractTextTrackCues(v);
                for (var i = 0; i < t.activeCues.length; i++) {
                    var cue = t.activeCues[i];
                    var txt = cue.text || (cue.getCueAsHTML && cue.getCueAsHTML().textContent) || '';
                    var dur = (cue.endTime && cue.startTime) ? (cue.endTime - cue.startTime) : 0;
                    var inTimeline = state.timelineCues.some(function(item) {
                        return Math.abs(item.start - cue.startTime) < 0.25 && normalizeText(item.text) === normalizeText(cleanDialogueText(txt));
                    });
                    if (inTimeline) checkTimeline(v);
                    else speak(txt, dur, v);
                }
                pollChunkAhead(v);
            }

            hookTracks();
            if (v.textTracks) v.textTracks.addEventListener('addtrack', hookTracks);
            if (v.textTracks) v.textTracks.addEventListener('change', function() {
                state.generation++;
                state.timelineCues = [];
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.aiDub) {
                    window.webkit.messageHandlers.aiDub.postMessage({ action: 'stop' });
                }
                hookTracks();
            });

            // Frame-accurate timeline loop (75ms interval)
            setInterval(function() {
                checkTimeline(v);
            }, 75);

            // Chunk prefetcher loop (1200ms interval)
            setInterval(function() {
                pollChunkAhead(v);
                scanDomTracks();
            }, 1200);

            v.addEventListener('play', function() {
                hookTracks();
                extractTextTrackCues(v);
                scanDomTracks();
                pollChunkAhead(v);
            });
            v.addEventListener('playing', function() {
                extractTextTrackCues(v);
                pollChunkAhead(v);
            });
            v.addEventListener('seeked', function() {
                pollChunkAhead(v);
            });
            v.addEventListener('timeupdate', function() {
                checkTimeline(v);
                var now = Date.now();
                if (now - state.lastPrefetchTime >= 1200) {
                    state.lastPrefetchTime = now;
                    pollChunkAhead(v);
                }
            });
            v.addEventListener('pause', function() {
                state.generation++;
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.aiDub) {
                    window.webkit.messageHandlers.aiDub.postMessage({ action: 'stop' });
                }
                unduck(v);
            });
            v.addEventListener('seeking', function() {
                state.generation++;
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.aiDub) {
                    window.webkit.messageHandlers.aiDub.postMessage({ action: 'stop' });
                }
                unduck(v);
                state.lastText = '';
                state.recentHistory = [];
                var cur = v.currentTime || 0;
                for (var i = 0; i < state.timelineCues.length; i++) {
                    if (state.timelineCues[i].start >= cur - 0.5) {
                        state.timelineCues[i].spoken = false;
                    }
                }
                pollChunkAhead(v);
            });

            // DOM Mutation Observer for live web player subtitles (targeted cue containers fallback)
            try {
                var cueObserver = null;
                var currentCueTarget = null;
                function syncCueObserver() {
                    if (currentCueTarget && currentCueTarget.isConnected) return;
                    var sel = '.jw-text-track-cue, .vjs-text-track-cue, .caption-window, .ytp-caption-window-container, [class*="caption-window"], [class*="subtitle-cue"]';
                    var target = document.querySelector(sel);
                    if (!target) return;
                    if (cueObserver) {
                        try { cueObserver.disconnect(); } catch (e) {}
                    }
                    cueObserver = new MutationObserver(function(mutations) {
                        if (!state.enabled) return;
                        if (state.hasActiveTextTracks && (Date.now() - state.lastTextTrackTime < 4500)) return;
                        if (state.timelineCues.length > 0 && (Date.now() - (state.lastTimelineSpokenTime || 0) < 4500)) return;

                        clearTimeout(state.domDebounceTimer);
                        state.domDebounceTimer = setTimeout(function() {
                            if (!state.enabled) return;
                            if (state.hasActiveTextTracks && (Date.now() - state.lastTextTrackTime < 4500)) return;
                            if (state.timelineCues.length > 0 && (Date.now() - (state.lastTimelineSpokenTime || 0) < 4500)) return;
                            if (target && target.isConnected) {
                                var txt = target.textContent;
                                if (txt && txt.trim().length >= 2 && txt.trim().length <= 220) {
                                    speak(txt.trim(), 0, v);
                                }
                            }
                        }, 40);
                    });
                    currentCueTarget = target;
                    cueObserver.observe(target, { childList: true, subtree: true, characterData: true });
                }
                syncCueObserver();
                setInterval(syncCueObserver, 1500);
            } catch (e) {}
        };

        window.__floatInstallAIDub();
        document.addEventListener('playing', function(e) {
            if (e.target && e.target.tagName === 'VIDEO') window.__floatInstallAIDub(e.target);
        }, true);
    })();
    """#

    private func buildVideoHTML(videoSrc: String, currentTime: Double) -> String {
        // Interpolated into a double-quoted JavaScript string inside the page's
        // <script>, so it needs JavaScript escaping — including `\u003c`, which
        // stops a crafted URL from closing the script element. HTML escaping
        // would be wrong here: it would corrupt a legitimate query string.
        let escapedSrc = Self.escapeJSString(videoSrc, quote: "\"")
        return """
        <!DOCTYPE html>
        <html><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            html, body { width: 100vw; height: 100vh; background: #000; overflow: hidden; }
            video {
                position: fixed; top: 0; left: 0;
                width: 100vw; height: 100vh;
                object-fit: contain;
                background: #000;
                cursor: pointer;
            }
        </style>
        <script src="https://cdn.jsdelivr.net/npm/hls.js@latest"></script>
        </head><body>
        <video id="player" autoplay playsinline></video>
        <script>
            const v = document.getElementById('player');
            const src = "\(escapedSrc)";
            const startTime = \(currentTime);
            function markStreamFailed() {
                window.__floatStreamFailed = true;
            }

            function playNative(url) {
                v.src = url;
                if (startTime > 0) v.currentTime = startTime;
                v.play().catch(function() {});
            }

            if (src.indexOf('.m3u8') !== -1) {
                if (typeof Hls !== 'undefined' && Hls.isSupported()) {
                    try {
                        const hls = new Hls({ enableWorker: true, lowLatencyMode: false });
                        hls.loadSource(src);
                        hls.attachMedia(v);
                        hls.on(Hls.Events.MANIFEST_PARSED, function() {
                            if (startTime > 0) v.currentTime = startTime;
                            v.play().catch(function() {});
                        });
                        hls.on(Hls.Events.ERROR, function(event, data) {
                            if (data.fatal) {
                                console.warn('[FloatVideo] HLS.js error, falling back to native player', data);
                                hls.destroy();
                                v.addEventListener('error', markStreamFailed, { once: true });
                                playNative(src);
                            }
                        });
                    } catch (e) {
                        v.addEventListener('error', markStreamFailed, { once: true });
                        playNative(src);
                    }
                } else {
                    v.addEventListener('error', markStreamFailed, { once: true });
                    playNative(src);
                }
            } else {
                v.addEventListener('error', markStreamFailed, { once: true });
                playNative(src);
            }

            \(Self.smartFillJavaScript)
            v.addEventListener('loadeddata', function() { window.__floatInstallSmartFill(v); });
            v.addEventListener('playing', function() { window.__floatInstallSmartFill(v); });

            // The burned-in sponsor line is blurred by the shared overlay, the
            // same one the embed frames and full-page providers install.
            \(Self.bannerBlurJavaScript)
            window.__floatInstallAdBlur(v);
            \(Self.audioBoostJavaScript)
            // Re-applied per load: the page may not have its <video> yet, and
            // the in-page `playing` listener retries once it does.
            window.__floatSetAudioBoost(\(Self.preferredAudioBoost.factor));
            \(Self.adAudioTapJavaScript)
            \(Self.aiDubbingJavaScript)
            v.addEventListener('loadeddata', function() { window.__floatInstallAIDub(v); });
            v.addEventListener('playing', function() { window.__floatInstallAIDub(v); });

            // Full-screen spots (9922.com and the same gold/red card) get a
            // frame sample. Native OCR decides, then we jump ahead.
            var adShotBusy = false;
            var adCanvasBlocked = false;
            var lastFullAdScanAt = 0;
            function sampleInterstitial(force) {
                if (adShotBusy || adCanvasBlocked || window.__floatAdSkipping || v.paused || v.readyState < 2) return;
                if (!window.webkit || !window.webkit.messageHandlers || !window.webkit.messageHandlers.adWatch) return;
                var w = 280, h = 158;
                var shot = window.__floatAdShot || (window.__floatAdShot = document.createElement('canvas'));
                shot.width = w;
                shot.height = h;
                var sctx = shot.getContext('2d', { willReadFrequently: true });
                try { sctx.drawImage(v, 0, 0, w, h); } catch (e) { return; }
                var pixels;
                try { pixels = sctx.getImageData(0, 0, w, h).data; } catch (e) {
                    adCanvasBlocked = true;
                    try { window.webkit.messageHandlers.adWatch.postMessage('blocked'); } catch (err) {}
                    return;
                }
                var gold = 0, red = 0, neon = 0, seen = 0;
                for (var y = 0; y < h; y += 3) {
                    for (var x = 0; x < w; x += 3) {
                        var p = (y * w + x) * 4;
                        var r = pixels[p], g = pixels[p + 1], b = pixels[p + 2];
                        seen++;
                        if (r > 170 && g > 120 && b < 110) gold++;
                        if (r > 150 && g < 100 && b < 110) red++;
                        if (g > 160 && r < 130 && g > r + 40) neon++;
                    }
                }
                if (seen < 8) return;
                var hot = gold / seen > 0.06 && red / seen > 0.035 && neon / seen > 0.025;
                var now = Date.now();
                // Fast path for the known gold/red spot; periodic OCR catches
                // ads with different artwork without running OCR every tick.
                if (!hot && !force && now - lastFullAdScanAt < 800) return;
                lastFullAdScanAt = now;
                adShotBusy = true;
                try {
                    window.webkit.messageHandlers.adWatch.postMessage({
                        image: shot.toDataURL('image/jpeg', 0.5),
                        time: v.currentTime || 0,
                        hot: hot
                    });
                } catch (e) {}
                setTimeout(function() { adShotBusy = false; }, 400);
            }
            setInterval(function() { sampleInterstitial(false); }, 500);
            v.addEventListener('playing', function() { sampleInterstitial(true); });
            v.addEventListener('loadeddata', function() { sampleInterstitial(true); });

            // Shared with the provider frames — see `adAudioTapJavaScript`.
            // The video is known here, so install now; the script retries from
            // its own `playing` listener when the audio context was not allowed
            // to run yet.
            window.__floatInstallAdAudioTap(v);

            v.addEventListener('seeked', function() {
                if (!window.__floatAdSkipping) return;
                window.__floatAdSkipping = false;
                setTimeout(function() { sampleInterstitial(true); }, 450);
            });

            v.addEventListener('click', function(e) {
                if (e.target === v) {
                    if (v.paused) v.play().catch(function() {});
                    else v.pause();
                }
            });

            v.addEventListener('dblclick', function() {
                if (document.fullscreenElement) {
                    document.exitFullscreen().catch(function() {});
                } else if (v.requestFullscreen) {
                    v.requestFullscreen().catch(function() {});
                }
            });
        </script>
        </body></html>
        """
    }

    private func buildEmbedHTML(embedUrl: String) -> String {
        return """
        <!DOCTYPE html>
        <html><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            html, body { width: 100vw; height: 100vh; background: #000; overflow: hidden; }
            iframe {
                position: fixed; top: 0; left: 0;
                width: 100vw; height: 100vh;
                border: none;
            }
        </style>
        </head><body>
        <iframe src="\(Self.escapeHTML(embedUrl))"
                allow="accelerometer; autoplay *; clipboard-write; encrypted-media; gyroscope; picture-in-picture *; web-share; fullscreen *"
                referrerpolicy="strict-origin-when-cross-origin"
                allowfullscreen>
        </iframe>
        </body></html>
        """
    }

    // MARK: - WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Block popups from video/embed players
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        // Nobody is watching this page to click OK, so the alert is dismissed
        // immediately — but it is logged, so an unknown page that starts nagging
        // (or a player stuck in a loop) leaves a trace instead of vanishing.
        NSLog("[FloatVideo] Page alert dismissed: \(message.prefix(200))")
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        // Answer "no". The page is untrusted and the user has no way to answer,
        // so the safe default is the one that does not let a script talk itself
        // into an action (resume, retry, navigate) it was not granted.
        NSLog("[FloatVideo] Page confirm denied: \(message.prefix(200))")
        completionHandler(false)
    }

    private func injectEmbedPlayerAutomation() {
        let js = """
        (function() {
            if (window.__floatVideoEmbedAutomationInstalled) return;
            window.__floatVideoEmbedAutomationInstalled = true;
            window.__floatOfflineDubHold = \(isOfflineDubEnabled && !offlineDubPlaybackAuthorized ? "true" : "false");

            try {
                document.documentElement.style.overflow = 'hidden';
                document.body.style.overflow = 'hidden';
                document.body.style.margin = '0';
                document.body.style.padding = '0';
                document.body.style.background = '#000';
            } catch(e) {}

            var attempts = 0;
            var maxAttempts = 30; // 30 * 250ms = 7.5 seconds

            // Keep checking after playback begins: mid-roll ads can arrive
            // minutes later, long after the initial autoplay timer exits.
            if (!window.__floatVideoEmbedAdSkipInstalled) {
                window.__floatVideoEmbedAdSkipInstalled = true;
                var lastSkipClick = 0;
                setInterval(function() {
                    if (document.querySelectorAll) {
                        var bars = document.querySelectorAll(
                            '.jw-controlbar, .jw-slider-time, .vjs-control-bar, .vjs-progress-control, ' +
                            '.plyr__controls, .plyr__progress, .dplayer-controller, .dplayer-bar-wrap, ' +
                            '.art-controls, .art-progress, .xgplayer-controls, .xgplayer-progress'
                        );
                        for (var b = 0; b < bars.length; b++) {
                            bars[b].style.setProperty('display', 'none', 'important');
                            bars[b].style.setProperty('pointer-events', 'none', 'important');
                        }
                    }
                    var skipBtn = document.querySelector(
                        '.jw-skip, .jw-ad-skip, .jw-skip-ad, .skip-ad, .video-ad-skip, .vjs-ad-skip-button,' +
                        'button[aria-label*="Bỏ qua" i], button[aria-label*="Skip Ad" i]'
                    );
                    if (!skipBtn || skipBtn.offsetParent === null || skipBtn.disabled ||
                        skipBtn.getAttribute('aria-disabled') === 'true') return;
                    var now = Date.now();
                    if (now - lastSkipClick < 500) return;
                    lastSkipClick = now;
                    try { skipBtn.click(); } catch(e) {}
                }, 250);
            }

            var timer = setInterval(function() {
                if (window.__floatOfflineDubHold) return;
                attempts++;

                // 1. If JWPlayer API is ready, trigger play
                if (window.jwplayer && typeof window.jwplayer === 'function') {
                    try {
                        var jw = window.jwplayer();
                        var state = jw.getState();
                        if (state === 'idle' || state === 'paused') {
                            jw.play();
                        }
                        if (state === 'playing' || state === 'buffering') {
                            clearInterval(timer);
                            return;
                        }
                    } catch(e) {}
                }

                // 2. If <video> element exists, try playing
                var v = document.querySelector('video');
                if (v) {
                    if (v.paused) {
                        v.muted = false;
                        v.play().catch(function() {
                            v.muted = true;
                            v.play().then(function() {
                                setTimeout(function() { v.muted = false; }, 400);
                            }).catch(function() {});
                        });
                    } else {
                        clearInterval(timer);
                        return;
                    }
                }

                // 3. Auto-click splash play buttons / verification buttons
                var playSelectors = [
                    '.jw-display-icon-display',
                    '.jw-display-icon-container',
                    '.jw-icon-display',
                    'button.jw-display-icon-container',
                    '.stream-player-button',
                    '.stream-resume-button',
                    '#verification button:not([hidden])',
                    '#verification-retry',
                    '.play-button',
                    '.vjs-big-play-button',
                    'button[aria-label*="Play" i]',
                    'button[aria-label*="Phát" i]',
                    'button[title*="Play" i]',
                    'button[title*="Phát" i]'
                ];

                for (var i = 0; i < playSelectors.length; i++) {
                    var btn = document.querySelector(playSelectors[i]);
                    if (btn && btn.offsetParent !== null && !btn.disabled) {
                        try { btn.click(); } catch(e) {}
                        break;
                    }
                }

                if (attempts >= maxAttempts) {
                    clearInterval(timer);
                }
            }, 250);
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    private func injectVideoMaximize(site: String, currentTime: Double) {
        // Thorough JS injection: recursively traverse DOM tree, hide all elements not in the video's ancestor chain
        let js = """
        (function() {
            const site = '\(Self.escapeJSString(site, quote: "'"))';
            const initialTime = \(currentTime);

            function findMainVideo() {
                const videos = Array.from(document.querySelectorAll('video'));
                if (videos.length === 0) return null;
                if (window.__floatVideoMainVideo && document.contains(window.__floatVideoMainVideo)) {
                    return window.__floatVideoMainVideo;
                }

                let mainVideo = videos[0];
                let maxArea = 0;
                videos.forEach(v => {
                    const rect = v.getBoundingClientRect();
                    const area = rect.width * rect.height;
                    if (area > maxArea) {
                        maxArea = area;
                        mainVideo = v;
                    }
                });
                window.__floatVideoMainVideo = mainVideo;
                return mainVideo;
            }

            function ensureFloatVideoStyle() {
                const styleId = '__floatvideo-style';
                let styleEl = document.getElementById(styleId);
                if (!styleEl) {
                    styleEl = document.createElement('style');
                    styleEl.id = styleId;
                    (document.head || document.documentElement).appendChild(styleEl);
                }

                const youtubeCss = site === 'youtube' ? `
                    ytd-app, ytd-watch-flexy, #page-manager, #content, #columns, #primary,
                    #primary-inner, #player, #player-container, #player-full-bleed-container,
                    #full-bleed-container, #movie_player, .html5-video-player,
                    .html5-video-container {
                        margin: 0 !important;
                        padding: 0 !important;
                        background: #000 !important;
                        transform: none !important;
                        filter: none !important;
                        transition: none !important;
                        overflow: hidden !important;
                    }
                    #secondary, #masthead-container, #below, #related, #chat,
                    .ytp-chrome-top, .ytp-chrome-bottom, .ytp-gradient-top,
                    .ytp-gradient-bottom, .ytp-ce-element, .ytp-pause-overlay,
                    .ytp-cards-teaser, .ytp-paid-content-overlay, [class*="ytp-ce-"] {
                        display: none !important;
                        visibility: hidden !important;
                        opacity: 0 !important;
                    }
                    /* Caption overlay: sibling of the <video>, so it must be
                       explicitly kept and painted ABOVE the fullscreen video
                       (same z-index, later in DOM order => on top). Our layout
                       forces the player to viewport size, so YouTube's own
                       caption-window positioning stays valid. */
                    .ytp-caption-window-container {
                        display: block !important;
                        visibility: visible !important;
                        opacity: 1 !important;
                        position: fixed !important;
                        left: 0 !important;
                        top: 0 !important;
                        width: 100vw !important;
                        height: 100vh !important;
                        z-index: 2147483647 !important;
                        pointer-events: none !important;
                        background: transparent !important;
                    }
                ` : '';

                styleEl.textContent = `
                    html, body {
                        margin: 0 !important;
                        padding: 0 !important;
                        overflow: hidden !important;
                        background: #000 !important;
                        width: 100% !important;
                        height: 100% !important;
                    }
                    .__floatvideo-ancestor {
                        display: block !important;
                        visibility: visible !important;
                        opacity: 1 !important;
                        position: static !important;
                        overflow: visible !important;
                        max-width: none !important;
                        max-height: none !important;
                        width: 100% !important;
                        height: 100% !important;
                        margin: 0 !important;
                        padding: 0 !important;
                        background: #000 !important;
                        transform: none !important;
                        filter: none !important;
                        transition: none !important;
                    }
                    video.__floatvideo-main-video {
                        position: fixed !important;
                        inset: 0 !important;
                        width: 100vw !important;
                        height: 100vh !important;
                        left: 0 !important;
                        top: 0 !important;
                        right: auto !important;
                        bottom: auto !important;
                        margin: 0 !important;
                        padding: 0 !important;
                        min-width: 0 !important;
                        min-height: 0 !important;
                        max-width: none !important;
                        max-height: none !important;
                        object-fit: contain !important;
                        object-position: center center !important;
                        background: #000 !important;
                        z-index: 2147483647 !important;
                    }
                    ${youtubeCss}
                `;
            }

            function hideNonAncestors(element, ancestors, mainVideo) {
                if (!element || !element.children) return;
                Array.from(element.children).forEach(child => {
                    if (child === mainVideo) return;
                    if (ancestors.has(child)) {
                        child.style.setProperty('display', '', 'important');
                        child.style.setProperty('visibility', 'visible', 'important');
                        child.style.setProperty('opacity', '1', 'important');
                        child.style.setProperty('position', 'static', 'important');
                        child.style.setProperty('overflow', 'visible', 'important');
                        child.style.setProperty('max-height', 'none', 'important');
                        child.style.setProperty('max-width', 'none', 'important');
                        child.style.setProperty('width', '100%', 'important');
                        child.style.setProperty('height', '100%', 'important');
                        child.style.setProperty('margin', '0', 'important');
                        child.style.setProperty('padding', '0', 'important');
                        hideNonAncestors(child, ancestors, mainVideo);
                    } else {
                        // Caption overlay DOM is a SIBLING of the <video>, not an
                        // ancestor — never hide it, or captions can't render.
                        // The youtubeCss block overlays it above the video.
                        var cls = (typeof child.className === 'string') ? child.className : '';
                        if (cls.indexOf('ytp-caption-window-container') >= 0 ||
                            cls.indexOf('caption-window') >= 0) {
                            return;
                        }
                        // The banner-blur overlay must stay painted above the
                        // picture; hiding it would make "hide page chrome" also
                        // disable the blur on every full-page player.
                        if (child.id === 'float-ad-blur') return;
                        child.style.setProperty('display', 'none', 'important');
                    }
                });
            }

            \(Self.smartFillJavaScript)
            \(Self.bannerBlurJavaScript)
            \(Self.audioBoostJavaScript)
            // Re-applied per load: the page may not have its <video> yet, and
            // the in-page `playing` listener retries once it does.
            window.__floatSetAudioBoost(\(Self.preferredAudioBoost.factor));
            \(Self.adAudioTapJavaScript)
            \(Self.aiDubbingJavaScript)
            function applySmartFill(video) {
                if (!video || !video.videoWidth || video.readyState < 2) return;
                if (site !== 'youtube') {
                    window.__floatInstallSmartFill(video);
                    if (window.__floatInstallAdBlur) window.__floatInstallAdBlur(video);
                    return;
                }
                var vr = video.videoWidth / video.videoHeight;
                var fr = window.innerWidth / Math.max(window.innerHeight, 1);
                video.style.setProperty('transform', 'none', 'important');
                video.style.setProperty('object-position', 'center center', 'important');
                video.style.setProperty('object-fit', vr > fr + 0.01 ? 'cover' : 'contain', 'important');
                window.__floatContentTop = 0;
                window.__floatFillLocked = true;
            }

            function applyLayout() {
                if (window.__floatVideoApplyingLayout) return false;


                const mainVideo = findMainVideo();
                if (!mainVideo) return false;
                window.__floatVideoApplyingLayout = true;

                try {
                    ensureFloatVideoStyle();

                    document.querySelectorAll('.__floatvideo-ancestor').forEach(el => {
                        el.classList.remove('__floatvideo-ancestor');
                    });
                    document.querySelectorAll('.__floatvideo-main-video').forEach(el => {
                        el.classList.remove('__floatvideo-main-video');
                    });

                    const ancestors = new Set();
                    let current = mainVideo;
                    while (current) {
                        ancestors.add(current);
                        if (current.classList) {
                            current.classList.add('__floatvideo-ancestor');
                        }
                        current = current.parentElement;
                    }

                    document.documentElement.style.cssText = 'margin:0!important;padding:0!important;overflow:hidden!important;background:#000!important;width:100%!important;height:100%!important;';
                    document.body.style.cssText = 'margin:0!important;padding:0!important;overflow:hidden!important;background:#000!important;width:100%!important;height:100%!important;';

                    hideNonAncestors(document.body, ancestors, mainVideo);

                    if (site === 'youtube') {
                        ancestors.forEach(el => {
                            if (el !== mainVideo) {
                                el.style.setProperty('transform', 'none', 'important');
                                el.style.setProperty('filter', 'none', 'important');
                                el.style.setProperty('transition', 'none', 'important');
                                el.style.setProperty('background', '#000', 'important');
                            }
                        });
                    }

                    mainVideo.classList.add('__floatvideo-main-video');
                    mainVideo.style.setProperty('position', 'fixed', 'important');
                    mainVideo.style.setProperty('inset', '0', 'important');
                    mainVideo.style.setProperty('width', '100vw', 'important');
                    mainVideo.style.setProperty('height', '100vh', 'important');
                    mainVideo.style.setProperty('left', '0', 'important');
                    mainVideo.style.setProperty('top', '0', 'important');
                    mainVideo.style.setProperty('object-fit', 'contain', 'important');
                    mainVideo.style.setProperty('object-position', 'center center', 'important');
                    applySmartFill(mainVideo);
                    mainVideo.style.setProperty('margin', '0', 'important');
                    mainVideo.style.setProperty('padding', '0', 'important');
                    mainVideo.style.setProperty('background', '#000', 'important');
                    mainVideo.setAttribute('playsinline', '');

                    if (!window.__floatVideoInitialSeekDone && initialTime > 0) {
                        try {
                            mainVideo.currentTime = initialTime;
                        } catch (e) {}
                        window.__floatVideoInitialSeekDone = true;
                    }

                    mainVideo.play().catch(() => {});
                    // Native WebKit controls duplicate the external VibeFloat
                    // strip and can be scaled by smart fill with the picture.
                    mainVideo.controls = false;
                    mainVideo.removeAttribute('controls');
                    if (!mainVideo.__floatControlsObserver) {
                        mainVideo.__floatControlsObserver = new MutationObserver(function() {
                            if (mainVideo.controls) {
                                mainVideo.controls = false;
                                mainVideo.removeAttribute('controls');
                            }
                        });
                        mainVideo.__floatControlsObserver.observe(mainVideo, {
                            attributes: true, attributeFilter: ['controls']
                        });
                    }
                    window.__floatVideoMainVideo = mainVideo;
                    return true;
                } finally {
                    window.__floatVideoApplyingLayout = false;
                }
            }

            window.__floatVideoApplyLayout = applyLayout;

            if (!window.__floatVideoResizeHookInstalled) {
                window.__floatVideoResizeHookInstalled = true;
                let delayedLayoutPass = null;
                window.addEventListener('resize', () => {
                    if (delayedLayoutPass) {
                        clearTimeout(delayedLayoutPass);
                    }
                    delayedLayoutPass = setTimeout(() => {
                        if (window.__floatVideoApplyLayout) {
                            window.__floatVideoApplyLayout();
                        }
                    }, 0);
                    setTimeout(() => {
                        if (window.__floatVideoApplyLayout) {
                            window.__floatVideoApplyLayout();
                        }
                    }, 120);
                });
            }

            return applyLayout();
        })();
        """
        webView.evaluateJavaScript(js) { [weak self] result, err in
            if let err = err {
                NSLog("[FloatVideo] JS injection error: \(err)")
            } else if let found = result as? Bool, found {
                self?.hasInjectedJS = true
                self?.youtubeFallbackWorkItem?.cancel()
                self?.youtubeFallbackWorkItem = nil
                if self?.shouldUseYouTubeFullPagePrimary() == true {
                    self?.hideLoadingOverlay()
                }
            }
        }
    }

    /// Installs a self-contained, idempotent in-page guard that auto-clicks
    /// YouTube's "Skip Ad" button the instant it becomes available.
    ///
    /// Why this is needed: the full-page isolation injection (`injectVideoMaximize`)
    /// hides every element that isn't an ancestor of the <video>, which includes
    /// YouTube's ad container and the Skip button it creates ~15s into an ad. The
    /// button still exists in the DOM, so `HTMLElement.click()` fires its handler
    /// even while it is `display:none` — no CSS/z-index/layout changes required.
    ///
    /// Limitation: this only reaches the same-origin YouTube watch page loaded via
    /// the `.fullPageInject` primary path. The cross-origin IFrame-API fallback
    /// (LocalHTTPServer) hosts YouTube in an <iframe> whose ad DOM is unreachable,
    /// so auto-skip does not apply there.
    private func injectAdSkip() {
        let js = """
        (function() {
            if (window.__floatVideoAdSkipInstalled) return 'already';
            window.__floatVideoAdSkipInstalled = true;
            window.__floatVideoAdSkipCount = window.__floatVideoAdSkipCount || 0;
            window.__floatVideoAdFFCount = window.__floatVideoAdFFCount || 0;

            // Covers old + modern YouTube ad-skip markup.
            var SKIP_SELECTORS = [
                '.ytp-ad-skip-button-modern',
                '.ytp-ad-skip-button',
                '.ytp-skip-ad-button',
                '.ytp-skip-ad button',
                '.ytp-ad-skip-button-slot button',
                '.ytp-ad-skip-button-container button'
            ];

            function findSkipButton() {
                for (var i = 0; i < SKIP_SELECTORS.length; i++) {
                    var el = document.querySelector(SKIP_SELECTORS[i]);
                    if (!el) continue;
                    // Only click a genuinely enabled skip control. YouTube only
                    // inserts the real button once skipping is allowed, but guard
                    // against disabled/aria-disabled states just in case.
                    if (el.disabled) continue;
                    if (el.getAttribute('aria-disabled') === 'true') continue;
                    return el;
                }
                return null;
            }

            // --- Trusted-click support -----------------------------------
            // YouTube now ignores untrusted (JS-synthesized) clicks on the
            // skip button, so the actual press is performed by the native app
            // as a real mouse event. To make that possible the button must be
            // renderable and hit-testable: reveal its ancestor chain (siblings
            // stay hidden — they carry their own inline display:none), keep
            // the button itself at 2% opacity so nothing is visible over the
            // video, then publish its center point for the Swift side, which
            // consumes it via the state poll and posts real mouse events.
            var revealed = [];

            function prepareForTrustedClick(btn) {
                try {
                    var node = btn;
                    var playerRoot = document.querySelector('#movie_player, .html5-video-player');
                    while (node && node !== document.body) {
                        // The guard can start at didCommit, before the layout
                        // pass marks video ancestors. Never rewrite the player
                        // root or hide it when the ad state ends.
                        if (node === playerRoot) break;
                        // The chain shared with the <video> is already visible
                        // and must keep receiving pointer events — skip it.
                        if (node.classList && node.classList.contains('__floatvideo-ancestor')) {
                            node = node.parentElement;
                            continue;
                        }
                        node.style.setProperty('display', 'block', 'important');
                        node.style.setProperty('visibility', 'visible', 'important');
                        if (node === btn) {
                            node.style.setProperty('opacity', '0.02', 'important');
                            node.style.setProperty('pointer-events', 'auto', 'important');
                            node.style.setProperty('position', 'relative', 'important');
                            node.style.setProperty('z-index', '2147483647', 'important');
                        } else {
                            node.style.setProperty('pointer-events', 'none', 'important');
                        }
                        if (revealed.indexOf(node) < 0) revealed.push(node);
                        node = node.parentElement;
                    }
                    var r = btn.getBoundingClientRect();
                    if (!r || r.width < 2 || r.height < 2) return null;
                    var x = r.left + r.width / 2;
                    var y = r.top + r.height / 2;
                    if (x < 1 || y < 1 || x > window.innerWidth - 1 || y > window.innerHeight - 1) return null;
                    return { x: x, y: y };
                } catch (e) { return null; }
            }

            function restoreRevealed() {
                while (revealed.length) {
                    var n = revealed.pop();
                    try {
                        n.style.setProperty('display', 'none', 'important');
                        n.style.removeProperty('pointer-events');
                        n.style.removeProperty('z-index');
                    } catch (e) {}
                }
                window.__floatVideoPendingTrustedClick = null;
            }

            // Per-ad-break state machine. Clicking Skip too early (before a real
            // user ever could, ~5s) makes YouTube's ad server treat the ad as
            // improperly delivered and RE-SERVE it — observed as the same break
            // looping 6-7 ads of 1-2s each. Strategy: instance 1 in a break keeps
            // the instant skip (most ads tolerate it); each detected re-serve
            // backs the next click off progressively past human timing.
            var lastAdT = 0;          // ad video currentTime last tick
            var instanceCount = 0;    // ad instances in the current logical break
            var clicks = 0;           // clicks for the current instance (max 2)
            var lastClickAt = 0;
            var ffDone = false;
            var coolOffUntil = 0;     // break-level circuit breaker
            var lastCoolInstance = 0; // instance that last triggered a cool-off
            var adGoneTicks = 0;      // consecutive ticks with no ad showing

            function resetInstance() {
                clicks = 0;
                lastClickAt = 0;
                ffDone = false;
            }

            window.__floatVideoAdSkipTimer = setInterval(function() {
                var player = document.querySelector('#movie_player, .html5-video-player');
                var adShowing = !!(player && (player.classList.contains('ad-showing') ||
                                              player.classList.contains('ad-interrupting')));
                if (!adShowing) {
                    restoreRevealed();
                    // Between re-serves YouTube drops out of ad state for a few
                    // hundred ms (observed in logs), so only treat the break as
                    // over after 3s without an ad. Real content stretches are
                    // minutes long; a re-serve gap never is.
                    if (++adGoneTicks >= 15 && instanceCount > 0) {
                        instanceCount = 0;
                        lastAdT = 0;
                        coolOffUntil = 0;
                        lastCoolInstance = 0;
                        resetInstance();
                    }
                    return;
                }
                var gapTicks = adGoneTicks;
                adGoneTicks = 0;

                var v = player.querySelector('video') || document.querySelector('video');
                if (!v) return;

                // New ad instance: break just started, ad state came back after
                // a short gap (re-serve), or the ad video's clock jumped
                // backwards (pod advance within continuous ad state).
                if (instanceCount === 0 || gapTicks > 0 || v.currentTime < lastAdT - 1.0) {
                    restoreRevealed();
                    instanceCount++;
                    resetInstance();
                }
                lastAdT = v.currentTime;

                var now = Date.now();
                if (now < coolOffUntil) return;
                if (instanceCount >= 5 && instanceCount > lastCoolInstance) {
                    // Pathological re-serve loop: pause once per new instance and
                    // let the ad play legitimately for a while before retrying,
                    // instead of locking out (or hammering) for the whole break.
                    lastCoolInstance = instanceCount;
                    coolOffUntil = now + 20000;
                    return;
                }

                // Re-served ads retain the observed human-timing backoff;
                // seeking them too early can make YouTube issue the same ad again.
                var minAdTime = (instanceCount === 1)
                    ? 0
                    : Math.min(5.2 + 4.0 * (instanceCount - 2), 30);
                if (v.currentTime < minAdTime) return;

                var btn = findSkipButton();
                if (!btn) {
                    // Only seek when YouTube itself reports an active ad and
                    // its media has a finite duration. The ad may still be
                    // re-served, so the break-level circuit breaker stays on.
                    if (!ffDone && player.classList.contains('ad-showing') &&
                        v.currentTime >= 1.2 && isFinite(v.duration) &&
                        v.duration > 5 && v.duration <= 120) {
                        restoreRevealed();
                        v.currentTime = Math.max(0, v.duration - 0.15);
                        window.__floatVideoAdFFCount++;
                        ffDone = true;
                    }
                    return;
                }

                if (clicks < 2) {
                    if (now - lastClickAt < 800) return;
                    // Free first shot: some player builds expose an internal
                    // skipAd(); harmless no-op elsewhere.
                    try { if (typeof player.skipAd === 'function') player.skipAd(); } catch (e) {}
                    var pt = prepareForTrustedClick(btn);
                    if (pt) {
                        // Native side consumes this via the state poll and posts
                        // a real (trusted) mouse click at these page coordinates.
                        var pending = window.__floatVideoPendingTrustedClick;
                        if (!pending || now - pending.ts > 1000) {
                            window.__floatVideoPendingTrustedClick = { x: pt.x, y: pt.y, ts: now };
                        }
                    } else {
                        // Could not obtain a hit-testable rect — fall back to the
                        // untrusted click (better than nothing).
                        btn.click();
                    }
                    lastClickAt = now;
                    if (++clicks === 1) window.__floatVideoAdSkipCount++;
                } else if (!ffDone && now - lastClickAt >= 1200) {
                    // 2 clicks ignored. Only for SKIPPABLE ads (button present):
                    // jump to just before the end and let 'ended' fire naturally,
                    // which the ad pipeline credits as a completion far more
                    // reliably than a hard seek to duration (fewer re-serves).
                    // Main content is never touched (adShowing gate).
                    if (isFinite(v.duration) && v.duration > 0.5) {
                        restoreRevealed();
                        v.currentTime = Math.max(0, v.duration - 0.15);
                        window.__floatVideoAdFFCount++;
                        ffDone = true;
                    }
                }
            }, 200);

            return 'installed';
        })();
        """
        webView.evaluateJavaScript(js) { [weak self] result, err in
            if let err = err {
                NSLog("[FloatVideo] Ad-skip guard injection error: \(err)")
            } else {
                self?.hasInjectedAdSkip = true
                // Only log fresh installs; the poll-driven self-heal re-invokes
                // this until the flag is visible, which would otherwise spam.
                if (result as? String) == "installed" {
                    NSLog("[FloatVideo] Ad-skip guard installed")
                }
            }
        }
    }

    /// Posts a real mouse down/up pair at the given page coordinates (CSS px,
    /// top-left origin) inside the WKWebView. Real AppKit events produce
    /// TRUSTED DOM events in WebKit — required because YouTube now ignores
    /// untrusted (JS-synthesized) clicks on the ad Skip button.
    private func performTrustedClick(pageX: Double, pageY: Double) {
        let bounds = webView.bounds
        guard pageX >= 1, pageY >= 1,
              pageX <= Double(bounds.width) - 1,
              pageY <= Double(bounds.height) - 1 else { return }

        // Page Y grows downward; AppKit view coordinates grow upward.
        let viewPoint = NSPoint(x: pageX, y: bounds.height - CGFloat(pageY))

        // Never click through our own overlay UI; the guard retries in <=2s,
        // by which time the hover bars are usually hidden again.
        if let container = webView.superview {
            let containerPoint = webView.convert(viewPoint, to: container)
            if titleBarView.alphaValue > 0.01, titleBarView.frame.contains(containerPoint) { return }
            if controlBarView.alphaValue > 0.01, controlBarView.frame.contains(containerPoint) { return }
        }

        let windowPoint = webView.convert(viewPoint, to: nil)
        let time = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: windowPoint,
                                            modifierFlags: [], timestamp: time,
                                            windowNumber: windowNumber, context: nil,
                                            eventNumber: 0, clickCount: 1, pressure: 1),
              let up = NSEvent.mouseEvent(with: .leftMouseUp, location: windowPoint,
                                          modifierFlags: [], timestamp: time + 0.05,
                                          windowNumber: windowNumber, context: nil,
                                          eventNumber: 0, clickCount: 1, pressure: 1) else { return }

        isPostingSyntheticClick = true
        sendEvent(down)
        sendEvent(up)
        isPostingSyntheticClick = false
        NSLog("[FloatVideo] Trusted click at page (\(Int(pageX)), \(Int(pageY)))")
    }

    // MARK: - Window Actions

    func show() {
        titleBarView.alphaValue = 1.0
        // Restore vibe-coding prefs before first paint.
        applyPreferredGhostOnOpen()
        mountControlStrip()
        // Restore the last preset on every open, fitting it to this display.
        let preset = Self.savedSizePreset
        applySizePreset(preset, fromUser: false)
        if !isPinned { placeAwayFromCode() }
        ensureVisibleOnScreen()
        syncControlStrip(animated: false)
        refreshWatchAssistButtonStyles()
        // Never activate or become key — the IDE must keep the keyboard.
        self.orderFrontRegardless()
        showControls()
        scheduleHideControls(after: Self.chromeHideDelay)
        let controlsHintKey = "FloatVideoDidShowControlsHint"
        if !UserDefaults.standard.bool(forKey: controlsHintKey) {
            UserDefaults.standard.set(true, forKey: controlsHintKey)
            showHUD("Di chuột vào video để hiện điều khiển", duration: 3.2)
        }
        // Force another front pass after AppKit settles collection/space membership.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.ensureVisibleOnScreen()
            self.enforcePinnedOrigin()
            self.orderFrontRegardless()
            if self.isHovering {
                self.setStripChromeVisible(true, animated: false)
            }
            NSLog("[FloatVideo] Window shown frame=\(NSStringFromRect(self.frame)) alpha=\(self.alphaValue) ghost=\(self.isGhostMode) screen=\(self.screen?.localizedName ?? "nil")")
        }
        if !isPinned { vibeDock.attach(self) }
        VibeNowPlaying.install(target: self)
        startCursorPolling()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { [weak self] in
            self?.hideLoadingOverlay()
        }
    }

    /// Keep the player on a real visible display — never leave it off-screen after dock/restore.
    func ensureVisibleOnScreen() {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }

        let pad: CGFloat = 8
        var frame = self.frame
        if frame.width < minSize.width || frame.height < 80 || frame.width.isNaN || frame.height.isNaN {
            let w = max(minSize.width, 420)
            frame.size = NSSize(width: w, height: w / max(videoAspectRatio, 0.2))
        }

        // A locked window stays exactly where the user pinned it. Only recover
        // it if that display has gone away and the window is entirely offscreen.
        if isPinned && screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
            return
        }

        let intersects = screens.contains { $0.visibleFrame.intersects(frame.insetBy(dx: 24, dy: 24)) }
        let screen = (intersects ? (self.screen ?? NSScreen.main) : nil) ?? NSScreen.main ?? screens[0]
        let vis = screen.visibleFrame

        if frame.width > vis.width - pad * 2 {
            frame.size.width = max(minSize.width, vis.width - pad * 2)
            frame.size.height = frame.size.width / max(videoAspectRatio, 0.2)
        }
        if frame.height > vis.height - VibePlacer.stripHeight - pad * 2 {
            frame.size.height = max(minSize.height, vis.height - VibePlacer.stripHeight - pad * 2)
            frame.size.width = frame.size.height * max(videoAspectRatio, 0.2)
        }

        frame.origin.x = min(max(frame.origin.x, vis.minX + pad), vis.maxX - frame.width - pad)
        frame.origin.y = min(max(frame.origin.y, vis.minY + pad + VibePlacer.stripHeight), vis.maxY - frame.height - pad)

        if frame != self.frame {
            if isPinned { lockedOrigin = frame.origin }
            setFrame(frame, display: true)
            syncControlStrip(animated: false)
        }

        // Never open invisibly soft — coding-safe soft opacity still stays readable.
        if alphaValue < 0.45 {
            alphaValue = 0.72
        }
    }

    private func startCursorPolling() {
        cursorPollTimer?.invalidate()
        // The IDE stays frontmost, so it resets the cursor on every move.
        // A short poll plus a post-event update wins that race while the
        // pointer is over VibeFloat.
        cursorPollTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.pollCursorPosition()
            self?.syncFastCursorTimer()
        }
        if cursorEventMonitor == nil {
            cursorEventMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
                DispatchQueue.main.async { self?.refreshHoverCursor() }
            }
        }
    }

    private func syncFastCursorTimer() {
        let mouse = NSEvent.mouseLocation
        let nearStrip = (controlStrip?.alphaValue ?? 0) > 0.4
            && controlStrip?.frame.insetBy(dx: -8, dy: -8).contains(mouse) == true
        let nearVideo = !isGhostMode && frame.insetBy(dx: -8, dy: -8).contains(mouse)
        guard nearStrip || nearVideo else {
            cursorFastTimer?.invalidate()
            cursorFastTimer = nil
            return
        }
        guard cursorFastTimer == nil else { return }
        cursorFastTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.refreshHoverCursor()
        }
    }

    /// Sets the cursor only while the pointer is over this player. Leaving the
    /// window alone keeps the front app's cursor.
    private func refreshHoverCursor() {
        let mouse = NSEvent.mouseLocation
        if let strip = controlStrip, strip.alphaValue > 0.4, strip.frame.contains(mouse) {
            updateStripPointerFeedback()
            return
        }
        guard !isGhostMode, frame.contains(mouse) else { return }
        let local = convertPoint(fromScreen: mouse)
        if isOnPlaybackBar(local) {
            cursorForPlaybackBar(at: local).set()
            return
        }
        let edge = detectResizeEdge(at: local)
        (edge == .none ? NSCursor.arrow : cursorForEdge(edge)).set()
    }

    private func pollCursorPosition() {
        let hoveringChrome = isPointerOverChrome()

        if isResizing || isInteractingWithChrome {
            // Keep chrome visible during resize / scrubber drag; freeze hide.
            keepChromeVisibleForInteraction()
            cursorWasInside = true
            return
        }

        if hoveringChrome {
            cursorWasInside = true
            hideTimer?.cancel()
            hideTimer = nil
            if !isHovering {
                showControls()
            } else {
                // Strip shown: never leave ignoresMouseEvents=true under the cursor.
                ensureStripAcceptsMouseWhileVisible()
            }
            updateStripPointerFeedback()
        } else if cursorWasInside {
            cursorWasInside = false
            hideHoverTip()
            if isHovering { scheduleHideControls(after: Self.chromeHideDelay) }
        }
    }

    /// The strip is a non-key panel, so AppKit will not show view tooltips or
    /// change the cursor while the IDE stays frontmost. Do both ourselves.
    func updateStripPointerFeedback() {
        guard let strip = controlStrip, let content = strip.contentView else {
            hideHoverTip()
            return
        }
        let local = strip.convertPoint(fromScreen: NSEvent.mouseLocation)
        guard content.bounds.contains(local) else {
            hideHoverTip()
            return
        }
        let edge = ControlBarView.edgeWidth
        if local.x < edge || local.x > content.bounds.width - edge {
            NSCursor.resizeLeftRight.set()
            hideHoverTip()
            return
        }
        var control: NSView?
        var view: NSView? = content.hitTest(local)
        while let current = view, current !== content {
            if !current.isHidden, ControlBarView.isInteractive(current) {
                control = current
                break
            }
            view = current.superview
        }
        guard let control else {
            (isPinned ? NSCursor.arrow : NSCursor.openHand).set()
            hideHoverTip()
            return
        }
        NSCursor.pointingHand.set()
        guard let text = control.toolTip, !text.isEmpty else {
            hideHoverTip()
            return
        }
        if hoverTipAnchor !== control {
            hoverTipAnchor = control
            hoverTipSince = Date()
            hideHoverTip(keepAnchor: true)
            return
        }
        guard let since = hoverTipSince, Date().timeIntervalSince(since) >= 0.35 else { return }
        showHoverTip(text, anchor: control)
    }

    private func showHoverTip(_ text: String, anchor: NSView) {
        guard let strip = controlStrip else { return }
        let label = hoverTipLabel ?? NSTextField(labelWithString: "")
        hoverTipLabel = label
        label.stringValue = text
        label.font = VibeTheme.Font.label
        label.textColor = VibeTheme.icon
        label.alignment = .center
        label.drawsBackground = false
        label.isBezeled = false
        label.isBordered = false
        let width = min(240, ceil((text as NSString).size(withAttributes: [.font: label.font as Any]).width) + 18)
        let height: CGFloat = 22
        label.frame = NSRect(x: 0, y: 3, width: width, height: 16)
        let panel: NSPanel
        if let existing = hoverTip {
            panel = existing
        } else {
            let created = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            created.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)) + 4)
            created.isOpaque = false
            created.backgroundColor = .clear
            created.hasShadow = true
            created.ignoresMouseEvents = true
            created.hidesOnDeactivate = false
            created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            let bg = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
            bg.wantsLayer = true
            bg.layer?.backgroundColor = VibeTheme.chromeStrong.cgColor
            bg.layer?.cornerRadius = VibeTheme.Radius.sm
            created.contentView = bg
            hoverTip = created
            panel = created
        }
        if label.superview == nil {
            panel.contentView?.addSubview(label)
        }
        panel.contentView?.frame.size = NSSize(width: width, height: height)
        let anchorOnScreen = strip.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        panel.setFrame(NSRect(
            x: anchorOnScreen.midX - width / 2,
            y: anchorOnScreen.maxY + 6,
            width: width,
            height: height
        ), display: true)
        panel.orderFrontRegardless()
    }

    private func hideHoverTip(keepAnchor: Bool = false) {
        hoverTip?.orderOut(nil)
        if !keepAnchor {
            hoverTipAnchor = nil
            hoverTipSince = nil
        }
    }

    /// True while the user is actively using strip controls (scrubber, etc.).
    private var isInteractingWithChrome: Bool {
        scrubberView?.isDragging == true
    }

    /// Cursor over video, strip, or the small gap between them — keep chrome stable.
    private func isPointerOverChrome(at point: NSPoint = NSEvent.mouseLocation) -> Bool {
        if isResizing || isInteractingWithChrome { return true }
        // Inflate by stripGap so the band between video and strip does not thrash hide/show.
        let pad = VibePlacer.stripGap + 4
        if frame.insetBy(dx: -2, dy: -pad).contains(point) { return true }
        if let strip = controlStrip, strip.frame.insetBy(dx: -2, dy: -pad).contains(point) {
            return true
        }
        return false
    }

    private func keepChromeVisibleForInteraction() {
        hideTimer?.cancel()
        hideTimer = nil
        if !isHovering { showControls() }
        else { ensureStripAcceptsMouseWhileVisible() }
    }

    /// Called from the external strip panel so hover/click keeps chrome visible.
    func noteStripInteraction() {
        cursorWasInside = true
        keepChromeVisibleForInteraction()
    }

    /// Strip mouseExited — only start the long idle hide if pointer left video+strip.
    func noteStripPointerExited() {
        if isResizing || isInteractingWithChrome { return }
        if isPointerOverChrome() {
            hideTimer?.cancel()
            hideTimer = nil
            return
        }
        scheduleHideControls(after: Self.chromeHideDelay)
    }

    /// While chrome is up, the strip must receive mouse (grips/buttons) — never click-through.
    private func ensureStripAcceptsMouseWhileVisible() {
        guard isHovering, let strip = controlStrip else { return }
        if strip.ignoresMouseEvents {
            strip.ignoresMouseEvents = false
            strip.acceptsMouseMovedEvents = true
        }
        if strip.alphaValue < 0.95 {
            strip.alphaValue = 1
        }
    }

    /// First load hides the overlay and resumes there. A later episode has
    /// already removed the overlay, so didFinish used to return without ever
    /// clearing the suspend — next episode loaded and stayed silent.
    private func scheduleResumeIfOverlayAlreadyGone() {
        guard loadingOverlay == nil else { return }
        let generation = loadGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self = self, self.loadGeneration == generation else { return }
            self.resumeMediaPlayback()
        }
    }

    private func resumeMediaPlayback() {
        guard !isOfflineDubEnabled || offlineDubPlaybackAuthorized else { return }
        webView.setAllMediaPlaybackSuspended(false) { [weak self] in
            guard let self = self else { return }
            guard !self.isOfflineDubEnabled || self.offlineDubPlaybackAuthorized else { return }
            self.triggerPlayback()
            let generation = self.loadGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self = self, self.loadGeneration == generation else { return }
                self.suppressWatchAssist = false
            }
        }
    }

    private func hideLoadingOverlay() {
        resumeMediaPlayback()
        guard let overlay = loadingOverlay else {
            startUpdateTimer()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            overlay.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.loadingOverlay?.removeFromSuperview()
            self?.loadingOverlay = nil
            self?.startUpdateTimer()
            // After loading completes, hide title bar if mouse is not inside the window
            if !(self?.isHovering ?? false) {
                self?.hideControls()
            }
        })
    }

    private func triggerPlayback() {
        guard !isOfflineDubEnabled || offlineDubPlaybackAuthorized else { return }
        let wantMute = userWantsMute
        let mutedJSBool = wantMute ? "true" : "false"
        let ytMuteCmd = wantMute ? "'mute'" : "'unmute'"
        // Never force volume 1.0 while ducked — keep the ducked level.
        let playVol: Double = {
            if wantMute { return 0 }
            if isDucked {
                return volumeSlider?.doubleValue ?? max(0.05, preDuckVolume * 0.2)
            }
            let chosen = volumeSlider?.doubleValue ?? 1
            return chosen > 0 ? chosen : 1
        }()
        let jwVol = Int(playVol * 100)
        let js = """
        (function() {
            var wantMute = \(mutedJSBool);
            var playVol = \(playVol);
            document.querySelectorAll('video').forEach(function(v) {
                v.muted = wantMute;
                if (!wantMute) v.volume = playVol;
                try { v.playbackRate = \(playbackRate); } catch (e) {}
                v.play().catch(function() {});
            });
            if (window.jwplayer && typeof window.jwplayer === 'function') {
                try {
                    var jw = window.jwplayer();
                    jw.setMute(wantMute);
                    if (!wantMute) jw.setVolume(\(jwVol));
                    if (jw.getState() !== 'playing') jw.play();
                } catch(e) {}
            }
            if (window.playerCommand) {
                window.playerCommand(\(ytMuteCmd));
                if (!wantMute) window.playerCommand('volume', playVol);
                window.playerCommand('play');
            }
            var iframe = document.querySelector('iframe');
            if (iframe) {
                try {
                    iframe.contentWindow.postMessage(JSON.stringify({event:'command',func:'playVideo',args:[]}), '*');
                } catch(e) {}
            }
            if (window.__floatControlEmbeddedMedia) window.__floatControlEmbeddedMedia('play');
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.isPlaying,
                  !self.isOfflineDubEnabled || self.offlineDubPlaybackAuthorized else { return }
            self.webView.evaluateJavaScript(js, completionHandler: nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.isPlaying,
                  !self.isOfflineDubEnabled || self.offlineDubPlaybackAuthorized else { return }
            self.webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "aiDub" {
            guard let payload = message.body as? [String: Any] else { return }
            let action = payload["action"] as? String ?? "speak"
            if action == "debug" {
                NSLog("[AIDub] JS %@", payload["text"] as? String ?? "")
                return
            }
            if action == "speak", let text = payload["text"] as? String {
                self.lastTextTrackDubbedAt = Date()
                let duration = (payload["duration"] as? NSNumber)?.doubleValue ?? 0
                speakAIDubText(text, duration: duration)
            } else if action == "prefetch", let text = payload["text"] as? String {
                prefetchAIDubText(text)
            } else if action == "prefetchBatch", let texts = payload["texts"] as? [String] {
                prefetchBatchAIDubTexts(texts)
            } else if action == "offlineTimeline", let rawCues = payload["cues"] as? [[String: Any]] {
                if ProcessInfo.processInfo.environment["VIBEFLOAT_DUB_DEBUG"] == "1" {
                    NSLog("[OfflineDub] received JS timeline payload cues=%d", rawCues.count)
                }
                let cues = rawCues.compactMap { item -> OfflineDubSession.Cue? in
                    guard let start = (item["start"] as? NSNumber)?.doubleValue,
                          let end = (item["end"] as? NSNumber)?.doubleValue,
                          let text = item["text"] as? String else { return nil }
                    return OfflineDubSession.Cue(start: start, end: end, text: text)
                }
                prepareOfflineDubbing(cues)
            } else if action == "stop" {
                stopAIDub()
            }
            return
        }
        if message.name == "adAudio" {
            guard let payload = message.body as? String else { return }
            hearAdvertisement(payload)
            return
        }
        if message.name == "adSkip" {
            guard let payload = message.body as? [String: Any],
                  let x = (payload["x"] as? NSNumber)?.doubleValue,
                  let y = (payload["y"] as? NSNumber)?.doubleValue else { return }
            performTrustedClick(pageX: x, pageY: y)
            return
        }
        guard message.name == "adWatch" else { return }
        if let status = message.body as? String, status == "blocked" {
            NSLog("[FloatVideo] Ad scan could not read the video frame")
            directFrameUnreadable = true
            return
        }
        guard loadingStrategy == .directVideo,
              let payload = message.body as? [String: Any],
              let imagePayload = payload["image"] as? String,
              let sampledTime = (payload["time"] as? NSNumber)?.doubleValue else { return }
        guard !interstitialScanBusy else { return }
        interstitialScanBusy = true
        let generation = loadGeneration
        interstitialQueue.async { [weak self] in
            let image = Self.image(fromDataURL: imagePayload)
            let visual = image?.cgImage(forProposedRect: nil, context: nil, hints: nil).map(Self.looksLikeSlotFrame) ?? false
            // The accurate recognizer, not the fast one. Measured on the actual
            // creative: over the page's 280x158 JPEG the fast pass returns a
            // single meaningless box, while the accurate pass still reads the
            // giant `9922` wordmark. That is why this path never skipped a 9922
            // spot no matter how many times it sampled.
            let hits = image.map { Self.readTextHits(in: $0, accurate: true) } ?? []
            let text = hits.map(\.text).joined(separator: " ")
            let kind = AdClassifier.kind(for: hits)
            let textual = kind == .splash || Self.looksLikeInterstitialAd(text)
            if Self.adTraceEnabled {
                NSLog("[FloatVideo] adtrace direct=%@ visual=%@ kind=%@ text=%@",
                      String(format: "%.1f", sampledTime), String(visual),
                      String(describing: kind), String(text.prefix(70)))
                DispatchQueue.main.async { [weak self] in self?.tracePlayerTimeline(tag: "direct") }
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.interstitialScanBusy = false
                guard self.loadGeneration == generation,
                      (self.playbackElapsed == 0 || abs(self.playbackElapsed - sampledTime) < 4) else { return }
                let now = Date()
                let repeatedVisual = visual && self.lastVisualAdAt.map { now.timeIntervalSince($0) < 1.5 } == true
                self.lastVisualAdAt = visual ? now : nil
                if repeatedVisual || textual {
                    self.lastAdDetectionAt = now
                    NSLog("[FloatVideo] Interstitial ad frame visual=\(visual) kind=\(kind) text=\(text.prefix(80))")
                    self.skipInterstitialAd()
                    if kind == .splash { self.forceAdCover(fullFrame: true) }
                } else if kind == .banner {
                    // A sponsor line stays for the whole episode: cover it, never
                    // seek on it.
                    self.lastAdDetectionAt = now
                    self.forceAdCover(fullFrame: false)
                } else if let lastAd = self.lastAdDetectionAt,
                          now.timeIntervalSince(lastAd) > 3 {
                    self.interstitialSkipOrigin = nil
                    self.didAnnounceInterstitialSkip = false
                    self.lastAdDetectionAt = nil
                    self.clearAdCover()
                }
            }
        }
    }

    private static func image(fromDataURL payload: String) -> NSImage? {
        guard let comma = payload.firstIndex(of: ",") else { return nil }
        let b64 = String(payload[payload.index(after: comma)...])
        guard let data = Data(base64Encoded: b64) else { return nil }
        return NSImage(data: data)
    }

    /// Slot spots are gold + red character + neon green at once. A drama frame is not.
    private static func looksLikeSlotFrame(_ image: CGImage) -> Bool {
        let rep = NSBitmapImageRep(cgImage: image)
        var gold = 0, red = 0, neon = 0, n = 0
        let step = 3
        var y = 0
        while y < rep.pixelsHigh {
            var x = 0
            while x < rep.pixelsWide {
                if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                    let r = c.redComponent, g = c.greenComponent, b = c.blueComponent
                    n += 1
                    if r > 0.62 && g > 0.42 && b < 0.45 { gold += 1 }
                    if r > 0.55 && g < 0.42 && b < 0.45 { red += 1 }
                    if g > 0.58 && r < 0.5 && g > r + 0.16 { neon += 1 }
                }
                x += step
            }
            y += step
        }
        guard n > 20 else { return false }
        let gn = Double(gold) / Double(n)
        let rn = Double(red) / Double(n)
        let nn = Double(neon) / Double(n)
        return gn > 0.07 && rn > 0.04 && nn > 0.03
    }

    /// OCR with the line boxes kept. The geometry is what separates a giant
    /// wordmark from a caption line, so the boxes are the useful part and the
    /// flat string is only a convenience for logging.
    private static func readTextHits(in image: NSImage, accurate: Bool = false) -> [AdTextHit] {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = accurate ? .accurate : .fast
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["vi-VN", "en-US"]
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        try? handler.perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            return AdTextHit(text: text, box: observation.boundingBox)
        }
    }

    private static func readText(in image: NSImage, accurate: Bool = false) -> String {
        readTextHits(in: image, accurate: accurate).map(\.text).joined(separator: " ")
    }

    private func scanEmbedAdIfNeeded() {
        // A provider's own full-page player (VTVgo and friends) hides its spots
        // inside the stream, so the rendered frame is the only place to see
        // them. YouTube already reports ad state to the in-page guard, so it is
        // deliberately left out of this scan.
        let fullPageMovie = loadingStrategy == .fullPageInject && currentSite != "youtube"
        let isMovie = movieContext != nil || loadingStrategy == .directVideo
        let wantsRenderScan = loadingStrategy == .siteEmbed || fullPageMovie || directFrameUnreadable || isMovie
        let recentAd = lastAdDetectionAt.map { Date().timeIntervalSince($0) < 12 } == true
        let opening = playbackDuration < 30 || playbackElapsed < 180
        let closing = playbackDuration > 360 && playbackElapsed > playbackDuration - 200
        let interval: TimeInterval = (recentAd || opening || closing) ? 0.4 : (isPlaying ? 1.4 : 2.8)
        guard wantsRenderScan, !interstitialScanBusy,
              Date().timeIntervalSince(lastEmbedAdScanAt) >= interval else { return }
        interstitialScanBusy = true
        lastEmbedAdScanAt = Date()
        embedVisualScans += 1
        let scanIndex = embedVisualScans
        let generation = loadGeneration
        let config = WKSnapshotConfiguration()
        let cap: CGFloat = 720
        let width = min(webView.bounds.width * 1.5, cap)
        if width > 0 {
            config.snapshotWidth = NSNumber(value: Double(width))
        }
        webView.takeSnapshot(with: config) { [weak self] image, error in
            guard let self = self else { return }
            guard self.loadGeneration == generation, let image = image, error == nil else {
                self.interstitialScanBusy = false
                return
            }
            self.interstitialQueue.async { [weak self] in
                guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    DispatchQueue.main.async { self?.interstitialScanBusy = false }
                    return
                }
                let splash = Self.looksLike9922Splash(cg)
                let slot = Self.looksLikeSlotFrame(cg)
                // OCR now runs for every strategy. Measured on the real creative:
                // the colour heuristic keeps only two of its three signals once
                // the frame is downscaled to the 420/640 px this app samples (the
                // neon ornament reads 0.023 against its 0.03 threshold), so the
                // brand has to be read out of the frame. The line geometry is what
                // then separates a spot to skip from a sponsor line to blur — and
                // that distinction is exactly what makes reading the frame safe on
                // a full-page provider too, since a banner never causes a seek.
                let hits = Self.readTextHits(in: image, accurate: true)
                let text = hits.map(\.text).joined(separator: " ")
                let kind = AdClassifier.kind(for: hits)
                let measureBars = !splash && !slot && kind != .splash && (scanIndex % 3 == 0)
                let band = measureBars ? Self.renderedLetterbox(cg) : nil
                if Self.adTraceEnabled {
                    let bandText = band.map { String(format: "%.3f..%.3f", $0.0, $0.1) } ?? "nil"
                    NSLog("[FloatVideo] adtrace scan=%@ splash=%@ slot=%@ kind=%@ band=%@ text=%@",
                          String(scanIndex), String(splash), String(slot), String(describing: kind),
                          bandText, String(text.prefix(70)))
                    DispatchQueue.main.async { [weak self] in self?.tracePlayerTimeline(tag: "snapshot") }
                }
                if let band = band {
                    DispatchQueue.main.async {
                        self?.noteRenderedLetterbox(top: band.0, bottom: band.1, generation: generation)
                    }
                }
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.interstitialScanBusy = false
                    guard self.loadGeneration == generation else { return }
                    let now = Date()
                    if splash || slot || kind == .splash {
                        self.lastAdDetectionAt = now
                        NSLog("[FloatVideo] Embedded movie ad splash=\(splash) slot=\(slot) kind=\(kind) text=\(text.prefix(80))")
                        self.skipInterstitialAd()
                        if kind == .splash { self.forceAdCover(fullFrame: true) }
                    } else if kind == .banner {
                        // The sponsor line is on screen for the whole episode:
                        // cover it, and never seek on it.
                        self.lastAdDetectionAt = now
                        self.forceAdCover(fullFrame: false)
                    } else if let lastAd = self.lastAdDetectionAt,
                              now.timeIntervalSince(lastAd) > 120 {
                        self.interstitialSkipOrigin = nil
                        self.didAnnounceInterstitialSkip = false
                        self.lastAdDetectionAt = nil
                        if !self.isManualBannerBlurEnabled {
                            self.clearAdCover()
                        }
                    }
                }
            }
        }
    }

    /// Black bands in a rendered frame. Nil while the picture itself is dark,
    /// so a night scene does not clear a crop already in effect.
    ///
    /// The row test asks for a *majority* of black, not all of it: the sponsor
    /// line and the channel logo are burned into the middle of the top bar, and
    /// an all-black requirement stopped the scan on that ink, leaving the bars
    /// (and the banner with them) uncropped for exactly the streams that need
    /// it most. The middle-row check still keeps a dark scene from cropping.
    private static func renderedLetterbox(_ image: CGImage) -> (Double, Double)? {
        let rep = NSBitmapImageRep(cgImage: image)
        let width = rep.pixelsWide
        let height = rep.pixelsHigh
        guard width > 80, height > 60 else { return nil }
        func rowDark(_ y: Int) -> Bool {
            guard y >= 0, y < height else { return false }
            var dark = 0, count = 0
            let step = max(2, width / 80)
            var x = Int(Double(width) * 0.08)
            let end = Int(Double(width) * 0.92)
            while x < end {
                if let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                    count += 1
                    let light = color.redComponent * 0.2126
                        + color.greenComponent * 0.7152
                        + color.blueComponent * 0.0722
                    if light < 22.0 / 255.0 { dark += 1 }
                }
                x += step
            }
            return count > 0 && Double(dark) / Double(count) >= 0.5
        }
        let maxBar = Int(Double(height) * 0.28)
        // Same edge tolerance as the in-page scanner: one bright row at the very
        // top or bottom edge (a window or video border) must not stop the scan
        // before it starts, or the bars stay on screen.
        let minBar = max(3, height / 48)
        func barRun(from start: Int) -> Int {
            var y = start
            while y < maxBar, rowDark(y) { y += 1 }
            return y
        }
        func barRunUp(from start: Int) -> Int {
            var y = start
            while y > height - 1 - maxBar, rowDark(y) { y -= 1 }
            return y
        }
        var top = 0
        for lead in 0..<3 {
            let end = barRun(from: lead)
            if end - lead >= minBar, end > top { top = end }
        }
        var bottom = height - 1
        for trail in 0..<3 {
            let start = height - 1 - trail
            let end = barRunUp(from: start)
            if start - end >= minBar, end < bottom { bottom = end }
        }
        let mid = [0.4, 0.5, 0.6].map { Int(Double(height) * $0) }
        if !mid.contains(where: { !rowDark($0) }) { return nil }
        let upper = Double(top) / Double(height)
        let lower = Double(bottom + 1) / Double(height)
        let thick = Double(minBar) / Double(height)
        // A band on *either* edge is a bar, not only a matching pair. Measured
        // on the reported stream: the black band ran across the top with
        // picture all the way to the last row, so the old two-sided test never
        // fired and the band stayed on screen. Centring the picture is what
        // keeps a dark top of a night scene from being cropped.
        let hasTop = upper >= thick
        let hasBottom = (1 - lower) >= thick
        let centred = abs((upper + lower) / 2 - 0.5) <= 0.12
        if (hasTop || hasBottom), centred, lower - upper >= 0.55 {
            return (upper, lower)
        }
        return (0, 1)
    }

    /// Blur the ad region from the native side.
    ///
    /// The in-page detector can only read the video's own pixels, so a spot
    /// drawn as page markup, or served inside a cross-origin player frame, is
    /// invisible to it — and detection has to work there too. Every strategy
    /// installs `window.__floatForceAdCover` in its frames, so one call reaches
    /// the page whatever the ad actually is. `fullFrame` covers a splash;
    /// otherwise only the top band (a sponsor line) is blurred.
    private(set) var isManualBannerBlurEnabled = false

    private func forceAdCover(fullFrame: Bool, permanent: Bool = false) {
        adCoverOn = true
        let fullFlag = fullFrame ? "true" : "false"
        let height = fullFrame ? "100%" : "calc(38px + 16%)"
        let js = """
        (function() {
            function apply() {
                if (window.__floatForceAdCover) {
                    window.__floatForceAdCover(true, \(fullFlag), \(permanent ? "true" : "false"));
                    return;
                }
                var el = document.getElementById('float-ad-blur');
                if (!el && document.body) {
                    el = document.createElement('div');
                    el.id = 'float-ad-blur';
                    el.setAttribute('aria-hidden', 'true');
                    document.body.appendChild(el);
                }
                if (!el) return;
                el.style.cssText = 'position:fixed;left:0;right:0;top:0;height:\(height);z-index:2147483647;pointer-events:none;opacity:1;background:rgba(0,0,0,0.58);backdrop-filter:blur(28px) saturate(0.7);-webkit-backdrop-filter:blur(28px) saturate(0.7);transform:translateZ(1px);';
            }
            apply();
            [250, 750, 1500].forEach(function(ms) { setTimeout(apply, ms); });
        })();
        """
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    private func clearAdCover() {
        guard adCoverOn, !isManualBannerBlurEnabled else { return }
        adCoverOn = false
        webView?.evaluateJavaScript("window.__floatForceAdCover && window.__floatForceAdCover(false)",
                                   completionHandler: nil)
    }

    @objc func toggleManualBannerBlur() {
        isManualBannerBlurEnabled = !isManualBannerBlurEnabled
        if isManualBannerBlurEnabled {
            forceAdCover(fullFrame: false, permanent: true)
            showHUD("Làm mờ banner: Đang bật")
        } else {
            clearAdCover()
            showHUD("Làm mờ banner: Đã tắt")
        }
    }

    private func noteRenderedLetterbox(top: Double, bottom: Double, generation: Int) {
        guard loadGeneration == generation else { return }
        let same = letterboxCandidateTop.map { abs($0 - top) <= 2.0 / 72 } == true
            && letterboxCandidateBottom.map { abs($0 - bottom) <= 2.0 / 72 } == true
        if same {
            letterboxHits += 1
        } else {
            letterboxCandidateTop = top
            letterboxCandidateBottom = bottom
            letterboxHits = 1
        }
        guard letterboxHits >= 3 else { return }
        if let currentTop = letterboxTop, let currentBottom = letterboxBottom,
           abs(currentTop - top) <= 1.0 / 72, abs(currentBottom - bottom) <= 1.0 / 72 {
            return
        }
        letterboxTop = top
        letterboxBottom = bottom
        let js = "window.__floatApplyHostLetterbox && window.__floatApplyHostLetterbox(\(top), \(bottom))"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    /// The supplied ad opens with a pale, full-width search card between a
    /// dark top edge and vivid red/gold game artwork. The strict combination
    /// is strong enough to act on the first captured frame.
    private static func looksLike9922Splash(_ image: CGImage) -> Bool {
        let rep = NSBitmapImageRep(cgImage: image)
        guard rep.pixelsWide > 100, rep.pixelsHigh > 60 else { return false }
        func coverage(_ x0: Double, _ x1: Double, _ y0: Double, _ y1: Double,
                      where matches: (Double, Double, Double) -> Bool) -> Double {
            var count = 0, found = 0
            let step = max(2, rep.pixelsWide / 120)
            for y in stride(from: Int(Double(rep.pixelsHigh) * y0),
                            to: Int(Double(rep.pixelsHigh) * y1), by: step) {
                for x in stride(from: Int(Double(rep.pixelsWide) * x0),
                                to: Int(Double(rep.pixelsWide) * x1), by: step) {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    count += 1
                    if matches(c.redComponent, c.greenComponent, c.blueComponent) { found += 1 }
                }
            }
            return count == 0 ? 0 : Double(found) / Double(count)
        }
        let pale = coverage(0.08, 0.92, 0.30, 0.67) { r, g, b in
            min(r, g, b) > 0.58 && max(r, g, b) - min(r, g, b) < 0.24
        }
        let darkBorder = coverage(0.08, 0.92, 0.13, 0.18) { r, g, b in
            max(r, g, b) < 0.25
        }
        let festive = coverage(0.08, 0.92, 0.01, 0.13) { r, g, b in
            (r > 0.58 && g > 0.35 && b < 0.45) || (r > 0.5 && g < 0.38 && b < 0.4)
        }
        return pale > 0.88 && darkBorder >= 0.45 && festive > 0.30
    }

    @objc private func requestAdSpeechRecognition(_ sender: NSMenuItem) {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            showHUD("Nhận dạng tiếng quảng cáo đã được cấp quyền")
            return
        case .denied, .restricted:
            showHUD("Hãy bật Nhận dạng giọng nói cho VibeFloat trong Cài đặt hệ thống")
            return
        case .notDetermined:
            break
        @unknown default:
            return
        }
        SFSpeechRecognizer.requestAuthorization { status in
            NSLog("[FloatVideo] Speech recognition auth \(status.rawValue)")
            DispatchQueue.main.async { [weak self] in
                self?.showHUD(status == .authorized
                    ? "Đã bật nhận dạng tiếng quảng cáo"
                    : "Chưa cấp quyền nhận dạng tiếng quảng cáo")
            }
        }
    }

    /// One second of 16 kHz mono PCM from the video element, not the microphone.
    private func hearAdvertisement(_ base64: String) {
        // Youtube's ads are handled inside the page. Every other strategy now
        // installs the shared audio tap, so a wordless spot still has one signal.
        guard loadingStrategy != .youtubeEmbed, currentSite != "youtube" else {
            if Self.adTraceEnabled {
                NSLog("[FloatVideo] adtrace audio skipped: youtube handles its own ads")
            }
            return
        }
        guard !audioScanBusy else { return }
        let generation = loadGeneration
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            if !didWarnSpeech {
                didWarnSpeech = true
                NSLog("[FloatVideo] Speech recognition is not authorized — the audio ad signal is OFF; "
                      + "the only signal left for a wordless video spot is frame colour and OCR")
            }
            return
        }
        guard speechRecognizer?.isAvailable == true, let data = Data(base64Encoded: base64), data.count > 4000 else { return }
        audioScanBusy = true
        audioScanToken += 1
        let token = audioScanToken
        let sampleCount = data.count / 2
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleCount)),
              let dst = buffer.floatChannelData?[0] else {
            audioScanBusy = false
            return
        }
        buffer.frameLength = AVAudioFrameCount(sampleCount)
        data.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            for i in 0..<sampleCount {
                dst[i] = Float(Int16(littleEndian: src[i])) / 32768
            }
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.append(buffer)
        request.endAudio()
        let task = speechRecognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            let done = (result?.isFinal == true) || error != nil
            if let text = result?.bestTranscription.formattedString {
                // Log every transcript while tracing, not only the matching ones:
                // whether the spot is *audibly* branded at all is exactly the
                // unknown when a video ad slips past the frame detectors.
                if Self.adTraceEnabled {
                    NSLog("[FloatVideo] adtrace heard %@", String(text.prefix(80)))
                }
            }
            if let text = result?.bestTranscription.formattedString,
               (self.loadingStrategy == .siteEmbed ? Self.looksLike9922Ad(text)
                                                    : Self.looksLikeInterstitialAd(text)) {
                NSLog("[FloatVideo] Heard ad: \(text.prefix(80))")
                DispatchQueue.main.async {
                    guard self.loadGeneration == generation, self.audioScanToken == token else { return }
                    self.lastAdDetectionAt = Date()
                    self.skipInterstitialAd()
                }
            }
            if done {
                DispatchQueue.main.async {
                    if self.audioScanToken == token { self.audioScanBusy = false }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self = self, self.loadGeneration == generation,
                  self.audioScanToken == token, self.audioScanBusy else { return }
            task?.cancel()
            self.audioScanBusy = false
        }
    }

    private static func looksLikeInterstitialAd(_ text: String) -> Bool {
        let folded = text.folding(options: .diacriticInsensitive, locale: Locale(identifier: "vi")).lowercased()
        if folded.range(of: #"\d{2,6}\s*\.\s*(com|vip|net|cc|xyz|club|fun|bet|top|live)\b"#, options: .regularExpression) != nil {
            return true
        }
        let phrases = ["ban ca", "song bai", "no hu", "casino", "jackpot", "big win", "game bai", "nap tien", "9922", "quang cao", "tai tro", "khuyen mai"]
        return phrases.contains { folded.contains($0) }
    }

    private static func looksLike9922Ad(_ text: String) -> Bool {
        let folded = text.folding(options: .diacriticInsensitive, locale: Locale(identifier: "vi"))
            .lowercased()
        if folded.range(of: #"9\s*9\s*2\s*2"#, options: .regularExpression) != nil {
            return true
        }
        return folded.range(of: #"\b(chin|9)\s*(chin|9)\s*(hai|2)\s*(hai|2)\b"#,
                            options: .regularExpression) != nil
    }

    /// Gambling spots are skipped inside the player. Screen recording is not
    /// used: that API prompts again on every launch for an ad-hoc signed app.
    private func startEmbedAudioMonitorIfNeeded() {}

    private func stopEmbedAudioMonitor() {
        embedAudioMonitor = nil
    }

    private func installGamblingContentRules() {
        let rules = """
        [
          {"trigger":{"url-filter":"9922\\\\.com","resource-type":["media","script","image","raw","fetch"]},"action":{"type":"block"}},
          {"trigger":{"url-filter":"gamebai","resource-type":["media","script","raw"]},"action":{"type":"block"}},
          {"trigger":{"url-filter":"bancah5","resource-type":["media","script","raw"]},"action":{"type":"block"}},
          {"trigger":{"url-filter":"nohu","resource-type":["media","script","raw"]},"action":{"type":"block"}},
          {"trigger":{"url-filter":"songbai","resource-type":["media","script","raw"]},"action":{"type":"block"}}
        ]
        """
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "float-gambling-ads", encodedContentRuleList: rules) { [weak self] list, error in
            DispatchQueue.main.async {
                if let error = error {
                    NSLog("[FloatVideo] Gambling content rules: \(error.localizedDescription)")
                    return
                }
                guard let self = self, let list = list else { return }
                self.webView.configuration.userContentController.add(list)
            }
        }
    }

    // MARK: - Ad trace (forensics)

    private static let adTraceDefaultsKey = "vibefloat.adTrace"

    /// Ad forensics, off by default.
    ///
    /// Every detector here works on still frames — colour (a gold/red slot) or
    /// text (OCR through `AdClassifier`). A spot that is neither, which a plain
    /// video creative usually is, leaves no signal at all, and the log at that
    /// point cannot say whether the frame was never seen or was seen and
    /// rejected. Turning this on logs the frame evidence next to the live
    /// timeline for every scan, so one real occurrence is enough to measure.
    ///
    ///   VIBEFLOAT_AD_TRACE=1 ./FloatVideo
    ///   defaults write <bundle-id> vibefloat.adTrace -bool YES
    static var adTraceEnabled: Bool {
        if ProcessInfo.processInfo.environment["VIBEFLOAT_AD_TRACE"] == "1" { return true }
        return UserDefaults.standard.bool(forKey: adTraceDefaultsKey)
    }

    /// One compact line of live player state, so a logged scan can be tied to
    /// what was actually on screen: which media file, how far in, and whether
    /// the seek guard is set.
    private func tracePlayerTimeline(tag: String) {
        guard Self.adTraceEnabled else { return }
        let js = """
        (function() {
            var v = window.__floatVideoMainVideo || document.querySelector('video');
            if (!v) return 'no-video';
            var src = (v.currentSrc || v.src || '').split('?')[0];
            var name = src.split('/').slice(-1)[0] || '';
            return 'src=' + name +
                   ' ct=' + (v.currentTime || 0).toFixed(1) +
                   ' dur=' + (isFinite(v.duration) ? v.duration.toFixed(1) : 'inf') +
                   ' paused=' + v.paused + ' rs=' + v.readyState +
                   ' skipping=' + !!window.__floatAdSkipping;
        })();
        """
        webView.evaluateJavaScript(js) { result, _ in
            NSLog("[FloatVideo] adtrace %@ %@", tag, (result as? String) ?? "?")
        }
    }

    private func skipInterstitialAd() {
        guard !interstitialSkipBusy else { return }
        if loadingStrategy == .siteEmbed {
            interstitialSkipBusy = true
            let generation = loadGeneration
            webView.evaluateJavaScript("window.__floatSkipEmbedAd && window.__floatSkipEmbedAd()") {
                [weak self] result, _ in
                guard let self = self, self.loadGeneration == generation else { return }
                if result as? Bool == true, !self.didAnnounceInterstitialSkip {
                    self.didAnnounceInterstitialSkip = true
                    self.showHUD("Đã tua qua quảng cáo")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                    guard let self = self, self.loadGeneration == generation else { return }
                    self.interstitialSkipBusy = false
                    self.lastEmbedAdScanAt = .distantPast
                    self.scanEmbedAdIfNeeded()
                }
            }
            return
        }
        // Full-page providers use the same bounded seek; the layout pass has
        // already pinned `__floatVideoMainVideo`, so the lookup below finds the
        // real player rather than an ad frame. YouTube is excluded because its
        // skip is handled inside the page.
        guard loadingStrategy == .directVideo
                || (loadingStrategy == .fullPageInject && currentSite != "youtube") else { return }
        interstitialSkipBusy = true
        let generation = loadGeneration
        let js = """
        (function() {
            var v = window.__floatVideoMainVideo || document.getElementById('player') || document.querySelector('video');
            if (!v) return null;
            var duration = v.duration;
            if (!isFinite(duration) || duration < 30) {
                try {
                    if (v.seekable && v.seekable.length)
                        duration = v.seekable.end(v.seekable.length - 1);
                } catch (e) {}
            }
            var time = v.currentTime || 0;
            if (!isFinite(duration) || duration < 30) duration = time + 120;
            return { time: time, duration: duration };
        })();
        """
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self = self, self.loadGeneration == generation,
                  let state = result as? [String: Any],
                  let now = (state["time"] as? NSNumber)?.doubleValue,
                  let duration = (state["duration"] as? NSNumber)?.doubleValue else {
                self?.interstitialSkipBusy = false
                return
            }
            if let previousOrigin = self.interstitialSkipOrigin, now < previousOrigin - 2 {
                self.interstitialSkipOrigin = nil
            }
            let origin = self.interstitialSkipOrigin ?? now
            self.interstitialSkipOrigin = origin
            guard now >= origin - 2, now - origin < 90, now + 2 < duration else {
                self.interstitialSkipBusy = false
                return
            }
            // Seek one bounded step, then inspect the new frame. This avoids
            // skipping the story when an ad phrase appears in real dialogue.
            let target = min(now + 10, duration - 1.5)
            if !self.didAnnounceInterstitialSkip {
                self.didAnnounceInterstitialSkip = true
                self.showHUD("Đã tua qua quảng cáo")
            }
            let jump = """
            (function() {
                var v = window.__floatVideoMainVideo || document.getElementById('player') || document.querySelector('video');
                if (!v) return;
                var duration = v.duration;
                if (!isFinite(duration)) {
                    try {
                        if (v.seekable && v.seekable.length)
                            duration = v.seekable.end(v.seekable.length - 1);
                    } catch (e) {}
                }
                if (!isFinite(duration) || duration < 1) duration = (v.currentTime || 0) + 30;
                var next = Math.min(duration - 0.4, \(target));
                if (next <= (v.currentTime || 0) + 0.4) return;
                window.__floatAdSkipping = true;
                try { v.currentTime = next; }
                catch (e) { window.__floatAdSkipping = false; return; }
                setTimeout(function() { window.__floatAdSkipping = false; }, 1200);
                v.play().catch(function() {});
            })();
            """
            self.webView.evaluateJavaScript(jump, completionHandler: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self = self, self.loadGeneration == generation else { return }
                self.interstitialSkipBusy = false
            }
        }
    }

    @objc func closeWindow() {
        stopEmbedAudioMonitor()
        emitProgress(force: true)
        hideTimer?.cancel()
        hideTimer = nil
        cursorPollTimer?.invalidate()
        cursorPollTimer = nil
        cursorFastTimer?.invalidate()
        cursorFastTimer = nil
        if let cursorEventMonitor {
            NSEvent.removeMonitor(cursorEventMonitor)
            self.cursorEventMonitor = nil
        }
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        vibeDock.stop()
        VibeNowPlaying.clear()
        hideHoverTip()
        controlStrip?.orderOut(nil)
        controlStrip?.close()
        controlStrip = nil
        resetYouTubeFallbackState()
        reinjectLayoutWorkItem?.cancel()
        reinjectLayoutWorkItem = nil
        stopUpdateTimer()
        saveWindowFrame()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "adWatch")
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "adAudio")
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "adSkip")
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "aiDub")
        stopAIDub()
        onClose?()
        self.close()
    }

    // MARK: - Hover Controls

    private func showControls() {
        hideTimer?.cancel()
        let alreadyShown = isHovering && titleBarView.alphaValue > 0.98
        isHovering = true
        setStripChromeVisible(true, animated: !alreadyShown)
        // Restarting the fade on every hover poll made the corner grip blink.
        guard !alreadyShown else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            titleBarView.animator().alphaValue = 1.0
            resizeIndicator?.animator().alphaValue = 0.9
        })
    }

    private func scheduleHideControls(after delay: TimeInterval = 2.5) {
        if isResizing || isInteractingWithChrome || isPointerOverChrome() {
            hideTimer?.cancel()
            hideTimer = nil
            return
        }
        hideTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.hideControls()
        }
        hideTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Schedule idle hide only when the pointer has left video + strip.
    private func scheduleHideControlsIfPointerLeft(after delay: TimeInterval = 2.5) {
        if isPointerOverChrome() {
            hideTimer?.cancel()
            hideTimer = nil
            keepChromeVisibleForInteraction()
            return
        }
        scheduleHideControls(after: delay)
    }

    private func hideControls() {
        guard isHovering else { return }
        if Self.keepControlsVisible || (!isPlaying && playbackDuration > 0) {
            setStripChromeVisible(true, animated: false)
            return
        }
        if isResizing || isInteractingWithChrome || isPointerOverChrome() {
            // Pointer returned (or still on strip/grips) — restore solid chrome, no flicker.
            hideTimer = nil
            keepChromeVisibleForInteraction()
            return
        }
        isHovering = false
        setStripChromeVisible(false, animated: true)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            titleBarView.animator().alphaValue = 0
            resizeIndicator?.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self = self, !self.isHovering else { return }
            if let view = self.contentView { self.invalidateCursorRects(for: view) }
        })
    }

    /// Fade the external strip. When hidden, ignore mouse so the band does not
    /// block the IDE; cursor polling still reveals via strip frame hit-test.
    /// Never set ignoresMouseEvents=true while the pointer is over the strip.
    private func setStripChromeVisible(_ visible: Bool, animated: Bool) {
        guard let strip = controlStrip else { return }
        let target: CGFloat = visible ? 1 : 0
        if visible {
            strip.ignoresMouseEvents = false
            strip.acceptsMouseMovedEvents = true
            if isWindowVisible { strip.orderFrontRegardless() }
        }
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = visible ? 0.16 : 0.2
                strip.animator().alphaValue = target
            }, completionHandler: { [weak self, weak strip] in
                guard let self = self, let strip = strip else { return }
                if visible {
                    strip.ignoresMouseEvents = false
                    return
                }
                // Click-through only when fully hidden AND pointer is away from chrome.
                if !self.isHovering && !self.isPointerOverChrome() {
                    strip.ignoresMouseEvents = true
                } else {
                    strip.ignoresMouseEvents = false
                    if self.isPointerOverChrome() {
                        self.isHovering = true
                        strip.alphaValue = 1
                    }
                }
            })
        } else {
            strip.alphaValue = target
            if visible {
                strip.ignoresMouseEvents = false
            } else if !isPointerOverChrome() {
                strip.ignoresMouseEvents = true
            } else {
                strip.ignoresMouseEvents = false
            }
        }
    }

    private func makeStripResizeGrip(isLeft: Bool) -> NSView {
        let width = ControlStripPanel.resizeEdgeWidth
        let grip = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 58))
        grip.wantsLayer = true
        grip.layer?.backgroundColor = VibeTheme.stroke.cgColor

        let pillW: CGFloat = 5
        let pillH: CGFloat = 22
        let pill = NSView(frame: NSRect(
            x: isLeft ? 10 : width - 10 - pillW,
            y: (58 - pillH) / 2,
            width: pillW,
            height: pillH
        ))
        pill.wantsLayer = true
        pill.layer?.backgroundColor = VibeTheme.iconMuted.cgColor
        pill.layer?.cornerRadius = pillW / 2
        pill.autoresizingMask = [.minYMargin, .maxYMargin]
        grip.addSubview(pill)
        grip.toolTip = "Kéo để đổi kích thước"
        return grip
    }

    private func makeTextChip(title: String, action: Selector) -> NSButton {
        let btn = StripIconButton(frame: NSRect(x: 0, y: 0, width: 52, height: 26))
        btn.isBordered = false
        btn.wantsLayer = true
        btn.wash = .chip(VibeTheme.chipIdle)
        btn.layer?.backgroundColor = VibeTheme.chipIdle.cgColor
        btn.layer?.cornerRadius = VibeTheme.Radius.sm
        btn.title = title
        btn.font = VibeTheme.Font.chip
        btn.contentTintColor = VibeTheme.icon
        btn.target = self
        btn.action = action
        return btn
    }

    private func makeSizePresetChip(_ preset: SizePreset) -> NSButton {
        let btn = NSButton(frame: NSRect(x: 0, y: 0, width: 36, height: 22))
        btn.bezelStyle = .inline
        btn.isBordered = false
        btn.wantsLayer = true
        btn.layer?.cornerRadius = VibeTheme.Radius.sm
        btn.title = preset.chipTitle
        btn.font = VibeTheme.Font.chip
        btn.contentTintColor = VibeTheme.icon
        btn.target = self
        btn.action = #selector(sizePresetChipClicked(_:))
        let chips: [SizePreset] = [.mini, .standard, .wide]
        btn.tag = chips.firstIndex(of: preset) ?? 0
        btn.toolTip = "Cỡ \(preset.chipTitle.lowercased())"
        return btn
    }

    @objc private func sizePresetChipClicked(_ sender: NSButton) {
        let presets: [SizePreset] = [.mini, .standard, .wide]
        let idx = sender.tag
        guard presets.indices.contains(idx) else { return }
        applySizePreset(presets[idx])
    }

    /// Reshape the window to the video's own aspect ratio so the frame fills it
    /// exactly, instead of leaving letterbox bars wherever the source ratio
    /// differs from the window's shape — a 2.39:1 film in a 16:9 window, a Short
    /// or a vertical clip in a landscape one.
    ///
    /// A manual resize or an explicit size preset wins: `userLockedSize` stops
    /// this from fighting the user, and callers never have to check.
    private func adoptVideoAspectRatio(_ ratio: CGFloat) {
        guard Self.preferredHugVideoFrame, !userLockedSize, !isUserExpanded else { return }
        // Rough sanity band. Outside it the value is a broken readout (a 0-height
        // video, an ad slot, a collapsed element), not a real frame.
        guard ratio.isFinite, ratio >= 0.35, ratio <= 3.2 else { return }
        guard abs(ratio - videoAspectRatio) > 0.012 else { return }

        let previous = frame
        videoAspectRatio = ratio
        contentAspectRatio = NSSize(width: ratio, height: 1)
        applySizeConstraints()

        // Keep the top edge and the horizontal centre: the video looks like it
        // reflows in place rather than jumping elsewhere on screen.
        var newW = previous.width
        var newH = newW / ratio
        let screen = self.screen ?? NSScreen.main
        // `maxSize` already preserves the ratio, so clamping the width here is
        // enough and keeps the result deterministic instead of depending on
        // whether AppKit clamps `setFrame` for us.
        let widthCeiling = max(maxSize.width, minSize.width)
        if newW > widthCeiling { newW = widthCeiling; newH = newW / ratio }
        if newW < minSize.width { newW = minSize.width; newH = newW / ratio }
        if let vis = screen?.visibleFrame {
            let maxH = max(minSize.height, vis.height - VibePlacer.stripHeight - 24)
            if newH > maxH { newH = maxH; newW = newH * ratio }
            let maxW = max(minSize.width, vis.width - 16)
            if newW > maxW { newW = maxW; newH = newW / ratio }
        }

        var newFrame = NSRect(x: previous.midX - newW / 2, y: previous.maxY - newH,
                              width: newW, height: newH)
        if let vis = screen?.visibleFrame {
            newFrame.origin.x = min(max(newFrame.origin.x, vis.minX + 4), vis.maxX - newW - 4)
            newFrame.origin.y = min(max(newFrame.origin.y, vis.minY + 4 + VibePlacer.stripHeight), vis.maxY - newH - 4)
        }
        // Not animated on purpose: every intermediate frame makes the WebView
        // re-layout the page, which is visible as a stutter in live video.
        setFrame(keepingLockedOrigin(newFrame), display: true, animate: false)
        syncControlStrip(animated: false)
        saveWindowFrame()
        layoutVideoChrome()
        scheduleInjectedLayoutRefresh()
        NSLog("[FloatVideo] Hugged video frame: ratio \(String(format: "%.3f", ratio)) size \(Int(newW))x\(Int(newH))")
    }

    /// Ask the page for the main video's intrinsic size and fit to it once.
    private func requestVideoFrameHug() {
        let js = """
        (function() {
            var v = window.__floatVideoMainVideo || document.querySelector('video');
            if (!v || !v.videoWidth || !v.videoHeight) return 0;
            return v.videoWidth / v.videoHeight;
        })();
        """
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self = self,
                  let ratio = (result as? NSNumber)?.doubleValue, ratio > 0 else { return }
            self.adoptVideoAspectRatio(CGFloat(ratio))
        }
    }

    /// Re-enable fitting and apply it now — the way back after a manual resize
    /// has locked the size.
    @objc private func hugNow() {
        userLockedSize = false
        requestVideoFrameHug()
    }

    @objc private func toggleHugVideoFrame() {
        Self.preferredHugVideoFrame = !Self.preferredHugVideoFrame
        userLockedSize = false
        if Self.preferredHugVideoFrame {
            requestVideoFrameHug()
        }
        showHUD(Self.preferredHugVideoFrame ? "Ôm sát khung phát: Bật" : "Ôm sát khung phát: Tắt")
    }

    /// `fromUser` separates an explicit size choice from the default applied
    /// on open. Only an explicit choice should stop the automatic fit.
    func applySizePreset(_ preset: SizePreset, fromUser: Bool = true) {
        noteStripInteraction()
        if isWindowFullScreen {
            isWindowFullScreen = false
            setButtonSymbol(maximizeButton, "arrow.up.left.and.arrow.down.right")
        }
        selectedSizePreset = preset
        preservesPresetSize = true
        // A new selection supersedes any earlier automatic shrink/restore frame.
        isCodingSafeMode = false
        preSafeFrame = .zero
        Self.persistSizePreset(preset)
        refreshSizePresetChipStyles()

        isMaximized = false
        if fromUser {
            // An explicit size choice is the user overruling the automatic fit.
            userLockedSize = true
        }
        setButtonSymbol(maximizeButton, "arrow.up.left.and.arrow.down.right")

        // Freeze auto-dock briefly so placer does not shrink the new size away.
        presetHoldWorkItem?.cancel()
        autoDockPaused = true
        isResizing = true

        let screen = self.screen ?? NSScreen.main
        let vis = screen?.visibleFrame ?? frame
        let old = frame
        var targetW: CGFloat
        var targetH: CGFloat
        var origin = old.origin

        if preset == .pocket {
            let maxW = min(vis.width - 32, maxSize.width)
            let maxH = min(vis.height - VibePlacer.stripHeight - 32, maxW / videoAspectRatio)
            targetW = min(maxW, maxH * videoAspectRatio)
            targetH = targetW / videoAspectRatio
            let obstacles = vibeDock.liveObstacles(on: vis)
            if let decision = VibePlacer.bestFrame(
                size: NSSize(width: targetW, height: targetH),
                screen: vis,
                obstacles: obstacles
            ) {
                applyDock(videoFrame: decision.frame, animated: true)
                showHUD("Cỡ Lớn — \(Int(decision.frame.width))×\(Int(decision.frame.height))")
                finishPresetHold()
                return
            }
        } else {
            targetW = preset.fittedSize(aspectRatio: videoAspectRatio, screen: vis.size,
                                        minimumWidth: minSize.width, maximumWidth: maxSize.width,
                                        stripHeight: VibePlacer.stripHeight,
                                        stripGap: VibePlacer.stripGap).width
        }

        let minW = minSize.width
        let maxW = max(maxSize.width, minW)
        targetW = min(max(targetW, minW), maxW)
        if let screen = screen {
            targetW = min(targetW, max(minW, screen.visibleFrame.width - 16))
        }
        targetH = targetW / videoAspectRatio
        if let screen = screen {
            let maxH = max(minW / videoAspectRatio, screen.visibleFrame.height - VibePlacer.stripHeight - 24)
            if targetH > maxH {
                targetH = maxH
                targetW = targetH * videoAspectRatio
            }
        }

        // Keep the nearest screen-corner anchor so the player stays where it was docked.
        let preferRight = old.midX >= vis.midX
        let preferTop = old.midY >= vis.midY
        origin.x = preferRight ? old.maxX - targetW : old.minX
        origin.y = preferTop ? old.maxY - targetH : old.minY
        origin.x = min(max(origin.x, vis.minX + 4), vis.maxX - targetW - 4)
        origin.y = min(max(origin.y, vis.minY + 4 + VibePlacer.stripHeight), vis.maxY - targetH - 4)

        let newFrame = NSRect(origin: origin, size: NSSize(width: targetW, height: targetH))
        setFrame(keepingLockedOrigin(newFrame), display: true, animate: false)
        syncControlStrip(animated: false)
        layoutControlBar()
        vibeDock.noteUserDidPlace()
        saveWindowFrame()
        showHUD("\(preset.chipTitle) — \(Int(targetW)) pt")
        finishPresetHold()
    }

    private func finishPresetHold() {
        presetHoldWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.isResizing = false
            self.autoDockPaused = false
            self.scheduleHideControlsIfPointerLeft(after: Self.chromeHideDelay)
        }
        presetHoldWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func refreshSizePresetChipStyles() {
        let map: [(NSButton?, SizePreset)] = [
            (sizePresetMiniButton, .mini),
            (sizePresetStandardButton, .standard),
            (sizePresetWideButton, .wide),
        ]
        for (button, preset) in map {
            guard let button = button else { continue }
            let on = selectedSizePreset == preset
            button.layer?.backgroundColor = (on ? VibeTheme.accent : VibeTheme.chipIdle).cgColor
            button.contentTintColor = on ? VibeTheme.onAccent : VibeTheme.icon
        }
    }

    // MARK: - Auto next episode / skip intro

    var isAutoNextEpisodeEnabled: Bool { Self.preferredAutoNextEpisode }
    var isAutoSkipIntroEnabled: Bool { Self.preferredAutoSkipIntro }

    @objc func toggleAutoNextEpisode() {
        let next = Self.setPreferredAutoNextEpisode(!Self.preferredAutoNextEpisode)
        refreshWatchAssistButtonStyles()
        showHUD(next ? "Tự chuyển tập: Bật" : "Tự chuyển tập: Tắt")
        noteStripInteraction()
    }

    @objc func toggleAutoSkipIntro() {
        let next = Self.setPreferredAutoSkipIntro(!Self.preferredAutoSkipIntro)
        refreshWatchAssistButtonStyles()
        showHUD(next ? "Tự bỏ GT: Bật" : "Tự bỏ GT: Tắt")
        noteStripInteraction()
    }

    @objc func manualSkipIntro() {
        // Option-click toggles auto preference instead of seeking.
        if NSApp.currentEvent?.modifierFlags.contains(.option) == true {
            toggleAutoSkipIntro()
            return
        }
        noteStripInteraction()
        let end = introEndSeconds(forDuration: max(playbackDuration, 600))
        userSeekedThisEpisode = true
        didAutoSkipIntroThisEpisode = true
        if let slug = movieContext?.slug {
            Self.rememberIntroEnd(end, forSlug: slug)
        }
        seekTo(seconds: end)
        showHUD("Đã bỏ qua giới thiệu")
    }

    private func introEndSeconds(forDuration duration: Double) -> Double {
        let slug = movieContext?.slug ?? ""
        if let remembered = Self.rememberedIntroEnd(forSlug: slug) {
            return min(remembered, max(30, duration * 0.15))
        }
        return min(WatchAssist.defaultIntroSeconds, max(30, duration * 0.15))
    }

    /// Called from vibe-sync / HTTP API after toggling prefs.
    func refreshWatchAssistFromAPI() {
        refreshWatchAssistButtonStyles()
        layoutControlBar()
    }

    private func refreshWatchAssistButtonStyles() {
        if let btn = stripAutoNextButton {
            let on = Self.preferredAutoNextEpisode
            setButtonSymbol(btn, on ? "forward.end.alt.fill" : "forward.end.alt")
            btn.contentTintColor = on ? VibeTheme.accent : VibeTheme.icon
            btn.toolTip = on
                ? "Tự chuyển tập: Bật — bấm để tắt"
                : "Tự chuyển tập: Tắt — bấm để bật"
            btn.isHidden = true
        }
        if let btn = stripSkipIntroButton {
            let on = Self.preferredAutoSkipIntro
            btn.contentTintColor = on ? VibeTheme.accent : VibeTheme.icon
            btn.toolTip = on
                ? "Bỏ qua GT (bấm). ⌥+bấm: tắt tự động"
                : "Bỏ qua GT (bấm). ⌥+bấm: bật tự động"
            btn.isHidden = true
        }
    }

    private func resetEpisodeWatchAssistState() {
        didAutoSkipIntroThisEpisode = false
        userSeekedThisEpisode = false
        didAutoAdvanceThisEpisode = false
        lastPlaybackSample = 0
        lastWatchAssistReason = nil
    }

    private func handleWatchAssist(currentTime ct: Double, duration dur: Double, paused: Bool,
                                   ended: Bool = false,
                                   durationSource: EpisodeDurationSource = .unknown) {
        // A preroll or an HLS discontinuity jumps the clock. That is not the
        // viewer scrubbing, but it must not cancel the intro skip either, so
        // only an actual drag counts as one.
        if scrubberView?.isDragging == true {
            userSeekedThisEpisode = true
        }
        lastPlaybackSample = ct

        let sample = WatchAssistSample(
            hasMovie: movieContext != nil,
            ct: ct,
            dur: dur,
            durSource: durationSource,
            introEnd: introEndSeconds(forDuration: dur),
            paused: paused,
            ended: ended,
            userSeeked: userSeekedThisEpisode,
            suppress: suppressWatchAssist,
            autoSkipIntro: Self.preferredAutoSkipIntro,
            autoNext: Self.preferredAutoNextEpisode,
            hasPlaylist: movieContext?.hasPlaylist == true,
            didSkipIntro: didAutoSkipIntroThisEpisode,
            didAdvance: didAutoAdvanceThisEpisode
        )
        let decision = WatchAssist.decide(sample)
        if decision.introPassed { didAutoSkipIntroThisEpisode = true }
        traceWatchAssist(decision, sample: sample)

        switch decision.action {
        case .none:
            break
        case .skipIntro(let seconds):
            didAutoSkipIntroThisEpisode = true
            seekTo(seconds: seconds)
            showHUD("Đã bỏ qua giới thiệu")
        case .advanceToNextEpisode:
            didAutoAdvanceThisEpisode = true
            // Only the episode switch may announce anything: it knows the next
            // episode by name, and says so itself when the list is over. A HUD
            // here claimed a skip that could not happen at the last episode.
            _ = switchEpisode(by: 1)
        }
    }

    /// One line per verdict *change*, so a single credits roll says whether the
    /// assist acted, and if not, which condition held it back. Logging every
    /// poll would be two lines a second.
    private func traceWatchAssist(_ decision: WatchAssistDecision, sample: WatchAssistSample) {
        guard decision.reason != lastWatchAssistReason else { return }
        lastWatchAssistReason = decision.reason
        NSLog("[FloatVideo] Watch assist: %@ — ct=%.1f dur=%.1f src=%@ ended=%@ step=%@",
              decision.reason.rawValue, sample.ct, sample.dur, sample.durSource.rawValue,
              sample.ended ? "yes" : "no", String(describing: decision.action))
    }

    private func layoutControlBar() {
        guard let bar = controlBarView else { return }
        let layout = FloatingPlayerLayout(width: bar.bounds.width, episodes: movieContext?.hasPlaylist == true)
        stripTitleLabel.frame = layout.title
        stripStateLabel.frame = layout.status
        timeLabel?.frame = layout.clock
        timeLabel?.alignment = .right
        scrubberView?.frame = layout.timeline
        controlBarRule?.frame = layout.rule
        let buttons: [(String, NSButton?)] = [
            ("play", playPauseButton), ("rewind", rewindButton), ("forward", skipButton),
            ("volume", volumeButton), ("previous", stripPrevEpisodeButton),
            ("next", stripNextEpisodeButton), ("speed", speedButton),
            ("close", stripCloseButton), ("more", stripMoreButton),
            ("maximize", maximizeButton), ("pin", stripPinButton), ("ghost", stripGhostButton)
        ]
        for (name, button) in buttons {
            button?.isHidden = layout.controls[name] == nil
            if let frame = layout.controls[name] { button?.frame = frame }
            if let button = button, let hint = button.toolTip { button.setAccessibilityLabel(hint) }
        }
        volumeSlider?.isHidden = layout.controls["slider"] == nil
        if let frame = layout.controls["slider"] { volumeSlider?.frame = frame }
        for button in [sizeUpButton, sizeDownButton, sizePresetMiniButton, sizePresetStandardButton,
                       sizePresetWideButton, stripSkipIntroButton, stripAutoNextButton,
                       stripAudioBoostButton, stripDubButton, stripDuckButton] {
            button?.isHidden = true
        }
        refreshPlaybackHeader()
        bar.window?.invalidateCursorRects(for: bar)
    }

    private func refreshPlaybackHeader() {
        stripTitleLabel.stringValue = videoTitle.isEmpty ? "VibeFloat" : videoTitle
        stripTitleLabel.toolTip = stripTitleLabel.stringValue
        title = stripTitleLabel.stringValue
        stripStateLabel.stringValue = playbackDuration > 0
            ? (playbackElapsed >= playbackDuration - 0.5 ? "Đã kết thúc" : isPlaying ? "Đang phát" : "Tạm dừng")
            : (isPlaying ? "Đang phát" : "Đang tải")
        var detail = stripStateLabel.stringValue
        if let ctx = movieContext, let server = ctx.servers[safe: ctx.serverIdx], ctx.hasPlaylist {
            detail += " · Tập \(ctx.epIdx + 1)/\(server.items.count)"
        }
        if playbackDuration.isFinite && playbackDuration > 0 {
            detail += " · Còn \(formatTime(max(0, playbackDuration - playbackElapsed)))"
        }
        stripStateLabel.toolTip = detail
        playPauseButton?.toolTip = isPlaying ? "Tạm dừng (Space)" : "Phát (Space)"
        playPauseButton?.setAccessibilityLabel(playPauseButton?.toolTip ?? "Phát / Tạm dừng")
        rewindButton?.toolTip = "Tua lùi 10 giây (←)"
        skipButton?.toolTip = "Tua tới 10 giây (→)"
        volumeButton?.toolTip = userWantsMute ? "Bật tiếng (M)" : "Tắt tiếng (M)"
    }

    private func refreshPlaybackClock() {
        guard scrubberView?.isPreviewing != true else { return }
        timeLabel?.stringValue = playbackDuration.isFinite && playbackDuration > 0
            ? "\(formatTime(playbackElapsed)) / \(formatTime(playbackDuration))"
            : (playbackElapsed > 0 ? "\(formatTime(playbackElapsed)) / Trực tiếp" : "--:-- / --:--")
    }

    @objc private func toggleKeepControlsVisible() {
        Self.keepControlsVisible.toggle()
        showControls()
        if !Self.keepControlsVisible { scheduleHideControls(after: 2) }
    }

    private func makePrimaryPlayButton(action: Selector) -> NSButton {
        let btn = StripIconButton(frame: NSRect(x: 0, y: 0, width: 34, height: 34))
        btn.isBordered = false
        btn.wantsLayer = true
        btn.layer?.backgroundColor = VibeTheme.knob.cgColor
        btn.layer?.cornerRadius = 17
        btn.layer?.borderWidth = 0
        btn.contentTintColor = VibeTheme.onWhite
        btn.target = self
        btn.action = action
        if let img = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Phát/Tạm dừng") {
            let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .bold)
            btn.image = img.withSymbolConfiguration(config)
            btn.title = ""
            btn.imagePosition = .imageOnly
        }
        return btn
    }

    private func makeControlButton(symbolName: String, action: Selector, pointSize: CGFloat = 13) -> NSButton {
        let btn = StripIconButton(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        btn.isBordered = false
        btn.wantsLayer = true
        btn.layer?.backgroundColor = NSColor.clear.cgColor
        btn.layer?.cornerRadius = VibeTheme.Radius.md
        btn.contentTintColor = VibeTheme.icon
        btn.wash = .glyph
        btn.target = self
        btn.action = action
        if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
            btn.image = img.withSymbolConfiguration(config)
            btn.title = ""
            btn.imagePosition = .imageOnly
        } else {
            btn.title = symbolName
            btn.font = NSFont.systemFont(ofSize: pointSize, weight: .semibold)
        }
        return btn
    }

    private func setButtonSymbol(_ btn: NSButton, _ symbolName: String, pointSize: CGFloat? = nil) {
        if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            let ps = pointSize ?? ((btn == playPauseButton) ? 15 : 13)
            let config = NSImage.SymbolConfiguration(pointSize: ps, weight: (btn == playPauseButton) ? .bold : .semibold)
            btn.image = img.withSymbolConfiguration(config)
            btn.title = ""
        } else {
            btn.title = symbolName
        }
    }

    private func videoJS(_ directJS: String, youtubeCmd: String? = nil, jwAction: String? = nil) {
        var js = """
        (function() {
            var v = document.querySelector('video');
            if (!v) {
                try {
                    var iframes = document.querySelectorAll('iframe');
                    for (var i = 0; i < iframes.length; i++) {
                        var iv = iframes[i].contentDocument.querySelector('video');
                        if (iv) { v = iv; break; }
                    }
                } catch(e) {}
            }
            if (v) {
                \(directJS)
            } else if (window.jwplayer && typeof window.jwplayer === 'function') {
                try {
                    var jw = window.jwplayer();
                    \(jwAction ?? "")
                } catch(e) {}
            }
        """
        if let cmd = youtubeCmd {
            js += """
            else if (window.playerCommand) {
                \(cmd)
            }
            """
        }
        js += "})();"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    @objc func togglePlayPause() {
        if isOfflineDubEnabled && !isPlaying {
            guard offlineDubSession.isReady else {
                showHUD("Offline Dub đang dựng audio — hãy chờ hoàn tất")
                forcePauseForOfflineDubbing()
                return
            }
            offlineDubPlaybackAuthorized = true
            updateOfflineDubProgress(nil)
            webView.evaluateJavaScript("window.__floatOfflineDubHold = false", completionHandler: nil)
            resumeMediaPlayback()
            isPlaying = true
            setButtonSymbol(playPauseButton, "pause.fill")
            return
        }
        if isPlaying {
            videoJS("v.pause()",
                    youtubeCmd: "playerCommand('pause')",
                    jwAction: "jw.pause()")
            webView.evaluateJavaScript("window.__floatControlEmbeddedMedia && window.__floatControlEmbeddedMedia('pause')", completionHandler: nil)
            isPlaying = false
            stopAIDub()
        } else {
            videoJS("v.play().catch(()=>{})",
                    youtubeCmd: "playerCommand('play')",
                    jwAction: "jw.play()")
            webView.evaluateJavaScript("window.__floatControlEmbeddedMedia && window.__floatControlEmbeddedMedia('play')", completionHandler: nil)
            isPlaying = true
        }
        setButtonSymbol(playPauseButton, isPlaying ? "pause.fill" : "play.fill")
    }

    @objc func skipBackward() {
        userSeekedThisEpisode = true
        stopAIDub()
        videoJS("v.currentTime = Math.max(0, v.currentTime - 10)",
                youtubeCmd: "playerCommand('seek', Math.max(0, (window.getPlayerState()?.ct||0)-10))",
                jwAction: "jw.seek(Math.max(0, (jw.getPosition()||0) - 10))")
    }

    @objc func skipForward() {
        userSeekedThisEpisode = true
        stopAIDub()
        videoJS("v.currentTime = Math.min(v.duration || 999999, v.currentTime + 10)",
                youtubeCmd: "playerCommand('seek', (window.getPlayerState()?.ct||0)+10)",
                jwAction: "jw.seek((jw.getPosition()||0) + 10)")
    }

    @objc func toggleMute() {
        userWantsMute.toggle()
        if userWantsMute {
            videoJS("v.muted = true",
                    youtubeCmd: "playerCommand('mute')",
                    jwAction: "jw.setMute(true)")
            setButtonSymbol(volumeButton, "speaker.slash.fill")
            volumeSlider.doubleValue = 0
        } else {
            videoJS("v.muted = false; v.volume = 1.0",
                    youtubeCmd: "playerCommand('unmute'); playerCommand('volume', 1.0)",
                    jwAction: "jw.setMute(false); jw.setVolume(100)")
            setButtonSymbol(volumeButton, "speaker.wave.2.fill")
            volumeSlider.doubleValue = 1.0
        }
    }

    @objc func volumeChanged(_ sender: NSSlider) {
        let vol = sender.doubleValue
        userWantsMute = vol == 0
        setButtonSymbol(volumeButton, userWantsMute ? "speaker.slash.fill" : "speaker.wave.2.fill")
        volumeApplyWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.applyVolume(vol)
        }
        volumeApplyWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    private func applyVolume(_ vol: Double) {
        let muted = vol == 0
        videoJS("v.volume = \(vol); v.muted = \(muted)",
                youtubeCmd: "playerCommand('volume', \(vol)); playerCommand(\(muted ? "'mute'" : "'unmute'"))",
                jwAction: "jw.setVolume(\(Int(vol * 100))); jw.setMute(\(muted))")
    }

    func adjustVolume(by delta: Double) {
        let current = userWantsMute ? 0 : volumeSlider.doubleValue
        let newVol = max(0, min(1.0, current + delta))
        volumeSlider.doubleValue = newVol
        volumeChanged(volumeSlider)
    }

    @objc private func menuSetPlaybackRate(_ sender: NSMenuItem) {
        guard let rate = sender.representedObject as? Double,
              let index = playbackRates.firstIndex(of: rate) else { return }
        currentRateIndex = index
        applyPlaybackRate()
    }

    @objc func cyclePlaybackRate() {
        currentRateIndex = (currentRateIndex + 1) % playbackRates.count
        applyPlaybackRate()
    }

    private func applyPlaybackRate() {
        let rate = playbackRates[currentRateIndex]
        speedButton.title = Self.formatRate(rate)
        videoJS("v.playbackRate = \(rate)",
                youtubeCmd: "playerCommand('setPlaybackRate', \(rate))",
                jwAction: "jw.setPlaybackRate(\(rate))")
    }

    /// Explicit expansion wins over automatic obstacle placement until restored.
    var isUserExpanded: Bool { isMaximized || isWindowFullScreen }

    @objc func toggleMaximize() {
        noteStripInteraction()
        if isWindowFullScreen {
            toggleFullScreenWindow()
            return
        }
        guard let screen = self.screen ?? NSScreen.main else { return }
        let vis = screen.visibleFrame
        let target: NSRect
        if isMaximized {
            isMaximized = false
            setButtonSymbol(maximizeButton, "arrow.up.left.and.arrow.down.right")
            maximizeButton.toolTip = "Phóng tối đa / Khôi phục kích thước (F)"
            if preMaximizeFrame != .zero && vis.intersects(preMaximizeFrame) {
                target = preMaximizeFrame
            } else {
                let width = min(640, vis.width - 48)
                let height = min(width / videoAspectRatio,
                                 vis.height - VibePlacer.stripHeight - VibePlacer.stripGap - 48)
                target = NSRect(x: vis.midX - height * videoAspectRatio / 2,
                                y: vis.maxY - height - 24,
                                width: height * videoAspectRatio, height: height)
            }
        } else {
            preMaximizeFrame = frame
            isMaximized = true
            setButtonSymbol(maximizeButton, "arrow.down.right.and.arrow.up.left")
            maximizeButton.toolTip = "Khôi phục kích thước (F hoặc Esc)"
            // Maximize is a user choice to cover other apps. Leave room for the
            // control strip, but never fall back to a small coding-safe pocket.
            let width = min(vis.width - 48, maxSize.width)
            let height = min(vis.height - 48 - VibePlacer.stripHeight - VibePlacer.stripGap,
                             width / videoAspectRatio)
            target = NSRect(x: vis.midX - height * videoAspectRatio / 2,
                            y: vis.maxY - height - 24,
                            width: height * videoAspectRatio, height: height)
        }
        // An explicit resize may reposition a pinned panel to fit the display.
        // Capture the new anchor before AppKit's move delegate enforces it.
        if isPinned { lockedOrigin = target.origin }
        applyDock(videoFrame: target, animated: true)
        DispatchQueue.main.async { [weak self] in
            self?.layoutControlBar()
            self?.syncControlStrip(animated: true)
        }
    }

    @objc func applySizePresetMini() { applySizePreset(.mini) }
    @objc func applySizePresetStandard() { applySizePreset(.standard) }
    @objc func applySizePresetWide() { applySizePreset(.wide) }
    @objc func applySizePresetPocket() { applySizePreset(.pocket) }

    /// Fill the current display while keeping the floating panel above other
    /// apps. This is intentionally a frame-based full screen: it works with
    /// the borderless nonactivating panel and does not steal keyboard focus
    /// from the editor like native window full screen can.
    @objc func toggleFullScreenWindow() {
        guard let screen = self.screen ?? NSScreen.main else { return }
        let vis = screen.visibleFrame
        if isWindowFullScreen {
            isWindowFullScreen = false
            setButtonSymbol(maximizeButton, "arrow.up.left.and.arrow.down.right")
            let restore = preFullScreenFrame == .zero ? NSRect(
                x: vis.maxX - 720 - 24,
                y: vis.maxY - 720 / videoAspectRatio - 24,
                width: 720,
                height: 720 / videoAspectRatio
            ) : preFullScreenFrame
            applyDock(videoFrame: restore, animated: true)
            showHUD("Đã thoát toàn màn hình")
        } else {
            preFullScreenFrame = frame
            isWindowFullScreen = true
            isMaximized = false
            setButtonSymbol(maximizeButton, "arrow.down.right.and.arrow.up.left")
            setFrame(vis, display: true, animate: true)
            syncControlStrip(animated: true)
            layoutVideoChrome()
            showHUD("Toàn màn hình")
        }
        layoutControlBar()
    }

    @objc func growWindow() {
        adjustWindowScale(by: 1.18)
        showControls()
        scheduleHideControlsIfPointerLeft(after: Self.chromeHideDelay)
    }

    @objc func shrinkWindow() {
        adjustWindowScale(by: 1.0 / 1.18)
        showControls()
        scheduleHideControlsIfPointerLeft(after: Self.chromeHideDelay)
    }

    /// Scale the floating window while keeping aspect ratio and staying on-screen.
    @discardableResult
    func adjustWindowScale(by factor: CGFloat) -> NSSize {
        guard factor > 0 else { return frame.size }
        isMaximized = false
        setButtonSymbol(maximizeButton, "arrow.up.left.and.arrow.down.right")

        let minW = minSize.width
        let maxW = max(maxSize.width, minW)
        var newW = frame.width * factor
        newW = min(max(newW, minW), maxW)
        var newH = newW / videoAspectRatio

        if let screen = screen ?? NSScreen.main {
            let vis = screen.visibleFrame
            let maxFitW = max(minW, vis.width - 16)
            let maxFitH = max(minW / videoAspectRatio, vis.height - VibePlacer.stripHeight - 24)
            if newW > maxFitW {
                newW = maxFitW
                newH = newW / videoAspectRatio
            }
            if newH > maxFitH {
                newH = maxFitH
                newW = newH * videoAspectRatio
            }
        }

        var newFrame = frame
        // Grow/shrink from the center so the window feels anchored in place.
        newFrame.origin.x += (frame.width - newW) / 2
        newFrame.origin.y += (frame.height - newH) / 2
        newFrame.size = NSSize(width: newW, height: newH)

        if let screen = screen ?? NSScreen.main {
            let vis = screen.visibleFrame
            newFrame.origin.x = min(max(newFrame.origin.x, vis.minX + 4), vis.maxX - newFrame.width - 4)
            newFrame.origin.y = min(max(newFrame.origin.y, vis.minY + 4 + VibePlacer.stripHeight), vis.maxY - newFrame.height - 4)
        }

        setFrame(keepingLockedOrigin(newFrame), display: true, animate: false)
        syncControlStrip(animated: false)
        vibeDock.noteUserDidPlace()
        saveWindowFrame()
        layoutControlBar()
        return newFrame.size
    }

    /// Absolute width setter used by vibe-sync / API (`height` follows aspect ratio).
    @discardableResult
    func setWindowWidth(_ width: CGFloat) -> NSSize {
        guard width > 0 else { return frame.size }
        let factor = width / max(frame.width, 1)
        return adjustWindowScale(by: factor)
    }

    private func seekTo(percent: Double) {
        let js = """
        (function() {
            var v = document.querySelector('video');
            if (!v) {
                try {
                    var iframes = document.querySelectorAll('iframe');
                    for (var i = 0; i < iframes.length; i++) {
                        var iv = iframes[i].contentDocument.querySelector('video');
                        if (iv) { v = iv; break; }
                    }
                } catch(e) {}
            }
            var jw = null;
            try { if (window.jwplayer) jw = window.jwplayer(); } catch (e) {}
            var contentDur = window.__floatContentDur || 0;
            try {
                var item = jw && jw.getPlaylistItem && jw.getPlaylistItem();
                if (item && item.duration > 90) contentDur = item.duration;
            } catch (e) {}
            var ad = !!(document.querySelector('.jwplayer.jw-flag-ads, .jwplayer.jw-flag-ads-vpaid'));
            if (jw && contentDur > 90 && (ad || !v || !isFinite(v.duration) || v.duration < 90)) {
                try { jw.seek(contentDur * \(percent)); return; } catch (e) {}
            }
            if (v && v.duration) {
                v.currentTime = v.duration * \(percent);
            } else if (jw) {
                try {
                    var dur = contentDur || jw.getDuration();
                    if (dur > 0) jw.seek(dur * \(percent));
                } catch(e) {}
            } else if (window.getPlayerState && window.playerCommand) {
                var s = window.getPlayerState();
                if (s && s.dur) playerCommand('seek', s.dur * \(percent));
            }
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    func seekTo(seconds: Double) {
        let safe = max(0, seconds)
        let js = """
        (function() {
            var t = \(safe);
            var v = document.querySelector('video');
            if (!v) {
                try {
                    var iframes = document.querySelectorAll('iframe');
                    for (var i = 0; i < iframes.length; i++) {
                        var iv = iframes[i].contentDocument.querySelector('video');
                        if (iv) { v = iv; break; }
                    }
                } catch(e) {}
            }
            var jw = null;
            try { if (window.jwplayer) jw = window.jwplayer(); } catch (e) {}
            var contentDur = window.__floatContentDur || 0;
            try {
                var item = jw && jw.getPlaylistItem && jw.getPlaylistItem();
                if (item && item.duration > 90) contentDur = Math.max(contentDur, item.duration);
            } catch (e) {}
            try {
                var reported = jw && jw.getDuration && jw.getDuration();
                if (isFinite(reported) && reported > 90) contentDur = Math.max(contentDur, reported);
            } catch (e) {}
            if (jw && contentDur > 90 && (!v || !isFinite(v.duration) || Math.abs(v.duration - contentDur) > 5)) {
                try { jw.seek(Math.min(t, Math.max(0, contentDur - 0.5))); return; } catch (e) {}
            }
            if (v && isFinite(v.duration) && v.duration > 1) {
                v.currentTime = Math.min(t, Math.max(0, v.duration - 0.25));
            } else if (jw) {
                try { jw.seek(t); } catch(e) {}
            } else if (window.playerCommand) {
                playerCommand('seek', t);
            }
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - Control Bar State Polling

    private func startUpdateTimer() {
        updateTimer?.invalidate()
        startEmbedAudioMonitorIfNeeded()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.pollVideoState()
            self.scanEmbedAdIfNeeded()
            self.scanSubtitlesIfNeeded()
            self.retryAudioBoostIfNeeded()
            self.verifyInjectionAliveIfNeeded()
        }
    }

    /// Asserts the one invariant everything else depends on: the document in
    /// the web view is still the document we injected into.
    ///
    /// `didFinish` cannot be trusted for this. It skips re-injection while
    /// `hasInjectedJS` is true, and `hasInjectedJS` only means "injected once,
    /// into some document of this web view" — so a page that navigates itself
    /// leaves the next document raw: no layout CSS, no ad skip, no watch-assist
    /// hooks. Probing for our own globals closes that hole
    /// whatever the navigation semantics turn out to be, and it self-heals on
    /// every site rather than only the one that was reported.
    private func verifyInjectionAliveIfNeeded() {
        guard loadingStrategy == .fullPageInject, hasInjectedJS else { return }
        injectionProbeTicks += 1
        if injectionProbeTicks < 6 { return }   // 0.5s ticks: probe every 3s
        injectionProbeTicks = 0
        let generation = loadGeneration
        let js = "!!(window.__floatVideoApplyLayout && document.getElementById('__floatvideo-style'))"
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self = self, self.loadGeneration == generation else { return }
            guard let alive = result as? Bool, !alive else { return }
            NSLog("[FloatVideo] Injected document was replaced; re-injecting (site: \(self.currentSite))")
            self.hasInjectedJS = false
            self.injectVideoMaximize(site: self.currentSite, currentTime: self.currentVideoTime)
            // Everything the app installs per document has to come back with
            // it. The ad skip carries its own in-page guard, so this is a no-op
            // on a document that still has one.
            if self.currentSite == "youtube" { self.injectAdSkip() }
        }
    }

    private func stopUpdateTimer() {
        updateTimer?.invalidate()
        updateTimer = nil
    }

    private func pollVideoState() {
        let generation = loadGeneration
        let js = """
        (function() {
            var v = document.querySelector('video');
            if (!v) {
                try {
                    var iframes = document.querySelectorAll('iframe');
                    for (var i = 0; i < iframes.length; i++) {
                        var iv = iframes[i].contentDocument.querySelector('video');
                        if (iv) { v = iv; break; }
                    }
                } catch(e) {}
            }
            var clock = window.__floatClock;
            if (!v && clock && clock.dur > 1) {
                return { ct: clock.ct || 0, dur: clock.dur, durSrc: 'clock', vol: 1, muted: false, paused: !!clock.paused,
                         ended: false, vw: 0, vh: 0, streamFailed: false, skips: 0, ff: 0,
                         adSkipInstalled: true, tc: null, ads: !!clock.ad };
            }
            if (v) {
                var tc = window.__floatVideoPendingTrustedClick || null;
                window.__floatVideoPendingTrustedClick = null;
                var mp = document.querySelector('#movie_player, .html5-video-player');
                var ads = !!(mp && (mp.classList.contains('ad-showing') ||
                                    mp.classList.contains('ad-interrupting')));
                if (clock && clock.ad) ads = true;
                var dur = v.duration;
                // Where this number came from decides whether the end credits
                // can be measured from it at all. `seekable.end()` is a buffer
                // edge, not a length.
                var durSrc = (isFinite(dur) && dur >= 1) ? 'media' : 'unknown';
                if (!isFinite(dur) || dur < 1) {
                    try {
                        if (v.seekable && v.seekable.length) {
                            dur = v.seekable.end(v.seekable.length - 1);
                            durSrc = 'seekable';
                        }
                    } catch (e) {}
                }
                // HLS often reports only the buffered window. The episode length
                // published by the player is the one intro and outro skips need.
                if (clock && clock.dur > dur) { dur = clock.dur; durSrc = 'clock'; }
                var ct = v.currentTime || 0;
                if (clock && clock.ad && clock.dur > 90) ct = clock.ct || 0;
                else if (clock && isFinite(clock.ct)) ct = Math.max(ct, clock.ct);
                var paused = !!v.paused;
                if (clock && clock.paused === false) paused = false;
                // The layout pass remembers which element is the real player;
                // prefer it over "first video on the page".
                var mv = window.__floatVideoMainVideo || v;
                return { ct: ct, dur: (isFinite(dur) ? dur : 0), durSrc: durSrc, vol: v.volume, muted: v.muted, paused: paused,
                         ended: !!v.ended,
                         vw: mv.videoWidth || 0,
                         vh: mv.videoHeight || 0,
                         streamFailed: !!window.__floatStreamFailed,
                         skips: window.__floatVideoAdSkipCount || 0,
                         ff: window.__floatVideoAdFFCount || 0,
                         adSkipInstalled: !!window.__floatVideoAdSkipInstalled,
                         tc: tc, ads: ads };
            }
            if (window.jwplayer && typeof window.jwplayer === 'function') {
                try {
                    var jw = window.jwplayer();
                    var state = jw.getState();
                    return {
                        ct: jw.getPosition() || 0,
                        dur: jw.getDuration() || 0,
                        durSrc: 'clock',
                        vol: (jw.getVolume() || 100) / 100,
                        muted: jw.getMute() || false,
                        paused: (state !== 'playing' && state !== 'buffering'),
                        skips: 0,
                        ff: 0,
                        adSkipInstalled: true,
                        tc: null,
                        ads: (state === 'ad')
                    };
                } catch(e) {}
            }
            // The site's own player publishes its episode length, which is the
            // number the intro and outro skips are built on.
            if (window.getPlayerState) return window.getPlayerState();
            return null;
        })()
        """
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self = self, self.loadGeneration == generation,
                  let dict = result as? [String: Any] else { return }
            if (dict["streamFailed"] as? Bool) == true {
                self.fallbackToEmbedIfDirectFailed()
            }
            // Fit the window to the video's own shape as soon as the page can
            // report it. No-ops when the fit is off, still converging, or the
            // user has taken over the size.
            let vw = (dict["vw"] as? NSNumber)?.doubleValue ?? 0
            let vh = (dict["vh"] as? NSNumber)?.doubleValue ?? 0
            if vw > 0, vh > 0 {
                self.adoptVideoAspectRatio(CGFloat(vw / vh))
            }

            let ct = (dict["ct"] as? NSNumber)?.doubleValue ?? 0
            let dur = (dict["dur"] as? NSNumber)?.doubleValue ?? 0
            // A payload with no label at all comes from a site player that
            // reports its own length (`getPlayerState`), which is what the
            // intro and outro skips were already built on: keep trusting it.
            // A label we do not recognise is treated as unusable instead.
            let durSource = EpisodeDurationSource(rawValue: dict["durSrc"] as? String ?? "")
                ?? (dict["durSrc"] == nil ? .clock : .unknown)
            let vol = (dict["vol"] as? NSNumber)?.doubleValue ?? 1
            let muted = dict["muted"] as? Bool ?? false
            let paused = dict["paused"] as? Bool ?? true
            let ended = dict["ended"] as? Bool ?? false

            let skips = (dict["skips"] as? NSNumber)?.intValue ?? 0
            if skips > self.lastAdSkipCount {
                NSLog("[FloatVideo] Auto-skipped ad (total \(skips))")
                self.lastAdSkipCount = skips
            }
            let ff = (dict["ff"] as? NSNumber)?.intValue ?? 0
            if ff > self.lastAdFFCount {
                NSLog("[FloatVideo] Fast-forwarded stuck ad (total \(ff))")
                self.lastAdFFCount = ff
            }

            let adSkipInstalled = dict["adSkipInstalled"] as? Bool ?? true
            if !adSkipInstalled, self.currentSite == "youtube",
               self.loadingStrategy == .fullPageInject {
                self.injectAdSkip()
            }

            if let tc = dict["tc"] as? [String: Any],
               (dict["ads"] as? Bool) == true,
               let px = (tc["x"] as? NSNumber)?.doubleValue,
               let py = (tc["y"] as? NSNumber)?.doubleValue {
                self.performTrustedClick(pageX: px, pageY: py)
            }

            self.scrubberView?.canSeek = dur.isFinite && dur > 0
            self.scrubberView?.setProgress(dur.isFinite && dur > 0 ? CGFloat(ct / dur) : 0)

            // Sync play state
            let offlineHold = self.isOfflineDubEnabled && !self.offlineDubPlaybackAuthorized
            if offlineHold && !paused { self.forcePauseForOfflineDubbing() }
            let wasPlaying = self.isPlaying
            self.isPlaying = !paused && !offlineHold
            self.playbackElapsed = ct
            self.playbackDuration = dur
            self.refreshPlaybackClock()
            self.refreshPlaybackHeader()
            if !self.isPlaying && dur > 0 { self.showControls() }
            if self.isPlaying && !wasPlaying { self.scheduleHideControls(after: Self.chromeHideDelay) }
            if self.isOfflineDubEnabled {
                self.offlineDubSession.update(videoTime: ct, playing: !paused && !offlineHold,
                                              rate: self.playbackRate)
            }
            self.handleWatchAssist(currentTime: ct, duration: dur, paused: paused, ended: ended,
                                   durationSource: durSource)
            self.setButtonSymbol(self.playPauseButton, paused || offlineHold ? "play.fill" : "pause.fill")
            VibeNowPlaying.update(
                title: self.videoTitle,
                elapsed: ct,
                duration: dur,
                playing: !paused,
                rate: self.playbackRate
            )
            if !paused {
                self.emitProgress(force: false)
            }

            // Mute/volume reconciliation — never force 1.0 while ducked
            let desiredMuted = self.userWantsMute
            self.setButtonSymbol(self.volumeButton, desiredMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            if desiredMuted {
                self.volumeSlider.doubleValue = 0
                if !muted {
                    self.videoJS("v.muted = true", youtubeCmd: "playerCommand('mute')", jwAction: "jw.setMute(true)")
                }
            } else if self.isDucked {
                let duckedVol = self.volumeSlider?.doubleValue ?? max(0.05, self.preDuckVolume * 0.2)
                self.volumeSlider.doubleValue = duckedVol
                if muted || abs(vol - duckedVol) > 0.08 {
                    self.videoJS("v.muted = false; v.volume = \(duckedVol)",
                                 youtubeCmd: "playerCommand('unmute'); playerCommand('volume', \(duckedVol))",
                                 jwAction: "jw.setMute(false); jw.setVolume(\(Int(duckedVol * 100)))")
                }
            } else {
                self.volumeSlider.doubleValue = max(vol, 0.01)
                if muted || vol == 0 {
                    self.videoJS("v.muted = false; v.volume = 1.0",
                                 youtubeCmd: "playerCommand('unmute'); playerCommand('volume', 1.0)",
                                 jwAction: "jw.setMute(false); jw.setVolume(100)")
                }
            }
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && !seconds.isNaN else { return "0:00" }
        let s = Int(seconds)
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%d:%02d", m, sec)
    }

    /// "1.0x" / "1.5x" / "0.75x" — shared by the speed badge and the menu, so
    /// the same rate is never spelled two different ways.
    static func formatRate(_ rate: Double) -> String {
        if rate == 1.0 { return "1.0x" }
        if rate.truncatingRemainder(dividingBy: 1) == 0 { return "\(Int(rate)).0x" }
        return "\(rate)x"
    }

    @objc func toggleOpacity() {
        // Cycle: full → slightly soft → readable minimum → full.
        let current = self.alphaValue
        if current > 0.9 {
            self.alphaValue = 0.9
        } else if current > 0.8 {
            self.alphaValue = 0.8
        } else {
            self.alphaValue = 1.0
        }
        if !isGhostMode {
            preGhostAlpha = self.alphaValue
        }
        UserDefaults.standard.set(Double(self.alphaValue), forKey: Self.opacityPrefKey)
    }

    @objc func play() {
        if !isPlaying { togglePlayPause() }
    }

    @objc func pause() {
        if isPlaying { togglePlayPause() }
    }

    @objc func duckVolume() {
        if !isDucked {
            preDuckVolume = volumeSlider?.doubleValue ?? 1.0
            let ducked = max(0.05, preDuckVolume * 0.2)
            volumeSlider?.doubleValue = ducked
            if let slider = volumeSlider { volumeChanged(slider) }
            isDucked = true
            showHUD("Đã hạ tiếng")
            NSLog("[FloatVideo] Audio ducked to 20% for AI review")
        }
    }

    @objc func unduckVolume() {
        if isDucked {
            volumeSlider?.doubleValue = preDuckVolume
            if let slider = volumeSlider { volumeChanged(slider) }
            isDucked = false
            showHUD("Khôi phục âm lượng")
            NSLog("[FloatVideo] Audio restored to 100%")
        }
    }

    private func applyPreferredGhostOnOpen() {
        setGhostMode(Self.preferredGhostMode, persist: false)
        if let saved = UserDefaults.standard.object(forKey: Self.opacityPrefKey) as? Double {
            // Migrate old near-invisible values so the player stays readable.
            let normalized = min(1.0, max(0.8, saved))
            setOpacity(normalized)
            UserDefaults.standard.set(normalized, forKey: Self.opacityPrefKey)
        }
    }

    /// Solid opacity for a clickable player — never the coding-safe / ghost soft values.
    private static func preferredSolidOpacity(fallback: CGFloat) -> CGFloat {
        if let saved = UserDefaults.standard.object(forKey: opacityPrefKey) as? Double {
            let v = CGFloat(saved)
            if v >= 0.9 { return min(1.0, v) }
        }
        if fallback >= 0.9 { return min(1.0, fallback) }
        return 1.0
    }

    func setGhostMode(_ enabled: Bool, persist: Bool = true) {
        isGhostMode = enabled
        // Only the video window passes clicks through. The control strip stays live.
        self.ignoresMouseEvents = enabled
        if enabled {
            // Ghost Mode is click-through only. Keep the video at its current
            // brightness so enabling it does not make playback look dim.
            preGhostAlpha = self.alphaValue
            if let stripGhostButton {
                setButtonSymbol(stripGhostButton, "eye.slash")
                stripGhostButton.contentTintColor = VibeTheme.accent
            }
            stripGhostButton?.toolTip = "Đang xuyên chuột"
        } else {
            // User wants a solid, clickable picture. Restore full/preferred opacity —
            // do not leave coding-safe washout (~0.55) even if layout stays shrunk.
            let solid = Self.preferredSolidOpacity(fallback: preGhostAlpha)
            self.alphaValue = solid
            preGhostAlpha = solid
            if let stripGhostButton {
                setButtonSymbol(stripGhostButton, "eye")
                stripGhostButton.contentTintColor = VibeTheme.icon
            }
            stripGhostButton?.toolTip = "Xuyên chuột"
            // Keep isCodingSafeMode for size/placement; opacity follows ghost preference.
        }
        mountControlStrip()
        syncControlStrip(animated: false)
        if persist {
            Self.setPreferredGhostMode(enabled)
        }
    }

    @objc func toggleGhostMode() {
        setGhostMode(!isGhostMode, persist: true)
    }

    /// No clear pocket over the IDE — shrink, soften, park in least-bad corner.
    /// Suggests ghost only on enter when preferredGhostMode is true; never re-forces
    /// ghost on later dock ticks so a manual OFF stays OFF.
    func applyCodingSafeMode(preferred: NSRect) {
        guard !isUserExpanded else { return }
        let entering = !isCodingSafeMode
        if entering {
            preSafeFrame = frame
            preSafeAlpha = alphaValue
            // Suggest click-through once when entering, only if user still prefers it.
            if Self.preferredGhostMode && !isGhostMode {
                setGhostMode(true, persist: false)
            }
        }
        isCodingSafeMode = true
        // Soft dim only while ghost/click-through is on. If the user turned ghost
        // OFF for a solid player, keep coding-safe size/placement but do not re-wash.
        if isGhostMode && alphaValue > 0.6 {
            animator().alphaValue = 0.55
        }

        // Presets and manual sizes survive obstacle placement. Only an
        // unsized player may shrink on first entry; all sizes still fit the screen.
        let preserveSize = preservesPresetSize || userLockedSize
        let codingCap = max(minSize.width, 380)
        var targetW = entering && !preserveSize
            ? min(max(preferred.width, minSize.width), codingCap)
            : max(frame.width, minSize.width)
        var targetH = targetW / videoAspectRatio
        if let screen = screen ?? NSScreen.main {
            let vis = screen.visibleFrame
            let maxH = max(minSize.height, preserveSize
                ? vis.height - VibePlacer.stripHeight - VibePlacer.stripGap - 32
                : vis.height * 0.34)
            if targetH > maxH {
                targetH = maxH
                targetW = targetH * videoAspectRatio
            }
            var frame = NSRect(
                x: preferred.midX - targetW / 2,
                y: preferred.midY - targetH / 2,
                width: targetW,
                height: targetH
            )
            // Prefer the upper corners so the caret/input band stays free.
            let corners = [
                NSPoint(x: vis.maxX - targetW - 14, y: vis.maxY - targetH - 14),
                NSPoint(x: vis.minX + 14, y: vis.maxY - targetH - 14),
                NSPoint(x: vis.maxX - targetW - 14, y: vis.minY + VibePlacer.stripHeight + 20),
                NSPoint(x: vis.minX + 14, y: vis.minY + VibePlacer.stripHeight + 20),
            ]
            let obstacles = vibeDock.liveObstacles(on: vis)
            let ranked = corners.map { origin -> (NSRect, CGFloat) in
                let candidate = NSRect(origin: origin, size: NSSize(width: targetW, height: targetH))
                let foot = VibePlacer.footprint(video: candidate, screen: vis)
                let overlap = obstacles.reduce(CGFloat(0)) { sum, o in
                    sum + max(0, foot.intersection(o.frame.insetBy(dx: -o.pad, dy: -o.pad)).width)
                        * max(0, foot.intersection(o.frame.insetBy(dx: -o.pad, dy: -o.pad)).height)
                        * o.weight
                }
                return (candidate, -overlap)
            }.sorted { $0.1 > $1.1 }
            frame = ranked.first?.0 ?? frame
            applyDock(videoFrame: frame, animated: true)
        } else {
            applyDock(videoFrame: preferred, animated: true)
        }
        if entering {
            showHUD(preserveSize ? "Đã chuyển vị trí để chừa chỗ gõ" : "Thu nhỏ để chừa chỗ gõ")
            NSLog("[FloatVideo] Coding-safe placement: preserveSize=\(preserveSize), ghost=\(self.isGhostMode)")
        }
    }

    func exitCodingSafeModeIfClear() {
        guard isCodingSafeMode else { return }
        isCodingSafeMode = false
        let restore = preSafeFrame
        preSafeFrame = .zero
        if !preservesPresetSize && !userLockedSize,
           restore.width >= minSize.width && restore.height >= minSize.height {
            applyDock(videoFrame: restore, animated: true)
        }
        // Keep ghost preference; restore opacity — solid when ghost is off.
        if isGhostMode {
            if let saved = UserDefaults.standard.object(forKey: Self.opacityPrefKey) as? Double {
                animator().alphaValue = CGFloat(max(0.45, saved))
            } else {
                animator().alphaValue = max(preSafeAlpha, 0.72)
            }
        } else {
            animator().alphaValue = Self.preferredSolidOpacity(fallback: preSafeAlpha)
        }
        showHUD(preservesPresetSize || userLockedSize ? "Đã đặt cửa sổ vào vùng trống" : "Đã phóng lại kích thước trước")
    }

    private func applyPositionLockState() {
        (titleBarView as? DraggableTitleBar)?.isLocked = isPinned
        pinButton?.alphaValue = isPinned ? 1 : 0.45
        pinButton?.toolTip = isPinned
            ? "Đã khóa vị trí — bấm để mở khóa"
            : "Khóa vị trí trên màn hình"
        if let stripPinButton {
            setButtonSymbol(stripPinButton, isPinned ? "pin.fill" : "pin")
            stripPinButton.contentTintColor = isPinned ? VibeTheme.accent : VibeTheme.icon
            stripPinButton.toolTip = isPinned
                ? "Đã khóa vị trí — bấm để mở khóa"
                : "Khóa vị trí trên màn hình"
        }
    }

    @objc func togglePin() {
        togglePositionLock()
    }

    @objc private func togglePositionLock() {
        isPinned.toggle()
        Self.preferredPositionLocked = isPinned
        applyPositionLockState()
        if isPinned {
            // Capture the window's *current* location before any more dock ticks.
            // A frame assignment also ends an in-flight NSWindow animation.
            lockedOrigin = frame.origin
            vibeDock.stop()
            setFrame(frame, display: true)
            syncControlStrip(animated: false)
            autoDockPaused = false
            saveWindowFrame()
            showHUD("Đã khóa vị trí trên màn hình")
        } else {
            lockedOrigin = nil
            vibeDock.attach(self)
            showHUD("Đã mở khóa vị trí")
        }
    }

    @objc func toggleDuck() {
        if isDucked { unduckVolume() } else { duckVolume() }
        if let stripDuckButton {
            setButtonSymbol(stripDuckButton, isDucked ? "ear.fill" : "ear")
            stripDuckButton.contentTintColor = isDucked ? VibeTheme.accent : VibeTheme.icon
        }
    }

    // MARK: - HUD / Progress / Episodes

    func showHUD(_ message: String, duration: TimeInterval = 1.6) {
        guard let hud = hudToast, let container = contentView else {
            NSLog("[FloatVideo] HUD: \(message)")
            return
        }
        let maxWidth = max(120, container.bounds.width - 24)
        hud.present(message, symbol: Self.toastSymbol(for: message), maxWidth: maxWidth)
        hud.isHidden = false
        let y = container.bounds.height - 30 - 10 - hud.frame.height
        hud.frame.origin = CGPoint(
            x: max(12, (container.bounds.width - hud.frame.width) / 2),
            y: max(12, y)
        )
        hud.alphaValue = 0
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            hud.animator().alphaValue = 1
        })
        hudHideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let hud = self?.hudToast else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.22
                hud.animator().alphaValue = 0
            }, completionHandler: {
                hud.isHidden = true
            })
        }
        hudHideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private static func toastSymbol(for message: String) -> String {
        let text = message.folding(options: .diacriticInsensitive, locale: Locale(identifier: "vi")).lowercased()
        if text.contains("quang cao") { return "forward.fill" }
        if text.contains("gioi thieu") || text.contains("bo gt") { return "forward.end" }
        if text.contains("tap") || text.contains("mua") { return "film" }
        if text.contains("tieng") || text.contains("am luong") { return "speaker.wave.2.fill" }
        if text.contains("coding") || text.contains("phong lai") { return "arrow.down.right.and.arrow.up.left" }
        if text.contains("loi") || text.contains("phim tat") { return "exclamationmark.circle" }
        if text.contains("nguon") { return "arrow.triangle.2.circlepath" }
        if text.contains("nho") || text.contains("vua") || text.contains("rong") || text.contains("lon") || text.contains("px") {
            return "aspectratio"
        }
        return "checkmark.circle"
    }

    func emitProgress(force: Bool) {
        guard movieContext != nil || playbackElapsed > 0 else { return }
        let now = Date()
        if !force, now.timeIntervalSince(lastProgressSentAt) < progressHeartbeatInterval {
            return
        }
        lastProgressSentAt = now
        let payload = progressPayload()
        guard !payload.isEmpty else { return }
        onProgress?(payload)
    }

    func progressPayload() -> [String: Any] {
        var payload: [String: Any] = [
            "type": "PROGRESS",
            "currentTime": playbackElapsed,
            "duration": playbackDuration,
        ]
        if let ctx = movieContext {
            payload["slug"] = ctx.slug
            payload["name"] = ctx.name
            payload["source"] = ctx.source
            payload["poster"] = ctx.poster
            payload["serverIdx"] = ctx.serverIdx
            payload["epIdx"] = ctx.epIdx
            if let ep = ctx.currentEpisode {
                payload["epName"] = ep.name
                payload["epSlug"] = ep.slug
                payload["linkM3u8"] = ep.linkM3u8
                payload["linkEmbed"] = ep.linkEmbed
            }
        } else {
            payload["name"] = videoTitle
            payload["linkEmbed"] = currentEmbedUrl ?? ""
            payload["linkM3u8"] = ""
        }
        return payload
    }

    private func updateEpisodeButtons() {
        let hasNav = movieContext?.hasPlaylist == true
        stripPrevEpisodeButton?.isHidden = !hasNav
        stripNextEpisodeButton?.isHidden = !hasNav
        if let ctx = movieContext, let server = ctx.servers[safe: ctx.serverIdx] {
            stripPrevEpisodeButton?.isEnabled = ctx.epIdx > 0
            stripNextEpisodeButton?.isEnabled = ctx.epIdx + 1 < server.items.count
        }
        layoutControlBar()
    }

    @objc func prevEpisode() {
        switchEpisode(by: -1)
    }

    @objc func nextEpisode() {
        switchEpisode(by: 1)
    }

    @discardableResult
    func switchEpisode(by delta: Int) -> Bool {
        guard var ctx = movieContext else {
            showHUD("Không có danh sách tập")
            return false
        }
        guard let ep = ctx.moveEpisode(by: delta) else {
            showHUD(delta < 0 ? "Đã ở tập đầu" : "Hết mùa / hết danh sách")
            return false
        }
        movieContext = ctx
        reloadEpisode(ep, context: ctx)
        return true
    }

    private func reloadEpisode(_ ep: MovieEpisodeItem, context: MovieContext) {
        emitProgress(force: true)
        videoTitle = context.name.isEmpty ? ep.name : "\(context.name) — \(ep.name)"
        titleLabel?.stringValue = videoTitle
        currentVideoTime = 0
        playbackElapsed = 0
        playbackDuration = 0
        hasInjectedJS = false
        resetEpisodeWatchAssistState()
        updateEpisodeButtons()
        refreshWatchAssistButtonStyles()
        showHUD(ep.name)

        let m3u8 = ep.linkM3u8
        let embed = ep.linkEmbed
        let pageURL = !embed.isEmpty ? embed : currentPageURL
        NSLog("[FloatVideo] Episode \(ep.name) m3u8=\(!m3u8.isEmpty) embed=\(!embed.isEmpty)")
        loadVideo(
            url: pageURL,
            videoSrc: m3u8.isEmpty ? nil : m3u8,
            embedUrl: embed.isEmpty ? nil : embed,
            currentTime: 0,
            site: currentSite == "generic" || currentSite.isEmpty ? "movie" : currentSite,
            httpServerPortProvider: httpServerPortProvider,
            httpServerPlayCapabilityProvider: httpServerPlayCapabilityProvider,
            cookies: [],
            playerPrefs: playerPrefs
        )
        // Episode change itself is a progress checkpoint (time 0 on new ep).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.emitProgress(force: true)
        }
    }

    @objc func showOverflowMenu(_ sender: NSButton) {
        let menu = NSMenu(title: "Tùy chọn")
        menu.autoenablesItems = false
        // A real menu checkmark lands in its own column, so the labels line up.
        // The old "✓ " prefix shifted every title by a glyph and read as text.
        func item(_ title: String, action: Selector, on: Bool = false) -> NSMenuItem {
            let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
            it.target = self
            it.state = on ? .on : .off
            return it
        }
        func separator() { menu.addItem(NSMenuItem.separator()) }

        // Playback
        menu.addItem(item("Tua lùi 10 giây", action: #selector(skipBackward)))
        menu.addItem(item("Tua tới 10 giây", action: #selector(skipForward)))
        menu.addItem(item(userWantsMute ? "Bật tiếng" : "Tắt tiếng", action: #selector(toggleMute)))
        let speedParent = NSMenuItem(title: "Tốc độ phát: \(Self.formatRate(playbackRate))", action: nil, keyEquivalent: "")
        let speeds = NSMenu()
        for rate in playbackRates.sorted() {
            let speed = item(Self.formatRate(rate), action: #selector(menuSetPlaybackRate(_:)), on: rate == playbackRate)
            speed.representedObject = rate
            speeds.addItem(speed)
        }
        speedParent.submenu = speeds
        menu.addItem(speedParent)

        // Episodes
        if movieContext?.hasPlaylist == true {
            separator()
            let previous = item("Tập trước", action: #selector(prevEpisode))
            let next = item("Tập sau", action: #selector(nextEpisode))
            previous.isEnabled = stripPrevEpisodeButton?.isEnabled == true
            next.isEnabled = stripNextEpisodeButton?.isEnabled == true
            menu.addItem(previous)
            menu.addItem(next)
        }
        if movieContext != nil {
            separator()
            menu.addItem(item("Tự chuyển tập cuối phim",
                              action: #selector(toggleAutoNextEpisode),
                              on: Self.preferredAutoNextEpisode))
            menu.addItem(item("Tự bỏ qua giới thiệu",
                              action: #selector(toggleAutoSkipIntro),
                              on: Self.preferredAutoSkipIntro))
            menu.addItem(item("Bỏ qua giới thiệu ngay", action: #selector(manualSkipIntro)))

            // Audio boost reads best as a submenu: the parent shows the level in
            // force, so the current setting is visible without opening it.
            let boostParent = NSMenuItem(title: "Tăng âm thanh: \(Self.preferredAudioBoost.menuTitle)",
                                         action: nil, keyEquivalent: "")
            let boostMenu = NSMenu()
            for level in AudioBoostLevel.allCases {
                let boostItem = NSMenuItem(title: level.menuTitle,
                                           action: #selector(menuSetAudioBoost(_:)),
                                           keyEquivalent: "")
                boostItem.target = self
                boostItem.representedObject = level.rawValue
                boostItem.state = level == Self.preferredAudioBoost ? .on : .off
                boostMenu.addItem(boostItem)
            }
            boostParent.submenu = boostMenu
            menu.addItem(boostParent)
        }

        separator()
        let audioParent = NSMenuItem(title: "Âm thanh và lồng tiếng", action: nil, keyEquivalent: "")
        let audioMenu = NSMenu()
        audioMenu.autoenablesItems = false
        audioMenu.addItem(item(isOfflineDubEnabled ? "Tắt Offline Dub" :
                          (offlineDubSession.isReady ? "Bật Offline Dub — audio đã sẵn sàng" : "Offline Dub — dựng audio trước rồi phát"),
                          action: #selector(toggleOfflineDubbing), on: isOfflineDubEnabled))

        let voiceParent = NSMenuItem(title: "Giọng đọc Edge AI: \(EdgeTTSManager.shared.selectedVoice.displayName)",
                                     action: nil, keyEquivalent: "")
        let voiceMenu = NSMenu()
        for voice in EdgeTTSManager.Voice.allCases {
            let voiceItem = NSMenuItem(title: voice.description,
                                       action: #selector(menuSetEdgeVoice(_:)),
                                       keyEquivalent: "")
            voiceItem.target = self
            voiceItem.representedObject = voice.rawValue
            voiceItem.state = voice == EdgeTTSManager.shared.selectedVoice ? .on : .off
            voiceMenu.addItem(voiceItem)
        }
        voiceParent.submenu = voiceMenu
        audioMenu.addItem(voiceParent)
        audioParent.submenu = audioMenu
        menu.addItem(audioParent)

        // Window size
        separator()
        let sizeParent = NSMenuItem(title: "Kích thước cửa sổ", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        sizeMenu.autoenablesItems = false
        sizeMenu.addItem(item(SizePreset.mini.menuTitle, action: #selector(applySizePresetMini),
                          on: selectedSizePreset == .mini))
        sizeMenu.addItem(item(SizePreset.standard.menuTitle, action: #selector(applySizePresetStandard),
                          on: selectedSizePreset == .standard))
        sizeMenu.addItem(item(SizePreset.wide.menuTitle, action: #selector(applySizePresetWide),
                          on: selectedSizePreset == .wide))
        sizeMenu.addItem(item(SizePreset.pocket.menuTitle, action: #selector(applySizePresetPocket)))
        sizeMenu.addItem(item("Phóng to", action: #selector(growWindow)))
        sizeMenu.addItem(item("Thu nhỏ", action: #selector(shrinkWindow)))
        sizeMenu.addItem(item(isMaximized ? "Khôi phục kích thước" : "Phóng tối đa",
                          action: #selector(toggleMaximize)))
        sizeMenu.addItem(item(isWindowFullScreen ? "Thoát toàn màn hình" : "Toàn màn hình",
                          action: #selector(toggleFullScreenWindow),
                          on: isWindowFullScreen))

        sizeParent.submenu = sizeMenu
        menu.addItem(sizeParent)

        // Window behaviour
        separator()
        menu.addItem(item("Luôn hiện thanh điều khiển", action: #selector(toggleKeepControlsVisible), on: Self.keepControlsVisible))
        menu.addItem(item("Xuyên chuột (G)", action: #selector(toggleGhostMode), on: isGhostMode))
        menu.addItem(item("Giảm âm lượng tạm thời", action: #selector(toggleDuck), on: isDucked))
        let behaviourParent = NSMenuItem(title: "Tùy chọn khác", action: nil, keyEquivalent: "")
        let behaviourMenu = NSMenu()
        behaviourMenu.autoenablesItems = false
        behaviourMenu.addItem(item("Làm mờ banner quảng cáo (Shift+B)", action: #selector(toggleManualBannerBlur),
                          on: isManualBannerBlurEnabled || adCoverOn))
        behaviourMenu.addItem(item(SFSpeechRecognizer.authorizationStatus() == .authorized
                          ? "Nhận dạng tiếng quảng cáo: đã cấp quyền"
                          : "Cấp quyền nhận dạng tiếng quảng cáo",
                          action: #selector(requestAdSpeechRecognition(_:))))
        behaviourMenu.addItem(item("Ôm sát khung phát", action: #selector(toggleHugVideoFrame),
                          on: Self.preferredHugVideoFrame))
        behaviourMenu.addItem(item("Ôm lại khung ngay", action: #selector(hugNow)))
        behaviourMenu.addItem(item("Khóa vị trí trên màn hình", action: #selector(togglePositionLock),
                          on: Self.preferredPositionLocked))
        behaviourMenu.addItem(item("Phím tắt toàn cục", action: #selector(toggleHotkeys),
                          on: Self.preferredHotkeysEnabled))
        behaviourParent.submenu = behaviourMenu
        menu.addItem(behaviourParent)
        let point = NSPoint(x: sender.bounds.midX, y: sender.bounds.minY - 2)
        menu.popUp(positioning: nil, at: point, in: sender)
    }

    /// Kill switch for the global hotkeys. They are only registered while a
    /// window is open, but even then they override combinations the frontmost
    /// app may own, so the user needs a way out without quitting.
    @objc private func toggleHotkeys() {
        Self.preferredHotkeysEnabled = !Self.preferredHotkeysEnabled
        let effective = onToggleHotkeys?() ?? Self.preferredHotkeysEnabled
        showHUD(effective ? "Đã bật phím tắt" : "Đã tắt phím tắt")
    }

    /// Show the boost level in the strip's colour and symbol, so "is the film
    /// being lifted?" is answerable without opening the menu.
    private func refreshAudioBoostButtonStyle() {
        guard let btn = stripAudioBoostButton else { return }
        let on = Self.preferredAudioBoost != .off
        btn.contentTintColor = on ? VibeTheme.accent : VibeTheme.icon
        setButtonSymbol(btn, on ? "speaker.wave.3.fill" : "speaker.wave.2", pointSize: 12)
    }

    @objc private func cycleAudioBoost() {
        let levels = AudioBoostLevel.allCases
        guard let idx = levels.firstIndex(of: Self.preferredAudioBoost) else { return }
        setAudioBoost(levels[(idx + 1) % levels.count])
    }

    @objc private func menuSetAudioBoost(_ sender: NSMenuItem) {
        guard let level = AudioBoostLevel(rawValue: sender.representedObject as? Int ?? -1) else { return }
        setAudioBoost(level)
    }

    private func setAudioBoost(_ level: AudioBoostLevel) {
        Self.preferredAudioBoost = level
        refreshAudioBoostButtonStyle()
        pushAudioBoostState()
        showHUD(level.hudTitle)
        showControls()
        scheduleHideControlsIfPointerLeft(after: Self.chromeHideDelay)
    }

    @objc func menuSetEdgeVoice(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let voice = EdgeTTSManager.Voice(rawValue: raw) else { return }
        EdgeTTSManager.shared.selectedVoice = voice
        showHUD("Giọng đọc Edge AI: \(voice.displayName)")
        if isAIDubEnabled {
            speakAIDubText("Đã chọn giọng \(voice.displayName)", duration: 1.5, force: true)
        }
    }

    // MARK: - AI Dubbing (Lồng tiếng Edge AI từ phụ đề)

    @objc func toggleAIDubbing() {
        toggleOfflineDubbing()
    }

    @objc func toggleOfflineDubbing() {
        isOfflineDubEnabled.toggle()
        NSLog("[OfflineDub] toggled enabled=%@", isOfflineDubEnabled ? "yes" : "no")
        if isOfflineDubEnabled {
            offlineDubPlaybackAuthorized = false
            forcePauseForOfflineDubbing()
            isAIDubEnabled = false
            Self.preferredAIDubEnabled = false
            refreshAIDubButtonStyle()
            webView?.evaluateJavaScript("if (window.__floatToggleAIDub) { window.__floatToggleAIDub(false); }", completionHandler: nil)
            if !isDucked {
                duckVolume()
                offlineDubChangedVolume = true
            }
            if offlineDubSession.isReady && offlineDubTimelineSignature != nil {
                let count = offlineDubSession.cueCount
                showHUD("Offline Dub: audio đã sẵn sàng — \(count) câu", duration: 3.0)
                updateOfflineDubProgress("Offline Dub • Audio \(count) câu đã sẵn sàng. Bấm Play để phát.", progress: 1)
                dismissOfflineDubProgress(after: 5)
            } else {
                offlineDubTimelineSignature = nil
                offlineDubUsedOCR = false
                showHUD("Offline Dub: đã dừng video — đang dựng audio phụ đề…", duration: 3.0)
                updateOfflineDubProgress("Offline Dub • Đang lấy timeline phụ đề…",
                                         indeterminate: true, active: true)
                webView?.evaluateJavaScript("if (window.__floatRequestOfflineTimeline) { window.__floatRequestOfflineTimeline(); }", completionHandler: nil)
                requestOfflineTimelineFromWebView(after: 0.35)
            }
        } else {
            offlineDubPlaybackAuthorized = false
            offlineDubOCR?.cancel()
            offlineDubOCR = nil
            if offlineDubSession.isReady {
                offlineDubSession.update(videoTime: playbackElapsed, playing: false, rate: playbackRate)
            } else {
                offlineDubSession.stop()
                offlineDubTimelineSignature = nil
                offlineDubUsedOCR = false
            }
            webView?.evaluateJavaScript("window.__floatOfflineDubHold = false", completionHandler: nil)
            if offlineDubChangedVolume {
                unduckVolume()
                offlineDubChangedVolume = false
            }
            // Offline Dub paused the player as well as suspending WebKit media.
            // Clearing the suspension alone leaves the video paused.
            resumeMediaPlayback()
            showHUD("Offline Dub: Tắt")
            updateOfflineDubProgress(nil)
        }
        refreshAIDubButtonStyle()
        showControls()
        scheduleHideControlsIfPointerLeft(after: Self.chromeHideDelay)
    }

    private func prepareOfflineDubbing(_ cues: [OfflineDubSession.Cue]) {
        guard isOfflineDubEnabled else { return }
        let validCues = cues.filter {
            $0.end > $0.start && $0.text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
        }
        guard !validCues.isEmpty else { return }
        let signature = validCues.map { "\($0.start):\($0.end):\($0.text)" }.joined(separator: "\u{1f}")
        guard signature != offlineDubTimelineSignature else { return }
        offlineDubOCR?.cancel()
        offlineDubOCR = nil
        offlineDubTimelineSignature = signature
        let baseProgress = offlineDubUsedOCR ? 0.5 : 0
        updateOfflineDubProgress("Offline Dub • Đã lấy \(validCues.count) câu — đang dịch và tạo giọng (\(Int(baseProgress * 100))%)",
                                 progress: baseProgress, active: true)
        offlineDubSession.prepare(cues: validCues, onProgress: { [weak self] progress in
            guard let self, self.isOfflineDubEnabled else { return }
            let overall = self.offlineDubUsedOCR ? 0.5 + progress.fraction * 0.5 : progress.fraction
            let percent = Int((overall * 100).rounded())
            let step = progress.translated < progress.total ? "Đang dịch và tạo giọng" : "Đang tạo giọng"
            let failures = progress.failed > 0 ? " • lỗi \(progress.failed)" : ""
            let fallback = progress.fallback > 0 ? " • giọng dự phòng \(progress.fallback)" : ""
            self.updateOfflineDubProgress(
                "Offline Dub • \(step) \(percent)% — dịch \(progress.translated)/\(progress.total), audio \(progress.rendered - progress.failed)/\(progress.total)\(fallback)\(failures)",
                progress: overall,
                active: true
            )
        }) { [weak self] result in
            guard let self, self.isOfflineDubEnabled else { return }
            switch result {
            case .success(let count):
                self.showHUD(count > 0 ? "Offline Dub: đã dựng \(count) câu" : "Không tìm thấy phụ đề đủ dài")
                let fallback = self.offlineDubSession.fallbackCount
                let fallbackNote = fallback > 0 ? " (\(fallback) câu dùng giọng Việt trên máy)" : ""
                self.updateOfflineDubProgress(
                    count > 0 ? "Offline Dub • Hoàn tất 100% — audio \(count)/\(validCues.count) câu\(fallbackNote). Bấm Play để phát." : "Offline Dub • Hoàn tất — không tạo được audio",
                    progress: count > 0 ? 1 : 0,
                    indeterminate: false
                )
                if count > 0 { self.dismissOfflineDubProgress(after: 5) }
                self.offlineDubSession.update(videoTime: self.playbackElapsed, playing: self.isPlaying,
                                              rate: self.playbackRate)
            case .failure(let error):
                self.offlineDubPlaybackAuthorized = false
                self.forcePauseForOfflineDubbing()
                self.updateOfflineDubProgress("Offline Dub • \(error.localizedDescription). Tắt/bật để thử lại.",
                                              progress: 0)
                self.showHUD("Offline Dub lỗi: \(error.localizedDescription)")
            }
        }
    }

    private func requestOfflineTimelineFromWebView(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isOfflineDubEnabled else { return }
            self.webView?.evaluateJavaScript("window.__floatGetOfflineTimeline ? window.__floatGetOfflineTimeline() : []") { [weak self] result, error in
                if let error { NSLog("[OfflineDub] direct timeline JS error: %@", error.localizedDescription) }
                guard let self, self.isOfflineDubEnabled else { return }
                let raw = result as? [[String: Any]] ?? []
                if ProcessInfo.processInfo.environment["VIBEFLOAT_DUB_DEBUG"] == "1" {
                    NSLog("[OfflineDub] direct timeline cues=%d", raw.count)
                }
                let cues = raw.compactMap { item -> OfflineDubSession.Cue? in
                    guard let start = (item["start"] as? NSNumber)?.doubleValue,
                          let end = (item["end"] as? NSNumber)?.doubleValue,
                          let text = item["text"] as? String else { return nil }
                    return OfflineDubSession.Cue(start: start, end: end, text: text)
                }
                if cues.isEmpty {
                    self.webView?.evaluateJavaScript("if (window.__floatRequestOfflineTimeline) { window.__floatRequestOfflineTimeline(); }")
                    if delay < 2.0 {
                        self.requestOfflineTimelineFromWebView(after: delay + 0.45)
                    } else if self.offlineDubTimelineSignature == nil {
                        self.scanBurnedInSubtitlesIfPossible()
                    }
                } else {
                    self.prepareOfflineDubbing(cues)
                }
            }
        }
    }

    private func scanBurnedInSubtitlesIfPossible() {
        guard isOfflineDubEnabled, offlineDubOCR == nil else { return }
        guard let source = currentOfflineVideoURL,
              source.path.lowercased().hasSuffix(".m3u8") || source.path.lowercased().hasSuffix(".mp4") else {
            updateOfflineDubProgress("Offline Dub • Không có track phụ đề hoặc nguồn video để quét OCR.")
            return
        }
        offlineDubUsedOCR = true
        let scanner = OfflineSubtitleOCR()
        offlineDubOCR = scanner
        updateOfflineDubProgress("Offline Dub • Phụ đề gắn trong hình — đang quét OCR 0%",
                                 progress: 0, active: true)
        scanner.scan(url: source, expectedDuration: playbackDuration, onProgress: { [weak self, weak scanner] time, count, percent in
            guard let self, let scanner, self.isOfflineDubEnabled, self.offlineDubOCR === scanner else { return }
            let shownPercent = max(0, percent)
            let overall = Double(shownPercent) / 200.0
            self.updateOfflineDubProgress(
                percent >= 0
                    ? "Offline Dub • Quét OCR \(shownPercent)% (tổng \(Int(overall * 100))%) — \(self.formatTime(time)), \(count) câu"
                    : "Offline Dub • Quét OCR — \(self.formatTime(time)), \(count) câu",
                progress: percent >= 0 ? overall : nil,
                indeterminate: percent < 0,
                active: true
            )
        }) { [weak self, weak scanner] result in
            guard let self, let scanner, self.isOfflineDubEnabled, self.offlineDubOCR === scanner else { return }
            self.offlineDubOCR = nil
            switch result {
            case .success(let cues):
                self.updateOfflineDubProgress("Offline Dub • Quét OCR xong — tìm thấy \(cues.count) câu (50%)",
                                              progress: 0.5, active: true)
                self.prepareOfflineDubbing(cues)
            case .failure(let error):
                self.updateOfflineDubProgress("Offline Dub • Quét OCR lỗi: \(error.localizedDescription)")
                self.showHUD("Offline Dub: \(error.localizedDescription)")
            }
        }
    }

    private func updateOfflineDubProgress(_ message: String?, progress: Double? = nil,
                                          indeterminate: Bool = false, active: Bool = false) {
        guard let label = offlineDubProgressLabel else { return }
        offlineDubProgressDismissWorkItem?.cancel()
        offlineDubProgressDismissWorkItem = nil
        offlineDubProgressMessage = message ?? ""
        if ProcessInfo.processInfo.environment["VIBEFLOAT_DUB_DEBUG"] == "1" {
            NSLog("[OfflineDub] progress %@", message ?? "(hidden)")
        }
        offlineDubLastProgressAt = Date()
        if active {
            if offlineDubProgressTimer == nil {
                offlineDubProgressTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    self?.renderOfflineDubProgressText()
                }
            }
        } else {
            offlineDubProgressTimer?.invalidate()
            offlineDubProgressTimer = nil
        }
        renderOfflineDubProgressText()
        label.isHidden = message == nil
        let width = min(520, max(160, (contentView?.bounds.width ?? 320) - 28))
        label.frame.size = NSSize(width: width, height: 24)
        guard let bar = offlineDubProgressBar else { return }
        bar.isHidden = message == nil
        bar.isIndeterminate = indeterminate
        if indeterminate {
            bar.startAnimation(nil)
        } else {
            bar.stopAnimation(nil)
            bar.doubleValue = min(1, max(0, progress ?? 0))
        }
        bar.frame.size.width = width
    }

    private func dismissOfflineDubProgress(after delay: TimeInterval) {
        offlineDubProgressDismissWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isOfflineDubEnabled, self.offlineDubSession.isReady else { return }
            self.offlineDubProgressDismissWorkItem = nil
            self.updateOfflineDubProgress(nil)
        }
        offlineDubProgressDismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func renderOfflineDubProgressText() {
        guard let label = offlineDubProgressLabel else { return }
        let waiting = Int(Date().timeIntervalSince(offlineDubLastProgressAt))
        let suffix = offlineDubProgressTimer != nil && waiting >= 3
            ? (waiting >= 30 ? " • chờ \(waiting)s, kiểm tra mạng" : " • đang chờ \(waiting)s")
            : ""
        label.stringValue = offlineDubProgressMessage + suffix
        label.toolTip = label.stringValue
    }

    private func forcePauseForOfflineDubbing() {
        webView?.setAllMediaPlaybackSuspended(true, completionHandler: nil)
        let js = """
        (function() {
            window.__floatOfflineDubHold = true;
            document.querySelectorAll('video').forEach(function(v) { try { v.pause(); } catch(e) {} });
            if (window.jwplayer && typeof window.jwplayer === 'function') {
                try { window.jwplayer().pause(); } catch(e) {}
            }
            if (window.playerCommand) { try { window.playerCommand('pause'); } catch(e) {} }
        })();
        """
        webView?.evaluateJavaScript(js, completionHandler: nil)
        webView?.evaluateJavaScript("window.__floatControlEmbeddedMedia && window.__floatControlEmbeddedMedia('pause')", completionHandler: nil)
        isPlaying = false
        offlineDubSession.update(videoTime: playbackElapsed, playing: false, rate: playbackRate)
    }

    func setAIDubEnabled(_ enabled: Bool) {
        if enabled != isOfflineDubEnabled {
            toggleOfflineDubbing()
        }
    }

    private func refreshAIDubButtonStyle() {
        guard let btn = stripDubButton else { return }
        btn.contentTintColor = (isOfflineDubEnabled || isAIDubEnabled) ? VibeTheme.accent : VibeTheme.icon
        setButtonSymbol(btn, isOfflineDubEnabled ? "waveform.badge.plus" : (isAIDubEnabled ? "waveform.badge.mic" : "waveform"), pointSize: 12)
        btn.toolTip = isOfflineDubEnabled
            ? "Offline Dub đang bật — bấm Thêm để tắt"
            : "Offline Dub — dựng audio trước rồi phát"
    }

    private func setupAIDubbing() {
        EdgeTTSManager.shared.warmup()
    }

    private func normalizedForDubbing(_ str: String) -> String {
        return SubtitleClassifier.normalizedForDubbing(str)
    }

    func prefetchAIDubText(_ text: String) {
        let clean = SubtitleClassifier.cleanSubtitleText(text)
        guard clean.count >= 2 else { return }
        DubbingTranslator.shared.translateToVietnamese(text: clean) { viText in
            EdgeTTSManager.shared.prefetch(text: viText)
        }
    }

    func prefetchBatchAIDubTexts(_ texts: [String]) {
        let cleaned = texts.map { SubtitleClassifier.cleanSubtitleText($0) }.filter { $0.count >= 2 }
        guard !cleaned.isEmpty else { return }
        if ProcessInfo.processInfo.environment["VIBEFLOAT_DUB_DEBUG"] == "1" {
            NSLog("[AIDub] timeline prefetch batch count=%d", cleaned.count)
        }
        DubbingTranslator.shared.translateBatch(texts: cleaned) { dict in
            for vi in dict.values {
                EdgeTTSManager.shared.prefetch(text: vi)
            }
        }
    }

    func speakAIDubText(_ text: String, duration: Double = 0, force: Bool = false) {
        guard isAIDubEnabled || force else { return }

        let clean = SubtitleClassifier.cleanSubtitleText(text)
        guard clean.count >= 2 else { return }
        let sourceKey = normalizedForDubbing(clean)
        if !force && sourceKey == lastRequestedDubSource && Date().timeIntervalSince(lastRequestedDubAt) < 1.0 { return }
        lastRequestedDubSource = sourceKey
        lastRequestedDubAt = Date()
        let generation = dubGeneration
        latestDubSequence &+= 1
        let sequence = latestDubSequence
        let requestedAt = Date()

        // If dialogue is already authentic Vietnamese, synthesize immediately without async translation hop!
        if SubtitleClassifier.isLikelyVietnameseDialogue(clean) {
            self.speakAIDubVietnameseText(clean, duration: duration, force: force, generation: generation, sequence: sequence, requestedAt: requestedAt)
            return
        }

        DubbingTranslator.shared.translateToVietnamese(text: clean) { [weak self] viText in
            DispatchQueue.main.async {
                guard let self = self, self.dubGeneration == generation, self.latestDubSequence == sequence else { return }
                guard self.isAIDubEnabled || force else { return }
                self.speakAIDubVietnameseText(viText, duration: duration, force: force, generation: generation, sequence: sequence, requestedAt: requestedAt)
            }
        }
    }

    private func speakAIDubVietnameseText(_ text: String, duration: Double = 0, force: Bool = false, generation: Int, sequence: Int, requestedAt: Date) {
        guard dubGeneration == generation, latestDubSequence == sequence else { return }
        guard isAIDubEnabled || force else { return }

        // Sliding window deduplication (12s history, near-duplicate & substring filter)
        if !force {
            guard dubDeduplicator.shouldDub(text: text) else {
                return
            }
        }

        let clean = SubtitleClassifier.cleanSubtitleText(text)
        guard clean.count >= 2 else { return }
        let norm = normalizedForDubbing(clean)

        lastDubbedText = clean
        lastDubbedNorm = norm
        lastDubbedTime = Date()
        if duration > 0 {
            lastTextTrackDubbedAt = Date()
        }

        // Match the prefetch rate so the prepared audio can start immediately.
        // AVAudioPlayer adjusts playback rate to the remaining cue duration.
        let edgeRate = EdgeTTSManager.calculateSubtitleRate(text: clean)

        EdgeTTSManager.shared.synthesize(text: clean, rate: edgeRate) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, self.dubGeneration == generation, self.latestDubSequence == sequence else { return }
                guard self.isAIDubEnabled || force else { return }

                switch result {
                case .success(let audioURL):
                    if duration > 0.4 && Date().timeIntervalSince(requestedAt) >= duration {
                        NSLog("[AIDub] Dropped audio after cue expired (%.2fs)", Date().timeIntervalSince(requestedAt))
                        return
                    }
                    // Queue-level deduplication:
                    // 1. Don't queue if this exact line is currently being spoken
                    if let playing = self.currentPlayingItem {
                        if playing.normalized == norm || SubtitleClassifier.isNearDuplicate(clean, of: playing.text) {
                            return
                        }
                    }

                    // A new cue takes the audio slot as soon as its MP3 is ready.
                    // Waiting for the previous sentence is the main source of lag.
                    self.edgeAudioPlayer?.stop()
                    self.edgeAudioPlayer = nil
                    self.currentPlayingItem = nil
                    self.dubQueue.removeAll()

                    let item = DubItem(text: clean, normalized: norm, audioURL: audioURL, createdAt: requestedAt, cueDuration: duration)
                    self.dubQueue.append(item)
                    self.drainDubQueueIfNeeded()

                case .failure(let error):
                    NSLog("[FloatVideo] Edge TTS failed (%@)", error.localizedDescription)
                }
            }
        }
    }

    private func drainDubQueueIfNeeded() {
        guard isAIDubEnabled else {
            dubQueue.removeAll()
            currentPlayingItem = nil
            if let player = edgeAudioPlayer, player.isPlaying { player.stop() }
            edgeAudioPlayer = nil
            unduckForDubbing()
            return
        }

        // If dialogue is currently playing, let it finish and trigger next via delegate
        if let player = edgeAudioPlayer, player.isPlaying {
            return
        }

        let now = Date()
        // Drop dialogue items older than 4.5s so speech never lags behind the screen
        dubQueue.removeAll { now.timeIntervalSince($0.createdAt) > 4.5 }

        // If multiple items are backed up in queue, keep only the latest 1 to immediately recover sync!
        if dubQueue.count > 1 {
            let newest = dubQueue.removeLast()
            dubQueue.removeAll()
            dubQueue.append(newest)
        }

        guard !dubQueue.isEmpty else {
            currentPlayingItem = nil
            unduckForDubbing()
            return
        }

        let nextItem = dubQueue.removeFirst()
        do {
            let player = try AVAudioPlayer(contentsOf: nextItem.audioURL)
            player.delegate = self
            player.enableRate = true

            // Time-slot compression: match playback rate to the cue's visual duration
            let audioDuration = player.duration
            let targetDuration = nextItem.cueDuration > 0.4 ? nextItem.cueDuration : max(1.2, Double(nextItem.text.count) / 13.0)
            let maxAllowedTime = targetDuration * 1.15

            if audioDuration > maxAllowedTime {
                let requiredRate = Float(audioDuration / maxAllowedTime)
                player.rate = min(1.65, max(1.10, requiredRate))
            } else {
                player.rate = 1.15
            }

            player.volume = 1.0
            player.prepareToPlay()
            duckForDubbing()
            player.play()
            self.edgeAudioPlayer = player
            self.currentPlayingItem = nextItem
            if ProcessInfo.processInfo.environment["VIBEFLOAT_DUB_DEBUG"] == "1" {
                NSLog("[AIDub] window audio started %.3fs after cue", Date().timeIntervalSince(nextItem.createdAt))
            }
        } catch {
            NSLog("[FloatVideo] AVAudioPlayer failed (%@)", error.localizedDescription)
            self.edgeAudioPlayer = nil
            self.currentPlayingItem = nil
            drainDubQueueIfNeeded()
        }
    }

    func stopAIDub() {
        dubGeneration &+= 1
        lastRequestedDubSource = ""
        dubQueue.removeAll()
        currentPlayingItem = nil
        dubDeduplicator.reset()
        EdgeTTSManager.shared.cancelAll()
        if let player = edgeAudioPlayer, player.isPlaying {
            player.stop()
        }
        edgeAudioPlayer = nil
        unduckForDubbing()
        lastDubbedNorm = ""
        lastDubbedText = ""
    }

    private func duckForDubbing() {
        guard !isAudioDuckedByDubbing else { return }
        isAudioDuckedByDubbing = true
        let js = """
        (function() {
            var v = window.__floatVideoMainVideo || document.querySelector('video');
            if (v) {
                if (window.__floatPreDubVol === undefined) window.__floatPreDubVol = v.volume;
                v.volume = Math.max(0.05, (window.__floatPreDubVol || 1.0) * 0.22);
            }
            if (window.jwplayer && typeof window.jwplayer === 'function') {
                try {
                    var jw = window.jwplayer();
                    if (window.__floatJwVol === undefined && jw.getVolume) window.__floatJwVol = jw.getVolume();
                    if (jw.setVolume) jw.setVolume(20);
                } catch(e) {}
            }
        })();
        """
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    private func unduckForDubbing() {
        guard isAudioDuckedByDubbing else { return }
        isAudioDuckedByDubbing = false
        let js = """
        (function() {
            var v = window.__floatVideoMainVideo || document.querySelector('video');
            if (v && window.__floatPreDubVol !== undefined) {
                v.volume = window.__floatPreDubVol;
                delete window.__floatPreDubVol;
            }
            if (window.jwplayer && typeof window.jwplayer === 'function') {
                try {
                    var jw = window.jwplayer();
                    if (window.__floatJwVol !== undefined && jw.setVolume) {
                        jw.setVolume(window.__floatJwVol);
                        delete window.__floatJwVol;
                    }
                } catch(e) {}
            }
        })();
        """
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    private func scanSubtitlesIfNeeded() {
        guard isAIDubEnabled, isPlaying, !subtitleScanBusy else { return }
        let now = Date()
        guard now.timeIntervalSince(lastSubtitleScanAt) >= 0.35 else { return }
        // Suppress OCR scanning if soft text tracks are actively delivering cues
        guard now.timeIntervalSince(lastTextTrackDubbedAt) >= 4.0 else { return }

        let bounds = webView.bounds
        guard bounds.width > 80, bounds.height > 50 else { return }

        subtitleScanBusy = true
        lastSubtitleScanAt = now
        let scanStartedAt = now
        let generation = loadGeneration

        let config = WKSnapshotConfiguration()
        // Subtitle strip: bottom 25% of the webView, inset 5% horizontally to avoid sidebars/watermarks
        let subH = bounds.height * 0.25
        let subY = bounds.height * 0.74
        config.rect = CGRect(x: bounds.width * 0.05, y: subY, width: bounds.width * 0.90, height: subH)
        config.snapshotWidth = NSNumber(value: 960)

        webView.takeSnapshot(with: config) { [weak self] image, error in
            guard let self = self else { return }
            guard self.loadGeneration == generation, let image = image, error == nil else {
                self.subtitleScanBusy = false
                return
            }

            self.subtitleQueue.async { [weak self] in
                guard let self = self else { return }
                defer {
                    DispatchQueue.main.async { self.subtitleScanBusy = false }
                }
                guard self.loadGeneration == generation else { return }

                var rect = CGRect(origin: .zero, size: image.size)
                guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return }

                var inputCG = cg
                let ci = CIImage(cgImage: cg)
                if let filter = CIFilter(name: "CIColorControls") {
                    filter.setValue(ci, forKey: kCIInputImageKey)
                    filter.setValue(1.35, forKey: kCIInputContrastKey)
                    filter.setValue(0.04, forKey: kCIInputBrightnessKey)
                    if let output = filter.outputImage,
                       let enhanced = self.ciContext.createCGImage(output, from: output.extent) {
                        inputCG = enhanced
                    }
                }

                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.recognitionLanguages = ["vi-VN"]
                let handler = VNImageRequestHandler(cgImage: inputCG, options: [:])
                try? handler.perform([request])

                let hits = (request.results ?? []).compactMap { obs -> SubtitleTextHit? in
                    guard let text = obs.topCandidates(1).first?.string else { return nil }
                    return SubtitleTextHit(text: text, box: obs.boundingBox)
                }

                guard let cleanDialogue = SubtitleClassifier.extractCleanSubtitle(from: hits) else {
                    return
                }

                DispatchQueue.main.async {
                    guard self.loadGeneration == generation, self.isAIDubEnabled, self.isPlaying else { return }
                    if ProcessInfo.processInfo.environment["VIBEFLOAT_DUB_DEBUG"] == "1" {
                        NSLog("[AIDub] OCR found cue in %.3fs", Date().timeIntervalSince(scanStartedAt))
                    }
                    // Prevent duplicate OCR triggers across consecutive frames
                    guard self.dubDeduplicator.shouldDub(text: cleanDialogue) else { return }
                    NSLog("[FloatVideo] Extracted movie subtitle: \(cleanDialogue)")
                    self.speakAIDubText(cleanDialogue, duration: 0, force: true)
                }
            }
        }
    }

    // MARK: - AVAudioPlayerDelegate

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            guard let self = self else { return }
            if self.edgeAudioPlayer === player {
                self.edgeAudioPlayer = nil
                self.currentPlayingItem = nil
                self.drainDubQueueIfNeeded()
            }
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.edgeAudioPlayer === player {
                self.edgeAudioPlayer = nil
                self.currentPlayingItem = nil
                self.drainDubQueueIfNeeded()
            }
        }
    }

    /// Hand the chosen lift to the page, and relay it into child frames in case
    /// the real `<video>` lives behind a cross-origin boundary. The page reports
    /// back through `__floatAudioBoostStatus`, which is logged when it is not
    /// `on` so a page that silently refuses the graph is attributable.
    private func pushAudioBoostState() {
        let level = Self.preferredAudioBoost
        let js = """
        (function() {
            var factor = \(level.factor);
            var status = 'unsupported';
            try {
                if (window.__floatSetAudioBoost) status = window.__floatSetAudioBoost(factor);
            } catch (e) {}
            var frames = document.querySelectorAll('iframe');
            for (var i = 0; i < frames.length; i++) {
                try { frames[i].contentWindow.postMessage({ __floatAudioBoost: factor }, '*'); } catch (e) {}
            }
            return status || 'unsupported';
        })();
        """
        lastAudioBoostPushAt = Date()
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self = self else { return }
            let status = result as? String ?? "unknown"
            self.lastAudioBoostStatus = status
            if level != .off, status != "on", status != "pending" {
                NSLog("[FloatVideo] Audio boost \(level.menuTitle) not applied: \(status)")
            }
        }
    }

    /// The first seconds of a load have no `<video>`, and the AudioContext can
    /// stay suspended until the first real playback resumes it. Retry at a slow
    /// cadence so the choice eventually lands without another user action.
    private func retryAudioBoostIfNeeded() {
        guard Self.preferredAudioBoost != .off, lastAudioBoostStatus != "on" else { return }
        guard Date().timeIntervalSince(lastAudioBoostPushAt) > 2.5 else { return }
        pushAudioBoostState()
    }


    @objc func setOpacity(_ val: Double) {
        let clamped = max(0.8, min(1.0, CGFloat(val)))
        self.animator().alphaValue = clamped
        if !isGhostMode { preGhostAlpha = clamped }
    }

    @objc func toggleBossHide() {
        if isWindowVisible {
            emitProgress(force: true)
            hideTimer?.cancel()
            hideTimer = nil
            if isPlaying {
                pause()
                pausedForBoss = true
            } else {
                pausedForBoss = false
            }
            controlStrip?.orderOut(nil)
            self.orderOut(nil)
            isWindowVisible = false
            isHovering = false
        } else {
            self.orderFrontRegardless()
            isWindowVisible = true
            syncControlStrip(animated: false)
            showControls()
            scheduleHideControls(after: Self.chromeHideDelay)
            if pausedForBoss {
                play()
                pausedForBoss = false
            }
        }
    }

    func applyDock(videoFrame: NSRect, animated: Bool) {
        let videoFrame = keepingLockedOrigin(videoFrame)
        if isPinned {
            setFrame(videoFrame, display: true)
            syncControlStrip(animated: false)
            return
        }
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if animated && !reduced {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.32
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.animator().setFrame(videoFrame, display: true)
            }, completionHandler: { [weak self] in
                self?.syncControlStrip(animated: false)
            })
        } else {
            setFrame(videoFrame, display: true)
            syncControlStrip(animated: false)
        }
    }

    func syncControlStrip(animated: Bool) {
        guard let strip = controlStrip else { return }
        let target = predictedStripFrame(for: frame)
        if animated {
            strip.animator().setFrame(target, display: true)
        } else {
            strip.setFrame(target, display: true)
        }
        if isWindowVisible { strip.orderFrontRegardless() }
        layoutControlBar()
    }

    private func predictedStripFrame(for video: NSRect) -> NSRect {
        let screen = self.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? video
        return VibePlacer.stripFrame(video: video, screen: screen)
    }

    private func mountControlStrip() {
        guard let bar = controlBarView else { return }
        if controlStrip != nil {
            syncControlStrip(animated: false)
            return
        }
        bar.removeFromSuperview()
        let panel = ControlStripPanel(
            contentRect: NSRect(x: 0, y: 0, width: frame.width, height: VibePlacer.stripHeight),
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.owner = self
        panel.title = "VibeFloat — Điều khiển"
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)) + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        bar.frame = panel.contentView?.bounds ?? NSRect(x: 0, y: 0, width: frame.width, height: VibePlacer.stripHeight)
        bar.autoresizingMask = [.width, .height]
        bar.alphaValue = 1
        bar.isHidden = false
        panel.contentView = bar
        // Tracking so mouseMoved delivers edge cursors on the strip.
        if let content = panel.contentView {
            let tracking = NSTrackingArea(
                rect: content.bounds,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                owner: panel,
                userInfo: nil
            )
            content.addTrackingArea(tracking)
        }
        controlStrip = panel
        syncControlStrip(animated: false)
        layoutVideoChrome()
    }

    private func layoutVideoChrome() {
        guard let container = contentView, let webView = webView else { return }
        let bounds = container.bounds
        // Controls live on the external strip — video uses the full panel.
        webView.frame = bounds
        resizeEdgeView?.frame = bounds
        loadingOverlay?.frame = webView.frame
        let progressWidth = min(520, max(160, bounds.width - 28))
        offlineDubProgressLabel?.frame = NSRect(x: 14, y: max(52, bounds.height - 64),
                                               width: progressWidth, height: 24)
        offlineDubProgressBar?.frame = NSRect(x: 14, y: max(42, bounds.height - 75),
                                             width: progressWidth, height: 7)
        if titleBarView != nil {
            let titleH = titleBarView.frame.height > 0 ? titleBarView.frame.height : 30
            titleBarView.frame = NSRect(x: 0, y: bounds.height - titleH, width: bounds.width, height: titleH)
        }
    }

    func trackMoveFromStrip() {
        guard !isPinned, let strip = controlStrip else { return }
        autoDockPaused = true
        let startMouse = NSEvent.mouseLocation
        let startOrigin = frame.origin
        strip.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .eventTracking) { [weak self] event, stop in
            guard let self = self, let event = event else { return }
            if event.type == .leftMouseUp {
                stop.pointee = true
                return
            }
            let mouse = NSEvent.mouseLocation
            self.setFrameOrigin(NSPoint(
                x: startOrigin.x + mouse.x - startMouse.x,
                y: startOrigin.y + mouse.y - startMouse.y
            ))
            self.syncControlStrip(animated: false)
        }
        autoDockPaused = false
        vibeDock.noteUserDidPlace()
        saveWindowFrame()
    }

    func trackResizeFromStrip() {
        guard let strip = controlStrip else { return }
        noteStripInteraction()
        autoDockPaused = true
        isResizing = true
        initialMouseLocation = NSEvent.mouseLocation
        initialWindowFrame = frame
        resizeEdge = NSEvent.mouseLocation.x > frame.midX ? .right : .left
        strip.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .eventTracking) { [weak self] event, stop in
            guard let self = self, let event = event else { return }
            if event.type == .leftMouseUp {
                stop.pointee = true
                return
            }
            self.mouseDragged(with: event)
        }
        isResizing = false
        resizeEdge = .none
        autoDockPaused = false
        vibeDock.noteUserDidPlace()
        saveWindowFrame()
        scheduleHideControlsIfPointerLeft(after: Self.chromeHideDelay)
    }

    // MARK: - Resize Edge Detection

    private func detectResizeEdge(at point: NSPoint) -> ResizeEdge {
        let w = self.frame.width
        let h = self.frame.height
        let b = resizeBorderWidth

        // The drawn grip is the resize handle, including the part above the thin edge.
        if let grip = resizeIndicator, grip.alphaValue > 0.2,
           grip.frame.insetBy(dx: -8, dy: -8).contains(point) {
            return .bottomRight
        }

        // The playback bar owns the bottom of the window. Don't turn it into a resize edge.
        if isOnPlaybackBar(point), point.x >= b, point.x <= w - b {
            return .none
        }

        let onLeft = point.x < b
        let onRight = point.x > w - b
        let onBottom = point.y < b && !isOnPlaybackBar(point)
        let onTop = point.y > h - b

        if onTop && onLeft { return .topLeft }
        if onTop && onRight { return .topRight }
        if onBottom && onLeft { return .bottomLeft }
        if onBottom && onRight { return .bottomRight }
        if onLeft { return .left }
        if onRight { return .right }
        if onBottom { return .bottom }
        if onTop { return .top }
        return .none
    }

    private func cursorForEdge(_ edge: ResizeEdge) -> NSCursor {
        switch edge {
        case .left, .right, .topLeft, .bottomRight, .topRight, .bottomLeft:
            return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        case .none: return .arrow
        }
    }

    // MARK: - Event Interception (intercept resize events before WKWebView)

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            // Synthetic trusted clicks (ad skip) must reach the web view even
            // when they land inside the resize border.
            if isPostingSyntheticClick { break }
            // Position lock also blocks dragging the external playback bar;
            // manual edge/corner resize remains available.
            let location = event.locationInWindow
            if isOnPlaybackBar(location) {
                if !playbackHitIsControl(location) {
                    if isPinned { break }
                    autoDockPaused = true
                    performDrag(with: event)
                    autoDockPaused = false
                    vibeDock.noteUserDidPlace()
                    return
                }
                break
            }
            let edge = detectResizeEdge(at: location)
            if edge != .none {
                // When title bar is visible, drag takes priority over top-edge resize
                if titleBarView.alphaValue > 0,
                   titleBarView.frame.contains(location) {
                    break // Let DraggableTitleBar handle the drag
                }
                // Ghost mode passes clicks through — edge resize is unavailable on the
                // video panel; strip L/R grips and +/- / hotkeys still resize.
                if isGhostMode { break }
                isResizing = true
                resizeEdge = edge
                initialMouseLocation = NSEvent.mouseLocation
                initialWindowFrame = self.frame
                showControls()
                return
            }
        case .leftMouseDragged:
            if isResizing {
                mouseDragged(with: event)
                return
            }
        case .leftMouseUp:
            if isResizing {
                mouseUp(with: event)
                return
            }
        default:
            break
        }
        super.sendEvent(event)
    }

    // MARK: - Mouse Handling

    private func isOnPlaybackBar(_ point: NSPoint) -> Bool {
        guard isHovering, let bar = controlBarView, !bar.isHidden, bar.superview != nil, bar.alphaValue > 0.05 else { return false }
        return bar.frame.contains(point)
    }

    private func playbackHitIsControl(_ point: NSPoint) -> Bool {
        guard let container = contentView, let hit = container.hitTest(point) else { return false }
        var view: NSView? = hit
        while let current = view {
            if current === controlBarView { return false }
            if current is NSControl || current is ModernScrubberView { return true }
            view = current.superview
        }
        return false
    }

    private func cursorForPlaybackBar(at point: NSPoint) -> NSCursor {
        playbackHitIsControl(point) ? .pointingHand : .openHand
    }

    override func mouseMoved(with event: NSEvent) {
        let location = event.locationInWindow
        if isOnPlaybackBar(location) {
            cursorForPlaybackBar(at: location).set()
            return
        }
        if titleBarView.alphaValue > 0.05, titleBarView.frame.contains(location) {
            NSCursor.openHand.set()
            return
        }
        let edge = detectResizeEdge(at: location)
        cursorForEdge(edge).set()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            let loc = event.locationInWindow
            let onControlBar = (controlBarView.alphaValue > 0.1 && controlBarView.frame.contains(loc))
            if !onControlBar {
                toggleMaximize()
                return
            }
        }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isResizing else {
            super.mouseDragged(with: event)
            return
        }

        // Dragging an edge is a deliberate size choice; stop auto-fitting.
        userLockedSize = true
        let currentMouse = NSEvent.mouseLocation
        let deltaX = currentMouse.x - initialMouseLocation.x
        let deltaY = currentMouse.y - initialMouseLocation.y
        var newFrame = initialWindowFrame
        let aspect = videoAspectRatio

        // Corner drags follow whichever axis the pointer moved more, then lock aspect.
        func width(fromX: CGFloat, fromY: CGFloat, corner: Bool) -> CGFloat {
            if !corner || abs(deltaX) >= abs(deltaY) { return fromX }
            return fromY
        }
        switch resizeEdge {
        case .right:
            newFrame.size.width = initialWindowFrame.width + deltaX
        case .left:
            newFrame.size.width = initialWindowFrame.width - deltaX
        case .top:
            newFrame.size.width = (initialWindowFrame.height + deltaY) * aspect
        case .bottom:
            newFrame.size.width = (initialWindowFrame.height - deltaY) * aspect
        case .topRight:
            newFrame.size.width = width(
                fromX: initialWindowFrame.width + deltaX,
                fromY: (initialWindowFrame.height + deltaY) * aspect,
                corner: true
            )
        case .bottomRight:
            newFrame.size.width = width(
                fromX: initialWindowFrame.width + deltaX,
                fromY: (initialWindowFrame.height - deltaY) * aspect,
                corner: true
            )
        case .topLeft:
            newFrame.size.width = width(
                fromX: initialWindowFrame.width - deltaX,
                fromY: (initialWindowFrame.height + deltaY) * aspect,
                corner: true
            )
        case .bottomLeft:
            newFrame.size.width = width(
                fromX: initialWindowFrame.width - deltaX,
                fromY: (initialWindowFrame.height - deltaY) * aspect,
                corner: true
            )
        case .none:
            break
        }
        if resizeEdge != .none {
            newFrame.size.height = newFrame.size.width / aspect
        }

        // Enforce min/max size while keeping aspect ratio
        let minW = self.minSize.width
        let maxW = max(self.maxSize.width, minW)
        if newFrame.size.width < minW {
            newFrame.size.width = minW
            newFrame.size.height = minW / videoAspectRatio
        } else if newFrame.size.width > maxW {
            newFrame.size.width = maxW
            newFrame.size.height = maxW / videoAspectRatio
        }

        // Anchor to opposite edge
        switch resizeEdge {
        case .left, .bottomLeft, .topLeft:
            newFrame.origin.x = initialWindowFrame.maxX - newFrame.size.width
        default: break
        }
        switch resizeEdge {
        case .bottom, .bottomLeft, .bottomRight:
            newFrame.origin.y = initialWindowFrame.maxY - newFrame.size.height
        default: break
        }

        self.setFrame(keepingLockedOrigin(newFrame), display: true, animate: false)
        syncControlStrip(animated: false)
    }

    override func mouseUp(with event: NSEvent) {
        if isResizing {
            saveWindowFrame()
            vibeDock.noteUserDidPlace()
        }
        isResizing = false
        resizeEdge = .none
        NSCursor.arrow.set()
        super.mouseUp(with: event)
    }

    override func mouseEntered(with event: NSEvent) {
        hideTimer?.cancel()
        showControls()
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        if !isResizing {
            NSCursor.arrow.set()
        }
        // Long idle only — short delay raced strip reveal and caused flicker.
        if isPointerOverChrome() {
            hideTimer?.cancel()
            hideTimer = nil
        } else {
            scheduleHideControls(after: Self.chromeHideDelay)
        }
        super.mouseExited(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        // Option+scroll (or trackpad pinch-like vertical scroll) resizes while hovering.
        // Works when ghost is OFF (video receives events). Ghost ON: use strip +/- or ⌃⌥=/−.
        let wantsResize = event.modifierFlags.contains(.option)
            || detectResizeEdge(at: event.locationInWindow) != .none
        guard wantsResize, !isGhostMode else {
            super.scrollWheel(with: event)
            return
        }
        let delta = event.scrollingDeltaY
        guard abs(delta) > 0.2 else { return }
        let factor: CGFloat = delta > 0 ? 1.06 : (1.0 / 1.06)
        adjustWindowScale(by: factor)
        showControls()
        scheduleHideControlsIfPointerLeft(after: Self.chromeHideDelay)
    }

    // Allow window to become key window + respond to first click
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override var acceptsMouseMovedEvents: Bool {
        get { true }
        set { super.acceptsMouseMovedEvents = newValue }
    }

    // Comprehensive keyboard shortcuts (Space, Arrows, M, F, J, K, L, Digits 0-9, ESC)
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // ESC
            if isMaximized {
                toggleMaximize()
            } else {
                closeWindow()
            }
        case 49, 40: // Space, K -> Play/Pause
            togglePlayPause()
            showControls()
            scheduleHideControls(after: 2.0)
        case 123, 38: // Left Arrow, J -> Rewind 10s
            skipBackward()
            showControls()
            scheduleHideControls(after: 2.0)
        case 124, 37: // Right Arrow, L -> Forward 10s
            skipForward()
            showControls()
            scheduleHideControls(after: 2.0)
        case 126: // Up Arrow -> Volume Up
            adjustVolume(by: 0.1)
            showControls()
            scheduleHideControls(after: 2.0)
        case 125: // Down Arrow -> Volume Down
            adjustVolume(by: -0.1)
            showControls()
            scheduleHideControls(after: 2.0)
        case 46: // M -> Mute
            toggleMute()
            showControls()
            scheduleHideControls(after: 2.0)
        case 3: // F -> Fullscreen / Maximize
            toggleMaximize()
        case 5: // G -> Ghost Mode (Click-through)
            toggleGhostMode()
            showControls()
            scheduleHideControls(after: 2.0)
        case 11: // B -> Boss Key, Shift+B -> Toggle Banner Blur
            if event.modifierFlags.contains(.shift) {
                toggleManualBannerBlur()
            } else {
                toggleBossHide()
            }
        case 24, 69: // = / keypad + -> grow
            growWindow()
            showControls()
            scheduleHideControls(after: 1.5)
        case 27, 78: // - / keypad - -> shrink
            shrinkWindow()
            showControls()
            scheduleHideControls(after: 1.5)
        default:
            if let chars = event.charactersIgnoringModifiers, let digit = Int(chars), digit >= 0 && digit <= 9 {
                seekTo(percent: Double(digit) / 10.0)
                showControls()
                scheduleHideControls(after: 2.0)
            } else {
                super.keyDown(with: event)
            }
        }
    }
}
