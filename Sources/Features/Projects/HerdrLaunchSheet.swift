import SwiftUI
import Lemonade

/// Shown when the user clicks the Herdr action on a project/worktree row. Prompts for the
/// session name (the Herdr tab — "what we're working on" — which also names the new git
/// worktree in the project-root flow). On first run it also collects the app-wide `claude`
/// command. Confirming hands both back to the model, which launches in Herdr.
struct HerdrLaunchSheet: View {
    let model: ProjectsModel

    @State private var tabName = ""
    @State private var command = ""
    @FocusState private var nameFocused: Bool

    private var needsConfig: Bool { !model.isHerdrConfigured }
    private var canOpen: Bool { !tabName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()

            VStack(alignment: .leading, spacing: 8) {
                LemonadeUi.Text(
                    "What are you working on?",
                    textStyle: LemonadeTypography.shared.bodyMediumSemiBold,
                    color: LemonadeTheme.colors.content.contentPrimary
                )
                TextField("e.g. fix login flicker", text: $tabName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($nameFocused)
                    .onSubmit { if canOpen { submit() } }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(LemonadeTheme.colors.background.bgNeutralSubtle)
                    )
                Text("Names the Herdr tab, and the new git worktree when starting one.")
                    .font(.system(size: 11))
                    .foregroundStyle(LemonadeTheme.colors.content.contentTertiary)
            }

            if needsConfig { configSection }

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Spacer()
                LemonadeUi.Button(
                    label: "Cancel", onClick: { model.cancelHerdrLaunch() },
                    variant: .neutral, type: .subtle, size: .small
                )
                LemonadeUi.Button(
                    label: "Open in Herdr", onClick: { submit() },
                    variant: .primary, type: .solid, size: .small, enabled: canOpen
                )
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(LemonadeTheme.colors.background.bgDefault)
        .onAppear {
            command = model.herdrClaudeCommand
            nameFocused = true
        }
    }

    /// First-run only: the app-wide Claude command (persisted on confirm).
    private var configSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            LemonadeUi.Text(
                "Claude command",
                textStyle: LemonadeTypography.shared.bodyMediumSemiBold,
                color: LemonadeTheme.colors.content.contentPrimary
            )
            Text("Herdr runs this to start Claude Code. Saved for all projects — change it later from the gear in the Projects header.")
                .font(.system(size: 11))
                .foregroundStyle(LemonadeTheme.colors.content.contentSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            TextField("", text: $command, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, design: .monospaced))
                .lineLimit(1...4)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(LemonadeTheme.colors.background.bgNeutralSubtle)
                )
        }
    }

    private var header: some View {
        HStack(spacing: 11) {
            if let icon = NSImage(named: "HerdrIcon") {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 2) {
                LemonadeUi.Text(
                    "Open in Herdr",
                    textStyle: LemonadeTypography.shared.bodyLargeMedium,
                    color: LemonadeTheme.colors.content.contentPrimary
                )
                LemonadeUi.Text(
                    "Name this session",
                    textStyle: LemonadeTypography.shared.bodySmallRegular,
                    color: LemonadeTheme.colors.content.contentSecondary
                )
            }
            Spacer(minLength: 0)
        }
    }

    private func submit() {
        guard canOpen else { return }
        model.confirmHerdrLaunch(tabName: tabName, command: needsConfig ? command : nil)
    }
}
