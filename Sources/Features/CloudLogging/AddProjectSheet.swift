import SwiftUI
import Lemonade

/// Sheet to add a GCP project (reqs 3–4): enter a project id (and an optional display name),
/// validated against gcloud before it's stored.
struct AddProjectSheet: View {
    @Bindable var registry: CloudLoggingRegistry
    @Environment(\.dismiss) private var dismiss

    @State private var projectID = ""
    @State private var displayName = ""
    @State private var validating = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing400) {
            HStack {
                LemonadeUi.Text("Add a GCP project",
                                textStyle: LemonadeTypography.shared.headingSmall,
                                color: LemonadeTheme.colors.content.contentPrimary)
                Spacer()
                LemonadeUi.Button(label: "Cancel", onClick: { dismiss() },
                                  variant: .neutral, type: .subtle, size: .small)
            }

            VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing200) {
                field(label: "PROJECT ID", placeholder: "my-gcp-project-123", text: $projectID)
                    .onSubmit { add() }
                field(label: "DISPLAY NAME (OPTIONAL)", placeholder: "Production", text: $displayName)
                    .onSubmit { add() }
            }

            if let error {
                LemonadeUi.Notice(content: error, voice: .critical)
            }

            HStack(spacing: LemonadeTheme.spaces.spacing200) {
                Spacer()
                if validating { ProgressView().controlSize(.small) }
                LemonadeUi.Button(
                    label: validating ? "Validating…" : "Add project",
                    onClick: { add() },
                    leadingIcon: .circleCheck,
                    variant: .primary, type: .solid, size: .medium
                )
                .fixedSize()
                .disabled(projectID.trimmingCharacters(in: .whitespaces).isEmpty || validating)
            }
        }
        .padding(LemonadeTheme.spaces.spacing600)
        .frame(width: 480)
        .background(LemonadeTheme.colors.background.bgDefault)
    }

    private func field(label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LemonadeUi.Text(label, textStyle: LemonadeTypography.shared.bodyXSmallOverline,
                            color: LemonadeTheme.colors.content.contentTertiary)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .padding(.vertical, 8).padding(.horizontal, 10)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(LemonadeTheme.colors.background.bgNeutralSubtle))
        }
    }

    private func add() {
        let id = projectID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, !validating else { return }
        validating = true
        error = nil
        Task {
            let result = await registry.addProject(id: id, displayName: displayName)
            validating = false
            switch result {
            case .added, .alreadyExists:
                dismiss()
            case .failure(let message):
                error = message
            }
        }
    }
}
