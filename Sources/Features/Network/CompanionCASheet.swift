import SwiftUI
import Lemonade

/// Guided HTTPS-decryption setup for a companion device — the companion-focused counterpart
/// of the proxy "Install CA" sheet. It shows live progress (connect → install → decrypting),
/// the install walkthrough video (when one is bundled), and confirms automatically the moment
/// the first request decrypts. Non-blocking: the user can close it and it keeps validating in
/// the background (the status banner stays in the toolbar).
struct CompanionCASheet: View {
    let session: NetworkSession
    @Environment(\.dismiss) private var dismiss
    @State private var linked = false
    @State private var capturing = false

    private var decrypting: Bool { session.caReady }
    /// Show the walkthrough video column only when a clip is actually bundled (placeholder
    /// today, same as the proxy flow) — otherwise the steps + guidance stand on their own.
    private var showVideo: Bool { TutorialVideo.url != nil }

    var body: some View {
        HStack(spacing: 0) {
            leftColumn
                .padding(LemonadeTheme.spaces.spacing600)
                .frame(width: showVideo ? 500 : 540, height: 480, alignment: .topLeading)
            if showVideo, let videoURL = TutorialVideo.url {
                Rectangle().fill(LemonadeTheme.colors.border.borderNeutralLow).frame(width: 1)
                TutorialVideoView(url: videoURL)
                    .frame(width: 300).frame(maxHeight: .infinity).background(Color.black)
            }
        }
        .frame(width: showVideo ? 801 : 540, height: 480)
        .background(LemonadeTheme.colors.background.bgDefault)
        .task(id: session.id) {
            while !Task.isCancelled {
                linked = session.companionLinked
                capturing = session.deviceCapturing
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .accessibilityIdentifier("companionCASheet")
    }

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing400) {
            VStack(alignment: .leading, spacing: 2) {
                LemonadeUi.Text("Set up HTTPS decryption",
                                textStyle: LemonadeTypography.shared.headingSmall,
                                color: LemonadeTheme.colors.content.contentPrimary)
                LemonadeUi.Text(session.device.displayModel,
                                textStyle: LemonadeTypography.shared.bodySmallRegular,
                                color: LemonadeTheme.colors.content.contentTertiary)
            }
            steps
            guidance
            Spacer(minLength: 0)
            footer
        }
        .animation(.easeInOut(duration: 0.2), value: linked)
        .animation(.easeInOut(duration: 0.2), value: decrypting)
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing300) {
            stepRow(
                done: linked, active: !linked,
                title: "Connect the companion",
                detail: linked
                    ? "Linked to \(session.device.displayModel)."
                    : "Open the Jaca app on the device — it connects automatically."
            )
            stepRow(
                done: capturing, active: linked && !capturing,
                title: "Start capture",
                detail: capturing
                    ? "Capture is running on the device."
                    : "In the Jaca app, tap Start capture so the VPN is running."
            )
            stepRow(
                done: decrypting, active: capturing && !decrypting,
                title: "Install the certificate",
                detail: decrypting
                    ? "Certificate trusted — HTTPS is decrypting."
                    : "In the Jaca app, tap Install certificate and confirm in Settings. Jaca detects it automatically — nothing to download."
            )
        }
    }

    @ViewBuilder
    private func stepRow(done: Bool, active: Bool, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: LemonadeTheme.spaces.spacing200) {
            Group {
                if done {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(LemonadeTheme.colors.content.contentPositive)
                } else if active {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "circle")
                        .foregroundStyle(LemonadeTheme.colors.content.contentTertiary)
                }
            }
            .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                LemonadeUi.Text(title,
                                textStyle: active ? LemonadeTypography.shared.bodySmallSemiBold
                                                  : LemonadeTypography.shared.bodySmallRegular,
                                color: (done || active) ? LemonadeTheme.colors.content.contentPrimary
                                                        : LemonadeTheme.colors.content.contentTertiary)
                LemonadeUi.Text(detail,
                                textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                                color: LemonadeTheme.colors.content.contentTertiary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var guidance: some View {
        if decrypting {
            LemonadeUi.Notice(content: "HTTPS is decrypting on \(session.device.displayModel).",
                              voice: .info, title: "All set")
        } else {
            LemonadeUi.Notice(content: nextStep, voice: .warning, title: "Finish on the device")
        }
    }

    private var nextStep: String {
        if !linked { return "Open the Jaca app on the device — it connects automatically." }
        if !capturing { return "Tap Start capture in the Jaca app so the VPN is running." }
        return "No download needed — the certificate is already on the device. In the Jaca app, tap Install certificate."
            + (showVideo ? " The video shows how." : "")
    }

    private var footer: some View {
        HStack(spacing: LemonadeTheme.spaces.spacing200) {
            Spacer()
            LemonadeUi.Button(label: decrypting ? "Done" : "Close",
                              onClick: { dismiss() }, variant: .primary, type: .solid, size: .small)
                .fixedSize()
        }
    }
}
