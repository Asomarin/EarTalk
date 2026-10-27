import SwiftUI
import Translation

struct ContentView: View {
    @StateObject private var rec = Recognizer()
    @State private var zhToEn: TranslationSession.Configuration? =
        .init(source: Locale.Language(identifier: "zh-Hans"), target: Locale.Language(identifier: "en"))
    @State private var enToZh: TranslationSession.Configuration? =
        .init(source: Locale.Language(identifier: "en"), target: Locale.Language(identifier: "zh-Hans"))

    private let zhColor = Color.cyan
    private let enColor = Color.orange

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.04, green: 0.06, blue: 0.15),
                                    Color(red: 0.15, green: 0.07, blue: 0.27)],
                           startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            VStack(spacing: 14) {
                header
                earCards
                visualizer
                conversation
                controls
            }
            .padding(.horizontal)
        }
        .preferredColorScheme(.dark)
        .translationTask(zhToEn) { session in await run(session, "zh") }
        .translationTask(enToZh) { session in await run(session, "en") }
        .onChange(of: rec.log.count) { _, _ in
            zhToEn?.invalidate()
            enToZh?.invalidate()
        }
    }

    // MARK: pieces

    private var header: some View {
        HStack {
            Image(systemName: "ear.and.waveform").font(.title2).foregroundStyle(zhColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("EarTalk").font(.title2.bold())
                Text(rec.status).font(.caption).foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
            Toggle("Speak", isOn: $rec.speakOn).labelsHidden().tint(zhColor)
            Image(systemName: rec.speakOn ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private func earCard(_ title: String, _ side: String, _ color: Color, _ active: Bool) -> some View {
        VStack(spacing: 4) {
            Image(systemName: "earbuds").font(.title3).foregroundStyle(color)
            Text(title).font(.headline)
            Text(side).font(.caption2).foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14).fill(color.opacity(active ? 0.30 : 0.12)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(color.opacity(active ? 0.9 : 0.3)))
    }

    private var earCards: some View {
        let zhActive = rec.liveLang == "zh"
        let enActive = rec.liveLang == "en"
        let zh = earCard("中文", rec.chineseOnLeft ? "LEFT EAR" : "RIGHT EAR", zhColor, zhActive)
        let en = earCard("English", rec.chineseOnLeft ? "RIGHT EAR" : "LEFT EAR", enColor, enActive)
        return HStack(spacing: 10) {
            if rec.chineseOnLeft { zh } else { en }
            Button { rec.chineseOnLeft.toggle() } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .padding(10).background(Circle().fill(.white.opacity(0.12)))
            }.foregroundStyle(.white)
            if rec.chineseOnLeft { en } else { zh }
        }
    }

    private var visualizer: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(rec.running ? Color.green : Color.gray).frame(width: 8, height: 8)
                Text(rec.running ? "LISTENING" : "PAUSED")
                    .font(.caption.bold()).foregroundStyle(.white.opacity(0.7))
                Spacer()
            }
            HStack(spacing: 3) {
                ForEach(rec.bars.indices, id: \.self) { i in
                    Capsule()
                        .fill(LinearGradient(colors: [zhColor, enColor], startPoint: .bottom, endPoint: .top))
                        .frame(height: max(4, rec.bars[i] * 64))
                }
            }
            .frame(height: 64)
            .animation(.easeOut(duration: 0.08), value: rec.bars)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16).fill(.white.opacity(0.07)))
    }

    private func bubble(_ e: Entry) -> some View {
        let isZh = e.lang == "zh"
        let c = isZh ? zhColor : enColor
        return HStack {
            if !isZh { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 6) {
                Text(isZh ? "中文" : "ENGLISH").font(.caption2.bold()).foregroundStyle(c)
                Text(e.original).font(.footnote).foregroundStyle(.white.opacity(0.65))
                Text(e.translation ?? "Translating…").font(.body.weight(.semibold))
                Text(e.debug).font(.caption2).foregroundStyle(.white.opacity(0.3))
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 16).fill(c.opacity(0.16)))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(c.opacity(0.35)))
            if isZh { Spacer(minLength: 40) }
        }
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(rec.log) { bubble($0) }
                    if !rec.live.isEmpty {
                        Text(rec.live).font(.footnote).italic()
                            .foregroundStyle(.white.opacity(0.5))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
            }
            .onChange(of: rec.log.count) { _, _ in withAnimation { proxy.scrollTo("end") } }
            .onChange(of: rec.live) { _, _ in proxy.scrollTo("end") }
        }
    }

    private var controls: some View {
        let level = rec.running ? (rec.bars.last ?? 0) : 0
        return Button { rec.running ? rec.stop() : rec.start() } label: {
            ZStack {
                Circle().stroke(zhColor.opacity(0.35), lineWidth: 4)
                    .frame(width: 78 + level * 34, height: 78 + level * 34)
                Circle()
                    .fill(LinearGradient(colors: rec.running ? [.red, .pink] : [zhColor, .blue],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 78, height: 78)
                Image(systemName: rec.running ? "stop.fill" : "mic.fill")
                    .font(.title).foregroundStyle(.white)
            }
        }
        .frame(height: 120)
        .animation(.easeOut(duration: 0.1), value: level)
    }

    // MARK: translation

    private func run(_ session: TranslationSession, _ lang: String) async {
        try? await session.prepareTranslation()
        for e in rec.log where e.translation == nil && e.lang == lang {
            guard rec.claim(e.id) else { continue }
            if let r = try? await session.translate(e.original) {
                await MainActor.run {
                    rec.setTranslation(e.id, r.targetText)
                    rec.speak(r.targetText, outLang: lang == "zh" ? "en" : "zh")
                }
            } else {
                rec.release(e.id)
            }
        }
    }
}
