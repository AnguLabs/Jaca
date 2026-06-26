import SwiftUI
import Lemonade

/// Bottom-center transient toast for the Cloud Logging area (mirrors `ProjectsToastView`).
struct CloudLoggingToastView: View {
    let toast: CloudLoggingToast

    private var icon: LemonadeIcon? {
        switch toast.systemFallback {
        case "checkmark": return .circleCheck
        case "eraser": return .trash
        case "refresh": return .arrowRotateCw
        default: return nil
        }
    }

    var body: some View {
        LemonadeUi.Toast(label: toast.message, voice: .neutral, icon: icon)
    }
}
