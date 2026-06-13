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
                    color: LemonadeTheme.colors.content.contentPrimary
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
            .padding(.top, LemonadeTheme.spaces.spacing200)

            if model.adbURL == nil {
                adbMissingNotice
            }

            if model.devices.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing300) {
                        ForEach(platforms, id: \.self) { platform in
                            VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing100) {
                                LemonadeUi.Text(
                                    platform.displayName.uppercased(),
                                    textStyle: LemonadeTypography.shared.bodyXSmallOverline,
                                    color: LemonadeTheme.colors.content.contentTertiary
                                )
                                ForEach(model.devices.filter { $0.platform == platform }) { device in
                                    DeviceRow(
                                        device: device,
                                        onStart: { model.startSession(for: device) },
                                        onInspectNetwork: { model.startNetworkSession(for: device, autoStart: false) },
                                        checkProxy: { await model.strandedProxy(for: device) },
                                        revertProxy: { await model.revertDeviceProxy(device) }
                                    )
                                }
                            }
                        }
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
        for device in model.devices where !seen.contains(device.platform) {
            seen.append(device.platform)
        }
        return seen
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

    private var deviceButton: some View {
        Button(action: { if device.state.isReady { onStart() } }) {
            HStack(spacing: LemonadeTheme.spaces.spacing200) {
                LemonadeUi.Icon(
                    icon: device.platform == .android ? .smartphone : .smartphone,
                    contentDescription: nil, size: .medium,
                    tint: LemonadeTheme.colors.content.contentSecondary
                )
                VStack(alignment: .leading, spacing: 1) {
                    LemonadeUi.Text(
                        device.displayModel,
                        textStyle: LemonadeTypography.shared.bodySmallSemiBold,
                        color: LemonadeTheme.colors.content.contentPrimary,
                        maxLines: 1
                    )
                    LemonadeUi.Text(
                        device.id,
                        textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                        color: LemonadeTheme.colors.content.contentTertiary,
                        maxLines: 1
                    )
                }
                Spacer(minLength: 0)
                if device.state.isReady {
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
                    .fill(hovering && device.state.isReady
                        ? LemonadeTheme.colors.interaction.bgSubtleInteractive
                        : .clear)
            )
            // Whole row is clickable, not just the text/icon.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!device.state.isReady)
        .accessibilityIdentifier("deviceRow")
        .onHover { hovering = $0 }
        .help(device.state.isReady ? "Start logcat" : device.state.label)
        .contextMenu {
            Button("Start Logcat", action: onStart)
            Button("Inspect Network", action: onInspectNetwork)
        }
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
