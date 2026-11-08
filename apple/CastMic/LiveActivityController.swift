#if os(iOS)
import ActivityKit
import Foundation

/// 接続中は Live Activity を出し、ミュート状態を反映する
@MainActor
final class LiveActivityController {
    private var activity: Activity<CastActivityAttributes>?
    private var last: CastActivityAttributes.ContentState?

    func update(_ session: CastSession) {
        let active = session.status == .connected || session.status == .reconnecting
        guard active, ActivityAuthorizationInfo().areActivitiesEnabled else {
            end()
            return
        }
        let state = CastActivityAttributes.ContentState(muted: session.muted, reconnecting: session.status == .reconnecting)
        if let activity {
            guard state != last else { return }
            last = state
            Task { await activity.update(.init(state: state, staleDate: nil)) }
        } else {
            last = state
            activity = try? Activity.request(
                attributes: CastActivityAttributes(pcName: session.connectedName ?? "PC"),
                content: .init(state: state, staleDate: nil))
        }
    }

    func end() {
        guard let a = activity else { return }
        activity = nil
        last = nil
        Task { await a.end(nil, dismissalPolicy: .immediate) }
    }
}
#endif
