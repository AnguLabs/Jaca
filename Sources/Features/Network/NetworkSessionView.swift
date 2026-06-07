import SwiftUI
import Lemonade
import AppKit

/// Network-inspection tab: proxy toolbar, captured-transaction list, and a detail
/// pane (overview / headers / bodies / timing) for the selected transaction.
struct NetworkSessionView: View {
    @Bindable var session: NetworkSession
    @State private var showSetup = false
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            divider
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
            divider
            statusBar
        }
        .background(LemonadeTheme.colors.background.bgDefault)
        .accessibilityIdentifier("networkSessionView")
        .onAppear { searchText = session.filterText }
        .sheet(isPresented: $showSetup) { NetworkSetupSheet(session: session) }
    }

    private var divider: some View {
        Rectangle().fill(LemonadeTheme.colors.border.borderNeutralLow).frame(height: 1)
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
            .help(session.isRunning ? "Stop proxy" : "Start proxy")
            .accessibilityIdentifier("netTransportButton")

            LemonadeUi.IconButton(icon: .trash, contentDescription: "Clear") { session.clear() }

            LemonadeUi.SearchField(
                input: $searchText,
                onInputChanged: { session.filterText = $0 },
                placeholder: "Filter by URL, host, method…",
                onInputClear: { session.filterText = "" }
            )
            .frame(maxWidth: 360)

            Spacer()

            if let status = session.statusMessage {
                LemonadeUi.Text(status, textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                                color: LemonadeTheme.colors.content.contentSecondary, maxLines: 1)
            }
            LemonadeUi.IconButton(icon: .download, contentDescription: "Export HAR") { exportHAR() }
            LemonadeUi.Button(label: "Setup", onClick: { showSetup = true },
                              leadingIcon: .circleInfo, variant: .neutral, type: .subtle, size: .small)
        }
        .padding(.horizontal, LemonadeTheme.spaces.spacing300)
        .padding(.vertical, LemonadeTheme.spaces.spacing200)
        .background(LemonadeTheme.colors.background.bgElevated)
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
            LemonadeUi.Text(session.isRunning ? "Waiting for traffic…" : "Proxy stopped",
                            textStyle: LemonadeTypography.shared.bodySmallRegular,
                            color: LemonadeTheme.colors.content.contentSecondary)
            LemonadeUi.Text("Open Setup to point your device at the proxy and trust the CA.",
                            textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                            textAlign: .center,
                            color: LemonadeTheme.colors.content.contentTertiary)
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
            if session.boundPort > 0 { metric("proxy \(session.hostAddress):\(session.boundPort)") }
            if session.proxyConfigured { metric("device configured") }
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
