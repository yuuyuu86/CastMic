import SwiftUI

/// 初回起動時の使い方ガイド
struct OnboardingView: View {
    let onDone: () -> Void

    private struct Step: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let body: String
    }

    private let steps: [Step] = [
        Step(icon: "desktopcomputer", title: "Windows に CastMic を入れる",
             body: "PC で CastMic を起動すると、QR コードとペアリングコードが表示されます。"),
        Step(icon: "qrcode.viewfinder", title: "QR コードを読む",
             body: "この画面の「QR コードで接続」か、iPhone の標準カメラで QR を読むと接続できます。"),
        Step(icon: "mic.fill", title: "PC のアプリでマイクを選ぶ",
             body: "Zoom や Discord などのマイクに「マイク (CastMic)」(または「CABLE Output」) を選んでください。"),
        Step(icon: "lock.iphone", title: "ロック画面からミュート",
             body: "接続中はロック画面と Dynamic Island からミュートを切り替えられます。"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("CastMic へようこそ")
                            .font(.largeTitle.bold())
                        Text("この端末を PC のマイク・スピーカー・Web カメラとして使えます。")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 40)

                    ForEach(Array(steps.enumerated()), id: \.element.id) { i, step in
                        HStack(alignment: .top, spacing: 16) {
                            ZStack {
                                Circle().fill(Color.accentColor.opacity(0.15))
                                Image(systemName: step.icon)
                                    .font(.title3)
                                    .foregroundStyle(Color.accentColor)
                            }
                            .frame(width: 48, height: 48)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(i + 1). \(step.title)").font(.headline)
                                Text(step.body)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
            }

            Button {
                onDone()
            } label: {
                Text("はじめる")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .padding(24)
        }
        .frame(minWidth: 360, minHeight: 560)
    }
}
