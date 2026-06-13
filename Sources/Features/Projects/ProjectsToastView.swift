import SwiftUI
import Lemonade

/// Renders a transient Projects toast using the Lemonade DS toast component.
/// `ProjectsModel` owns the toast lifecycle (auto-clears after ~2.6s), so this view is
/// purely presentational — it maps the model's `systemFallback` glyph onto a Lemonade icon.
struct ProjectsToastView: View {
    let toast: ProjectsToast

    private var icon: LemonadeIcon? {
        switch toast.systemFallback {
        case "checkmark": return .circleCheck
        case "sparkles": return .sparkles
        case "eraser": return .trash
        case "gear": return .gear
        case "refresh": return .arrowRotateCw
        default: return nil
        }
    }

    var body: some View {
        LemonadeUi.Toast(label: toast.message, voice: .neutral, icon: icon)
    }
}
