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

/// One recognizer (one language). If the system ends its task early (its own
/// end-of-speech detection, a timeout, an error) it immediately starts a new one
/// and keeps the text so far, so a sentence is never cut short.
final class Slot {
    let lang: String
    let offline: Bool
    private let recognizer: SFSpeechRecognizer
    private let reqLock = NSLock()
    private var request = SFSpeechAudioBufferRecognitionRequest()
    private var task: SFSpeechRecognitionTask?
    private var taskActive = false
    private var gen = 0
    private var started = Date()
    private var fails = 0
    private var committed = ""
    private var cur = ""
    private var curConf: Float = 0
    private var confSum: Float = 0
    private var confN = 0
    var finishing = false
    var done = false
    var onActivity: (() -> Void)?
    var onEnded: (() -> Void)?

    var text: String {
        if committed.isEmpty { return cur }
        if cur.isEmpty { return committed }
        return committed + (lang == "en" ? " " : "") + cur
    }
    var conf: Float {
        let n = confN + (cur.isEmpty ? 0 : 1)
        return n == 0 ? 0 : (confSum + (cur.isEmpty ? 0 : curConf)) / Float(n)
    }

    init?(locale: String, lang: String) {
        guard let r = SFSpeechRecognizer(locale: Locale(identifier: locale)), r.isAvailable else { return nil }
        self.lang = lang
        recognizer = r
        offline = r.supportsOnDeviceRecognition
        startTask()
    }

    func append(_ b: AVAudioPCMBuffer) {
        reqLock.lock(); let r = request; reqLock.unlock()
        if !done { r.append(b) }
    }

    private func startTask() {
        gen += 1
        let g = gen
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = offline
        reqLock.lock(); request = req; reqLock.unlock()
        started = Date()
        taskActive = true
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async { self?.handle(g, result, error) }
        }
    }

    private func handle(_ g: Int, _ result: SFSpeechRecognitionResult?, _ error: Error?) {
        guard g == gen, !done else { return }
        if let result {
            cur = result.bestTranscription.formattedString
            let segs = result.bestTranscription.segments
            curConf = segs.isEmpty ? 0 : segs.map { $0.confidence }.reduce(0, +) / Float(segs.count)
            onActivity?()
        }
        guard error != nil || result?.isFinal == true else { return }
        taskActive = false
        if !cur.isEmpty {              // bank this task's text
            committed = text
            confSum += curConf; confN += 1
            cur = ""; curConf = 0
        }
        if finishing { done = true; onEnded?(); return }
        let quick = Date().timeIntervalSince(started) < 0.4
        fails = quick ? fails + 1 : 0
        let delay = min(Double(fails) * 0.4, 2.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.finishing, !self.done else { return }
            self.startTask()
        }
    }

    func finish() {
        finishing = true
        if taskActive {
            reqLock.lock(); let r = request; reqLock.unlock()
            r.endAudio()
        } else if !done {
            done = true
            onEnded?()
        }
    }

    func cancel() {
        finishing = true; done = true
        task?.cancel()
    }
}

/// Chinese + English recognizers listening to the same audio at once.
final class Pair {
    let slots: [Slot]
    let start = Date()
    var onActivity: (() -> Void)?

    init() {
        slots = [Slot(locale: "zh-CN", lang: "zh"), Slot(locale: "en-US", lang: "en")].compactMap { $0 }
        for s in slots { s.onActivity = { [weak self] in self?.onActivity?() } }
    }

    func append(_ b: AVAudioPCMBuffer) { for s in slots { s.append(b) } }

    func finish(_ completion: @escaping (Pair) -> Void) {
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
            s.finish()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { fire() }
    }

    func cancel() { for s in slots { s.cancel() } }
}

final class Recognizer: ObservableObject {
    @Published var live = ""
    @Published var log: [Entry] = []
    @Published var running = false
    @Published var status = "Stopped"
    @Published var liveLang = ""
    @Published var bars: [Double] = Array(repeating: 0.04, count: 32)
    @Published var speakOn = true
    @Published var chineseOnLeft = true { didSet { speaker.chineseOnLeft = chineseOnLeft } }
    lazy var speaker = Speaker(engine: engine)
    private var tapCount = 0
    private var lastLoud: TimeInterval = 0
    private var lastText: TimeInterval = 0
    private var claimed = Set<UUID>()

    func claim(_ id: UUID) -> Bool { claimed.insert(id).inserted }
    func release(_ id: UUID) { claimed.remove(id) }
    func speak(_ text: String, outLang: String) {
        if speakOn { speaker.speak(text, outLang: outLang) }
    }

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
        // iOS stops the engine by itself when the audio route/format changes
        // (for example when a spoken translation starts playing). Restart it.
        nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self, self.running else { return }
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
                    self.timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
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
        live = ""; liveLang = ""
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
        // Try the best audio setup first, then simpler ones if the engine refuses to start.
        let attempts: [AVAudioSession.CategoryOptions] = [
            [.allowBluetoothA2DP, .defaultToSpeaker, .mixWithOthers],
            [.defaultToSpeaker, .mixWithOthers],
            [.allowBluetooth, .defaultToSpeaker, .mixWithOthers]
        ]
        var lastError: Error?
        for opts in attempts {
            do {
                let s = AVAudioSession.sharedInstance()
                try s.setCategory(.playAndRecord, mode: .default, options: opts)
                try s.setActive(true)
                engine.stop()
                _ = speaker   // attach the playback nodes before the engine starts
                let input = engine.inputNode
                input.removeTap(onBus: 0)
                input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buf, _ in
                    guard let self else { return }
                    self.lock.lock(); let p = self.current; self.lock.unlock()
                    p?.append(buf)
                    self.tapCount &+= 1
                    if self.tapCount % 3 == 0, let ch = buf.floatChannelData?[0] {
                        let n = Int(buf.frameLength)
                        var sum: Float = 0
                        for i in 0..<n { sum += ch[i] * ch[i] }
                        let rms = (sum / Float(max(n, 1))).squareRoot()
                        let lvl = Double(min(1, max(0, (20 * log10(max(rms, 1e-6)) + 50) / 50)))
                        if lvl > 0.3 { self.lastLoud = ProcessInfo.processInfo.systemUptime }
                        DispatchQueue.main.async {
                            self.bars.removeFirst()
                            self.bars.append(lvl)
                        }
                    }
                }
                engine.prepare()
                try engine.start()
                let old = swapCurrent(makePair())
                old?.finish { [weak self] p in self?.decide(p) }
                return
            } catch {
                lastError = error
                engine.inputNode.removeTap(onBus: 0)
            }
        }
        status = "Audio error: \(lastError?.localizedDescription ?? "unknown")"
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.running == true { self?.restartEngine() }
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
        liveLang = hasHan(zh) ? "zh" : (en.isEmpty ? "" : "en")
        lastText = ProcessInfo.processInfo.systemUptime
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
        let now = ProcessInfo.processInfo.systemUptime
        let age = Date().timeIntervalSince(p.start)
        let hasText = p.slots.contains { !$0.text.isEmpty }
        // A sentence ends when the room has been quiet for a while (not merely when
        // the recognizer is slow to report words), or when it runs very long.
        let quiet = now - lastLoud > 1.1 && now - lastText > 0.7
        if (hasText && (quiet || age > 12)) || age > 50 { endUtterance(p) }
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
        // Ignore our own spoken translation coming back through the microphone.
        if speaker.suppresses(best.0.lang) { return }
        let t = best.0.text.trimmingCharacters(in: .whitespacesAndNewlines)
        log.append(Entry(original: t, lang: best.0.lang, translation: nil))
    }
}
