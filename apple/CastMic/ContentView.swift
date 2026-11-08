import SwiftUI

struct ContentView: View {
    @Environment(CastSession.self) private var session
    @State private var discovery = Discovery()

    var body: some View {
        @Bindable var session = session
        NavigationStack {
            Form {
                if !session.isActive {
                    Section {
                        TextField("6 桁のコード", text: $session.pairingCode)
                            .monospacedDigit()
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                    } header: {
                        Text("ペアリングコード")
                    } footer: {
                        Text("Windows の CastMic ウィンドウに表示されているコードです。")
                    }

                    Section {
                        if discovery.hosts.isEmpty {
                            Label("検索中… (Windows で CastMic を起動してください)", systemImage: "magnifyingglass")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(discovery.hosts) { h in
                            Button {
                                session.connect(to: h.endpoint, label: h.name)
                            } label: {
                                Label(h.name, systemImage: "desktopcomputer")
                            }
                        }
                    } header: {
                        Text("見つかった PC")
                    }

                    Section {
                        TextField("Windows の IP アドレス", text: $session.host)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .keyboardType(.numbersAndPunctuation)
                            .textInputAutocapitalization(.never)
                            #endif
                            .onSubmit { session.connect() }
                        Button("接続") { session.connect() }
                            .disabled(session.host.isEmpty)
                    } header: {
                        Text("IP で接続")
                    } footer: {
                        Text("有線で使う場合: インターネット共有をオンにして USB で接続し、Windows 側に表示される 172.20.10.x のアドレスを入力してください。")
                    }
                } else {
                    Section {
                        LabeledContent("状態", value: statusText)
                        if let name = session.connectedName {
                            LabeledContent("PC", value: name)
                        }
                        if let fp = session.fingerprint {
                            LabeledContent("確認コード", value: fp)
                                .monospaced()
                        }
                        if let ms = session.latencyMs {
                            LabeledContent("往復遅延", value: "\(ms) ms")
                        }
                        Button("切断", role: .destructive) { session.disconnect() }
                    } header: {
                        Text("接続中")
                    } footer: {
                        Text("通信は暗号化されています。初めて接続した PC では、確認コードが Windows の画面の表示と一致するか確認してください。")
                    }
                }

                if case .error(let m) = session.status {
                    Section {
                        Label(m, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                        if session.mismatchLabel != nil {
                            Button("信頼をリセット", role: .destructive) { session.resetTrust() }
                        }
                    }
                }

                Section("マイク") {
                    Toggle("マイクとして送信", isOn: $session.micEnabled)
                    ProgressView(value: Double(session.micLevel))
                        .tint(session.micLevel > 0.9 ? .red : .green)
                    HStack {
                        Image(systemName: "speaker.wave.1")
                        Slider(value: $session.micGain, in: 0...4)
                        Text(String(format: "×%.1f", session.micGain))
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                    Toggle("ノイズ抑制・エコーキャンセル", isOn: $session.voiceProcessing)
                        .disabled(session.isActive)
                }

                Section("スピーカー") {
                    Toggle("PC の音を再生", isOn: $session.speakerEnabled)
                }

                Section {
                    Toggle("切断時に自動で再接続", isOn: $session.autoReconnect)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("CastMic")
        }
        .frame(minWidth: 340, minHeight: 520)
        .onAppear { discovery.start() }
        .onDisappear { discovery.stop() }
        #if os(iOS)
        .onChange(of: session.status) { _, st in
            // 接続中は画面を自動ロックしない
            UIApplication.shared.isIdleTimerDisabled = (st == .connected)
        }
        #endif
    }

    private var statusText: String {
        switch session.status {
        case .idle: "未接続"
        case .connecting: "接続中…"
        case .connected: "接続済み"
        case .reconnecting: "再接続中…"
        case .error(let m): "エラー: \(m)"
        }
    }
}
