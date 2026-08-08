import AppKit

/// Borderless, non-activating panel that lives above the menu bar on every space.
final class NotchPanel: NSPanel {
    enum KeyCommand {
        case previousModule
        case nextModule
        case close
    }

    /// Off by default: taking key status dims the title bar of whatever the
    /// user is working in and stops their insertion point blinking, which is
    /// far too rude for a panel one merely hovers. The translate tab needs
    /// typing, so it turns this on for as long as it is open.
    ///
    /// `.nonactivatingPanel` is what makes that affordable — the panel gets
    /// keyboard input without the app ever becoming active.
    var acceptsKeyboard = false {
        didSet {
            guard acceptsKeyboard != oldValue else { return }
            if acceptsKeyboard {
                makeKey()
            } else if isKeyWindow {
                // There is no supported way to simply hand key status back, and
                // this app owns no other window to pass it to. Ordering out and
                // straight back in resigns it; the panel is borderless and the
                // round trip happens within one pass, so nothing flickers.
                orderOut(nil)
                orderFrontRegardless()
            }
        }
    }

    override var canBecomeKey: Bool { acceptsKeyboard }
    override var canBecomeMain: Bool { false }

    /// Physical keys, so the shortcuts survive a keyboard layout change. A
    /// Cyrillic layout answers ⌘C with "с" (U+0441), not "c" (U+0063) — they
    /// are indistinguishable on screen and unequal to every string comparison,
    /// which is why matching on characters quietly fails exactly for the
    /// person typing Russian. Key codes name the key, not what it prints.
    private enum Key {
        static let a: UInt16 = 0
        static let z: UInt16 = 6
        static let x: UInt16 = 7
        static let c: UInt16 = 8
        static let v: UInt16 = 9
        static let escape: UInt16 = 53
        static let leftArrow: UInt16 = 123
        static let rightArrow: UInt16 = 124
    }

    /// ⌘A, ⌘X, ⌘C, ⌘V and ⌘Z are ordinarily key equivalents of the Edit menu,
    /// and an `.accessory` app has no menu bar to carry them — so they never
    /// reach the text view on their own. Installing a main menu just for them
    /// would put one in the menu bar the moment the app was ever activated, so
    /// they are dispatched here instead.
    ///
    /// Caught in `sendEvent` rather than in `performKeyEquivalent`: the latter
    /// is only ever called by `NSApplication` for its key window, and while the
    /// app is inactive it does not consider itself to have one. Every event the
    /// window receives passes through here regardless.
    /// Raised on any press inside the panel, before the press is delivered.
    ///
    /// A tap gesture on the text editor never fires — the text view claims the
    /// mouse down first — so the one place a click on the field can reliably
    /// be noticed is here, where every event the window receives passes.
    var onPress: (() -> Void)?
    var onKeyCommand: ((KeyCommand) -> Void)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let command = navigationCommand(for: event) {
            onKeyCommand?(command)
            return
        }
        if event.type == .keyDown, editingAction(for: event) != nil, perform(event) { return }
        // Before `super`, so the window is already key by the time the click
        // reaches the field and places a caret.
        if event.type == .leftMouseDown { onPress?() }
        super.sendEvent(event)
    }

    private func navigationCommand(for event: NSEvent) -> KeyCommand? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isEditingText = firstResponder is NSTextView

        if event.keyCode == Key.escape { return .close }

        let navigationFlags = flags.subtracting(.shift)
        let usesControlNavigation = navigationFlags == .control
        let usesPlainNavigation = flags.isEmpty && !isEditingText
        guard usesControlNavigation || usesPlainNavigation else { return nil }

        switch event.keyCode {
        case Key.leftArrow: return .previousModule
        case Key.rightArrow: return .nextModule
        default: return nil
        }
    }

    private func editingAction(for event: NSEvent) -> Selector? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.subtracting(.shift) == .command else { return nil }
        switch event.keyCode {
        case Key.a: return #selector(NSText.selectAll(_:))
        case Key.x: return #selector(NSText.cut(_:))
        case Key.c: return #selector(NSText.copy(_:))
        case Key.v: return #selector(NSText.paste(_:))
        // Undo and redo are informal: nothing declares them, the Edit menu just
        // names the selector and lets the chain find an undo manager.
        case Key.z: return flags.contains(.shift) ? Selector(("redo:")) : Selector(("undo:"))
        default: return nil
        }
    }

    /// Dispatched from our own first responder, not through `NSApp`: a
    /// nil-targeted `sendAction` starts at `NSApp.keyWindow`, and an inactive
    /// app reports that as nil however key this panel actually is.
    private func perform(_ event: NSEvent) -> Bool {
        guard let action = editingAction(for: event), let responder = firstResponder else { return false }
        return responder.tryToPerform(action, with: self)
    }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Inherit the system appearance. SwiftUI and its AppKit-backed text
        // controls then agree on light/dark colours instead of the window
        // forcing Dark Aqua while the rest of macOS is light.
        appearance = nil

        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        // One notch above the status bar so we cover the menu bar itself.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
    }
}
