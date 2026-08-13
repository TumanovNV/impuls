import AppKit
import SwiftUI

/// What the controller and the coordinator are allowed to know about a display's
/// presentation.
///
/// A protocol rather than the concrete class for one reason: every interesting
/// multi-display behaviour — handing the panel from one display to another,
/// dropping a file on the second monitor, a notification arriving while the
/// pointer is on a third — is a question about routing, and routing should be
/// answerable in a test rather than only by plugging in monitors. The live
/// implementation is `NotchDisplaySurface`; the suite substitutes a fake with no
/// window in it.
@MainActor
protocol NotchSurfacing: AnyObject {
    var displayID: UInt32 { get }
    var geometry: NotchGeometry { get }
    /// Whether this display owns the expanded panel. Exactly one surface has it.
    var isActive: Bool { get }
    var isReceivingDrag: Bool { get }
    /// Whether this display's window is currently allowed to take key input.
    var acceptsKeyboard: Bool { get set }
    /// Whether this display's window takes clicks, as opposed to letting them
    /// through to the app underneath.
    var isInteractive: Bool { get }

    var onDragEntered: (() -> Void)? { get set }
    var onDragExited: (() -> Void)? { get set }
    var onDrop: (([URL]) -> Bool)? { get set }
    var onPress: (() -> Void)? { get set }
    var onKeyCommand: ((NotchPanel.KeyCommand) -> Void)? { get set }

    /// Whether an AppKit window belongs to this surface. Losing key status is
    /// reported by window, and only the active surface's loss means the user
    /// clicked away — a surface being stood down resigns key too.
    func owns(_ window: NSWindow) -> Bool

    func update(geometry: NotchGeometry)
    func setActive(_ active: Bool)
    func setInteractive(_ interactive: Bool)
    /// Applies the click target for the current state and answers with the same
    /// rect in screen coordinates, which is what the pointer watcher needs.
    @discardableResult func applyActiveRect(open: Bool) -> CGRect
    func teardown()
}

/// The per-display half of the panel's state.
///
/// Everything here is presentation and geometry. Not one store, timer or
/// monitor lives on a surface: those are shared and belong to `NotchViewModel`,
/// which knows nothing about displays. That split is the whole point of the
/// multi-display layer — a third monitor must add rectangles, not a third
/// clipboard watcher.
@MainActor
final class NotchSurfaceState: ObservableObject {
    /// Whether this display owns the expanded panel. Exactly one surface has
    /// it, so two panels standing open at once is not a state the app can
    /// reach: the content view expands only when its own surface is active.
    @Published fileprivate(set) var isActive = false
    @Published fileprivate(set) var geometry: NotchGeometry

    init(geometry: NotchGeometry) {
        self.geometry = geometry
    }
}

/// One display's window, view hierarchy and geometry.
///
/// Created when a display appears, updated when it moves or resizes, torn down
/// when it goes away. Nothing else about Impuls is per-display.
@MainActor
final class NotchDisplaySurface: NotchSurfacing {
    let displayID: UInt32
    let state: NotchSurfaceState
    let panel: NotchPanel
    let rootView: NotchRootView

    private let hosting: NSHostingView<NotchContentView>

    var geometry: NotchGeometry { state.geometry }
    var isActive: Bool { state.isActive }
    var isReceivingDrag: Bool { rootView.isReceivingDrag }
    var isInteractive: Bool { !panel.ignoresMouseEvents }

    var acceptsKeyboard: Bool {
        get { panel.acceptsKeyboard }
        set { panel.acceptsKeyboard = newValue }
    }

    var onDragEntered: (() -> Void)? {
        get { rootView.onDragEntered }
        set { rootView.onDragEntered = newValue }
    }

    var onDragExited: (() -> Void)? {
        get { rootView.onDragExited }
        set { rootView.onDragExited = newValue }
    }

    var onDrop: (([URL]) -> Bool)? {
        get { rootView.onDrop }
        set { rootView.onDrop = newValue }
    }

    var onPress: (() -> Void)? {
        get { panel.onPress }
        set { panel.onPress = newValue }
    }

    var onKeyCommand: ((NotchPanel.KeyCommand) -> Void)? {
        get { panel.onKeyCommand }
        set { panel.onKeyCommand = newValue }
    }

    init(geometry: NotchGeometry, viewModel: NotchViewModel) {
        displayID = geometry.display.id
        let state = NotchSurfaceState(geometry: geometry)
        self.state = state

        panel = NotchPanel(contentRect: geometry.windowFrame)
        rootView = NotchRootView(frame: CGRect(origin: .zero, size: geometry.windowSize))
        rootView.autoresizingMask = [.width, .height]

        hosting = NSHostingView(rootView: NotchContentView(vm: viewModel, surface: state))
        hosting.frame = rootView.bounds
        hosting.autoresizingMask = [.width, .height]
        if #available(macOS 14.0, *) {
            hosting.sizingOptions = []
        }
        rootView.addSubview(hosting)

        panel.contentView = rootView
        panel.ignoresMouseEvents = true
        panel.setFrame(geometry.windowFrame, display: false)
        panel.orderFrontRegardless()
    }

    /// The display moved, resized, or the panel preset changed. The window
    /// follows; nothing is rebuilt, so the tab, the typed text and the
    /// selection all survive a monitor being rearranged.
    func update(geometry: NotchGeometry) {
        guard state.geometry != geometry else { return }
        state.geometry = geometry
        panel.setFrame(geometry.windowFrame, display: false)
    }

    func setActive(_ active: Bool) {
        guard state.isActive != active else { return }
        state.isActive = active
        if !active {
            // A surface losing activation must not still be holding the
            // keyboard: only the display the user moved to may take keys.
            panel.acceptsKeyboard = false
        }
    }

    func setInteractive(_ interactive: Bool) {
        panel.ignoresMouseEvents = !interactive
    }

    func owns(_ window: NSWindow) -> Bool { window === panel }

    @discardableResult
    func applyActiveRect(open: Bool) -> CGRect {
        let size = open ? geometry.expandedSize : geometry.collapsedSize
        var rect = geometry.contentRect(for: size)
        if open {
            // Slack so the concave shoulders stay grabbable. Never while
            // collapsed: that would swallow clicks on menu bar items next to
            // the notch.
            rect = rect.insetBy(dx: -Theme.openTopRadius, dy: 0)
        }
        rootView.activeRect = rect
        return geometry
            .contentScreenRect(for: size)
            .insetBy(dx: open ? -Theme.openTopRadius : 0, dy: 0)
    }

    func teardown() {
        // Left in the state an inactive surface is in, not merely unhooked. A
        // display that has been unplugged is gone from the coordinator, so
        // nothing would ever ask this object again — but an object that still
        // says it is active and still says it takes keys is a lie waiting for
        // the next reader, and the invariant is meant to hold over every
        // surface that has ever existed, not only the registered ones.
        setActive(false)
        panel.acceptsKeyboard = false
        panel.onPress = nil
        panel.onKeyCommand = nil
        rootView.onDragEntered = nil
        rootView.onDragExited = nil
        rootView.onDrop = nil
        panel.orderOut(nil)
        // Drops the hosting view, and with it this surface's only reference to
        // the shared view model. A display that is unplugged leaves nothing
        // behind.
        panel.contentView = nil
    }
}
