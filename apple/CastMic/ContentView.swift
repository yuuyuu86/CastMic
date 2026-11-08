import SwiftUI

struct ContentView: View {
    @Environment(CastSession.self) private var session

    var body: some View {
        @Bindable var session = session
        NavigationStack {
            Form {
                Section {
                    TextField("Windows の IP アドレス", text: $session.host)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        #endif
                        .disabled(isActive)
                    Button(isActive ? "切断" : "接続", role: isActive ? .destructive : nil) {
                        isActive ? session.disconnect() : session.connect()
                    }
                    .disabled(session.host.isEmpty)
                } header: {
                    Text("接続先")
                } footer: {
                    Text("有線で使う場合: インターネット共有をオンにして USB で接続し、Windows 側に表示される 172.20.10.x のアドレスを入力してください。")
                }

                Section("状態") {
                    LabeledContent("接続", value: statusText)
                    ProgressView(value: Double(session.micLevel))
                        .tint(.green)
                }

                Section("オーディオ") {
                    Toggle("マイクとして送信", isOn: $session.micEnabled)
                    Toggle("スピーカーとして再生", isOn: $session.speakerEnabled)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("CastMic")
        }
        .frame(minWidth: 320, minHeight: 420)
    }

    private var isActive: Bool {
        session.status == .connected || session.status == .connecting
    }

    private var statusText: String {
        switch session.status {
        case .idle: "未接続"
        case .connecting: "接続中…"
        case .connected: "接続済み"
        case .error(let m): "エラー: \(m)"
        }
    }
}
