import SwiftUI
import Lemonade

/// Renders a transient Gradle toast using the Lemonade DS toast component.
/// `GradleDaemonsModel` owns the `GradleToast` lifecycle (auto-clears after ~2.6s),
/// so this view is purely presentational.
struct GradleToastView: View {
    let toast: GradleToast

    private var icon: LemonadeIcon? {
        switch toast.systemFallback {
        case "checkmark": return .circleCheck
        case "eraser": return .trash
        default: return nil
        }
    }

    var body: some View {
        LemonadeUi.Toast(label: toast.message, voice: .neutral, icon: icon)
    }
}
