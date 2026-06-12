import SwiftUI
import Lemonade

/// Renders a transient worktrees toast using the Lemonade DS toast component.
///
/// `WorktreesTab` owns the `WorktreesToast` lifecycle (it auto-clears after ~2.6s),
/// so this view is purely presentational. It maps the tab's `systemFallback`
/// glyph string onto a `LemonadeIcon` and renders a neutral toast.
struct WorktreeToastView: View {
    let toast: WorktreesToast

    /// Maps the tab's system-glyph fallback string onto a Lemonade icon.
    private var icon: LemonadeIcon? {
        switch toast.systemFallback {
        case "checkmark": return .circleCheck
        case "sparkles": return .sparkles
        case "eraser": return .trash
        case "gear": return .gear
        case "refresh": return .arrowRotateCw
        case "android": return .brandAndroid
        case "apple": return .brandApple
        case "smartphone": return .smartphone
        case "folder": return nil
        default: return nil
        }
    }

    var body: some View {
        LemonadeUi.Toast(label: toast.message, voice: .neutral, icon: icon)
    }
}
