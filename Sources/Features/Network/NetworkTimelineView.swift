import SwiftUI
import Lemonade

/// Time axis of captured requests. Each request is a mark positioned by start
/// time, colored by status. Drag horizontally to select a time window that
/// filters the list; click to clear.
struct NetworkTimelineView: View {
    @Bindable var session: NetworkSession
    @State private var dragStartX: CGFloat?
    @State private var dragCurrentX: CGFloat?

    private let height: CGFloat = 56
    private let lanes = 6

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let domain = timeDomain()
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    draw(in: ctx, size: size, domain: domain)
                }
                selectionOverlay(width: width, domain: domain)
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(width: width, domain: domain))
            .overlay(alignment: .topTrailing) { clearButton }
        }
        .frame(height: height)
        .background(LemonadeTheme.colors.background.bgDefault)
    }

    // MARK: Drawing

    private func timeDomain() -> ClosedRange<Date> {
        guard let first = session.transactions.first?.startedAt else {
            let now = Date(); return now...now.addingTimeInterval(1)
        }
        let start = session.transactions.map(\.startedAt).min() ?? first
        let end = max(
            session.transactions.map { $0.finishedAt ?? $0.startedAt }.max() ?? first,
            start.addingTimeInterval(1)
        )
        return start...end
    }

    private func x(for date: Date, width: CGFloat, domain: ClosedRange<Date>) -> CGFloat {
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        guard span > 0 else { return 0 }
        let frac = date.timeIntervalSince(domain.lowerBound) / span
        return CGFloat(frac) * width
    }

    private func draw(in ctx: GraphicsContext, size: CGSize, domain: ClosedRange<Date>) {
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        guard span > 0 else { return }
        let laneHeight = (size.height - 8) / CGFloat(lanes)
        for (index, txn) in session.transactions.enumerated() {
            let startX = x(for: txn.startedAt, width: size.width, domain: domain)
            let end = txn.finishedAt ?? txn.startedAt
            let endX = max(startX + 2, x(for: end, width: size.width, domain: domain))
            let lane = CGFloat(index % lanes)
            let rect = CGRect(x: startX, y: 4 + lane * laneHeight,
                              width: endX - startX, height: max(3, laneHeight - 3))
            let color = NetworkFormatting.statusColor(txn)
            ctx.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(color.opacity(0.85)))
        }
    }

    // MARK: Selection

    @ViewBuilder
    private func selectionOverlay(width: CGFloat, domain: ClosedRange<Date>) -> some View {
        if let lo = dragStartX, let hi = dragCurrentX {
            let minX = min(lo, hi), maxX = max(lo, hi)
            Rectangle()
                .fill(LemonadeTheme.colors.content.contentBrand.opacity(0.15))
                .overlay(Rectangle().stroke(LemonadeTheme.colors.content.contentBrand, lineWidth: 1))
                .frame(width: max(1, maxX - minX), height: height)
                .offset(x: minX)
                .allowsHitTesting(false)
        } else if let range = session.selectedTimeRange {
            let minX = x(for: range.lowerBound, width: width, domain: domain)
            let maxX = x(for: range.upperBound, width: width, domain: domain)
            Rectangle()
                .fill(LemonadeTheme.colors.content.contentBrand.opacity(0.12))
                .overlay(Rectangle().stroke(LemonadeTheme.colors.content.contentBrand.opacity(0.6), lineWidth: 1))
                .frame(width: max(1, maxX - minX), height: height)
                .offset(x: minX)
                .allowsHitTesting(false)
        }
    }

    private func dragGesture(width: CGFloat, domain: ClosedRange<Date>) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if dragStartX == nil { dragStartX = value.startLocation.x }
                dragCurrentX = value.location.x
            }
            .onEnded { value in
                defer { dragStartX = nil; dragCurrentX = nil }
                guard let lo = dragStartX else { return }
                let minX = min(lo, value.location.x), maxX = max(lo, value.location.x)
                guard maxX - minX > 3 else { session.selectedTimeRange = nil; return }
                let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
                let start = domain.lowerBound.addingTimeInterval(Double(minX / max(width, 1)) * span)
                let end = domain.lowerBound.addingTimeInterval(Double(maxX / max(width, 1)) * span)
                session.selectedTimeRange = start...end
            }
    }

    @ViewBuilder
    private var clearButton: some View {
        if session.selectedTimeRange != nil {
            Button(action: { session.selectedTimeRange = nil }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(LemonadeTheme.colors.content.contentSecondary)
            }
            .buttonStyle(.plain)
            .padding(4)
            .help("Clear time selection")
        }
    }
}
