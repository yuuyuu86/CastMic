import SwiftUI

@main
struct CastMicApp: App {
    @State private var session = CastSession()
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(session)
        }
    }
}
