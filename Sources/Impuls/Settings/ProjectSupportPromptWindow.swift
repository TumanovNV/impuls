import AppKit
import SwiftUI

/// The one window Impuls opens on its own initiative.
///
/// A small ordinary window rather than a modal alert or a macOS notification: an
/// alert would seize the keyboard from whatever the user was doing, and a
/// notification would put a request for a favour in the same tray as their
/// messages. This can be ignored, moved or closed like any window.
///
/// Everything about *when* it may appear lives in `AppDelegate` and
/// `ProjectSupportPromptService`. This type only presents and reports back.
@MainActor
final class ProjectSupportPromptWindowController: NSObject, NSWindowDelegate {
    private let service: ProjectSupportPromptService
    private let onFeedback: () -> Void
    private var window: NSWindow?
    /// Set once a button has decided the outcome, so the close that follows a
    /// button press is not also counted as a decline.
    private var outcomeRecorded = false

    init(service: ProjectSupportPromptService, onFeedback: @escaping () -> Void) {
        self.service = service
        self.onFeedback = onFeedback
    }

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        outcomeRecorded = false
        let hosting = NSHostingController(rootView: ProjectSupportPromptView(
            onSupport: { [weak self] in self?.supportOnGitHub() ?? false },
            onFeedback: { [weak self] in self?.shareFeedback() },
            onNotNow: { [weak self] in self?.notNow() }
        ))
        let window = NSWindow(contentViewController: hosting)
        window.title = localized("Support Impuls")
        window.setContentSize(NSSize(width: 460, height: 260))
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Returns whether the browser accepted the URL, so the view can show the
    /// only failure it is in a position to report.
    ///
    /// Only a successful hand-off ends the conversation. A failed open leaves
    /// the state untouched and the window open, so it is not then closed and
    /// counted as a decline either.
    private func supportOnGitHub() -> Bool {
        guard service.openProjectPage() else { return false }
        outcomeRecorded = true
        close()
        return true
    }

    private func shareFeedback() {
        service.recordOpenedFeedback()
        outcomeRecorded = true
        close()
        // The existing feedback window, not a second feedback implementation.
        onFeedback()
    }

    private func notNow() {
        service.recordDeclined()
        outcomeRecorded = true
        close()
    }

    private func close() {
        window?.performClose(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Closing without choosing is a decline, not an unanswered question.
        // Leaving it undecided would mean asking again at the next opportunity,
        // which is exactly the nagging this feature is built to avoid.
        if !outcomeRecorded { service.recordDeclined() }
        outcomeRecorded = false
        window = nil
    }
}

private struct ProjectSupportPromptView: View {
    let onSupport: () -> Bool
    let onFeedback: () -> Void
    let onNotNow: () -> Void

    /// Shown only when handing the URL to the browser failed. There is nothing
    /// else this view can report: whether a star was given is not knowable here.
    @State private var couldNotOpenGitHub = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(localized("How is Impuls working for you?"))
                    .font(.title3.weight(.semibold))
                Text(localized("If Impuls has been useful, you can support the project with a star on GitHub. If something could be better, we'd be glad to hear your feedback."))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            if couldNotOpenGitHub {
                Label(localized("Could Not Open GitHub"), systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button(localized("Not now"), action: onNotNow)
                Spacer()
                Button(localized("Share Feedback"), action: onFeedback)
                Button(localized("Support on GitHub")) {
                    couldNotOpenGitHub = !onSupport()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 220)
    }
}
