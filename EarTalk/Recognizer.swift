import Foundation
import Speech
import AVFoundation

final class Recognizer: ObservableObject {
    @Published var live = ""
    @Published var log: [String] = []
    @Published var running = false
    @Published var status = "Stopped"
    @Published var localeID = "zh-CN"

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var gen = 0
    private var timer: Timer?
    private var pendingRestart: DispatchWorkItem?

    private func scheduleRestart() {
        pendingRestart?.cancel()
        let w = DispatchWorkItem { [weak self] in
            if self?.running == true { self?.restartEngine() }
        }
        pendingRestart = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: w)
    }

    init() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, self.running,
                  let v = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: v) == .ended else { return }
            self.scheduleRestart()
        }
        nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] n in
            // Only react to real plug/unplug events. Reacting to every route change
            // (including ones our own restart causes) creates an endless restart loop.
            guard let self, self.running,
                  let v = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: v),
                  reason == .newDeviceAvailable || reason == .oldDeviceUnavailable else { return }
            self.scheduleRestart()
        }
        nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.running else { return }
            self.scheduleRestart()
        }
    }

    func start() {
        SFSpeechRecognizer.requestAuthorization { auth in
            AVAudioApplication.requestRecordPermission { ok in
                DispatchQueue.main.async {
                    guard auth == .authorized, ok else {
                        self.status = "Permission denied (Settings > EarTalk)"
                        return
                    }
                    self.running = true
                    self.restartEngine()
                    // Recognition tasks time out after ~1 minute, so renew them early.
                    self.timer?.invalidate()
                    self.timer = Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in
                        self?.commit(); self?.startTask()
                    }
                }
            }
        }
    }

    func stop() {
        running = false
        pendingRestart?.cancel()
        timer?.invalidate()
        commit()
        task?.cancel(); request?.endAudio()
        engine.stop(); engine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(false)
        status = "Stopped"
    }

    func changeLanguage(_ id: String) {
        localeID = id
        if running { commit(); startTask() }
    }

    private func restartEngine() {
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playAndRecord, mode: .default,
                              options: [.allowBluetooth, .defaultToSpeaker, .mixWithOthers])
            try s.setActive(true)
            engine.stop()
            let input = engine.inputNode
            input.removeTap(onBus: 0)
            let fmt = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
                self?.request?.append(buf)
            }
            engine.prepare()
            try engine.start()
            startTask()
        } catch {
            status = "Audio error: \(error.localizedDescription)"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                if self?.running == true { self?.restartEngine() }
            }
        }
    }

    private func startTask() {
        gen += 1
        let myGen = gen
        task?.cancel(); request?.endAudio()
        guard let r = SFSpeechRecognizer(locale: Locale(identifier: localeID)), r.isAvailable else {
            status = "Recognizer unavailable for \(localeID)"
            return
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = r.supportsOnDeviceRecognition
        request = req
        status = r.supportsOnDeviceRecognition ? "Listening (offline)"
            : "Listening (needs internet: download dictation language in Settings > General > Keyboard)"
        task = r.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, myGen == self.gen else { return }
                if let result { self.live = result.bestTranscription.formattedString }
                if error != nil || result?.isFinal == true {
                    self.commit()
                    if self.running {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            if myGen == self.gen && self.running { self.startTask() }
                        }
                    }
                }
            }
        }
    }

    private func commit() {
        let t = live.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { log.insert(t, at: 0) }
        live = ""
    }
}
