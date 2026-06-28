import SwiftUI
import Lemonade
import UniformTypeIdentifiers

/// Horizontal strip of session tabs. Each tab shows a running dot, an editable
/// display name (double-click to rename), a filter subtitle, and a close button.
/// Tabs are draggable to reorder; Shift+Tab cycles the selection.
struct TabStripView: View {
    @Bindable var model: AppModel
    @State private var editingID: UUID?
    @State private var editingText = ""
    @State private var draggingID: UUID?
    @State private var hoveredID: UUID?
    @State private var hoverTask: Task<Void, Never>?
    @FocusState private var nameFocused: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: LemonadeTheme.spaces.spacing100) {
                ForEach(model.sessions, id: \.id) { session in
                    tab(session)
                        .opacity(draggingID == session.id ? 0.4 : 1)
                        .onDrag {
                            draggingID = session.id
                            return NSItemProvider(object: session.id.uuidString as NSString)
                        }
                        .onDrop(of: [.text],
                                delegate: TabDropDelegate(targetID: session.id, model: model,
                                                          draggingID: $draggingID))
                }
            }
            .padding(.horizontal, LemonadeTheme.spaces.spacing200)
            .padding(.vertical, LemonadeTheme.spaces.spacing100)
        }
        .background(LemonadeTheme.colors.background.bgElevated)
        .background {
            // Shift+Tab cycles tabs forward; ⌃⇧Tab cycles back.
            Button("") { model.cycleTab(forward: true) }
                .keyboardShortcut(.tab, modifiers: .shift).hidden()
            Button("") { model.cycleTab(forward: false) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift]).hidden()
        }
    }

    @ViewBuilder
    private func tab(_ session: any WorkspaceTab) -> some View {
        let isSelected = session.id == model.selectedSessionID
        Button(action: { model.select(session.id) }) {
            HStack(spacing: LemonadeTheme.spaces.spacing200) {
                Circle()
                    .fill(session.isRunning
                        ? LemonadeTheme.colors.content.contentPositive
                        : LemonadeTheme.colors.content.contentTertiary)
                    .frame(width: 7, height: 7)

                VStack(alignment: .leading, spacing: 0) {
                    if editingID == session.id {
                        TextField("Name", text: $editingText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(LemonadeTheme.colors.content.contentPrimary)
                            .frame(width: 130)
                            .focused($nameFocused)
                            .onSubmit { commitRename(session) }
                            .onExitCommand { editingID = nil }
                    } else {
                        LemonadeUi.Text(
                            session.displayName,
                            textStyle: LemonadeTypography.shared.bodySmallSemiBold,
                            color: LemonadeTheme.colors.content.contentPrimary,
                            maxLines: 1
                        )
                    }
                    LemonadeUi.Text(
                        session.subtitle,
                        textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                        color: LemonadeTheme.colors.content.contentTertiary,
                        maxLines: 1
                    )
                }
                // Cap the text column so a long subtitle truncates with "…" instead of stretching
                // the whole tab wide. A short name/subtitle still shrinks the tab to fit.
                .frame(maxWidth: 200, alignment: .leading)

                Button(action: { model.closeSession(session.id) }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(LemonadeTheme.colors.content.contentSecondary)
                }
                .buttonStyle(.plain)
                .help("Close tab")
                .accessibilityIdentifier("tabClose")
            }
            .padding(.horizontal, LemonadeTheme.spaces.spacing300)
            .padding(.vertical, LemonadeTheme.spaces.spacing200)
            .background(
                RoundedRectangle(cornerRadius: LemonadeTheme.radius.radius200)
                    .fill(isSelected
                        ? LemonadeTheme.colors.content.contentPositive.opacity(0.14)
                        : LemonadeTheme.colors.background.bgNeutralSubtle)
            )
            .overlay(
                RoundedRectangle(cornerRadius: LemonadeTheme.radius.radius200)
                    .stroke(isSelected
                        ? LemonadeTheme.colors.content.contentPositive
                        : LemonadeTheme.colors.border.borderNeutralMedium,
                        lineWidth: isSelected ? 1.5 : 1)
            )
            // Whole card is clickable, not just the text.
            .contentShape(RoundedRectangle(cornerRadius: LemonadeTheme.radius.radius200))
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded { beginRename(session) })
        .onHover { inside in
            if inside { scheduleTooltip(session.id) } else { cancelTooltip(session.id) }
        }
        .popover(isPresented: Binding(get: { hoveredID == session.id },
                                      set: { if !$0 { hoveredID = nil } }),
                 arrowEdge: .bottom) {
            tabTooltip(session)
        }
        .contextMenu {
            Button("Rename") { beginRename(session) }
            Divider()
            Button("Close Tab") { model.closeSession(session.id) }
        }
    }

    /// The hover tooltip: the tab's name plus its full context, one part per line (so a truncated
    /// subtitle is fully readable). Shown after a short dwell via `scheduleTooltip`.
    @ViewBuilder
    private func tabTooltip(_ session: any WorkspaceTab) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            LemonadeUi.Text(session.displayName,
                            textStyle: LemonadeTypography.shared.bodySmallSemiBold,
                            color: LemonadeTheme.colors.content.contentPrimary)
            ForEach(Array(session.subtitle.components(separatedBy: " · ")
                .filter { !$0.isEmpty }.enumerated()), id: \.offset) { _, part in
                LemonadeUi.Text(part,
                                textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                                color: LemonadeTheme.colors.content.contentSecondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: 380, alignment: .leading)
    }

    /// Shows the tooltip after a short dwell — unless the tab is being dragged or renamed.
    private func scheduleTooltip(_ id: UUID) {
        guard draggingID == nil, editingID != id else { return }
        hoverTask?.cancel()
        hoverTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, draggingID == nil, editingID != id else { return }
            hoveredID = id
        }
    }

    /// Cancels a pending tooltip and hides it when the cursor leaves the tab.
    private func cancelTooltip(_ id: UUID) {
        hoverTask?.cancel(); hoverTask = nil
        if hoveredID == id { hoveredID = nil }
    }

    /// Starts an inline rename (also reachable by double-clicking the tab), focusing the field.
    private func beginRename(_ session: any WorkspaceTab) {
        editingText = session.displayName
        editingID = session.id
        DispatchQueue.main.async { nameFocused = true }
    }

    /// Commits the rename. The new name is stored on the session and persisted via its
    /// `onStateChanged` (so it survives relaunch, restored from the saved tab descriptor).
    private func commitRename(_ session: any WorkspaceTab) {
        let trimmed = editingText.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { session.displayName = trimmed }
        editingID = nil
    }
}

/// Live-reorders tabs as the dragged one is hovered over another.
private struct TabDropDelegate: DropDelegate {
    let targetID: UUID
    let model: AppModel
    @Binding var draggingID: UUID?

    func dropEntered(info: DropInfo) {
        guard let dragging = draggingID, dragging != targetID else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            model.moveSession(dragging: dragging, over: targetID)
        }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { draggingID = nil; return true }
}
