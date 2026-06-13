import SwiftUI
import Lemonade

/// Renders a transient Xcode-area toast using the Lemonade DS toast component.
/// `DerivedDataModel` owns the `XcodeToast` lifecycle (auto-clears after ~2.6s),
/// so this view is purely presentational.
struct XcodeToastView: View {
    let toast: XcodeToast

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
