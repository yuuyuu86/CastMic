import SwiftUI

@main
struct CastMicApp: App {
    @State private var session = CastSession()
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(session)
                // iPhone 標準カメラで QR を読んだとき / アプリ内スキャナ
                .onOpenURL { session.handlePairURL($0) }
        }
    }
}
