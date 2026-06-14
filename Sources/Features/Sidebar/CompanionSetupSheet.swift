import SwiftUI
import Lemonade

/// "Connect a device" onboarding: a QR code the phone scans to download + install the
/// Jaca companion app (hosted by the desktop), or a one-click adb install over USB. Once
/// the app runs, the device connects automatically.
struct CompanionSetupSheet: View {
    @Bindable var model: CompanionSetupModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                LemonadeUi.Text("Connect a device", textStyle: LemonadeTypography.shared.headingSmall,
                                color: LemonadeTheme.colors.content.contentPrimary)
                Spacer()
                LemonadeUi.Button(label: "Done", onClick: { dismiss() }, variant: .neutral, type: .subtle, size: .small)
                    .fixedSize()
            }

            HStack(alignment: .top, spacing: 16) {
                qrView
                VStack(alignment: .leading, spacing: 6) {
                    LemonadeUi.Text("Scan with the phone",
                                    textStyle: LemonadeTypography.shared.bodyMediumSemiBold,
                                    color: LemonadeTheme.colors.content.contentPrimary)
                    LemonadeUi.Text("Download + install Jaca, then open it and start capture. The desktop connects automatically — no cables.",
                                    textStyle: LemonadeTypography.shared.bodySmallRegular,
                                    color: LemonadeTheme.colors.content.contentSecondary)
                    LemonadeUi.Text(model.connectURL,
                                    textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                                    color: LemonadeTheme.colors.content.contentTertiary)
                    if !model.seenIPs.isEmpty {
                        LemonadeUi.Text("Device reached us: \(model.seenIPs.joined(separator: ", "))",
                                        textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                                        color: LemonadeTheme.colors.content.contentPositive)
                    }
                }
            }

            Rectangle().fill(LemonadeTheme.colors.border.borderNeutralLow).frame(height: 1)

            LemonadeUi.Text("OR INSTALL OVER USB",
                            textStyle: LemonadeTypography.shared.bodyXSmallOverline,
                            color: LemonadeTheme.colors.content.contentTertiary)
            HStack(spacing: 8) {
                Menu {
                    if model.adbDevices.isEmpty {
                        Text("No USB devices")
                    } else {
                        ForEach(model.adbDevices) { d in
                            Button("\(d.displayModel)  ·  \(d.id)") { model.selectedSerial = d.id }
                        }
                    }
                } label: {
                    HStack(spacing: 6) { Image(systemName: "iphone"); Text(usbLabel).lineLimit(1) }
                }
                .fixedSize()
                LemonadeUi.Button(label: model.isInstalling ? "Installing…" : "Install",
                                  onClick: { model.installApk() }, variant: .primary, type: .solid, size: .xSmall,
                                  enabled: !model.isInstalling && model.selectedSerial != nil)
                    .fixedSize()
                Button(action: { model.refreshAdbDevices() }) {
                    Image(systemName: "arrow.clockwise").foregroundStyle(LemonadeTheme.colors.content.contentSecondary)
                }
                .buttonStyle(.plain).help("Rescan USB devices")
                Spacer(minLength: 0)
            }
            if let status = model.installStatus {
                LemonadeUi.Text(status, textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                                color: LemonadeTheme.colors.content.contentTertiary)
            }
        }
        .padding(20)
        .frame(width: 540)
        .background(LemonadeTheme.colors.background.bgDefault)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    @ViewBuilder private var qrView: some View {
        if let qr = model.qr {
            Image(nsImage: qr)
                .interpolation(.none)
                .resizable()
                .frame(width: 160, height: 160)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10).fill(.white))
        } else {
            RoundedRectangle(cornerRadius: 10)
                .fill(LemonadeTheme.colors.background.bgNeutralSubtle)
                .frame(width: 176, height: 176)
                .overlay(ProgressView())
        }
    }

    private var usbLabel: String {
        if let s = model.selectedSerial { return model.adbDevices.first { $0.id == s }?.displayModel ?? s }
        return model.adbDevices.isEmpty ? "No device" : "Select device"
    }
}
