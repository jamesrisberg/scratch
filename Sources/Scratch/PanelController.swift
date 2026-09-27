import AppKit
import Carbon
import HUDKit
import ScratchKit
import SwiftUI

/// HUDKit's panel recipe, keyable so the editor and search field take typing without
/// activating the app: a click (or `show(takeFocus: true)`) makes it key, the app stays in the
/// background. Sidebar undo (delete, clear) comes from the window's undo manager.
final class ScratchPanel: HUDPanelWindow {
    var listUndo: UndoManager?
    override var undoManager: UndoManager? { listUndo ?? super.undoManager }
}

/// Owns the panel window: visibility, the full / compact / parked modes, frames (including
/// frames MacHUD assigns over the socket), keyboard shortcuts and snapshots.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    static let fullSize = CGSize(width: 560, height: 400)
    static let compactSize = CGSize(width: 360, height: 44)
    static let fullStyle = HUDGlassView.Style(cornerRadius: 16, borderWidth: 0.5, borderAlpha: 0.22, gloss: false)
    static let compactStyle = HUDGlassView.Style(cornerRadius: 20, borderWidth: 0.5, borderAlpha: 0.2, gloss: true)
    static let minFullSize = NSSize(width: 340, height: 200)

    let model: AppModel
    let panel: ScratchPanel
    private let glass: HUDGlassView
    private var host: NSHostingView<RootView>!
    private var keyMonitor: Any?

    /// The mode shown (or returned to when unparking).
    private(set) var mode: HUDPanelMode = .full
    private var modeBeforeParking: HUDPanelMode = .full
    private var restFrame: CGRect?
    /// The edge and peek to park at (MacHUD's, once it has named them).
    private(set) var parking = ParkingSpot(peek: 14)
    /// Whether the panel is meant to be on screen (tracked apart from `isVisible`, which is
    /// still true during the fade-out).
    private(set) var isShown = false
    private var isAdjustingFrame = false
    /// Set while a "brief" show (paste to Scratch) is pending its automatic hide.
    private var briefHide: DispatchWorkItem?

    /// Called whenever visibility, mode or frame changes (for `state` events).
    var onStateChange: (() -> Void)?

    init(model: AppModel) {
        self.model = model
        panel = ScratchPanel(contentRect: CGRect(origin: .zero, size: Self.fullSize),
                             styleMask: HUDPanelWindow.recipeStyleMask.union(.resizable), backing: .buffered, defer: false)
        glass = HUDGlassView(style: Self.fullStyle)
        super.init()
        host = NSHostingView(rootView: RootView(model: model,
                                                expand: { [weak self] in self?.setMode(.full, takeFocus: true) },
                                                dismiss: { [weak self] in self?.hide() }))

        panel.keyable = true
        panel.applyHUDRecipe()
        panel.title = "Scratch"
        panel.identifier = NSUserInterfaceItemIdentifier("xyz.machud.scratch.pad")
        panel.becomesKeyOnlyIfNeeded = false
        panel.minSize = Self.minFullSize
        panel.delegate = self
        panel.listUndo = model.listUndo

        host.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            host.topAnchor.constraint(equalTo: glass.topAnchor),
            host.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
        ])
        panel.contentView = glass

        if let saved = Self.savedFrame(Self.fullFrameKey) {
            panel.setFrame(saved, display: false)
        } else {
            centerOnMouseScreen()
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    // MARK: - Keys

    /// Shortcuts for the panel. A non-activating panel of a menu-bar app has no main menu to
    /// route key equivalents, so the standard editing commands are dispatched here too.
    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if Int(event.keyCode) == kVK_Escape, flags.isEmpty {
            if model.isCompact { hide(); return true }
            if !model.searchText.isEmpty { model.searchText = ""; model.editor?.focus(); return true }
            if (panel.firstResponder as? NSTextView)?.hasMarkedText() == true { return false }
            hide()
            return true
        }
        guard flags.contains(.command) else { return false }
        let responder = panel.firstResponder
        func send(_ selector: Selector) -> Bool {
            responder?.tryToPerform(selector, with: nil)
            return true
        }
        switch (key, flags) {
        case ("s", [.command]):
            model.editor?.commitIfEditing(model.selectedID ?? "")
            model.show("Scratch saves automatically")
            return true
        case ("v", [.command, .shift]): model.editor?.pastePlainText(); return true
        case ("c", [.command, .shift]): model.copyPad(); return true
        case ("m", [.command, .shift]): model.toggleMonospace(); return true
        case ("n", [.command]): if model.isCompact { setMode(.full) }; model.newPad(); return true
        case ("k", [.command]):
            if let id = model.selectedID { model.clear(id); model.editor?.focus() }
            return true
        case ("l", [.command, .shift]): model.toggleSidebar(); return true
        case ("f", [.command]):
            // In the editor: the find bar. Elsewhere: the pad search field.
            if model.editor?.isFocused == true { return findInPad() }
            model.focusSearch(); return true
        case ("f", [.command, .option]): model.focusSearch(); return true
        case ("\u{7f}", [.command, .shift]), ("\u{8}", [.command, .shift]):
            if let id = model.selectedID { model.delete(id) }
            return true
        case ("w", [.command]): hide(); return true
        case ("z", [.command]):
            (responder?.undoManager ?? model.listUndo).undo(); return true
        case ("z", [.command, .shift]):
            (responder?.undoManager ?? model.listUndo).redo(); return true
        case ("x", [.command]): return send(#selector(NSText.cut(_:)))
        case ("c", [.command]): return send(#selector(NSText.copy(_:)))
        case ("v", [.command]): return send(#selector(NSText.paste(_:)))
        case ("a", [.command]): return send(#selector(NSText.selectAll(_:)))
        default:
            return false
        }
    }

    /// Cmd-F in the editor opens the find bar.
    private func findInPad() -> Bool {
        guard let textView = model.editor?.textView else { return true }
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        textView.performTextFinderAction(item)
        return true
    }

    var isVisible: Bool { isShown }

    // MARK: - Visibility

    /// How a show animates, picked from MacHUD's `panel show` options (see `showPlan(for:)`).
    struct ShowPlan: Equatable {
        enum Motion: Equatable { case fade, slide(from: HUDEdge) }
        var motion: Motion
        var duration: TimeInterval
        /// Whether the panel becomes key (never activates the app: the panel is non-activating).
        var takeFocus: Bool
    }

    /// How a hide animates, from `panel hide` options (see `hidePlan(for:)`).
    struct HidePlan: Equatable {
        enum Motion: Equatable { case fade, slide(toward: HUDEdge) }
        var motion: Motion
        var duration: TimeInterval
    }

    /// Hover shows fade in almost at once so moving between dock buttons cross-fades.
    nonisolated static let hoverFadeIn: TimeInterval = 0.08
    /// Hides MacHUD asks for (`to=`, or a hover leave) are gone almost at once.
    nonisolated static let quickFadeOut: TimeInterval = 0.1

    /// - `reason=hover`: a 0.08 s fade-in where the panel rests; never key (the pointer passing
    ///   over the dock must not take typing away from the app in front).
    /// - `from=<edge>` otherwise: `HUDAnimation.slide(in:)` out of that edge (0.22 s).
    /// - no options: the plain 0.22 s fade.
    /// `reason=click|summon` make the panel key so typing goes straight to the pad.
    nonisolated static func showPlan(for t: HUDPanelTransition) -> ShowPlan {
        let focus = t.reason == .click || t.reason == .summon
        if t.reason == .hover { return ShowPlan(motion: .fade, duration: hoverFadeIn, takeFocus: false) }
        if let from = t.from { return ShowPlan(motion: .slide(from: from), duration: HUDAnimation.revealDuration, takeFocus: focus) }
        return ShowPlan(motion: .fade, duration: HUDAnimation.revealDuration, takeFocus: focus)
    }

    /// - `to=<edge>`: slide `HUDAnimation.slideTravel` toward that edge while fading, 0.1 s.
    /// - `reason=hover` without `to=`: a 0.1 s fade.
    /// - otherwise: HUDAnimation's 0.18 s fade.
    nonisolated static func hidePlan(for t: HUDPanelTransition) -> HidePlan {
        if let to = t.to { return HidePlan(motion: .slide(toward: to), duration: quickFadeOut) }
        if t.reason == .hover { return HidePlan(motion: .fade, duration: quickFadeOut) }
        return HidePlan(motion: .fade, duration: HUDAnimation.concealDuration)
    }

    /// The frame MacHUD last assigned with `panel frame` for the current mode; cleared when the
    /// user moves or resizes the panel, or the mode changes.
    private(set) var assignedFrame: CGRect?
    /// Where the panel rests while shown (the target of the show in flight).
    private(set) var shownFrame: CGRect?
    /// Bumped by every show and hide; a hide's completion only orders out if nothing newer
    /// started, so a show that arrives mid-hide (hover cross-fade) wins cleanly.
    private var transitionGeneration: UInt = 0
    /// True while a show/hide animation moves the window, so its frames are not saved.
    private var isTransitioning = false

    /// Where a show with these options rests: MacHUD's `panel frame`, else next to the dock
    /// button (`anchor` + `from`), else the last frame.
    func restFrame(for t: HUDPanelTransition) -> CGRect {
        if let assignedFrame { return assignedFrame }
        if let anchored = t.panelFrame(size: shownFrame?.size ?? panel.frame.size) { return anchored }
        return shownFrame ?? panel.frame
    }

    /// Shows the panel at its last frame with the editor ready (first responder, caret at the
    /// end). `takeFocus` makes it key at once, for the user's own summons (hotkey, menu bar);
    /// MacHUD's socket shows (hover) pass false so the pointer passing over the dock never
    /// takes typing away from the app in front: the panel becomes key when clicked. Either
    /// way the app is never activated (the panel is non-activating).
    func show(takeFocus: Bool = true) {
        var plan = Self.showPlan(for: HUDPanelTransition())
        plan.takeFocus = takeFocus
        show(plan: plan, transition: HUDPanelTransition())
    }

    /// `panel show` with MacHUD's options (`from=`, `anchor=`, `reason=`).
    func show(_ transition: HUDPanelTransition) {
        show(plan: Self.showPlan(for: transition), transition: transition)
    }

    private func show(plan: ShowPlan, transition: HUDPanelTransition) {
        cancelBriefHide()
        if mode == .parked { return unpark(takeFocus: plan.takeFocus) }
        let wasShown = isShown
        isShown = true
        transitionGeneration &+= 1
        let generation = transitionGeneration
        var rest = restFrame(for: transition)
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rest) }) {
            centerOnMouseScreen()
            rest = panel.frame
        }
        shownFrame = rest
        let settled: @MainActor () -> Void = { [weak self] in
            guard let self, self.transitionGeneration == generation else { return }
            self.isTransitioning = false
        }
        isTransitioning = true
        switch plan.motion {
        case .slide(let edge):
            HUDAnimation.slide(in: panel, from: edge, to: rest, completion: settled)
        case .fade:
            if !panel.isVisible {
                panel.alphaValue = 0
                setFrameQuietly(rest)
                panel.orderFrontRegardless()
            }
            // Mid-hide the window may be partway toward the dock; always animating the frame to
            // `rest` replaces the hide's frame animation, so it comes back as it fades in.
            HUDAnimation.animate(panel, to: rest, alpha: 1, duration: plan.duration,
                                 timing: HUDAnimation.revealTiming, completion: settled)
        }
        if plan.takeFocus { panel.makeKeyAndOrderFront(nil) } else { panel.orderFrontRegardless() }
        if mode == .full { model.editor?.focus(atEnd: true) }
        if !wasShown { onStateChange?() }
    }

    /// Shows the panel without taking focus and hides it again after `duration`, unless the
    /// user moves into it or it becomes key meanwhile. A panel already on screen is left alone.
    func showBriefly(duration: TimeInterval = 1.8) {
        guard !isShown || briefHide != nil else { return }
        if mode == .parked { return unpark() }
        cancelBriefHide()
        if !isShown { show(takeFocus: false) }
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.briefHide = nil
            if self.panel.isKeyWindow || self.panel.frame.contains(NSEvent.mouseLocation) { return }
            self.hide()
        }
        briefHide = task
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: task)
    }

    private func cancelBriefHide() {
        briefHide?.cancel()
        briefHide = nil
    }

    func hide() { hide(HUDPanelTransition()) }

    /// `panel hide` with MacHUD's options (`to=`, `reason=`). The panel keeps its rest frame
    /// for the next show; a show that starts before the hide finishes wins.
    func hide(_ transition: HUDPanelTransition) {
        cancelBriefHide()
        guard isShown else { return }
        isShown = false
        if mode == .parked, let restFrame {
            mode = modeBeforeParking
            setFrameQuietly(restFrame)
            self.restFrame = nil
        }
        transitionGeneration &+= 1
        let generation = transitionGeneration
        let plan = Self.hidePlan(for: transition)
        let rest = shownFrame ?? panel.frame
        let target: CGRect?
        switch plan.motion {
        case .fade: target = nil
        case .slide(let edge): target = HUDAnimation.offset(rest, toward: edge)
        }
        isTransitioning = true
        HUDAnimation.animate(panel, to: target, alpha: 0, duration: plan.duration, timing: HUDAnimation.concealTiming) { [weak self] in
            guard let self, self.transitionGeneration == generation else { return }
            self.panel.orderOut(nil)
            self.setFrameQuietly(rest)
            self.panel.alphaValue = 1
            self.isTransitioning = false
        }
        onStateChange?()
    }

    func toggle(takeFocus: Bool = true) {
        if mode == .parked { return unpark(takeFocus: takeFocus) }
        if takeFocus {
            isShown && panel.isKeyWindow ? hide() : show()
        } else {
            isShown ? hide() : show(takeFocus: false)
        }
    }

    /// `panel toggle` with options: parked unparks, otherwise shows or hides (a hide takes
    /// `to=` from `from=` when MacHUD only named the dock edge).
    func toggle(_ transition: HUDPanelTransition) {
        if mode == .parked { return unpark(takeFocus: Self.showPlan(for: transition).takeFocus) }
        guard isShown else { return show(transition) }
        var t = transition
        if t.to == nil { t.to = t.from }
        hide(t)
    }

    // MARK: - Modes

    /// `options` carry the edge/peek MacHUD parks at; they only matter for `.parked`.
    func setMode(_ newMode: HUDPanelMode, options: HUDPanelModeOptions = HUDPanelModeOptions(),
                 takeFocus: Bool = false) {
        switch newMode {
        case .parked:
            park(options)
        case .full, .compact:
            if mode == .parked { unpark(to: newMode, takeFocus: takeFocus) } else { apply(newMode) }
            if !isShown { show(takeFocus: takeFocus) } else if takeFocus { panel.makeKey() }
        }
        onStateChange?()
    }

    private func apply(_ newMode: HUDPanelMode) {
        guard newMode != mode else { return }
        saveCurrentFrame()
        assignedFrame = nil
        shownFrame = nil
        mode = newMode
        model.isCompact = newMode == .compact
        glass.style = newMode == .compact ? Self.compactStyle : Self.fullStyle
        if newMode == .compact {
            panel.styleMask.remove(.resizable)
            panel.minSize = NSSize(width: 200, height: Self.compactSize.height)
            setFrameQuietly(Self.savedFrame(Self.compactFrameKey) ?? defaultCompactFrame(), animate: isShown)
        } else {
            panel.styleMask.insert(.resizable)
            panel.minSize = Self.minFullSize
            setFrameQuietly(Self.savedFrame(Self.fullFrameKey) ?? defaultFullFrame(), animate: isShown)
            if isShown { model.editor?.focus(atEnd: true) }
        }
        panel.invalidateShadow()
    }

    /// Parking takes over the window: a show/hide still animating must not order it out or
    /// move it afterwards.
    private func settleTransition() {
        transitionGeneration &+= 1
        isTransitioning = false
        panel.alphaValue = 1
    }

    private func park(_ options: HUDPanelModeOptions) {
        let moved = parking.update(with: options)
        if mode == .parked {
            // Already parked: move to the newly requested edge or peek.
            if moved, let restFrame { setFrameQuietly(parking.offScreenFrame(for: restFrame)) }
            return
        }
        if !isShown { show(takeFocus: false) }
        settleTransition()
        modeBeforeParking = mode
        restFrame = shownFrame ?? panel.frame
        mode = .parked
        let edge = parking.edge(for: panel.frame, in: HUDParking.screenFrame(for: panel.frame))
        isAdjustingFrame = true
        HUDParking.slideOut(panel, edge: edge, peek: parking.peek) { [weak self] in self?.isAdjustingFrame = false }
    }

    private func unpark(to target: HUDPanelMode? = nil, takeFocus: Bool = true) {
        guard mode == .parked else { return }
        settleTransition()
        let rest = restFrame ?? panel.frame
        mode = modeBeforeParking
        restFrame = nil
        isShown = true
        isAdjustingFrame = true
        HUDParking.slideIn(panel, to: rest) { [weak self] in
            guard let self else { return }
            self.isAdjustingFrame = false
            if let target, target != self.mode { self.apply(target) }
            if takeFocus { self.panel.makeKey() }
            self.onStateChange?()
        }
    }

    /// Cooperative placement from MacHUD (`panel frame`), kept as the frame for the current mode.
    func setFrame(_ frame: CGRect) {
        if mode == .parked {
            restFrame = frame
            setFrameQuietly(parking.offScreenFrame(for: frame))
            return
        }
        assignedFrame = frame
        shownFrame = frame
        setFrameQuietly(frame)
        saveCurrentFrame()
        onStateChange?()
    }

    private func setFrameQuietly(_ frame: CGRect, animate: Bool = false) {
        isAdjustingFrame = true
        panel.setFrame(frame, display: true, animate: animate)
        isAdjustingFrame = false
    }

    // MARK: - Frames

    private static let fullFrameKey = "ScratchFullFrame"
    private static let compactFrameKey = "ScratchCompactFrame"

    private static func savedFrame(_ key: String) -> CGRect? {
        guard let string = ScratchEnvironment.defaults.string(forKey: key) else { return nil }
        let rect = NSRectFromString(string)
        return rect.width > 0 && rect.height > 0 ? rect : nil
    }

    private func saveCurrentFrame() {
        switch mode {
        case .full: ScratchEnvironment.defaults.set(NSStringFromRect(panel.frame), forKey: Self.fullFrameKey)
        case .compact: ScratchEnvironment.defaults.set(NSStringFromRect(panel.frame), forKey: Self.compactFrameKey)
        case .parked: break
        }
    }

    private func defaultFullFrame() -> CGRect {
        let visible = (panel.screen ?? NSScreen.main)?.visibleFrame ?? CGRect(origin: .zero, size: Self.fullSize)
        return CGRect(x: visible.midX - Self.fullSize.width / 2, y: visible.midY - Self.fullSize.height / 2,
                      width: Self.fullSize.width, height: Self.fullSize.height)
    }

    /// The strip starts centred under the top edge of where the full panel was.
    private func defaultCompactFrame() -> CGRect {
        let full = panel.frame
        let frame = CGRect(x: full.midX - Self.compactSize.width / 2, y: full.maxY - Self.compactSize.height,
                           width: Self.compactSize.width, height: Self.compactSize.height)
        return HUDParking.restFrame(for: frame, in: HUDParking.screenFrame(for: full))
    }

    func windowDidMove(_ notification: Notification) {
        guard !isAdjustingFrame, !isTransitioning, !panel.inLiveResize else { return }
        userMoved()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        userMoved()
    }

    /// The user placed the panel: that frame wins over MacHUD's until it assigns another.
    private func userMoved() {
        assignedFrame = nil
        if isShown, mode != .parked { shownFrame = panel.frame }
        saveCurrentFrame()
    }

    private func centerOnMouseScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2))
    }

    // MARK: - Snapshot

    /// Writes a PNG of the panel. The glass backdrop blurs what is behind the window, which a
    /// view cache cannot capture, so the content is composited on a dark stand-in with the
    /// panel's corners and hairline border.
    func writeSnapshot(to url: URL) {
        let view: NSView = host
        let scale = panel.backingScaleFactor
        let size = view.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                         pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
        let radius = (mode == .compact ? Self.compactStyle : Self.fullStyle).cornerRadius
        let rect = CGRect(origin: .zero, size: size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor(calibratedWhite: 0.13, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        NSGraphicsContext.restoreGraphicsState()
        view.cacheDisplay(in: view.bounds, to: rep)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.withAlphaComponent(0.22).setStroke()
        let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        border.lineWidth = 1
        border.stroke()
        NSGraphicsContext.restoreGraphicsState()
        do {
            try rep.representation(using: .png, properties: [:])?.write(to: url)
        } catch {
            NSLog("Scratch: snapshot failed: %@", error.localizedDescription)
        }
    }
}
