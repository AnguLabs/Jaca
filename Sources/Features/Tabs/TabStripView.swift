import SwiftUI
import Lemonade

/// Horizontal strip of session tabs. Each tab shows a running dot, an editable
/// display name (double-click to rename), a filter subtitle, and a close button.
struct TabStripView: View {
    @Bindable var model: AppModel
    @State private var editingID: UUID?
    @State private var editingText = ""

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: LemonadeTheme.spaces.spacing100) {
                ForEach(model.sessions, id: \.id) { session in
                    tab(session)
                }
            }
            .padding(.horizontal, LemonadeTheme.spaces.spacing200)
            .padding(.vertical, LemonadeTheme.spaces.spacing100)
        }
        .background(LemonadeTheme.colors.background.bgElevated)
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

                Button(action: { model.closeSession(session.id) }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(LemonadeTheme.colors.content.contentSecondary)
                }
                .buttonStyle(.plain)
                .help("Close tab")
            }
            .padding(.horizontal, LemonadeTheme.spaces.spacing300)
            .padding(.vertical, LemonadeTheme.spaces.spacing200)
            .background(
                RoundedRectangle(cornerRadius: LemonadeTheme.radius.radius150)
                    .fill(isSelected
                        ? LemonadeTheme.colors.background.bgDefault
                        : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: LemonadeTheme.radius.radius150)
                    .stroke(isSelected
                        ? LemonadeTheme.colors.border.borderNeutralMedium
                        : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            editingText = session.displayName
            editingID = session.id
        })
    }

    private func commitRename(_ session: any WorkspaceTab) {
        let trimmed = editingText.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { session.displayName = trimmed }
        editingID = nil
    }
}
