import SwiftUI
import Lemonade

/// Live device list. Clicking a ready device starts a new logcat tab; clicking
/// again starts another (independent filter) tab on the same device.
struct DeviceSidebarView: View {
    @Bindable var model: AppModel
    @State private var showHistory = false
    @State private var showSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing300) {
            HStack {
                LemonadeUi.Text(
                    "Devices",
                    textStyle: LemonadeTypography.shared.headingXSmall,
                    color: model.mode == .devices
                        ? LemonadeTheme.colors.content.contentPrimary
                        : LemonadeTheme.colors.content.contentSecondary
                )
                Spacer()
                LemonadeUi.IconButton(
                    icon: .clockArrowUp, contentDescription: "History",
                    onClick: { showHistory = true }, size: .small
                )
                .accessibilityIdentifier("historyButton")
                Button(action: { showSettings = true }) {
                    Image(systemName: "gearshape")
                        .foregroundStyle(LemonadeTheme.colors.content.contentSecondary)
                }
                .buttonStyle(.plain)
                .help("Settings")
                .accessibilityIdentifier("settingsButton")
            }
            .padding(.horizontal, LemonadeTheme.spaces.spacing200)
            .padding(.vertical, LemonadeTheme.spaces.spacing100)
            .background(
                RoundedRectangle(cornerRadius: LemonadeTheme.radius.radius150)
                    .fill(model.mode == .devices ? LemonadeTheme.colors.interaction.bgSubtleInteractive : .clear)
            )
            .contentShape(Rectangle())
            .onTapGesture { model.mode = .devices }

            if model.adbURL == nil {
                adbMissingNotice
            }

            if model.devices.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing300) {
                        ForEach(platforms, id: \.self) { platform in
                            deviceSection(platform.displayName.uppercased(),
                                          model.devices.filter { $0.platform == platform && !$0.isCompanion })
                        }
                        // Devices reachable only over the companion link (no USB/ADB).
                        deviceSection("COMPANION", model.devices.filter { $0.isCompanion })
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(LemonadeTheme.spaces.spacing300)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LemonadeTheme.colors.background.bgElevated)
        .sheet(isPresented: $showHistory) {
            HistoryView(model: model)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(model: model)
        }
    }

    private var platforms: [DevicePlatform] {
        var seen: [DevicePlatform] = []
        for device in model.devices where !device.isCompanion && !seen.contains(device.platform) {
            seen.append(device.platform)
        }
        return seen
    }

    /// A titled group of device rows (a platform, or the companion-only section).
    @ViewBuilder
    private func deviceSection(_ title: String, _ devices: [Device]) -> some View {
        if !devices.isEmpty {
            VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing100) {
                LemonadeUi.Text(
                    title,
                    textStyle: LemonadeTypography.shared.bodyXSmallOverline,
                    color: LemonadeTheme.colors.content.contentTertiary
                )
                ForEach(devices) { device in
                    DeviceRow(
                        device: device,
                        onStart: { model.startSession(for: device) },
                        onInspectNetwork: { model.startNetworkSession(for: device, autoStart: false) },
                        onStartCompanion: { model.startNetworkSession(for: device, autoStart: true) },
                        checkProxy: { await model.strandedProxy(for: device) },
                        revertProxy: { await model.revertDeviceProxy(device) }
                    )
                }
            }
        }
    }

    private var adbMissingNotice: some View {
        LemonadeUi.Notice(
            content: "adb not found. Set its path in Settings or install Android platform-tools.",
            voice: .critical
        )
    }

    private var emptyState: some View {
        VStack(spacing: LemonadeTheme.spaces.spacing200) {
            LemonadeUi.Icon(icon: .smartphone, contentDescription: nil, size: .large,
                            tint: LemonadeTheme.colors.content.contentTertiary)
            LemonadeUi.Text(
                "No devices connected",
                textStyle: LemonadeTypography.shared.bodySmallRegular,
                textAlign: .center,
                color: LemonadeTheme.colors.content.contentSecondary
            )
            LemonadeUi.Text(
                "Connect a device or start an emulator.",
                textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                textAlign: .center,
                color: LemonadeTheme.colors.content.contentTertiary
            )
        }
        .frame(maxWidth: .infinity)
        .padding(.top, LemonadeTheme.spaces.spacing600)
    }
}

private struct DeviceRow: View {
    let device: Device
    let onStart: () -> Void
    let onInspectNetwork: () -> Void
    /// Start (and auto-run) companion network capture — the primary action for companion devices.
    let onStartCompanion: () -> Void
    /// Returns the device's stranded Jaca proxy (host == this Mac), or nil.
    let checkProxy: () async -> String?
    /// Clears the device's HTTP proxy.
    let revertProxy: () async -> Void
    @State private var hovering = false
    @State private var stranded: String?
    @State private var reverting = false

    var body: some View {
        VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing100) {
            deviceButton
            if let proxy = stranded { strandedBanner(proxy) }
        }
        .task(id: device.state) {
            stranded = device.state.isReady ? await checkProxy() : nil
        }
    }

    /// Primary action: companion devices open Network inspection (no logcat over the
    /// companion link); adb/ios devices start logcat.
    private var actionable: Bool { device.isCompanion || device.state.isReady }
    private func primaryAction() {
        if device.isCompanion { onStartCompanion() } else if device.state.isReady { onStart() }
    }

    private var deviceButton: some View {
        Button(action: primaryAction) {
            HStack(spacing: LemonadeTheme.spaces.spacing200) {
                LemonadeUi.Icon(
                    icon: .smartphone, contentDescription: nil, size: .medium,
                    tint: LemonadeTheme.colors.content.contentSecondary
                )
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        LemonadeUi.Text(
                            device.displayModel,
                            textStyle: LemonadeTypography.shared.bodySmallSemiBold,
                            color: LemonadeTheme.colors.content.contentPrimary,
                            maxLines: 1
                        )
                        if device.companionID != nil { companionChip }
                    }
                    LemonadeUi.Text(
                        device.isCompanion ? "Companion (network only)" : device.id,
                        textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                        color: LemonadeTheme.colors.content.contentTertiary,
                        maxLines: 1
                    )
                }
                Spacer(minLength: 0)
                if actionable {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(LemonadeTheme.colors.content.contentBrand)
                        .opacity(hovering ? 1 : 0.35)
                } else {
                    stateBadge
                }
            }
            .padding(.horizontal, LemonadeTheme.spaces.spacing200)
            .padding(.vertical, LemonadeTheme.spaces.spacing200)
            .background(
                RoundedRectangle(cornerRadius: LemonadeTheme.radius.radius150)
                    .fill(hovering && actionable
                        ? LemonadeTheme.colors.interaction.bgSubtleInteractive
                        : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!actionable)
        .accessibilityIdentifier("deviceRow")
        .onHover { hovering = $0 }
        .help(device.isCompanion ? "Inspect network (companion)"
              : (device.state.isReady ? "Start logcat" : device.state.label))
        .contextMenu {
            if !device.isCompanion {
                Button("Start Logcat", action: onStart)
                Button("Inspect Network", action: onInspectNetwork)
            } else {
                Button("Inspect Network", action: onStartCompanion)
            }
        }
    }

    /// Green when the companion stream is connected, red (caution) when it isn't.
    private var companionChip: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(device.companionConnected
                    ? LemonadeTheme.colors.content.contentPositive
                    : LemonadeTheme.colors.content.contentCritical)
                .frame(width: 6, height: 6)
            Text("companion")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(LemonadeTheme.colors.content.contentSecondary)
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(LemonadeTheme.colors.background.bgNeutralSubtle))
    }

    /// Shown when this device still has a proxy Jaca set but a teardown couldn't
    /// revert (e.g. the app was force-killed). One click clears it.
    private func strandedBanner(_ proxy: String) -> some View {
        HStack(spacing: LemonadeTheme.spaces.spacing200) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(LemonadeTheme.colors.content.contentCaution)
            VStack(alignment: .leading, spacing: 1) {
                LemonadeUi.Text("Proxy left set by Jaca",
                                textStyle: LemonadeTypography.shared.bodyXSmallSemiBold,
                                color: LemonadeTheme.colors.content.contentPrimary, maxLines: 1)
                LemonadeUi.Text(proxy,
                                textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                                color: LemonadeTheme.colors.content.contentTertiary, maxLines: 1)
            }
            Spacer(minLength: 6)
            if reverting {
                ProgressView().controlSize(.small)
            } else {
                LemonadeUi.Button(label: "Revert", onClick: { revert() },
                                  variant: .neutral, type: .subtle, size: .small)
            }
        }
        .padding(.horizontal, LemonadeTheme.spaces.spacing200)
        .padding(.vertical, LemonadeTheme.spaces.spacing100)
        .background(RoundedRectangle(cornerRadius: LemonadeTheme.radius.radius150)
            .fill(LemonadeTheme.colors.background.bgNeutralSubtle))
        .accessibilityIdentifier("strandedProxyBanner")
    }

    private func revert() {
        reverting = true
        Task {
            await revertProxy()
            stranded = await checkProxy()   // clears the banner once it's actually gone
            reverting = false
        }
    }

    private var stateBadge: some View {
        LemonadeUi.Text(
            device.state.label,
            textStyle: LemonadeTypography.shared.bodyXSmallSemiBold,
            color: device.state == .unauthorized
                ? LemonadeTheme.colors.content.contentCaution
                : LemonadeTheme.colors.content.contentTertiary,
            maxLines: 1
        )
    }
}
