import SwiftUI

@main
struct StarIndexApp: App {
    var body: some Scene {
        WindowGroup {
            // Plan 4.0: the sky is the first screen — no splash, drawn immediately from the bundle.
            SkyScreen()
                .preferredColorScheme(.dark)
        }
    }
}
