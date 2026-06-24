import SwiftUI
import Lemonade
import AppKit
import CoreImage.CIFilterBuiltins

/// "Pair device over Wi-Fi" sheet: a QR-code tab and a pairing-code tab, both driven
/// by `PairingModel`. Shows live mDNS discovery, a manual IP:port fallback for when
/// multicast is blocked, and a one-click adb recovery when mDNS looks disabled.
struct PairDeviceSheet: View {
    @Bindable var model: PairingModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing400) {
            header
            if !model.adbAvailable {
                LemonadeUi.Notice(
                    content: "adb not found. Set its path in Settings or install Android platform-tools.",
                    voice: .critical
                )
                Spacer(minLength: 0)
            } else {
                modePicker
                if case .disabled = model.mdnsHealth { healthBanner }
                ScrollView {
                    VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing400) {
                        switch model.mode {
                        case .qr: qrContent
                        case .code: codeContent
                        }
                    }
                    .padding(.bottom, LemonadeTheme.spaces.spacing200)
                }
            }
        }
        .padding(LemonadeTheme.spaces.spacing600)
        .frame(width: 480, height: 620)
        .background(LemonadeTheme.colors.background.bgDefault)
        .task { model.start() }
        .onDisappear { model.stop() }
    }

    // MARK: - Header / mode

    private var header: some View {
        HStack {
            LemonadeUi.Text("Pair device over Wi-Fi",
                            textStyle: LemonadeTypography.shared.headingSmall,
                            color: LemonadeTheme.colors.content.contentPrimary)
            Spacer()
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LemonadeTheme.colors.content.contentSecondary)
                    .padding(LemonadeTheme.spaces.spacing100)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close")
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("closePairing")
        }
    }

    private var modePicker: some View {
        LemonadeUi.SegmentedControl(
            properties: [.label("QR code"), .label("Pairing code")],
            selectedTab: model.mode == .qr ? 0 : 1,
            size: .small,
            onTabSelected: { model.mode = $0 == 0 ? .qr : .code }
        )
    }

    private var healthBanner: some View {
        VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing200) {
            LemonadeUi.Notice(
                content: "adb's wireless discovery (mDNS) looks disabled — devices may never appear. Restarting the adb server usually fixes it.",
                voice: .warning, title: "Discovery may be off"
            )
            LemonadeUi.Button(
                label: model.recovering ? "Restarting adb…" : "Restart adb server",
                onClick: { model.recoverMdns() },
                leadingIcon: .arrowLeftRight, variant: .neutral, type: .subtle, size: .small
            )
            .disabled(model.recovering)
        }
    }

    // MARK: - QR tab

    private var qrContent: some View {
        VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing300) {
            steps([
                "On your device: Settings → System → Developer options → Wireless debugging → Pair device with QR code.",
                "Point the camera at this code. Pairing happens automatically once it's scanned.",
            ])

            HStack {
                Spacer()
                qrImageView
                Spacer()
            }
            .padding(.vertical, LemonadeTheme.spaces.spacing200)

            HStack {
                Spacer()
                LemonadeUi.Button(label: "Regenerate code", onClick: { model.regenerateQR() },
                                  variant: .neutral, type: .subtle, size: .small)
                Spacer()
            }

            statusView
        }
    }

    @ViewBuilder
    private var qrImageView: some View {
        if let payload = model.qrPayload, let image = Self.qrImage(from: payload) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .frame(width: 220, height: 220)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: LemonadeTheme.radius.radius200))
                .overlay(
                    RoundedRectangle(cornerRadius: LemonadeTheme.radius.radius200)
                        .stroke(LemonadeTheme.colors.border.borderNeutralLow, lineWidth: 1)
                )
        } else {
            LemonadeUi.Notice(content: "Couldn't render the QR code.", voice: .critical)
        }
    }

    // MARK: - Pairing-code tab

    private var codeContent: some View {
        VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing300) {
            steps([
                "On your device: Wireless debugging → Pair device with pairing code.",
                "Pick your device below (or type the IP & port shown on its screen), enter the 6-digit code, and Pair.",
            ])

            discoveredList
            manualEntry

            LemonadeUi.Button(label: "Pair", onClick: { model.pairWithCode() },
                              leadingIcon: .smartphone, variant: .primary, type: .solid, size: .small)
                .disabled(isPairing)

            statusView
        }
    }

    @ViewBuilder
    private var discoveredList: some View {
        VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing100) {
            LemonadeUi.Text("DISCOVERED (mDNS)",
                            textStyle: LemonadeTypography.shared.bodyXSmallOverline,
                            color: LemonadeTheme.colors.content.contentTertiary)
            if model.pairingServices.isEmpty {
                LemonadeUi.Text("Searching… nothing yet. If your device is on this Wi-Fi but never appears, your network may block mDNS — use the manual entry below.",
                                textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                                color: LemonadeTheme.colors.content.contentSecondary)
            } else {
                ForEach(model.pairingServices) { service in
                    serviceRow(service)
                }
            }
        }
    }

    private func serviceRow(_ service: MdnsService) -> some View {
        let selected = model.selectedServiceID == service.id
        return Button {
            model.selectedServiceID = selected ? nil : service.id
            model.manualAddress = ""
        } label: {
            HStack(spacing: LemonadeTheme.spaces.spacing200) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected
                        ? LemonadeTheme.colors.content.contentBrand
                        : LemonadeTheme.colors.content.contentTertiary)
                VStack(alignment: .leading, spacing: 1) {
                    LemonadeUi.Text(service.instance,
                                    textStyle: LemonadeTypography.shared.bodySmallSemiBold,
                                    color: LemonadeTheme.colors.content.contentPrimary, maxLines: 1)
                    LemonadeUi.Text(service.address,
                                    textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                                    color: LemonadeTheme.colors.content.contentTertiary, maxLines: 1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, LemonadeTheme.spaces.spacing200)
            .padding(.vertical, LemonadeTheme.spaces.spacing200)
            .background(RoundedRectangle(cornerRadius: LemonadeTheme.radius.radius150)
                .fill(selected ? LemonadeTheme.colors.interaction.bgSubtleInteractive : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var manualEntry: some View {
        VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing100) {
            LemonadeUi.Text("OR ENTER MANUALLY",
                            textStyle: LemonadeTypography.shared.bodyXSmallOverline,
                            color: LemonadeTheme.colors.content.contentTertiary)
            HStack(spacing: LemonadeTheme.spaces.spacing200) {
                TextField("192.168.1.42:37313", text: $model.manualAddress)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onChange(of: model.manualAddress) { _, newValue in
                        if !newValue.isEmpty { model.selectedServiceID = nil }
                    }
                TextField("code", text: $model.pairingCode)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 90)
            }
        }
    }

    // MARK: - Shared status

    private var isPairing: Bool { if case .pairing = model.status { return true }; return false }

    @ViewBuilder
    private var statusView: some View {
        switch model.status {
        case .idle:
            EmptyView()
        case .waitingForScan:
            HStack(spacing: LemonadeTheme.spaces.spacing200) {
                LemonadeUi.Spinner()
                LemonadeUi.Text("Waiting for your device to scan the code…",
                                textStyle: LemonadeTypography.shared.bodySmallRegular,
                                color: LemonadeTheme.colors.content.contentSecondary)
            }
        case .pairing:
            HStack(spacing: LemonadeTheme.spaces.spacing200) {
                LemonadeUi.Spinner()
                LemonadeUi.Text("Pairing…",
                                textStyle: LemonadeTypography.shared.bodySmallRegular,
                                color: LemonadeTheme.colors.content.contentSecondary)
            }
        case .paired(let name):
            VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing200) {
                LemonadeUi.Notice(content: "Paired with \(name). It should appear in your device list now.",
                                  voice: .info, title: "Paired ✓")
                LemonadeUi.Button(label: "Pair another", onClick: { model.reset() },
                                  variant: .neutral, type: .subtle, size: .small)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing200) {
                LemonadeUi.Notice(content: message, voice: .critical, title: "Pairing failed")
                LemonadeUi.Button(label: "Try again", onClick: { model.reset() },
                                  variant: .neutral, type: .subtle, size: .small)
            }
        }
    }

    private func steps(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing200) {
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

    // MARK: - QR rendering

    private static let ciContext = CIContext()

    /// Renders `string` to a crisp QR `NSImage` via CoreImage (no third-party dep).
    /// We rasterize through a `CIContext` to a `CGImage` rather than wrapping the
    /// `CIImage` in an `NSCIImageRep` — the latter renders blank under SwiftUI.
    static func qrImage(from string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = ciContext.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width,
                                                      height: scaled.extent.height))
    }
}
