import Foundation
import Speech
import AVFoundation

struct Entry: Identifiable {
    let id = UUID()
    let original: String
    let lang: String          // "zh" or "en"
    var translation: String?
}

private func hasHan(_ s: String) -> Bool {
    s.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
}

/// One recognizer (one language) working on the shared audio.
final class Slot {
    let lang: String
    let offline: Bool
    let request = SFSpeechAudioBufferRecognitionRequest()
    var task: SFSpeechRecognitionTask?
    var text = ""
    var conf: Float = 0
    var done = false
    var onActivity: (() -> Void)?
    var onEnded: (() -> Void)?

    init?(locale: String, lang: String) {
        self.lang = lang
        guard let r = SFSpeechRecognizer(locale: Locale(identifier: locale)), r.isAvailable else { return nil }
        offline = r.supportsOnDeviceRecognition
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = r.supportsOnDeviceRecognition
        task = r.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, !self.done else { return }
                if let result {
                    self.text = result.bestTranscription.formattedString
                    let segs = result.bestTranscription.segments
                    self.conf = segs.isEmpty ? 0 : segs.map { $0.confidence }.reduce(0, +) / Float(segs.count)
                    self.onActivity?()
                }
                if error != nil || result?.isFinal == true {
                    self.done = true
                    self.onEnded?()
                }
            }
        }
    }
}

/// Chinese + English recognizers listening to the same audio at once.
final class Pair {
    let slots: [Slot]
    let start = Date()
    var finishing = false
    var onActivity: (() -> Void)?
    var onDied: (() -> Void)?

    init() {
        slots = [Slot(locale: "zh-CN", lang: "zh"), Slot(locale: "en-US", lang: "en")].compactMap { $0 }
        for s in slots {
            s.onActivity = { [weak self] in self?.onActivity?() }
            s.onEnded = { [weak self] in
                guard let self, !self.finishing else { return }
                self.onDied?()
            }
        }
    }

    func append(_ b: AVAudioPCMBuffer) { for s in slots { s.request.append(b) } }

    func finish(_ completion: @escaping (Pair) -> Void) {
        finishing = true
        var remaining = slots.filter { !$0.done }.count
        var called = false
        let fire = { [self] in
            if !called { called = true; completion(self) }
        }
        if remaining == 0 { fire(); return }
        for s in slots where !s.done {
            s.onEnded = {
                remaining -= 1
                if remaining == 0 { fire() }
            }
            s.request.endAudio()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { fire() }
    }

    func cancel() {
        finishing = true
        for s in slots { s.task?.cancel(); s.done = true }
    }
}

final class Recognizer: ObservableObject {
    @Published var live = ""
    @Published var log: [Entry] = []
    @Published var running = false
    @Published var status = "Stopped"

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var current: Pair?
    private var timer: Timer?
    private var silence: DispatchWorkItem?
    private var pendingRestart: DispatchWorkItem?

    init() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, self.running,
                  let v = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: v) == .ended else { return }
            self.scheduleRestart()
        }
        nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] n in
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

    // MARK: control

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
                    self.timer?.invalidate()
                    self.timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                        self?.tick()
                    }
                }
            }
        }
    }

    func stop() {
        running = false
        pendingRestart?.cancel(); silence?.cancel(); timer?.invalidate()
        let old = swapCurrent(nil)
        old?.finish { [weak self] p in self?.decide(p) }
        engine.stop(); engine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(false)
        live = ""
        status = "Stopped"
    }

    func setTranslation(_ id: UUID, _ t: String) {
        if let i = log.firstIndex(where: { $0.id == id }) { log[i].translation = t }
    }

    // MARK: audio

    private func scheduleRestart() {
        pendingRestart?.cancel()
        let w = DispatchWorkItem { [weak self] in
            if self?.running == true { self?.restartEngine() }
        }
        pendingRestart = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: w)
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
                guard let self else { return }
                self.lock.lock(); let p = self.current; self.lock.unlock()
                p?.append(buf)
            }
            engine.prepare()
            try engine.start()
            let old = swapCurrent(makePair())
            old?.finish { [weak self] p in self?.decide(p) }
        } catch {
            status = "Audio error: \(error.localizedDescription)"
            scheduleRestart()
        }
    }

    // MARK: utterances

    private func swapCurrent(_ new: Pair?) -> Pair? {
        lock.lock(); let old = current; current = new; lock.unlock()
        return old
    }

    private func peek() -> Pair? {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    private func makePair() -> Pair {
        let p = Pair()
        p.onActivity = { [weak self, weak p] in self?.activity(p) }
        p.onDied = { [weak self, weak p] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.endUtterance(p) }
        }
        if p.slots.isEmpty {
            status = "Speech recognizers unavailable"
        } else {
            status = p.slots.allSatisfy { $0.offline } ? "Listening (offline)" : "Listening (some need internet)"
        }
        return p
    }

    private func activity(_ p: Pair?) {
        guard let p, p === peek() else { return }
        let zh = p.slots.first { $0.lang == "zh" }?.text ?? ""
        let en = p.slots.first { $0.lang == "en" }?.text ?? ""
        live = hasHan(zh) ? zh : en
        silence?.cancel()
        let w = DispatchWorkItem { [weak self, weak p] in self?.endUtterance(p) }
        silence = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3, execute: w)
    }

    private func endUtterance(_ p: Pair?) {
        guard running, let p, p === peek() else { return }
        silence?.cancel()
        let old = swapCurrent(makePair())
        live = ""
        old?.finish { [weak self] pair in self?.decide(pair) }
    }

    private func tick() {
        guard running, let p = peek() else { return }
        let age = Date().timeIntervalSince(p.start)
        let hasText = p.slots.contains { !$0.text.isEmpty }
        if (age > 25 && hasText) || age > 50 { endUtterance(p) }
    }

    /// Pick the language whose recognizer understood the speech best.
    private func decide(_ pair: Pair) {
        pair.cancel()
        let cands = pair.slots.map { s -> (Slot, Float) in
            let t = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { return (s, -1) }
            if s.lang == "zh" && !hasHan(t) { return (s, -1) }
            if s.lang == "en" && hasHan(t) { return (s, -1) }
            return (s, s.conf)
        }
        guard let best = cands.max(by: {
            $0.1 < $1.1 || ($0.1 == $1.1 && $0.0.text.count < $1.0.text.count)
        }), best.1 >= 0 else { return }
        let t = best.0.text.trimmingCharacters(in: .whitespacesAndNewlines)
        log.insert(Entry(original: t, lang: best.0.lang, translation: nil), at: 0)
    }
}
