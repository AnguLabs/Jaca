import SwiftUI
import Lemonade
import AppKit

/// App settings: toolchain paths, history retention, and appearance. Persisted
/// via `UserDefaults` (`@AppStorage`); changes apply immediately.
struct SettingsView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    @AppStorage("adbPath") private var adbPath = ""
    @AppStorage("retentionDays") private var retentionDays = 7
    @AppStorage("colorScheme") private var colorScheme = "dark"

    var body: some View {
        VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing500) {
            HStack {
                LemonadeUi.Text("Settings", textStyle: LemonadeTypography.shared.headingSmall,
                                color: LemonadeTheme.colors.content.contentPrimary)
                Spacer()
                LemonadeUi.Button(label: "Done", onClick: { dismiss() },
                                  variant: .neutral, type: .subtle, size: .small)
            }

            section("Android") {
                LemonadeUi.Text(
                    "adb path",
                    textStyle: LemonadeTypography.shared.bodySmallSemiBold,
                    color: LemonadeTheme.colors.content.contentSecondary
                )
                HStack(spacing: LemonadeTheme.spaces.spacing200) {
                    TextField(currentADBPlaceholder, text: $adbPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    LemonadeUi.Button(label: "Browse…", onClick: browseADB,
                                      variant: .neutral, type: .subtle, size: .small)
                }
                LemonadeUi.Text(
                    "Leave blank to auto-detect ($ANDROID_HOME, ~/Library/Android/sdk, PATH).",
                    textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                    color: LemonadeTheme.colors.content.contentTertiary
                )
            }

            section("History") {
                Stepper(value: $retentionDays, in: 1...365) {
                    LemonadeUi.Text(
                        "Keep logs for \(retentionDays) day\(retentionDays == 1 ? "" : "s")",
                        textStyle: LemonadeTypography.shared.bodySmallRegular,
                        color: LemonadeTheme.colors.content.contentPrimary
                    )
                }
            }

            section("Appearance") {
                Picker("Theme", selection: $colorScheme) {
                    Text("System").tag("system")
                    Text("Dark").tag("dark")
                    Text("Light").tag("light")
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)
            }

            Spacer()
            HStack {
                Spacer()
                LemonadeUi.Button(label: "Apply & Rescan Devices", onClick: {
                    model.reloadProviders()
                    dismiss()
                }, variant: .primary, type: .solid, size: .medium)
            }
        }
        .padding(LemonadeTheme.spaces.spacing600)
        .frame(width: 560, height: 460)
        .background(LemonadeTheme.colors.background.bgDefault)
    }

    private var currentADBPlaceholder: String {
        AndroidToolchain.adbURL()?.path ?? "adb not found"
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing200) {
            LemonadeUi.Text(title.uppercased(),
                            textStyle: LemonadeTypography.shared.bodyXSmallOverline,
                            color: LemonadeTheme.colors.content.contentTertiary)
            content()
        }
    }

    private func browseADB() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            adbPath = url.path
        }
    }
}
