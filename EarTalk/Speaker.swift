import Foundation
import AVFoundation

/// Speaks translations. Each person wears one earbud: the translation is panned
/// fully to the ear of the person who needs to hear it.
final class Speaker {
    var chineseOnLeft = true
    private let synth = AVSpeechSynthesizer()
    private let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
    private let engine: AVAudioEngine
    private let left = AVAudioPlayerNode()
    private let right = AVAudioPlayerNode()
    private var queue: [(text: String, lang: String)] = []
    private var busy = false
    private let lock = NSLock()
    private var busyUntil: [String: Date] = [:]

    init(engine: AVAudioEngine) {
        self.engine = engine
        for (node, pan) in [(left, Float(-1)), (right, Float(1))] {
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: fmt)
            node.pan = pan
        }
    }

    /// True while a spoken translation in this language is playing (plus a short tail).
    func suppresses(_ lang: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return Date() < (busyUntil[lang] ?? .distantPast).addingTimeInterval(1.2)
    }

    /// On the phone speaker our own voice reaches the microphone, so everything heard
    /// while (and just after) a translation plays is ignored. Earbuds don't need this.
    func muteAll() -> Bool {
        let onSpeaker = AVAudioSession.sharedInstance().currentRoute.outputs.contains {
            $0.portType == .builtInSpeaker || $0.portType == .builtInReceiver
        }
        guard onSpeaker else { return false }
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        return busyUntil.values.contains { now < $0.addingTimeInterval(1.2) }
    }

    /// `outLang` is the language of the translation, i.e. what the listener understands.
    func speak(_ text: String, outLang: String) {
        queue.append((text, outLang))
        pump()
    }

    private func pump() {
        guard !busy, !queue.isEmpty, engine.isRunning else { return }
        busy = true
        let item = queue.removeFirst()
        // Chinese translations go to the Chinese speaker's ear, English to the other.
        let toLeft = (item.lang == "zh") == chineseOnLeft
        let player = toLeft ? left : right
        let u = AVSpeechUtterance(string: item.text)
        u.voice = AVSpeechSynthesisVoice(language: item.lang == "zh" ? "zh-CN" : "en-US")
        var converter: AVAudioConverter?
        synth.write(u) { [weak self] buffer in
            guard let self, let pcm = buffer as? AVAudioPCMBuffer else { return }
            if pcm.frameLength == 0 {
                DispatchQueue.main.async { self.busy = false; self.pump() }
                return
            }
            if converter == nil { converter = AVAudioConverter(from: pcm.format, to: self.fmt) }
            let ratio = self.fmt.sampleRate / pcm.format.sampleRate
            let cap = AVAudioFrameCount(Double(pcm.frameLength) * ratio) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: self.fmt, frameCapacity: cap) else { return }
            var fed = false
            var err: NSError?
            converter?.convert(to: out, error: &err) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData
                return pcm
            }
            guard out.frameLength > 0, self.engine.isRunning else { return }
            let dur = Double(out.frameLength) / self.fmt.sampleRate
            self.lock.lock()
            let start = max(Date(), self.busyUntil[item.lang] ?? .distantPast)
            self.busyUntil[item.lang] = start.addingTimeInterval(dur)
            self.lock.unlock()
            player.scheduleBuffer(out, completionHandler: nil)
            if !player.isPlaying { player.play() }
        }
    }
}
