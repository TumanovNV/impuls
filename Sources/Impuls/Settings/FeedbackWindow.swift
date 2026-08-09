import AppKit
import SwiftUI

@MainActor
final class FeedbackWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: FeedbackView())
        let window = NSWindow(contentViewController: hosting)
        window.title = localized("Send Feedback")
        window.setContentSize(NSSize(width: 640, height: 600))
        window.minSize = NSSize(width: 560, height: 540)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

private struct FeedbackView: View {
    @State private var category: FeedbackCategory = .problem
    @State private var area: FeedbackArea = .wholeApp
    @State private var frequency: FeedbackFrequency = .notSpecified
    @State private var rating = 0
    @State private var summary = ""
    @State private var details = ""
    @State private var includeDiagnostics = true
    @State private var statusMessage = ""
    @State private var statusIsError = false

    private let diagnostics = FeedbackDiagnostics.current

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Help Improve Impuls")
                    .font(.title2.weight(.semibold))
                Text("Tell us what got in your way or what should be improved before new features are added.")
                    .foregroundStyle(.secondary)
            }

            Form {
                Section("Feedback") {
                    Picker("Category", selection: $category) {
                        ForEach(FeedbackCategory.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    Picker("Related Area", selection: $area) {
                        ForEach(FeedbackArea.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    Picker("How Often", selection: $frequency) {
                        ForEach(FeedbackFrequency.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    Picker("Overall Experience", selection: $rating) {
                        Text("Not Specified").tag(0)
                        ForEach(1...5, id: \.self) { value in
                            Text("\(value) / 5").tag(value)
                        }
                    }
                    TextField("Short Summary", text: limitedSummary)
                    HStack {
                        Spacer()
                        Text("\(summary.count) / \(FeedbackService.maximumSummaryLength)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Details") {
                    TextEditor(text: limitedDetails)
                        .font(.body)
                        .frame(minHeight: 120)
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(nsColor: .separatorColor))
                        }
                    HStack {
                        Text("Describe what happened, what you expected, and how often it occurs.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(details.count) / \(FeedbackService.maximumDetailsLength)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Technical Context") {
                    Toggle("Include Basic Technical Information", isOn: $includeDiagnostics)
                    if includeDiagnostics {
                        Text(diagnostics.markdown)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    Text("Only the Impuls version, macOS version, and processor architecture are included. Clipboard contents, notes, files, paths, calendar data, logs, and device identifiers are never added.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Report Preview") {
                    if let submission {
                        ScrollView {
                            Text(submission.report)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 120)
                    } else {
                        Text("Enter a short summary to build the report.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            Text("GitHub issues are public. Review the report and remove any personal or confidential information before submitting it in your browser.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                if !statusMessage.isEmpty {
                    Label(statusMessage, systemImage: statusIsError ? "exclamationmark.triangle" : "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(statusIsError ? .red : .secondary)
                }
                Spacer()
                Button("Copy Report", action: copyReport)
                    .disabled(submission == nil)
                Button("Continue in GitHub…", action: continueInGitHub)
                    .buttonStyle(.borderedProminent)
                    .disabled(submission == nil)
            }
        }
        .padding(20)
        .frame(minWidth: 540, minHeight: 500)
    }

    private var limitedSummary: Binding<String> {
        Binding(
            get: { summary },
            set: { summary = String($0.prefix(FeedbackService.maximumSummaryLength)) }
        )
    }

    private var limitedDetails: Binding<String> {
        Binding(
            get: { details },
            set: { details = String($0.prefix(FeedbackService.maximumDetailsLength)) }
        )
    }

    private var submission: FeedbackSubmission? {
        FeedbackService.makeSubmission(draft: FeedbackDraft(
            category: category,
            area: area,
            frequency: frequency,
            rating: rating,
            summary: summary,
            details: details,
            includeDiagnostics: includeDiagnostics
        ), diagnostics: diagnostics)
    }

    private func copyReport() {
        guard let submission else { return }
        FeedbackService.copyReport(submission.report)
        statusIsError = false
        statusMessage = localized("Report Copied")
    }

    private func continueInGitHub() {
        guard let submission else { return }
        if FeedbackService.open(submission) {
            statusIsError = false
            statusMessage = submission.reportIncludedInURL
                ? localized("Report Opened in GitHub")
                : localized("Report Copied — Paste It into GitHub")
        } else {
            statusIsError = true
            statusMessage = localized("Could Not Open GitHub")
        }
    }
}
