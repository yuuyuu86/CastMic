import AVFoundation
import SwiftUI

struct ContentView: View {
    @Environment(CastSession.self) private var session
    @State private var discovery = Discovery()
    @State private var scanning = false
    @State private var showAdvanced = false
    @State private var showManual = false
    @State private var showDetails = false
    #if os(macOS)
    @State private var relay = RelayServer()
    @AppStorage("relayEnabled") private var relayEnabled = false
    #endif

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

                relaySection
                #endif

                statusHeader

                if case .error(let m) = session.status {
                    Section {
                        Label(m, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        if session.mismatchLabel != nil {
                            Button("信頼をリセット", role: .destructive) { session.resetTrust() }
                        }
                    }
                }

                if session.isActive {
                    connectedSection
                } else {
                    connectSections
                }

                featureSections

                Section {
                    DisclosureGroup("詳細設定", isExpanded: $showAdvanced) {
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
                                Text("途切れにくい").font(.caption)
                            }.foregroundStyle(.secondary)
                        }
                        Toggle("ノイズ抑制・エコーキャンセル", isOn: $session.voiceProcessing)
                            .disabled(session.isActive)
                        Toggle("音声を圧縮 (Opus)", isOn: $session.useOpus)
                            .disabled(session.isActive)
                        Toggle("切断時に自動で再接続", isOn: $session.autoReconnect)
                    }
                } footer: {
                    if showAdvanced {
                        Text("音が途切れるときは遅延を大きくしてください。圧縮すると通信量が 1/10 程度になります。ノイズ抑制と圧縮は切断中のみ変更できます。")
                    }
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
        .onAppear {
            discovery.start()
            #if os(macOS)
            if relayEnabled { relay.start() }
            #endif
        }
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

    // MARK: - Status

    private var statusHeader: some View {
        Section {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(statusColor.opacity(0.15))
                    if session.status == .connecting || session.status == .reconnecting {
                        ProgressView()
                    } else {
                        Image(systemName: statusIcon)
                            .font(.title2)
                            .foregroundStyle(statusColor)
                    }
                }
                .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle).font(.headline)
                    Text(statusSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
        }
    }

    private var statusColor: Color {
        switch session.status {
        case .connected: session.muted ? .red : .green
        case .connecting, .reconnecting: .orange
        case .error: .red
        case .idle: .secondary
        }
    }

    private var statusIcon: String {
        switch session.status {
        case .connected: session.muted ? "mic.slash.fill" : "checkmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        default: "antenna.radiowaves.left.and.right.slash"
        }
    }

    private var statusTitle: String {
        switch session.status {
        case .idle: "未接続"
        case .connecting: "接続しています…"
        case .connected: session.muted ? "接続中 (ミュート)" : "接続中"
        case .reconnecting: "再接続しています…"
        case .error: "接続できませんでした"
        }
    }

    private var statusSubtitle: String {
        switch session.status {
        case .connected, .reconnecting, .connecting:
            session.connectedName ?? "Windows PC"
        case .idle, .error:
            "下の方法で Windows の CastMic に接続してください"
        }
    }

    // MARK: - Connected

    @ViewBuilder private var connectedSection: some View {
        if session.status == .connected {
            Section {
                Button {
                    session.toggleMute()
                } label: {
                    Label(session.muted ? "ミュート中 — タップで解除" : "ミュートする",
                          systemImage: session.muted ? "mic.slash.fill" : "mic.fill")
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.borderedProminent)
                .tint(session.muted ? .red : .accentColor)
                .listRowInsets(EdgeInsets())
            } footer: {
                Text("Windows の Ctrl+Shift+M やロック画面からも切り替えられます。")
            }
        }

        Section {
            DisclosureGroup("接続の詳細", isExpanded: $showDetails) {
                if let c = session.codecName { LabeledContent("音声形式", value: c) }
                if let ms = session.latencyMs { LabeledContent("往復遅延", value: "\(ms) ms") }
                if let fp = session.fingerprint {
                    LabeledContent("確認コード", value: fp).monospaced()
                }
                Label("通信は暗号化されています", systemImage: "lock.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button(role: .destructive) { session.disconnect() } label: {
                Label("切断", systemImage: "xmark.circle")
            }
        }
    }

    // MARK: - Connect

    @ViewBuilder private var connectSections: some View {
        @Bindable var session = session
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
                    Label("QR コードを読み取って接続", systemImage: "qrcode.viewfinder")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.borderedProminent)
                .listRowInsets(EdgeInsets())
            } header: {
                Text("かんたん接続 (おすすめ)")
            } footer: {
                Text("Windows の CastMic に表示されている QR を読み取るだけで接続できます。")
            }
        }
        #endif

        Section {
            TextField("ペアリングコード (6 桁)", text: $session.pairingCode)
                .monospacedDigit()
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
            if discovery.hosts.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("同じ Wi-Fi の PC を探しています…")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(discovery.hosts) { h in
                Button {
                    session.connect(to: h.endpoint, label: h.name)
                } label: {
                    HStack {
                        Label(h.name, systemImage: "desktopcomputer")
                        Spacer()
                        Text("接続").foregroundStyle(.tint)
                    }
                }
                .disabled(session.pairingCode.count != 6)
            }
        } header: {
            Text(qrHeaderPrefix + "コードで接続")
        } footer: {
            Text("① Windows の CastMic に表示されている 6 桁のコードを入力 ② 見つかった PC をタップ")
        }

        Section {
            DisclosureGroup("IP アドレスで接続 (USB 有線など)", isExpanded: $showManual) {
                TextField("例: 172.20.10.2", text: $session.host)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    #endif
                    .onSubmit { session.connect() }
                Button("この IP に接続") { session.connect() }
                    .disabled(session.host.isEmpty)
                Text("有線で使う場合: iPhone のインターネット共有をオンにして USB で接続し、Windows に表示される 172.20.10.x のアドレスを入力します。上のペアリングコードも必要です。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var qrHeaderPrefix: String {
        #if os(iOS)
        QRScannerView.isAvailable ? "または " : ""
        #else
        ""
        #endif
    }

    // MARK: - Features

    @ViewBuilder private var featureSections: some View {
        @Bindable var session = session
        Section {
            Toggle(isOn: $session.micEnabled) {
                Label(micToggle, systemImage: rev ? "speaker.wave.2" : "mic")
            }
            if session.micEnabled {
                HStack {
                    Image(systemName: "speaker.wave.1").foregroundStyle(.secondary)
                    Slider(value: $session.micGain, in: 0...4)
                    Text(String(format: "×%.1f", session.micGain))
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
                if session.status == .connected {
                    ProgressView(value: Double(session.muted ? 0 : session.micLevel))
                        .tint(session.micLevel > 0.9 ? .red : .green)
                        .accessibilityLabel("入力レベル")
                }
            }

            Toggle(isOn: $session.speakerEnabled) {
                Label(speakerToggle, systemImage: rev ? "mic" : "speaker.wave.2")
            }

            if !rev {
                Toggle(isOn: $session.cameraEnabled) {
                    Label("Web カメラとして使う", systemImage: "video")
                }
                #if os(iOS)
                if session.cameraEnabled {
                    Picker("カメラ", selection: $session.cameraFront) {
                        Text("前面").tag(true)
                        Text("背面").tag(false)
                    }
                    .pickerStyle(.segmented)
                }
                #endif
            }
        } header: {
            Text("使う機能")
        } footer: {
            if !rev && session.cameraEnabled {
                Text("Windows 11 の「CastMic Camera」として使えます。iPhone は横向きにして、画面を開いたままにしてください。")
            } else if session.micEnabled {
                Text("スライダーはマイク音量です。相手に声が小さいと言われたら右へ。")
            }
        }
    }

    #if os(macOS)
    /// この Mac を中継にする (iPhone と Windows が直接つながらないネットワーク用)
    @ViewBuilder private var relaySection: some View {
        Section {
            Toggle("この Mac を中継にする", isOn: Binding(get: { relayEnabled }, set: { on in
                relayEnabled = on
                on ? relay.start() : relay.stop()
            }))
            if relayEnabled {
                if let e = relay.error {
                    Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                } else if relay.running {
                    LabeledContent("中継アドレス", value: RelayServer.localAddresses().joined(separator: ", "))
                        .textSelection(.enabled)
                    LabeledContent("待機中の PC", value: "\(relay.waitingHosts)")
                    LabeledContent("中継中の接続", value: "\(relay.activePairs)")
                }
            }
        } header: {
            Text("中継")
        } footer: {
            Text("iPhone と Windows が直接つながらないとき (学校の Wi-Fi と有線 LAN など) に使います。Windows の CastMic の「中継 Mac」に上のアドレスを入れてください。通信は暗号化されたまま中継されるので、この Mac から音声は見えません。Mac がスリープすると中継も止まります。")
        }
    }
    #endif

    private var pairTitle: String {
        session.pendingPair?.conflicts.isEmpty == false ? "⚠️ 証明書が以前と違います" : "この PC に接続しますか?"
    }

    private func pairMessage(_ p: CastSession.PendingPair) -> String {
        var lines = ["PC: \(p.name ?? "(名前なし)")"]
        if !p.addresses.isEmpty { lines.append("IP: \(p.addresses.joined(separator: ", "))") }
        if let r = p.relay { lines.append("中継 Mac: \(r)") }
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
    private var micToggle: String { rev ? "Mac の音を Windows で鳴らす" : "マイクとして使う" }
    private var speakerToggle: String { rev ? "Windows のマイクを Mac で使う" : "PC の音をこの端末で再生" }
}
