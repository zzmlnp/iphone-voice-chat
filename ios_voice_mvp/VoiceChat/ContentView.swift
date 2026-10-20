import SwiftUI
import Speech
import AVFoundation

struct ChatLine: Identifiable {
    let id = UUID()
    let role: String
    let content: String
}

@MainActor final class VoiceChatVM: ObservableObject {
    @Published var server = UserDefaults.standard.string(forKey: "server") ?? "http://192.168.1.100:8788"
    @Published var model = UserDefaults.standard.string(forKey: "model") ?? ""
    @Published var draft = ""
    @Published var status = "待命。请先填写电脑局域网地址和模型名称"
    @Published var running = false
    @Published var lines: [ChatLine] = []

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private var engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var silenceTask: Task<Void, Never>?
    private var generation = 0
    private var speaking = false
    private var busy = false
    private var player: AVAudioPlayer?
    private var lastSpeechTime = Date()
    private var sawSpeech = false
    private var activeTranscript = ""

    func saveSettings() {
        UserDefaults.standard.set(server.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "server")
        UserDefaults.standard.set(model.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "model")
    }

    func start() async {
        guard !running else { return }
        saveSettings()
        guard URL(string: server)?.scheme == "http" || URL(string: server)?.scheme == "https" else {
            status = "请填写完整的 http://电脑IP:8788 地址"; return
        }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status = "请先填写 Ollama 模型名称"; return
        }
        let speechAuth = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard speechAuth == .authorized else { status = "需要允许语音识别权限"; return }
        let micOK = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            AVAudioSession.sharedInstance().requestRecordPermission { c.resume(returning: $0) }
        }
        guard micOK else { status = "需要允许麦克风权限"; return }
        running = true
        await listen()
    }

    func stop() {
        running = false
        generation += 1
        stopListening()
        player?.stop(); player = nil
        speaking = false
        status = "已停止"
    }

    private func stopListening() {
        silenceTask?.cancel(); silenceTask = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        recognition?.cancel(); recognition = nil
        request = nil
    }

    private func listen() async {
        guard running && !busy && !speaking else { return }
        stopListening()
        activeTranscript = ""; draft = ""; sawSpeech = false
        lastSpeechTime = Date()
        let current = generation + 1; generation = current
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            request = req
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                req.append(buffer)
            }
            guard let recognizer = recognizer, recognizer.isAvailable else {
                status = "苹果语音识别暂不可用，请检查网络及系统权限"; running = false; stopListening(); return
            }
            recognition = recognizer.recognitionTask(with: req) { [weak self] result, error in
                Task { @MainActor [weak self] in
                    guard let self, self.running, current == self.generation else { return }
                    if let result {
                        let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty {
                            self.activeTranscript = text
                            self.draft = text
                            self.sawSpeech = true
                            self.lastSpeechTime = Date()
                        }
                        if result.isFinal && self.sawSpeech { await self.finishUtterance(current) }
                    }
                    if error != nil && !self.busy {
                        let captured = self.activeTranscript
                        self.stopListening()
                        if !captured.isEmpty { await self.submit(captured) }
                        else if self.running { try? await Task.sleep(for: .milliseconds(500)); await self.listen() }
                    }
                }
            }
            engine.prepare(); try engine.start()
            status = "正在听你说话，停顿约 2 秒自动发送"
            silenceTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(300))
                    guard let self, self.running, current == self.generation else { break }
                    if self.sawSpeech && Date().timeIntervalSince(self.lastSpeechTime) > 2.0 {
                        await self.finishUtterance(current); break
                    }
                }
            }
        } catch {
            status = "录音启动失败：\(error.localizedDescription)"
            running = false; stopListening()
        }
    }

    private func finishUtterance(_ current: Int) async {
        guard current == generation && !busy else { return }
        let text = activeTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        stopListening()
        generation += 1
        await submit(text)
    }

    func sendTyped() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty && !busy else { return }
        stopListening(); generation += 1
        await submit(text)
    }

    private func endpoint(_ path: String) -> URL? {
        URL(string: server.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path)
    }

    private func submit(_ text: String) async {
        guard !busy else { return }
        busy = true; draft = ""
        lines.append(ChatLine(role: "user", content: text))
        status = "AI 正在回复…"
        do {
            guard let url = endpoint("/api/chat") else { throw URLError(.badURL) }
            let history = lines.map { ["role": $0.role, "content": $0.content] }
            let payload: [String: Any] = [
                "model": model, "messages": history,
                "ollama_url": "http://127.0.0.1:11434", "character_id": "",
                "memory_enabled": false, "proactive_topic": false,
                "refusal_rate": 0, "refusal_level": "personality"
            ]
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: payload)
            req.timeoutInterval = 240
            let (bytes, response) = try await URLSession.shared.bytes(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw URLError(.badServerResponse) }
            var answer = ""
            var done = false
            for try await line in bytes.lines {
                if line.hasPrefix("event: done") { done = true }
                if line.hasPrefix("event: error") { throw NSError(domain: "Chat", code: 1, userInfo: [NSLocalizedDescriptionKey: "聊天服务返回错误"]) }
                if line.hasPrefix("data: ") {
                    let data = Data(line.dropFirst(6).utf8)
                    if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let token = obj["token"] as? String { answer += token }
                }
            }
            if !done { status = "回复可能不完整，服务器未返回结束信号" }
            let final = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !final.isEmpty {
                lines.append(ChatLine(role: "assistant", content: final))
                await speak(final)
            } else { status = "AI 没有返回文字" }
        } catch {
            status = "请求失败：\(error.localizedDescription)"
        }
        busy = false
        if running { await listen() }
    }

    private func speak(_ text: String) async {
        speaking = true
        status = "正在合成并播放 AI 语音…"
        defer { speaking = false }
        do {
            guard let url = endpoint("/api/tts") else { throw URLError(.badURL) }
            let payload: [String: Any] = ["text": text, "reference_audio": "", "reference_text": " ", "language": "Chinese", "use_xvec": false, "qwen_url": "http://127.0.0.1:8000"]
            var req = URLRequest(url: url)
            req.httpMethod = "POST"; req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: payload)
            req.timeoutInterval = 180
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw URLError(.badServerResponse) }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let path = json["audio_url"] as? String,
                  let audioURL = URL(string: path, relativeTo: URL(string: server + "/"))?.absoluteURL else { throw URLError(.cannotParseResponse) }
            let (audio, _) = try await URLSession.shared.data(from: audioURL)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.defaultToSpeaker])
            let p = try AVAudioPlayer(data: audio)
            player = p
            p.prepareToPlay(); p.play()
            while p.isPlaying && running { try? await Task.sleep(for: .milliseconds(200)) }
            p.stop(); player = nil
            status = "播放完成"
        } catch { status = "语音播放失败：\(error.localizedDescription)" }
    }
}

struct ContentView: View {
    @StateObject private var vm = VoiceChatVM()
    var body: some View {
        VStack(spacing: 12) {
            Text("苹果原生语音聊天测试版").font(.headline)
            TextField("电脑地址，例如 http://192.168.1.10:8788", text: $vm.server)
                .textInputAutocapitalization(.never).keyboardType(.URL).autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
            TextField("Ollama 模型完整名称", text: $vm.model)
                .textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(vm.lines) { line in
                        Text((line.role == "user" ? "你：" : "AI：") + line.content)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(line.role == "user" ? Color.blue.opacity(0.12) : Color.gray.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            Text(vm.status).font(.footnote).foregroundStyle(.secondary)
            HStack {
                TextField("也可以手动输入", text: $vm.draft).textFieldStyle(.roundedBorder)
                Button("发送") { Task { await vm.sendTyped() } }
            }
            Button(vm.running ? "停止连续对话" : "开始连续对话") {
                if vm.running { vm.stop() }
                else { Task { await vm.start() } }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}
