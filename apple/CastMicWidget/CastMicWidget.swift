import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct CastMicWidgetBundle: WidgetBundle {
    var body: some Widget { CastLiveActivity() }
}

struct CastLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CastActivityAttributes.self) { ctx in
            HStack(spacing: 12) {
                MicIcon(muted: ctx.state.muted).font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("CastMic").font(.headline)
                    Text(ctx.state.reconnecting ? "再接続中…" : ctx.attributes.pcName)
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                MuteButton(muted: ctx.state.muted)
            }
            .padding()
        } dynamicIsland: { ctx in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    MicIcon(muted: ctx.state.muted).font(.title2).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(ctx.state.reconnecting ? "再接続中…" : ctx.attributes.pcName).font(.headline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    MuteButton(muted: ctx.state.muted)
                }
            } compactLeading: {
                MicIcon(muted: ctx.state.muted)
            } compactTrailing: {
                Text(ctx.state.muted ? "OFF" : "ON").font(.caption2).bold()
            } minimal: {
                MicIcon(muted: ctx.state.muted)
            }
        }
    }
}

private struct MicIcon: View {
    let muted: Bool
    var body: some View {
        Image(systemName: muted ? "mic.slash.fill" : "mic.fill")
            .foregroundStyle(muted ? .red : .green)
    }
}

private struct MuteButton: View {
    let muted: Bool
    var body: some View {
        Button(intent: ToggleMuteIntent()) {
            Label(muted ? "解除" : "ミュート", systemImage: muted ? "mic.fill" : "mic.slash.fill")
        }
        .buttonStyle(.borderedProminent)
        .tint(muted ? .green : .red)
    }
}
