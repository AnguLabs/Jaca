import SwiftUI
import Lemonade

/// The shared "Ask Claude" window, generic over any `ClaudeUseCase`. The user describes what they
/// want in plain language; Claude Code returns a structured result that the use case previews and
/// applies. Reused everywhere the Claude affordance appears — only the `ClaudeUseCase` differs.
struct ClaudeAskSheet<Output: Decodable & Sendable>: View {
    @State private var model: ClaudeAskModel<Output>
    @Environment(\.dismiss) private var dismiss

    init(useCase: ClaudeUseCase<Output>) {
        _model = State(initialValue: ClaudeAskModel(useCase: useCase))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing400) {
            header
            if model.available == false {
                LemonadeUi.Notice(content: ClaudeCodeCLI.CLIError.notInstalled.errorDescription ?? "",
                                  voice: .warning)
            }
            requestField
            if model.output == nil { exampleChips }
            if let error = model.errorMessage {
                LemonadeUi.Notice(content: error, voice: .critical)
            }
            if let output = model.output {
                resultView(output)
            }
            footer
        }
        .padding(LemonadeTheme.spaces.spacing600)
        .frame(width: 580)
        .background(LemonadeTheme.colors.background.bgDefault)
        .animation(.easeInOut(duration: 0.18), value: model.output != nil)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(LemonadeTheme.colors.content.contentBrand)
            LemonadeUi.Text(model.useCase.title,
                            textStyle: LemonadeTypography.shared.headingSmall,
                            color: LemonadeTheme.colors.content.contentPrimary)
            Spacer()
            LemonadeUi.Button(label: "Close", onClick: { dismiss() },
                              variant: .neutral, type: .subtle, size: .small)
        }
    }

    private var requestField: some View {
        VStack(alignment: .leading, spacing: 4) {
            LemonadeUi.Text("DESCRIBE WHAT YOU WANT",
                            textStyle: LemonadeTypography.shared.bodyXSmallOverline,
                            color: LemonadeTheme.colors.content.contentTertiary)
            TextField(model.useCase.inputPlaceholder, text: $model.input, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(2...5)
                .font(.system(size: 13))
                .padding(.vertical, 9).padding(.horizontal, 11)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(LemonadeTheme.colors.background.bgNeutralSubtle))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(LemonadeTheme.colors.border.borderNeutralLow, lineWidth: 1))
        }
    }

    private var exampleChips: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.useCase.examples.isEmpty {
                LemonadeUi.Text("TRY", textStyle: LemonadeTypography.shared.bodyXSmallOverline,
                                color: LemonadeTheme.colors.content.contentTertiary)
                FlowLayout(spacing: 6) {
                    ForEach(model.useCase.examples, id: \.self) { example in
                        Button(action: { model.use(example: example) }) {
                            Text(example)
                                .font(.system(size: 11))
                                .foregroundStyle(LemonadeTheme.colors.content.contentSecondary)
                                .padding(.vertical, 4).padding(.horizontal, 9)
                                .background(Capsule().fill(LemonadeTheme.colors.background.bgNeutralSubtle))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func resultView(_ output: Output) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let explanation = model.useCase.explanation(output), !explanation.isEmpty {
                LemonadeUi.Text(explanation, textStyle: LemonadeTypography.shared.bodySmallRegular,
                                color: LemonadeTheme.colors.content.contentSecondary)
            }
            ScrollView {
                Text(model.useCase.preview(output))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(LemonadeTheme.colors.content.contentPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(maxHeight: 220)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(LemonadeTheme.colors.background.bgNeutralSubtle))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(LemonadeTheme.colors.border.borderNeutralLow, lineWidth: 1))
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var footer: some View {
        HStack(spacing: LemonadeTheme.spaces.spacing200) {
            if model.isRunning {
                ProgressView().controlSize(.small)
                LemonadeUi.Text("Asking Claude…", textStyle: LemonadeTypography.shared.bodySmallRegular,
                                color: LemonadeTheme.colors.content.contentTertiary)
            }
            Spacer()
            if model.isRunning {
                LemonadeUi.Button(label: "Cancel", onClick: { model.cancel() },
                                  variant: .neutral, type: .subtle, size: .medium).fixedSize()
            } else if model.output != nil {
                LemonadeUi.Button(label: "Ask again", onClick: { model.submit() },
                                  variant: .neutral, type: .subtle, size: .medium).fixedSize()
                LemonadeUi.Button(label: "Apply & Run", onClick: { model.apply(); dismiss() },
                                  leadingIcon: .circleCheck, variant: .primary, type: .solid, size: .medium)
                    .fixedSize()
            } else {
                LemonadeUi.Button(label: "Ask Claude", onClick: { model.submit() },
                                  leadingIcon: .chevronRight, variant: .primary, type: .solid, size: .medium)
                    .fixedSize()
                    .disabled(!model.canSubmit)
            }
        }
    }
}

/// The little "Ask Claude" affordance (✨) that opens a `ClaudeAskSheet` for a use case. Drop this
/// anywhere the Claude assistant should be offered; supply the place's `ClaudeUseCase`.
struct ClaudeAskButton<Output: Decodable & Sendable>: View {
    let label: String
    let help: String
    let useCase: ClaudeUseCase<Output>
    @State private var presented = false

    init(label: String = "Ask Claude", help: String = "Describe what you want; Claude writes it",
         useCase: ClaudeUseCase<Output>) {
        self.label = label
        self.help = help
        self.useCase = useCase
    }

    var body: some View {
        Button(action: { presented = true }) {
            HStack(spacing: 4) {
                Image(systemName: "sparkles").font(.system(size: 11))
                Text(label).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(LemonadeTheme.colors.content.contentBrand)
        }
        .buttonStyle(.plain)
        .help(help)
        .sheet(isPresented: $presented) { ClaudeAskSheet(useCase: useCase) }
    }
}
