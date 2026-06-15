import SwiftUI
import Lemonade
import AppKit

/// Network-inspection tab: proxy toolbar, captured-transaction list, and a detail
/// pane (overview / headers / bodies / timing) for the selected transaction.
struct NetworkSessionView: View {
    @Bindable var session: NetworkSession
    @State private var showSetup = false
    @State private var showCAInstall = false
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            divider
            // Companion mode: always show the live setup status (linked? decrypting?) so opening
            // a companion device tells you whether it's set up and what to do if not.
            if session.captureMode == .companion {
                CompanionStatusBanner(session: session)
                divider
            }
            if showCaptureChooser {
                captureChooser
            } else {
                if !session.transactions.isEmpty {
                    NetworkTimelineView(session: session)
                    divider
                }
                HSplitView {
                    transactionList
                        .frame(minWidth: 420, idealWidth: 560)
                    NetworkDetailView(transaction: session.selected)
                        .frame(minWidth: 320)
                }
            }
            divider
            statusBar
        }
        .background(LemonadeTheme.colors.background.bgDefault)
        .accessibilityIdentifier("networkSessionView")
        .onAppear { searchText = session.filterText }
        // Proxy started but HTTPS isn't decrypting yet → guide the user to set up
        // the CA (or switch to Agent). One-shot: cleared once consumed.
        .onChange(of: session.proxyNeedsSetup) { _, needs in
            if needs { showSetup = true; session.proxyNeedsSetup = false }
        }
        .sheet(isPresented: $showSetup) {
            NetworkSetupSheet(
                session: session,
                onInstallCA: { showSetup = false; openCAInstall() },
                onSwitchToAgent: { showSetup = false; session.reopenModeChooser() }
            )
        }
        .sheet(isPresented: $showCAInstall) {
            if let installer = session.caInstaller {
                CAInstallSheet(installer: installer, onCancel: { session.cancelCAInstall() })
            }
        }
    }

    /// Probes the device, builds the installer, then presents the blocking sheet
    /// (which starts it on appear).
    private func openCAInstall() {
        Task {
            await session.prepareCAInstall()
            if session.caInstaller != nil { showCAInstall = true }
        }
    }

    private var divider: some View {
        Rectangle().fill(LemonadeTheme.colors.border.borderNeutralLow).frame(height: 1)
    }

    /// A fresh/stopped tab with no captured traffic and no chosen mode shows the
    /// capture-mode chooser instead of auto-starting — proxy mode must be picked
    /// deliberately because it reconfigures the device. Once a mode is chosen (incl.
    /// restored from a previous launch) the tab is ready and the user just presses play.
    private var showCaptureChooser: Bool {
        !session.hasSelectedMode && !session.isRunning && session.transactions.isEmpty
    }

    private var captureChooser: some View {
        VStack(spacing: LemonadeTheme.spaces.spacing300) {
            Spacer()
            Image(systemName: "arrow.left.arrow.right.circle")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(LemonadeTheme.colors.content.contentTertiary)
            VStack(spacing: LemonadeTheme.spaces.spacing100) {
                LemonadeUi.Text(session.device.displayModel,
                                textStyle: LemonadeTypography.shared.bodyLargeMedium,
                                color: LemonadeTheme.colors.content.contentPrimary)
                LemonadeUi.Text("Choose how to capture traffic",
                                textStyle: LemonadeTypography.shared.bodySmallRegular,
                                color: LemonadeTheme.colors.content.contentTertiary)
            }

            if session.isConnecting {
                HStack(spacing: LemonadeTheme.spaces.spacing200) {
                    ProgressView().controlSize(.small)
                    LemonadeUi.Text("Connecting…",
                                    textStyle: LemonadeTypography.shared.bodySmallRegular,
                                    color: LemonadeTheme.colors.content.contentSecondary)
                }
            } else {
                VStack(spacing: LemonadeTheme.spaces.spacing200) {
                    let hasCompanion = session.availableSources.contains { $0.kind == .companion }
                    if hasCompanion {
                        LemonadeUi.Button(label: "Start companion capture", onClick: { session.startCompanionCapture() },
                                          leadingIcon: .smartphone, variant: .primary, type: .solid, size: .medium)
                            .fixedSize()
                        LemonadeUi.Text("Capture the whole device through the Jaca mobile app, attributed per app.",
                                        textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                                        textAlign: .center,
                                        color: LemonadeTheme.colors.content.contentTertiary)
                            .frame(maxWidth: 420)
                        if session.isADBDevice {
                            LemonadeUi.Button(label: "Install CA automatically", onClick: { openCAInstall() },
                                              leadingIcon: .smartphone, variant: .neutral, type: .subtle, size: .small)
                                .fixedSize()
                            if let hint = rootHint {
                                LemonadeUi.Text(hint,
                                                textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                                                textAlign: .center,
                                                color: LemonadeTheme.colors.content.contentTertiary)
                                    .frame(maxWidth: 420)
                            }
                        }
                    } else if !session.agentAvailable {
                        LemonadeUi.Text("Install the Jaca mobile app on this device to capture its traffic, then it appears here automatically.",
                                        textStyle: LemonadeTypography.shared.bodySmallRegular,
                                        textAlign: .center,
                                        color: LemonadeTheme.colors.content.contentSecondary)
                            .frame(maxWidth: 420)
                    }

                    if session.agentAvailable && session.isADBDevice {
                        if hasCompanion {
                            LemonadeUi.Text("— or —",
                                            textStyle: LemonadeTypography.shared.bodyXSmallOverline,
                                            color: LemonadeTheme.colors.content.contentTertiary)
                                .padding(.top, LemonadeTheme.spaces.spacing100)
                        }
                        NetworkAppPicker(session: session)
                        LemonadeUi.Text("Inspect one debuggable app in-process — call stacks behind each request, no CA.",
                                        textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                                        textAlign: .center,
                                        color: LemonadeTheme.colors.content.contentTertiary)
                            .frame(maxWidth: 420)
                    }
                }
            }

            if let status = session.statusMessage {
                LemonadeUi.Text(status,
                                textStyle: LemonadeTypography.shared.bodySmallRegular,
                                color: LemonadeTheme.colors.content.contentCritical)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LemonadeTheme.colors.background.bgDefault)
        .accessibilityIdentifier("networkCaptureChooser")
    }

    /// Surfaces the device's root status so the user knows whether the CA installs
    /// automatically or needs a tap on the device.
    private var rootHint: String? {
        guard session.isAndroid, let caps = session.deviceContext?.capabilities else { return nil }
        switch caps.root {
        case .rooted:
            return "Rooted / emulator — the CA installs into the system trust store automatically."
        case .notRooted:
            return caps.hasScreenLock
                ? "Not rooted — you'll confirm one certificate prompt on the device."
                : "Not rooted — set a screen lock on the device first (Android requires one for CA certs)."
        case .unknown:
            return nil
        }
    }

    private var toolbar: some View {
        HStack(spacing: LemonadeTheme.spaces.spacing200) {
            Button(action: { session.toggle() }) {
                Image(systemName: session.isRunning ? "stop.fill" : "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(session.isRunning
                        ? LemonadeTheme.colors.content.contentCritical
                        : LemonadeTheme.colors.content.contentBrand)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: LemonadeTheme.radius.radius150)
                        .fill(LemonadeTheme.colors.background.bgNeutralSubtle))
            }
            .buttonStyle(.plain)
            .help(session.isRunning ? "Stop capture" : "Start capture")
            .accessibilityIdentifier("netTransportButton")

            LemonadeUi.IconButton(icon: .trash, contentDescription: "Clear") { session.clear() }

            if session.isADBDevice {
                NetworkAppPicker(session: session)
            }

            LemonadeUi.SearchField(
                input: $searchText,
                onInputChanged: { session.filterText = $0 },
                placeholder: "Filter by URL, host, method…",
                onInputClear: { session.filterText = "" }
            )
            .frame(maxWidth: 360)

            Spacer()

            modeBadge

            if let status = session.statusMessage {
                LemonadeUi.Text(status, textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                                color: LemonadeTheme.colors.content.contentSecondary, maxLines: 1)
            }
            LemonadeUi.IconButton(icon: .download, contentDescription: "Export HAR") { exportHAR() }
            // Proxy/CA setup only applies to a real ADB device capturing via the proxy.
            // Companion and agent modes need no proxy setup (the companion app installs its
            // own CA), and a companion-only device has no adb to set up — so hide it there.
            if session.showsProxySetup {
                LemonadeUi.Button(label: "Setup", onClick: { showSetup = true },
                                  leadingIcon: .circleInfo, variant: .neutral, type: .subtle, size: .small)
            }
        }
        .padding(.horizontal, LemonadeTheme.spaces.spacing300)
        .padding(.vertical, LemonadeTheme.spaces.spacing200)
        .background(LemonadeTheme.colors.background.bgElevated)
    }

    private var modeBadge: some View {
        let mode = session.captureMode
        let color: Color = mode == .agent ? LemonadeTheme.colors.content.contentBrand
            : (mode == .companion ? LemonadeTheme.colors.content.contentPositive
                                  : LemonadeTheme.colors.content.contentTertiary)
        return HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(mode.label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(LemonadeTheme.colors.content.contentSecondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(LemonadeTheme.colors.background.bgNeutralSubtle))
        .help(mode == .agent ? "Capturing in-process via the agent (no proxy/CA)"
              : (mode == .companion ? "Streaming from the Jaca mobile companion app"
                                    : "Capturing via the MITM proxy"))
    }

    private func exportHAR() {
        guard let data = HARExport.data(from: session.transactions) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(session.displayName).har"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            try? data.write(to: url)
        }
    }

    private var transactionList: some View {
        VStack(spacing: 0) {
            columnHeader
            divider
            if session.filtered.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(session.filtered) { txn in
                            NetworkRowView(txn: txn, selected: txn.id == session.selectedID)
                                .contentShape(Rectangle())
                                .onTapGesture { session.selectedID = txn.id }
                        }
                    }
                }
            }
        }
        .background(LemonadeTheme.colors.background.bgDefault)
    }

    private var columnHeader: some View {
        HStack(spacing: LemonadeTheme.spaces.spacing200) {
            headerCell("Status", width: 52)
            headerCell("Method", width: 60)
            headerCell("Host", width: 150)
            headerCell("Path", width: nil)
            headerCell("Size", width: 70)
            headerCell("Time", width: 64)
        }
        .padding(.horizontal, LemonadeTheme.spaces.spacing300)
        .padding(.vertical, LemonadeTheme.spaces.spacing100)
        .background(LemonadeTheme.colors.background.bgElevated)
    }

    private func headerCell(_ title: String, width: CGFloat?) -> some View {
        LemonadeUi.Text(title.uppercased(),
                        textStyle: LemonadeTypography.shared.bodyXSmallOverline,
                        color: LemonadeTheme.colors.content.contentTertiary, maxLines: 1)
            .frame(width: width, alignment: .leading)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }

    private var emptyState: some View {
        VStack(spacing: LemonadeTheme.spaces.spacing200) {
            Spacer()
            LemonadeUi.Icon(icon: .arrowLeftRight, contentDescription: nil, size: .large,
                            tint: LemonadeTheme.colors.content.contentTertiary)
            LemonadeUi.Text(session.isRunning ? "Waiting for traffic…" : "Capture stopped",
                            textStyle: LemonadeTypography.shared.bodySmallRegular,
                            color: LemonadeTheme.colors.content.contentSecondary)
            if session.captureMode == .companion {
                LemonadeUi.Text("Open the Jaca app on \(session.device.displayModel) and start capture — it connects automatically. Install the certificate in the app to decrypt HTTPS.",
                                textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                                textAlign: .center,
                                color: LemonadeTheme.colors.content.contentTertiary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(LemonadeTheme.spaces.spacing400)
    }

    private var statusBar: some View {
        HStack(spacing: LemonadeTheme.spaces.spacing300) {
            Circle()
                .fill(session.isRunning ? LemonadeTheme.colors.content.contentPositive
                                        : LemonadeTheme.colors.content.contentTertiary)
                .frame(width: 8, height: 8)
            metric("\(session.transactions.count) requests")
            Spacer()
            metric(session.device.displayModel)
        }
        .padding(.horizontal, LemonadeTheme.spaces.spacing300)
        .padding(.vertical, LemonadeTheme.spaces.spacing100)
        .background(LemonadeTheme.colors.background.bgElevated)
    }

    private func metric(_ text: String) -> some View {
        LemonadeUi.Text(text, textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                        color: LemonadeTheme.colors.content.contentSecondary, maxLines: 1)
    }
}

/// Picks the app to inspect in-process. Lists installed apps, tags the debuggable
/// ones ("agent" — those the in-process capture can attach to), and offers a
/// "Whole device (proxy)" option to fall back to the MITM proxy.
private struct NetworkAppPicker: View {
    let session: NetworkSession
    @State private var show = false
    @State private var apps: [AppEntry] = []
    @State private var debuggable: Set<String> = []
    @State private var loading = false
    @State private var loaded = false
    @State private var query = ""

    /// Prefer the shared per-device list (polled once per device); fall back to
    /// this tab's own one-shot load when no context is wired (e.g. in tests).
    private var appList: [AppEntry] { session.deviceContext?.apps ?? apps }
    private var debugSet: Set<String> { session.deviceContext?.debuggable ?? debuggable }
    private var isLoading: Bool {
        if let ctx = session.deviceContext { return !ctx.appsLoaded }
        return loading
    }

    var body: some View {
        Button(action: { show = true; onOpen() }) {
            HStack(spacing: 5) {
                Image(systemName: "ladybug").font(.system(size: 11, weight: .semibold))
                Text(buttonLabel).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(session.targetPackage == nil
                ? LemonadeTheme.colors.content.contentSecondary
                : LemonadeTheme.colors.content.contentBrand)
            .padding(.horizontal, 10).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: LemonadeTheme.radius.radius150)
                .fill(LemonadeTheme.colors.background.bgNeutralSubtle))
        }
        .buttonStyle(.plain)
        .help("Choose a debuggable app to inspect in-process (agent), or the whole device (proxy)")
        .accessibilityIdentifier("netAppPicker")
        .popover(isPresented: $show, arrowEdge: .bottom) { popover }
    }

    private var buttonLabel: String {
        guard let p = session.targetPackage else { return "Inspect app" }
        return p.components(separatedBy: ".").last ?? p
    }

    private var sorted: [AppEntry] {
        let f = query.isEmpty ? appList : appList.filter {
            $0.id.localizedCaseInsensitiveContains(query) || ($0.name ?? "").localizedCaseInsensitiveContains(query)
        }
        return f.sorted { a, b in
            let da = debugSet.contains(a.id), db = debugSet.contains(b.id)
            if da != db { return da }                        // debuggable first
            if a.isUserApp != b.isUserApp { return a.isUserApp }
            return a.display.localizedCaseInsensitiveCompare(b.display) == .orderedAscending
        }
    }

    private var popover: some View {
        VStack(spacing: 0) {
            TextField("Search apps…", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(LemonadeTheme.spaces.spacing200)
                .accessibilityIdentifier("netAppSearch")
            Rectangle().fill(LemonadeTheme.colors.border.borderNeutralLow).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    row(title: "Whole device (companion)", subtitle: "capture all apps via the Jaca mobile app",
                        debug: false, selected: session.targetPackage == nil) { select(nil) }
                    if isLoading && appList.isEmpty {
                        ProgressView().padding(LemonadeTheme.spaces.spacing400).frame(maxWidth: .infinity)
                    }
                    ForEach(sorted) { app in
                        row(title: app.display, subtitle: app.name != nil ? app.id : nil,
                            debug: debugSet.contains(app.id),
                            selected: session.targetPackage == app.id) { select(app.id) }
                    }
                }
            }
        }
        .frame(width: 360, height: 420)
    }

    private func row(title: String, subtitle: String?, debug: Bool, selected: Bool,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: LemonadeTheme.spaces.spacing200) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).foregroundStyle(LemonadeTheme.colors.content.contentPrimary)
                        .font(.system(size: 12)).lineLimit(1)
                    if let subtitle {
                        Text(subtitle).foregroundStyle(LemonadeTheme.colors.content.contentTertiary)
                            .font(.system(size: 10, design: .monospaced)).lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                if debug {
                    Text("agent").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(LemonadeTheme.colors.content.contentBrand)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(LemonadeTheme.colors.background.bgNeutralSubtle))
                }
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                        .foregroundStyle(LemonadeTheme.colors.content.contentBrand)
                }
            }
            .padding(.horizontal, LemonadeTheme.spaces.spacing300)
            .padding(.vertical, LemonadeTheme.spaces.spacing100)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("netAppRow")
    }

    /// On open: nudge the shared per-device list to refresh, or do a one-shot
    /// load if there's no context.
    private func onOpen() {
        if let ctx = session.deviceContext { ctx.refreshApps() }
        else if !loaded { load() }
    }

    private func load() {
        loading = true
        Task { @MainActor in
            let result = await session.installedApps()
            apps = result
            loaded = true
            loading = false
            await withTaskGroup(of: (String, Bool).self) { group in
                for app in result where app.isUserApp {
                    group.addTask { (app.id, await session.isDebuggable(app.id)) }
                }
                for await (id, ok) in group where ok { debuggable.insert(id) }
            }
        }
    }

    private func select(_ id: String?) {
        show = false
        DispatchQueue.main.async { session.setTarget(id) }
    }
}

private struct NetworkRowView: View {
    let txn: NetworkTransaction
    let selected: Bool

    var body: some View {
        HStack(spacing: LemonadeTheme.spaces.spacing200) {
            Text(txn.statusText)
                .foregroundStyle(NetworkFormatting.statusColor(txn))
                .fontWeight(.semibold)
                .frame(width: 52, alignment: .leading)
            Text(txn.method)
                .foregroundStyle(LemonadeTheme.colors.content.contentSecondary)
                .frame(width: 60, alignment: .leading)
            Text(txn.host)
                .foregroundStyle(LemonadeTheme.colors.content.contentPrimary)
                .frame(width: 150, alignment: .leading).lineLimit(1).truncationMode(.tail)
            Text(txn.path)
                .foregroundStyle(LemonadeTheme.colors.content.contentPrimary)
                .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1).truncationMode(.middle)
            Text(NetworkFormatting.size(txn.responseBytes))
                .foregroundStyle(LemonadeTheme.colors.content.contentTertiary)
                .frame(width: 70, alignment: .leading)
            Text(NetworkFormatting.duration(txn.duration))
                .foregroundStyle(LemonadeTheme.colors.content.contentTertiary)
                .frame(width: 64, alignment: .leading)
        }
        .font(LogLevelStyle.mono(11))
        .padding(.horizontal, LemonadeTheme.spaces.spacing300)
        .padding(.vertical, LemonadeTheme.spaces.spacing100)
        .background(selected ? LemonadeTheme.colors.interaction.bgSubtleInteractive : .clear)
    }
}

/// Live companion setup status. Tells the user, when they open a companion device, whether
/// it's actually linked and whether HTTPS is decrypting — and what to do if not. The link
/// state is polled (the session's `Device` is a snapshot); `caReady` is observed and flips
/// the moment the first request is decrypted, so it validates automatically.
private struct CompanionStatusBanner: View {
    let session: NetworkSession
    @State private var linked = false

    var body: some View {
        let decrypting = session.caReady
        return HStack(spacing: LemonadeTheme.spaces.spacing200) {
            Circle().fill(dotColor(linked, decrypting)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                LemonadeUi.Text(title(linked, decrypting),
                                textStyle: LemonadeTypography.shared.bodyXSmallSemiBold,
                                color: LemonadeTheme.colors.content.contentPrimary, maxLines: 1)
                LemonadeUi.Text(detail(linked, decrypting),
                                textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                                color: LemonadeTheme.colors.content.contentTertiary, maxLines: 2)
            }
            Spacer(minLength: 6)
            if linked && !decrypting { ProgressView().controlSize(.small) }   // verifying decryption
        }
        .padding(.horizontal, LemonadeTheme.spaces.spacing300)
        .padding(.vertical, LemonadeTheme.spaces.spacing200)
        .background(LemonadeTheme.colors.background.bgElevated)
        .animation(.easeInOut(duration: 0.2), value: linked)
        .animation(.easeInOut(duration: 0.2), value: decrypting)
        .task(id: session.id) {
            while !Task.isCancelled {
                linked = session.companionLinked
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func dotColor(_ linked: Bool, _ decrypting: Bool) -> Color {
        if decrypting { return LemonadeTheme.colors.content.contentPositive }
        if linked { return LemonadeTheme.colors.content.contentCaution }
        return LemonadeTheme.colors.content.contentCritical
    }
    private func title(_ linked: Bool, _ decrypting: Bool) -> String {
        if decrypting { return "Decrypting HTTPS ✓" }
        if linked { return "Connected — setting up HTTPS" }
        return "Companion offline"
    }
    private func detail(_ linked: Bool, _ decrypting: Bool) -> String {
        if decrypting { return "Capturing decrypted traffic from \(session.device.displayModel)." }
        if linked { return "Open the Jaca app on the device and tap Install certificate to decrypt HTTPS — it confirms here automatically." }
        return "Open the Jaca app on \(session.device.displayModel) and start capture — it connects automatically."
    }
}
