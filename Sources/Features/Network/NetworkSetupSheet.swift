import SwiftUI
import Lemonade
import AppKit

/// Guides the user through pointing a device at the proxy and trusting the CA,
/// with platform-specific steps and an honest note on the limits of proxy-based
/// capture (no call stack; cert-pinning / ATS can block interception).
struct NetworkSetupSheet: View {
    let session: NetworkSession
    /// Presents the automatic CA-install flow (owned by `NetworkSessionView`).
    var onInstallCA: () -> Void = {}
    /// Abandons proxy mode and returns to the chooser to pick in-process Agent.
    var onSwitchToAgent: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing400) {
            HStack {
                LemonadeUi.Text("Network capture setup",
                                textStyle: LemonadeTypography.shared.headingSmall,
                                color: LemonadeTheme.colors.content.contentPrimary)
                Spacer()
                LemonadeUi.Button(label: "Done", onClick: { dismiss() },
                                  variant: .neutral, type: .subtle, size: .small)
            }

            LemonadeUi.Notice(
                content: "Proxy address: \(session.hostAddress):\(session.boundPort)",
                voice: .info, title: "Proxy"
            )

            HStack(spacing: LemonadeTheme.spaces.spacing200) {
                if session.device.platform == .android {
                    LemonadeUi.Button(label: "Install CA automatically", onClick: onInstallCA,
                                      leadingIcon: .smartphone, variant: .primary, type: .solid, size: .small)
                }
                LemonadeUi.Button(label: "Export CA certificate…", onClick: exportCA,
                                  leadingIcon: .download, variant: .neutral, type: .subtle, size: .small)
                Spacer()
                if session.agentAvailable {
                    LemonadeUi.Button(label: "Switch to Agent mode", onClick: onSwitchToAgent,
                                      variant: .neutral, type: .subtle, size: .small)
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing300) {
                    steps
                    limitations
                }
            }
        }
        .padding(LemonadeTheme.spaces.spacing600)
        .frame(width: 620, height: 560)
        .background(LemonadeTheme.colors.background.bgDefault)
    }

    @ViewBuilder
    private var steps: some View {
        switch session.device.platform {
        case .android:
            stepSection("Android", [
                "Start proxy capture from the tab — Jaca then sets the device proxy while it runs (http_proxy = \(session.hostAddress):\(session.boundPort)) and reverts it when you stop.",
                "Tap “Install CA automatically”. On an emulator or rooted device Jaca installs it into the system trust store with no further steps; otherwise it opens the on-device dialog for you to confirm, and detects when it's done.",
                "On a non-rooted device only apps that trust user CAs (debug builds via network-security-config) can be intercepted. Rooted/emulator system-store installs are trusted by every app that doesn't pin certs.",
            ])
        case .iosSimulator:
            stepSection("iOS Simulator", [
                "Set the Mac's proxy or run the app with HTTPS_PROXY=\(session.hostAddress):\(session.boundPort).",
                "Export the CA, then drag the .pem onto the booted simulator to install, and trust it in Settings → General → About → Certificate Trust Settings.",
                "ATS / cert pinning can still block interception unless the app trusts the CA.",
            ])
        case .iosDevice:
            stepSection("iOS Device", [
                "On the device: Settings → Wi-Fi → (i) → Configure Proxy → Manual → Server \(session.hostAddress), Port \(session.boundPort).",
                "Export and AirDrop/email the CA to the device, install the profile, then enable full trust in Settings → General → About → Certificate Trust Settings.",
                "ATS and cert pinning may block capture; there is no system-level per-app network inspector on iOS.",
            ])
        }
    }

    private var limitations: some View {
        LemonadeUi.Notice(
            content: "Proxy capture gives you full URLs, headers, bodies and timing — but not the call stack that initiated each request (that needs in-process instrumentation, which a proxy can't provide). Apps that pin certificates or don't trust user-installed CAs won't be interceptable.",
            voice: .warning, title: "What proxy capture can and can't do"
        )
    }

    private func stepSection(_ title: String, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing200) {
            LemonadeUi.Text(title.uppercased(), textStyle: LemonadeTypography.shared.bodyXSmallOverline,
                            color: LemonadeTheme.colors.content.contentTertiary)
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .top, spacing: LemonadeTheme.spaces.spacing200) {
                    LemonadeUi.Text("\(index + 1).",
                                    textStyle: LemonadeTypography.shared.bodySmallSemiBold,
                                    color: LemonadeTheme.colors.content.contentBrand)
                    LemonadeUi.Text(item, textStyle: LemonadeTypography.shared.bodySmallRegular,
                                    color: LemonadeTheme.colors.content.contentSecondary)
                }
            }
        }
    }

    private func exportCA() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "JacaProxyCA.pem"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            try? session.ca.exportRootCertificate(to: url)
        }
    }
}
