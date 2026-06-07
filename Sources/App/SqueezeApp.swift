import SwiftUI
import Lemonade

@main
struct SqueezeApp: App {
    init() {
        // Register the Figtree faces bundled with the Lemonade design system so
        // LemonadeUi.Text renders in the brand typeface instead of the system font.
        LemonadeFonts.registerFonts()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .frame(minWidth: 900, minHeight: 560)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1180, height: 760)
        .windowToolbarStyle(.unified(showsTitle: true))
    }
}
