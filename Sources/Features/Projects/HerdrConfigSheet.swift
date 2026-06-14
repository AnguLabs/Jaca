import SwiftUI
import Lemonade

/// App-wide configuration for the Herdr launcher: the `claude` command Herdr runs in the
/// new tab. Shown the first time the user clicks the Herdr action, and any time afterwards
/// from the Projects-header gear. Saving persists the command (app-wide, not per project)
/// and, on first run, continues the launch that was waiting on it.
struct HerdrConfigSheet: View {
    let model: ProjectsModel

    @State private var command: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()

            VStack(alignment: .leading, spacing: 8) {
                LemonadeUi.Text(
                    "Claude command",
                    textStyle: LemonadeTypography.shared.bodyMediumSemiBold,
                    color: LemonadeTheme.colors.content.contentPrimary
                )
                Text("Herdr opens a new tab in the project's Space and runs this to start Claude Code. On a project root that's a git repo, Jaca refreshes to latest and appends `--worktree`; in a worktree it just runs the command there.")
                    .font(.system(size: 12))
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

                if command.trimmingCharacters(in: .whitespacesAndNewlines) != ProjectsModel.defaultHerdrCommand {
                    Button(action: { command = ProjectsModel.defaultHerdrCommand }) {
                        Text("Reset to default")
                            .font(.system(size: 11))
                            .foregroundStyle(LemonadeTheme.colors.content.contentBrand)
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Spacer()
                LemonadeUi.Button(
                    label: "Cancel", onClick: { model.cancelHerdrConfig() },
                    variant: .neutral, type: .subtle, size: .small
                )
                LemonadeUi.Button(
                    label: "Save",
                    onClick: { model.saveHerdrConfig(command) },
                    variant: .primary, type: .solid, size: .small
                )
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(LemonadeTheme.colors.background.bgDefault)
        .onAppear { command = model.herdrClaudeCommand }
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
                    "Applies to all projects",
                    textStyle: LemonadeTypography.shared.bodySmallRegular,
                    color: LemonadeTheme.colors.content.contentSecondary
                )
            }
            Spacer(minLength: 0)
        }
    }
}
