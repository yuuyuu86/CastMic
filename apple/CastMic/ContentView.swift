import SwiftUI

struct ContentView: View {
    @Environment(CastSession.self) private var session
    @State private var discovery = Discovery()
    @State private var scanning = false

    var body: some View {
        @Bindable var session = session
        NavigationStack {
            Form {
                if session.isActive {
                    connectedSection
                } else {
                    #if os(iOS)
                    if QRScannerView.isAvailable {
                        Section {
                            Button {
                                scanning = true
                            } label: {
                                Label("QR コードで接続", systemImage: "qrcode.viewfinder")
                            }
                        } footer: {
                            Text("Windows の CastMic に表示されている QR を読み取ります。iPhone の標準カメラで読んでも接続できます。")
                        }
                    }
                    #endif
                    manualSections
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
                    Toggle("マイクとして使う", isOn: $session.micEnabled)
                    ProgressView(value: Double(session.muted ? 0 : session.micLevel))
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
                    VStack(alignment: .leading) {
                        HStack {
                            Text("遅延")
                            Spacer()
                            Text("\(session.bufferMs) ms").monospacedDigit().foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(get: { Double(session.bufferMs) }, set: { session.bufferMs = Int($0) }),
                               in: 40...300, step: 20)
                        HStack {
                            Text("低遅延").font(.caption)
                            Spacer()
                            Text("安定").font(.caption)
                        }.foregroundStyle(.secondary)
                    }
                    Toggle("音声を圧縮 (Opus)", isOn: $session.useOpus)
                        .disabled(session.isActive)
                    Toggle("切断時に自動で再接続", isOn: $session.autoReconnect)
                } header: {
                    Text("通信")
                } footer: {
                    Text("圧縮すると通信量が 1/10 程度になり、Wi-Fi が混んでいても途切れにくくなります。")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("CastMic")
        }
        .frame(minWidth: 340, minHeight: 560)
        .onAppear { discovery.start() }
        .onDisappear { discovery.stop() }
        #if os(iOS)
        .sheet(isPresented: $scanning) {
            NavigationStack {
                QRScannerView { url in
                    scanning = false
                    session.handlePairURL(url)
                }
                .ignoresSafeArea()
                .navigationTitle("QR コードを読み取る")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { scanning = false } }
                }
            }
        }
        .onChange(of: session.status) { _, st in
            UIApplication.shared.isIdleTimerDisabled = (st == .connected)
        }
        #endif
    }

    @ViewBuilder private var connectedSection: some View {
        Section {
            Button {
                session.toggleMute()
            } label: {
                Label(session.muted ? "ミュート中 (タップで解除)" : "ミュート",
                      systemImage: session.muted ? "mic.slash.fill" : "mic.fill")
                    .font(.title3)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(session.muted ? .red : .accentColor)
            .listRowInsets(EdgeInsets())
        }

        Section {
            LabeledContent("状態", value: statusText)
            if let name = session.connectedName { LabeledContent("PC", value: name) }
            if let c = session.codecName { LabeledContent("音声", value: c) }
            if let fp = session.fingerprint {
                LabeledContent("確認コード", value: fp).monospaced()
            }
            if let ms = session.latencyMs { LabeledContent("往復遅延", value: "\(ms) ms") }
            Button("切断", role: .destructive) { session.disconnect() }
        } header: {
            Text("接続中")
        } footer: {
            Text("通信は暗号化されています。ミュートは Windows の Ctrl+Shift+M とも連動します。")
        }
    }

    @ViewBuilder private var manualSections: some View {
        @Bindable var session = session
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

        Section("見つかった PC") {
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
