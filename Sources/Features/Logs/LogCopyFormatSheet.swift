import SwiftUI
import Lemonade

/// Configures the app-wide log **copy format** (⌘C) used by every log list — device logs and
/// Cloud Logging alike. Pick a one-click preset (each shows its example output) or hand-edit the
/// template + date format, with a live example. Saved to `LogCopyFormatStore` (~/.jaca).
struct LogCopyFormatSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var format = LogCopyFormatStore.shared.format

    private let columnColor = Color(red: 0.20, green: 0.60, blue: 0.62)

    var body: some View {
        VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing400) {
            header
            LemonadeUi.Text("How ⌘C copies selected log rows, in every log list. Pick a preset or edit the "
                            + "template below.", textStyle: LemonadeTypography.shared.bodySmallRegular,
                            color: LemonadeTheme.colors.content.contentSecondary)
            presets
            custom
            footer
        }
        .padding(LemonadeTheme.spaces.spacing600)
        .frame(width: 580)
        .background(LemonadeTheme.colors.background.bgDefault)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard").foregroundStyle(LemonadeTheme.colors.content.contentBrand)
            LemonadeUi.Text("Copy format", textStyle: LemonadeTypography.shared.headingSmall,
                            color: LemonadeTheme.colors.content.contentPrimary)
            Spacer()
            LemonadeUi.Button(label: "Cancel", onClick: { dismiss() },
                              variant: .neutral, type: .subtle, size: .small)
        }
    }

    private var presets: some View {
        VStack(alignment: .leading, spacing: 6) {
            LemonadeUi.Text("PRESETS", textStyle: LemonadeTypography.shared.bodyXSmallOverline,
                            color: LemonadeTheme.colors.content.contentTertiary)
            VStack(spacing: 0) {
                ForEach(Array(LogCopyPresets.all.enumerated()), id: \.element.id) { index, preset in
                    presetRow(preset)
                    if index != LogCopyPresets.all.count - 1 {
                        Rectangle().fill(LemonadeTheme.colors.border.borderNeutralLow).frame(height: 1)
                    }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(LemonadeTheme.colors.border.borderNeutralLow, lineWidth: 1))
        }
    }

    private func presetRow(_ preset: LogCopyFormatPreset) -> some View {
        let selected = preset.format == format
        return Button(action: { format = preset.format }) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(selected ? LemonadeTheme.colors.content.contentBrand
                                              : LemonadeTheme.colors.content.contentTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    LemonadeUi.Text(preset.name, textStyle: LemonadeTypography.shared.bodySmallMedium,
                                    color: LemonadeTheme.colors.content.contentPrimary)
                    Text(preset.format.render(LogCopyPresets.sample))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(LemonadeTheme.colors.content.contentTertiary)
                        .lineLimit(1).truncationMode(.tail)
                }
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var custom: some View {
        VStack(alignment: .leading, spacing: 6) {
            LemonadeUi.Text("CUSTOM", textStyle: LemonadeTypography.shared.bodyXSmallOverline,
                            color: LemonadeTheme.colors.content.contentTertiary)
            field("FORMAT", text: $format.template, placeholder: "{date} {level} {tag}  {message}")
            field("DATE FORMAT", text: $format.dateFormat, placeholder: "HH:mm:ss.SSS")
            tokenLegend
            exampleBox
        }
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            LemonadeUi.Text(label, textStyle: LemonadeTypography.shared.bodyXSmallOverline,
                            color: LemonadeTheme.colors.content.contentTertiary)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .padding(.vertical, 7).padding(.horizontal, 10)
                .background(RoundedRectangle(cornerRadius: 8).fill(LemonadeTheme.colors.background.bgNeutralSubtle))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(LemonadeTheme.colors.border.borderNeutralLow, lineWidth: 1))
        }
    }

    private var tokenLegend: some View {
        FlowLayout(spacing: 5, lineSpacing: 5) {
            ForEach(LogCopyFormat.knownTokens, id: \.self) { token in
                Text("{\(token)}")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(columnColor)
                    .padding(.vertical, 2).padding(.horizontal, 6)
                    .background(Capsule().fill(LemonadeTheme.colors.background.bgNeutralSubtle))
            }
        }
    }

    private var exampleBox: some View {
        VStack(alignment: .leading, spacing: 3) {
            LemonadeUi.Text("EXAMPLE", textStyle: LemonadeTypography.shared.bodyXSmallOverline,
                            color: LemonadeTheme.colors.content.contentTertiary)
            Text(format.render(LogCopyPresets.sample).isEmpty ? " " : format.render(LogCopyPresets.sample))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(LemonadeTheme.colors.content.contentPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(LemonadeTheme.colors.background.bgNeutralSubtle))
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            LemonadeUi.Button(label: "Save", onClick: { save() },
                              leadingIcon: .circleCheck, variant: .primary, type: .solid, size: .medium)
                .fixedSize()
        }
    }

    private func save() {
        LogCopyFormatStore.shared.format = format
        dismiss()
    }
}
