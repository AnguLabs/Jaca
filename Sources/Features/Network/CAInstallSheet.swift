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
        VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing400) {
            header
            modeNotice
            steps
            if case .awaitingUser = installer.phase { awaitingNotice }
            outcome
            Spacer(minLength: 0)
            footer
        }
        .padding(LemonadeTheme.spaces.spacing600)
        .frame(width: 540, height: 480)
        .background(LemonadeTheme.colors.background.bgDefault)
        .interactiveDismissDisabled(!isFinished)   // only Cancel/Done close it
        .onAppear { installer.start() }
        .accessibilityIdentifier("caInstallSheet")
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
        LemonadeUi.Notice(
            content: "Confirm the certificate install on the device. Give it a name if asked and tap OK — Jaca is watching and will continue automatically.",
            voice: .warning,
            title: "Waiting for the device"
        )
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
        HStack {
            Spacer()
            if isFinished {
                LemonadeUi.Button(label: "Done", onClick: { dismiss() },
                                  variant: .primary, type: .solid, size: .small)
            } else {
                LemonadeUi.Button(label: "Cancel", onClick: { onCancel(); dismiss() },
                                  variant: .neutral, type: .subtle, size: .small)
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
}
