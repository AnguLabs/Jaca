import SwiftUI
import Lemonade

/// Starts a new session from a pasted Cloud Console **Logs Explorer** URL: it parses the project
/// and the filter, adds the project if it's new (validating via gcloud), then opens a session
/// whose poller uses that raw filter (req: session config ingestion from a URL).
struct NewSessionFromURLSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var urlText = ""
    @State private var working = false
    @State private var error: String?

    private var registry: CloudLoggingRegistry { model.cloudLogging }
    private var parsed: (project: String?, query: String?) { CloudConsoleURL.parse(urlText) }

    var body: some View {
        VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing400) {
            HStack {
                LemonadeUi.Text("New session from URL",
                                textStyle: LemonadeTypography.shared.headingSmall,
                                color: LemonadeTheme.colors.content.contentPrimary)
                Spacer()
                LemonadeUi.Button(label: "Cancel", onClick: { dismiss() },
                                  variant: .neutral, type: .subtle, size: .small)
            }

            LemonadeUi.Text("Paste a Logs Explorer URL (console.cloud.google.com/logs/query…).",
                            textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                            color: LemonadeTheme.colors.content.contentTertiary)

            TextField("https://console.cloud.google.com/logs/query;query=…?project=…", text: $urlText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(2...6)
                .padding(.vertical, 8).padding(.horizontal, 10)
                .background(RoundedRectangle(cornerRadius: 8).fill(LemonadeTheme.colors.background.bgNeutralSubtle))

            if let project = parsed.project { field("PROJECT", project) }
            if let query = parsed.query { field("FILTER", query) }

            if let error {
                LemonadeUi.Notice(content: error, voice: .critical)
            }

            HStack(spacing: LemonadeTheme.spaces.spacing200) {
                Spacer()
                if working { ProgressView().controlSize(.small) }
                LemonadeUi.Button(label: working ? "Starting…" : "Start session",
                                  onClick: { start() }, leadingIcon: .chevronRight,
                                  variant: .primary, type: .solid, size: .medium)
                    .fixedSize()
                    .disabled(parsed.project == nil || working)
            }
        }
        .padding(LemonadeTheme.spaces.spacing600)
        .frame(width: 580)
        .background(LemonadeTheme.colors.background.bgDefault)
    }

    private func field(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            LemonadeUi.Text(label, textStyle: LemonadeTypography.shared.bodyXSmallOverline,
                            color: LemonadeTheme.colors.content.contentTertiary)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(LemonadeTheme.colors.content.contentPrimary)
                .textSelection(.enabled)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func start() {
        let (project, query) = parsed
        guard let project, !project.isEmpty else {
            error = "Couldn't find a project id in that URL."
            return
        }
        working = true
        error = nil
        Task {
            if registry.project(project) == nil {
                let result = await registry.addProject(id: project, displayName: "")
                if case .failure(let message) = result {
                    working = false
                    error = message
                    return
                }
            }
            model.startCloudLogSession(projectID: project, autoStart: false, rawFilter: query)
            working = false
            dismiss()
        }
    }
}
