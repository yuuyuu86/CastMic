import AVFoundation
import SwiftUI

struct ContentView: View {
    @Environment(CastSession.self) private var session
    @State private var discovery = Discovery()
    @State private var scanning = false

    var body: some View {
        @Bindable var session = session
        NavigationStack {
            Form {
                #if os(macOS)
                Section {
                    Picker("使い方", selection: $session.reverseMode) {
                        Text("Mac を Windows のマイク / スピーカーに").tag(false)
                        Text("Windows を Mac のマイク / スピーカーに").tag(true)
                    }
                    .pickerStyle(.radioGroup)
                    .disabled(session.isActive)
                    if session.reverseMode && !AudioIO.isDriverInstalled {
                        Label("Mac 用 CastMic ドライバが必要です。mac-driver/install.sh でインストールしてください。", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                } footer: {
                    if session.reverseMode {
                        Text("Mac のアプリでは入力に「CastMic Microphone」、出力に「CastMic Speaker」を選んでください。Windows の実際のマイク / スピーカーにつながります。")
                    }
                }
                #endif

                if session.isActive {
                    connectedSection
                } else {
                    #if os(iOS)
                    if QRScannerView.isAvailable {
                        Section {
                            Button {
                                Task {
                                    if AVCaptureDevice.authorizationStatus(for: .video) != .authorized {
                                        guard await AVCaptureDevice.requestAccess(for: .video) else {
                                            session.status = .error("カメラの使用が許可されていません。設定で CastMic のカメラを許可してください。")
                                            return
                                        }
                                    }
                                    scanning = true
                                }
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

                Section(micTitle) {
                    Toggle(micToggle, isOn: $session.micEnabled)
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

                Section(speakerTitle) {
                    Toggle(speakerToggle, isOn: $session.speakerEnabled)
                }

                if !rev {
                    Section {
                        Toggle("Web カメラとして使う", isOn: $session.cameraEnabled)
                        #if os(iOS)
                        Picker("カメラ", selection: $session.cameraFront) {
                            Text("前面").tag(true)
                            Text("背面").tag(false)
                        }
                        .pickerStyle(.segmented)
                        #endif
                    } header: {
                        Text("カメラ")
                    } footer: {
                        Text("Windows 11 の「CastMic Camera」として使えます。iPhone は横向きにして、画面を開いたままにしてください。")
                    }
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
        .alert(pairTitle, isPresented: Binding(get: { session.pendingPair != nil }, set: { if !$0 { session.cancelPair() } }),
               presenting: session.pendingPair) { _ in
            Button("接続") { session.confirmPair() }
            Button("キャンセル", role: .cancel) { session.cancelPair() }
        } message: { p in
            Text(pairMessage(p))
        }
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
        if session.status == .connected {
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

    private var pairTitle: String {
        session.pendingPair?.conflicts.isEmpty == false ? "⚠️ 証明書が以前と違います" : "この PC に接続しますか?"
    }

    private func pairMessage(_ p: CastSession.PendingPair) -> String {
        var lines = ["PC: \(p.name ?? "(名前なし)")"]
        if !p.addresses.isEmpty { lines.append("IP: \(p.addresses.joined(separator: ", "))") }
        lines.append("確認コード: \(p.shortFingerprint)")
        lines.append("Windows の CastMic に表示されている確認コードと同じか確認してください。")
        if !p.conflicts.isEmpty {
            lines.append("\n\(p.conflicts.joined(separator: ", ")) は以前別の証明書で接続しています。PC を再インストールしたなど心当たりがない場合は接続しないでください。")
        }
        return lines.joined(separator: "\n")
    }

    private var rev: Bool {
        #if os(macOS)
        session.reverseMode
        #else
        false
        #endif
    }
    private var micTitle: String { rev ? "Mac の音 → Windows のスピーカー" : "マイク" }
    private var micToggle: String { rev ? "Windows のスピーカーで鳴らす" : "マイクとして使う" }
    private var speakerTitle: String { rev ? "Windows のマイク → Mac" : "スピーカー" }
    private var speakerToggle: String { rev ? "Windows のマイクを Mac で使う" : "PC の音を再生" }

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
