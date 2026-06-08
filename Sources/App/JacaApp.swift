import SwiftUI
import Lemonade

@main
struct JacaApp: App {
    @AppStorage("colorScheme") private var colorScheme = "dark"

    init() {
        // Register the Figtree faces bundled with the Lemonade design system so
        // LemonadeUi.Text renders in the brand typeface instead of the system font.
        LemonadeFonts.registerFonts()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .frame(minWidth: 900, minHeight: 560)
                .preferredColorScheme(preferredScheme)
        }
        .defaultSize(width: 1180, height: 760)
        .windowToolbarStyle(.unified(showsTitle: true))
    }

    private var preferredScheme: ColorScheme? {
        switch colorScheme {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
}
