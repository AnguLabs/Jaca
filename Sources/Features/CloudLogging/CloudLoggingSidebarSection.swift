import SwiftUI
import Lemonade

/// Sidebar section for Cloud Logging — a header styled like the other area headers (taps to
/// the Cloud Logging home; `+` adds a project) plus a compact list of the configured GCP
/// projects. Clicking a project opens a small menu (Start new session / Configure log names /
/// Rename / Remove), mirroring the device row's inspect popover. Rendered only when gcloud is
/// detected (req 1).
struct CloudLoggingSidebarSection: View {
    @Bindable var model: AppModel
    @State private var showAdd = false
    @State private var showFromURL = false

    private var registry: CloudLoggingRegistry { model.cloudLogging }
    private var active: Bool { model.mode == .cloudLogging }

    var body: some View {
        if registry.isAvailable {
            VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing100) {
                header
                if !registry.projects.isEmpty {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(registry.projects) { project in
                            CloudProjectRow(project: project, model: model)
                        }
                    }
                    .padding(.horizontal, LemonadeTheme.spaces.spacing300)
                }
            }
            .padding(.bottom, LemonadeTheme.spaces.spacing100)
            .sheet(isPresented: $showAdd) { AddProjectSheet(registry: registry) }
            .sheet(isPresented: $showFromURL) { NewSessionFromURLSheet(model: model) }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            LemonadeUi.Text(
                "Cloud Logging",
                textStyle: LemonadeTypography.shared.headingXSmall,
                color: active
                    ? LemonadeTheme.colors.content.contentPrimary
                    : LemonadeTheme.colors.content.contentSecondary
            )
            Spacer()
            Menu {
                Button("Add GCP project…") { showAdd = true }
                Button("New session from URL…") { showFromURL = true }
            } label: {
                Image(systemName: "plus.circle")
                    .foregroundStyle(LemonadeTheme.colors.content.contentSecondary)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Add a project or start a session from a URL")
            .accessibilityIdentifier("cloudAddProjectButton")
        }
        .padding(.horizontal, LemonadeTheme.spaces.spacing200)
        .padding(.vertical, LemonadeTheme.spaces.spacing100)
        .background(
            RoundedRectangle(cornerRadius: LemonadeTheme.radius.radius150)
                .fill(active ? LemonadeTheme.colors.interaction.bgSubtleInteractive : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { model.mode = .cloudLogging }
        .padding(.horizontal, LemonadeTheme.spaces.spacing300)
        .padding(.top, LemonadeTheme.spaces.spacing300)
        .accessibilityIdentifier("cloudLoggingHeader")
    }
}

/// One project row in the sidebar. Clicking opens a menu of actions, like a device row.
private struct CloudProjectRow: View {
    let project: CloudProject
    @Bindable var model: AppModel

    @State private var hovering = false
    @State private var showOptions = false
    @State private var showLogNames = false
    @State private var renaming = false
    @State private var renameText = ""

    private var registry: CloudLoggingRegistry { model.cloudLogging }

    var body: some View {
        Button(action: { showOptions = true }) {
            HStack(spacing: LemonadeTheme.spaces.spacing200) {
                Image(systemName: "cloud")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LemonadeTheme.colors.content.contentSecondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    LemonadeUi.Text(
                        project.title,
                        textStyle: LemonadeTypography.shared.bodySmallSemiBold,
                        color: LemonadeTheme.colors.content.contentPrimary,
                        maxLines: 1
                    )
                    LemonadeUi.Text(
                        project.selectedLogName.map(CloudLogName.shortId) ?? project.projectID,
                        textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                        color: LemonadeTheme.colors.content.contentTertiary,
                        maxLines: 1
                    )
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(LemonadeTheme.colors.content.contentSecondary)
                    .rotationEffect(.degrees(showOptions ? 180 : 0))
                    .opacity(hovering || showOptions ? 1 : 0.35)
                    .animation(.easeInOut(duration: 0.15), value: showOptions)
            }
            .padding(.horizontal, LemonadeTheme.spaces.spacing200)
            .padding(.vertical, LemonadeTheme.spaces.spacing200)
            .background(
                RoundedRectangle(cornerRadius: LemonadeTheme.radius.radius150)
                    .fill(hovering || showOptions ? LemonadeTheme.colors.interaction.bgSubtleInteractive : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityIdentifier("cloudProjectRow")
        .popover(isPresented: $showOptions, arrowEdge: .bottom) { menu }
        .sheet(isPresented: $showLogNames) {
            LogNameSheet(registry: registry, projectID: project.projectID)
        }
        .alert("Rename project", isPresented: $renaming) {
            TextField("Display name", text: $renameText)
            Button("Save") { registry.setDisplayName(renameText, for: project.projectID) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var menu: some View {
        VStack(alignment: .leading, spacing: 2) {
            CloudMenuRow(icon: "play.fill", title: "Start new session") {
                showOptions = false
                model.startCloudLogSession(projectID: project.projectID)
            }
            CloudMenuRow(icon: "list.bullet.rectangle", title: "Configure log names…") {
                showOptions = false
                showLogNames = true
            }
            CloudMenuRow(icon: "pencil", title: "Rename…") {
                showOptions = false
                renameText = project.displayName
                renaming = true
            }
            Divider()
            CloudMenuRow(icon: "trash", title: "Remove", destructive: true) {
                showOptions = false
                registry.removeProject(project.projectID)
            }
        }
        .padding(LemonadeTheme.spaces.spacing100)
        .frame(minWidth: 210)
    }
}

/// A single row inside the project popover menu (mirrors the device `OptionMenuRow`).
private struct CloudMenuRow: View {
    let icon: String
    let title: String
    var destructive: Bool = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: LemonadeTheme.spaces.spacing200) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(destructive
                        ? LemonadeTheme.colors.content.contentCritical
                        : LemonadeTheme.colors.content.contentSecondary)
                    .frame(width: 18)
                LemonadeUi.Text(
                    title,
                    textStyle: LemonadeTypography.shared.bodySmallRegular,
                    color: destructive
                        ? LemonadeTheme.colors.content.contentCritical
                        : LemonadeTheme.colors.content.contentPrimary,
                    maxLines: 1
                )
                Spacer(minLength: 12)
            }
            .padding(.horizontal, LemonadeTheme.spaces.spacing200)
            .padding(.vertical, LemonadeTheme.spaces.spacing100)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: LemonadeTheme.radius.radius150)
                    .fill(hovering ? LemonadeTheme.colors.interaction.bgSubtleInteractive : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: hovering)
        .accessibilityIdentifier(title)
    }
}
