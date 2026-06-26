import SwiftUI
import Lemonade
import AppKit

/// The main-pane content for the Cloud Logging area: gcloud detection + sign-in status (with the
/// exact `gcloud auth login` command when needed — req 2) and GCP project management
/// (add / rename / configure log names / remove / start a session). Mirrors the other area views'
/// structure (header, list, bottom-center toast).
struct CloudLoggingHomeView: View {
    @Bindable var model: AppModel
    @State private var showAdd = false
    @State private var showFromURL = false

    private var registry: CloudLoggingRegistry { model.cloudLogging }

    var body: some View {
        VStack(spacing: 0) {
            header
            authBanner
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LemonadeTheme.colors.background.bgDefault)
        .overlay(alignment: .bottom) {
            if let toast = registry.toast {
                CloudLoggingToastView(toast: toast)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.2), value: registry.toast)
        .overlay(alignment: .bottomTrailing) { GcloudDebugButton().padding(16) }
        .sheet(isPresented: $showAdd) { AddProjectSheet(registry: registry) }
        .sheet(isPresented: $showFromURL) { NewSessionFromURLSheet(model: model) }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                LemonadeUi.Text("CLOUD LOGGING", textStyle: LemonadeTypography.shared.bodyXSmallOverline,
                                color: LemonadeTheme.colors.content.contentTertiary)
                LemonadeUi.Text(accountSummary, textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                                color: LemonadeTheme.colors.content.contentSecondary, maxLines: 1)
            }
            Spacer()
            LemonadeUi.Button(label: "Re-check", onClick: { registry.detect() }, leadingIcon: .arrowRotateCw,
                              variant: .neutral, type: .subtle, size: .xSmall).fixedSize()
            LemonadeUi.Button(label: "From URL…", onClick: { showFromURL = true },
                              variant: .neutral, type: .subtle, size: .xSmall).fixedSize()
                .disabled(!registry.isAvailable)
            LemonadeUi.Button(label: "Add project", onClick: { showAdd = true }, leadingIcon: .circleCheck,
                              variant: .primary, type: .subtle, size: .xSmall).fixedSize()
                .disabled(!registry.isAvailable)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(LemonadeTheme.colors.background.bgNeutralSubtle))
        .padding(.horizontal, 8).padding(.top, 8)
    }

    private var accountSummary: String {
        switch registry.authState {
        case .unknown: return registry.isDetecting ? "Detecting gcloud…" : "—"
        case .notInstalled: return "gcloud CLI not found"
        case .notAuthenticated: return "Not signed in"
        case .authenticated(let account): return "Signed in as \(account)"
        }
    }

    // MARK: - Auth banner (req 1, 2)

    @ViewBuilder private var authBanner: some View {
        switch registry.authState {
        case .notInstalled:
            VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing200) {
                LemonadeUi.Notice(
                    content: "The gcloud CLI wasn't found. Install the Google Cloud SDK, then click Re-check.",
                    voice: .warning, title: "gcloud not found")
            }
            .padding(.horizontal, 8).padding(.top, 8)
        case .notAuthenticated:
            authCommandCard
                .padding(.horizontal, 8).padding(.top, 8)
        default:
            EmptyView()
        }
    }

    private var authCommandCard: some View {
        VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing200) {
            LemonadeUi.Notice(
                content: "Sign in to gcloud in a terminal, then click Re-check.",
                voice: .warning, title: "Authentication required")
            HStack(spacing: 8) {
                Text(registry.authCommand)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(LemonadeTheme.colors.content.contentPrimary)
                    .textSelection(.enabled)
                    .padding(.vertical, 7).padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(LemonadeTheme.colors.background.bgNeutralSubtle))
                LemonadeUi.Button(label: "Copy", onClick: { copy(registry.authCommand) },
                                  leadingIcon: .copy, variant: .neutral, type: .subtle, size: .small).fixedSize()
                LemonadeUi.Button(label: "Open Terminal", onClick: { openTerminal() },
                                  variant: .neutral, type: .subtle, size: .small).fixedSize()
                LemonadeUi.Button(label: "Re-check", onClick: { registry.detect() },
                                  variant: .primary, type: .solid, size: .small).fixedSize()
            }
        }
    }

    // MARK: - Projects

    @ViewBuilder private var content: some View {
        if registry.projects.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(registry.projects) { project in
                        CloudProjectCard(project: project, model: model)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 8)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: LemonadeTheme.spaces.spacing300) {
            Image(systemName: "cloud").font(.system(size: 38))
                .foregroundStyle(LemonadeTheme.colors.content.contentTertiary)
            LemonadeUi.Text("No GCP projects yet", textStyle: LemonadeTypography.shared.headingSmall,
                            color: LemonadeTheme.colors.content.contentPrimary)
            LemonadeUi.Text("Add a project id to start streaming its Cloud Logging.",
                            textStyle: LemonadeTypography.shared.bodyMediumRegular, textAlign: .center,
                            color: LemonadeTheme.colors.content.contentSecondary)
            LemonadeUi.Button(label: "Add project", onClick: { showAdd = true }, leadingIcon: .circleCheck,
                              variant: .primary, type: .solid, size: .medium).fixedSize()
                .disabled(!registry.isAvailable)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
    }

    // MARK: - Actions

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        registry.flash("Copied")
    }

    private func openTerminal() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// One project card in the Cloud Logging home: title, id, selected log name, and actions.
private struct CloudProjectCard: View {
    let project: CloudProject
    @Bindable var model: AppModel

    @State private var showLogNames = false
    @State private var renaming = false
    @State private var renameText = ""
    @State private var confirmingRemove = false

    private var registry: CloudLoggingRegistry { model.cloudLogging }

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(LemonadeTheme.colors.background.bgNeutralSubtle)
                .frame(width: 34, height: 34)
                .overlay(Image(systemName: "cloud").foregroundStyle(LemonadeTheme.colors.content.contentPrimary))

            VStack(alignment: .leading, spacing: 2) {
                LemonadeUi.Text(project.title, textStyle: LemonadeTypography.shared.bodyMediumSemiBold,
                                color: LemonadeTheme.colors.content.contentPrimary, maxLines: 1)
                Text(logLine)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(LemonadeTheme.colors.content.contentSecondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            LemonadeUi.Button(label: "Log names", onClick: { showLogNames = true }, leadingIcon: .arrowRotateCw,
                              variant: .neutral, type: .subtle, size: .xSmall).fixedSize()
            LemonadeUi.Button(label: "Rename", onClick: { renameText = project.displayName; renaming = true },
                              variant: .neutral, type: .subtle, size: .xSmall).fixedSize()
            LemonadeUi.Button(label: confirmingRemove ? "Confirm?" : "Remove", onClick: { remove() },
                              leadingIcon: .trash, variant: .critical,
                              type: confirmingRemove ? .solid : .subtle, size: .xSmall).fixedSize()
            LemonadeUi.Button(label: "New session", onClick: { model.startCloudLogSession(projectID: project.projectID) },
                              variant: .primary, type: .solid, size: .xSmall).fixedSize()
        }
        .padding(.vertical, 9).padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(LemonadeTheme.colors.background.bgNeutralSubtle))
        .sheet(isPresented: $showLogNames) {
            LogNameSheet(registry: registry, projectID: project.projectID)
        }
        .alert("Rename project", isPresented: $renaming) {
            TextField("Display name", text: $renameText)
            Button("Save") { registry.setDisplayName(renameText, for: project.projectID) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var logLine: String {
        if let name = project.selectedLogName { return "\(project.projectID) · \(CloudLogName.shortId(name))" }
        return "\(project.projectID) · no log name selected"
    }

    private func remove() {
        if confirmingRemove {
            confirmingRemove = false
            registry.removeProject(project.projectID)
        } else {
            confirmingRemove = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                confirmingRemove = false
            }
        }
    }
}
