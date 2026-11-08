#if os(iOS)
import ActivityKit
import AppIntents

/// ロック画面 / Dynamic Island に出す Live Activity (アプリと Widget 拡張で共有)
struct CastActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var muted: Bool
        var reconnecting: Bool
    }
    var pcName: String
}

/// Live Activity のボタン。LiveActivityIntent はアプリ本体のプロセスで実行される
struct ToggleMuteIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "マイクのミュート切り替え"
    /// ショートカット等には出さない (Live Activity のボタン専用)
    static let isDiscoverable = false
    init() {}

    func perform() async throws -> some IntentResult {
        await MuteBridge.toggle()
        return .result()
    }
}

/// アプリ本体が起動時にハンドラを登録する (Widget 拡張側では nil のまま)
@MainActor
enum MuteBridge {
    static var handler: (() -> Void)?
    static func toggle() { handler?() }
}
#endif
