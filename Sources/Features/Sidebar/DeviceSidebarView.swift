import SwiftUI
import Lemonade

/// Live device list. Clicking a ready device starts a new logcat tab; clicking
/// again starts another (independent filter) tab on the same device.
struct DeviceSidebarView: View {
    @Bindable var model: AppModel
    @State private var showHistory = false

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
            }
            .padding(.top, LemonadeTheme.spaces.spacing200)

            if model.adbURL == nil {
                adbMissingNotice
            }

            if model.devices.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: LemonadeTheme.spaces.spacing100) {
                        ForEach(model.devices) { device in
                            DeviceRow(device: device) { model.startSession(for: device) }
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
    @State private var hovering = false

    var body: some View {
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
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(device.state.isReady ? "Start logcat" : device.state.label)
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
