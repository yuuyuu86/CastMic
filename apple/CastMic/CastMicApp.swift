import SwiftUI

@main
struct CastMicApp: App {
    @State private var session = CastSession()
    #if os(iOS)
    @State private var liveActivity = LiveActivityController()
    #endif
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(session)
                // iPhone 標準カメラで QR を読んだとき / アプリ内スキャナ
                .onOpenURL { session.handlePairURL($0) }
                #if os(iOS)
                .task {
                    MuteBridge.handler = { [session] in session.toggleMute() }
                    session.onChange = { [session, liveActivity] in liveActivity.update(session) }
                }
                #endif
        }
    }
}
