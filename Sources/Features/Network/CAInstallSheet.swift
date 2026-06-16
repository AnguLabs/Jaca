import SwiftUI
import Lemonade
import AppKit

/// Drives the automatic proxy-CA install with live, step-by-step progress.
///
/// Rooted/emulator devices install silently into the system trust store; other
/// devices get a prompt to confirm the system dialog, whose completion Jaca
/// detects in the background. The sheet is **blocking** — it can't be dismissed
/// while running; the only way out before success is **Cancel**, which tears the
/// whole operation down (removes pushed files, clears the proxy).
struct CAInstallSheet: View {
    @Bindable var installer: AndroidCACertInstaller
    /// Tears down the operation (installer cleanup + clears the device proxy).
    let onCancel: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 0) {
            leftColumn
                .padding(LemonadeTheme.spaces.spacing600)
                .frame(width: showVideo ? 500 : 540, height: 540, alignment: .topLeading)
            if showVideo, let videoURL = TutorialVideo.url {
                Rectangle().fill(LemonadeTheme.colors.border.borderNeutralLow).frame(width: 1)
                TutorialVideoView(url: videoURL)
                    .frame(width: 300)
                    .frame(maxHeight: .infinity)
                    .background(Color.black)
            }
        }
        .frame(width: showVideo ? 801 : 540, height: 540)
        .background(LemonadeTheme.colors.background.bgDefault)
        .interactiveDismissDisabled(!isFinished && !isAwaitingUser && !isChoosingMode)
        .onAppear { installer.start() }
        .accessibilityIdentifier("caInstallSheet")
    }

    /// Show the tutorial video (full-height, right column) only for the manual path.
    private var showVideo: Bool { installer.chosenMode == .manual && TutorialVideo.url != nil }

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing400) {
            header
            if isChoosingMode {
                modeChooser
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing300) {
                        if installer.rootMode { modeNotice }
                        steps
                        if case .awaitingUser = installer.phase { awaitingNotice }
                        outcome
                    }
                }
            }
            footer
        }
    }

    private var isChoosingMode: Bool { installer.phase == .choosingMode }

    /// Non-rooted: the user picks Auto (Jaca taps for them) or Manual (guided).
    private var modeChooser: some View {
        VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing300) {
            LemonadeUi.Notice(
                content: "This device isn't rooted, so the certificate must go through Android Settings. Choose how you'd like to do it.",
                voice: .info, title: "Choose how to install")
            VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing100) {
                LemonadeUi.Button(label: "Auto-install for me", onClick: { installer.chooseAuto() },
                                  leadingIcon: .smartphone, variant: .primary, type: .solid, size: .medium)
                    .fixedSize()
                LemonadeUi.Text("Jaca taps through Settings automatically — you only confirm with your fingerprint or PIN.",
                                textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                                color: LemonadeTheme.colors.content.contentTertiary)
            }
            VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing100) {
                LemonadeUi.Button(label: "Show me how (manual)", onClick: { installer.chooseManual() },
                                  variant: .neutral, type: .subtle, size: .medium)
                    .fixedSize()
                LemonadeUi.Text("Jaca opens an on-device guide — a short video plus a button to the right Settings screen. You do the taps.",
                                textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                                color: LemonadeTheme.colors.content.contentTertiary)
            }
        }
    }

    private var header: some View {
        LemonadeUi.Text("Install proxy CA",
                        textStyle: LemonadeTypography.shared.headingSmall,
                        color: LemonadeTheme.colors.content.contentPrimary)
    }

    private var modeNotice: some View {
        LemonadeUi.Notice(
            content: installer.rootMode
                ? "This device is rooted (or an emulator), so Jaca installs the CA into the system trust store automatically — every app will trust it."
                : "This device isn't rooted. Jaca opens the system certificate dialog; just confirm it on the device and Jaca detects when it's done.",
            voice: .info,
            title: installer.rootMode ? "Automatic" : "One tap on the device"
        )
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing200) {
            ForEach(installer.steps) { step in
                HStack(alignment: .top, spacing: LemonadeTheme.spaces.spacing200) {
                    stepIcon(step.state)
                        .frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        LemonadeUi.Text(
                            step.title,
                            textStyle: step.state == .active
                                ? LemonadeTypography.shared.bodySmallSemiBold
                                : LemonadeTypography.shared.bodySmallRegular,
                            color: step.state == .pending
                                ? LemonadeTheme.colors.content.contentTertiary
                                : LemonadeTheme.colors.content.contentPrimary)
                        if let detail = step.detail {
                            LemonadeUi.Text(detail,
                                            textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                                            color: LemonadeTheme.colors.content.contentTertiary)
                        }
                    }
                    Spacer()
                }
            }
        }
    }

    @ViewBuilder
    private func stepIcon(_ state: AndroidCACertInstaller.StepState) -> some View {
        switch state {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(LemonadeTheme.colors.content.contentTertiary)
        case .active:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(LemonadeTheme.colors.content.contentPositive)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(LemonadeTheme.colors.content.contentCritical)
        case .skipped:
            Image(systemName: "minus.circle")
                .foregroundStyle(LemonadeTheme.colors.content.contentTertiary)
        }
    }

    private var awaitingNotice: some View {
        VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing200) {
            LemonadeUi.Notice(
                content: "Install & trust the certificate on your device (the video shows how), then open any app — Jaca watches for the first decrypted HTTPS request and confirms automatically.",
                voice: .warning,
                title: "Finish on your device"
            )
            HStack(spacing: LemonadeTheme.spaces.spacing200) {
                LemonadeUi.Button(label: "Open Security settings",
                                  onClick: { Task { await installer.openSecuritySettings() } },
                                  leadingIcon: .smartphone, variant: .neutral, type: .subtle, size: .small)
                    .fixedSize()
                LemonadeUi.Button(label: "Verify now",
                                  onClick: { Task { await installer.triggerVerifyRequest() } },
                                  variant: .primary, type: .subtle, size: .small)
                    .fixedSize()
            }
        }
    }

    @ViewBuilder
    private var outcome: some View {
        switch installer.phase {
        case .succeeded:
            LemonadeUi.Notice(content: "The proxy CA is now trusted on this device.",
                              voice: .info, title: "Done")
        case .failed(let message):
            LemonadeUi.Notice(content: message, voice: .critical, title: "Install failed")
        default:
            EmptyView()
        }
    }

    private var footer: some View {
        HStack(spacing: LemonadeTheme.spaces.spacing200) {
            Spacer()
            if isFinished {
                LemonadeUi.Button(label: "Done", onClick: { dismiss() },
                                  variant: .primary, type: .solid, size: .small)
                    .fixedSize()
            } else if isAwaitingUser {
                // Guidance is on screen; let them close while Jaca keeps watching
                // for trust in the background, or cancel to tear it all down.
                LemonadeUi.Button(label: "Cancel", onClick: { onCancel(); dismiss() },
                                  variant: .neutral, type: .subtle, size: .small)
                    .fixedSize()
                LemonadeUi.Button(label: "Close", onClick: { dismiss() },
                                  variant: .primary, type: .solid, size: .small)
                    .fixedSize()
            } else {
                LemonadeUi.Button(label: "Cancel", onClick: { onCancel(); dismiss() },
                                  variant: .neutral, type: .subtle, size: .small)
                    .fixedSize()
            }
        }
    }

    /// True once the flow reached a terminal, dismissible state.
    private var isFinished: Bool {
        switch installer.phase {
        case .succeeded, .failed, .cancelled: return true
        default: return false
        }
    }

    private var isAwaitingUser: Bool {
        if case .awaitingUser = installer.phase { return true }
        return false
    }
}
