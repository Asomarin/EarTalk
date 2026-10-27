import SwiftUI
import Translation

struct ContentView: View {
    @StateObject private var rec = Recognizer()
    @State private var zhToEn: TranslationSession.Configuration? =
        .init(source: Locale.Language(identifier: "zh-Hans"), target: Locale.Language(identifier: "en"))
    @State private var enToZh: TranslationSession.Configuration? =
        .init(source: Locale.Language(identifier: "en"), target: Locale.Language(identifier: "zh-Hans"))

    var body: some View {
        VStack(spacing: 12) {
            Button(rec.running ? "Stop" : "Start listening") {
                rec.running ? rec.stop() : rec.start()
            }
            .buttonStyle(.borderedProminent)
            .tint(rec.running ? .red : .blue)

            Text(rec.status).font(.footnote).foregroundStyle(.secondary)
            Text(rec.live).frame(maxWidth: .infinity, alignment: .leading)
                .padding().background(.thinMaterial).clipShape(RoundedRectangle(cornerRadius: 10))

            List(rec.log) { e in
                VStack(alignment: .leading, spacing: 4) {
                    Text(e.original).font(.headline)
                    Text(e.translation ?? "Translating…").foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .translationTask(zhToEn) { session in await run(session, "zh") }
        .translationTask(enToZh) { session in await run(session, "en") }
        .onChange(of: rec.log.count) { _, _ in
            zhToEn?.invalidate()
            enToZh?.invalidate()
        }
    }

    private func run(_ session: TranslationSession, _ lang: String) async {
        try? await session.prepareTranslation()
        for e in rec.log where e.translation == nil && e.lang == lang {
            if let r = try? await session.translate(e.original) {
                await MainActor.run { rec.setTranslation(e.id, r.targetText) }
            }
        }
    }
}
