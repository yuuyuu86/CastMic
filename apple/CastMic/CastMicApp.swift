import SwiftUI

@main
struct CastMicApp: App {
    @State private var session = CastSession()
    @AppStorage("onboarded") private var onboarded = false
    #if os(iOS)
    @State private var liveActivity = LiveActivityController()
    #endif
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(session)
                // iPhone 標準カメラで QR を読んだとき / アプリ内スキャナ
                .onOpenURL { session.handlePairURL($0) }
                .sheet(isPresented: Binding(get: { !onboarded }, set: { if !$0 { onboarded = true } })) {
                    OnboardingView { onboarded = true }
                        .interactiveDismissDisabled()
                }
                #if os(iOS)
                .task {
                    MuteBridge.handler = { [session] in session.toggleMute() }
                    session.onChange = { [session, liveActivity] in liveActivity.update(session) }
                }
                #endif
        }
    }
}
