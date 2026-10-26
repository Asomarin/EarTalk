import SwiftUI

struct ContentView: View {
    @StateObject private var rec = Recognizer()

    var body: some View {
        VStack(spacing: 12) {
            Picker("Language", selection: Binding(
                get: { rec.localeID }, set: { rec.changeLanguage($0) })) {
                Text("中文").tag("zh-CN")
                Text("English").tag("en-US")
            }.pickerStyle(.segmented)

            Button(rec.running ? "Stop" : "Start listening") {
                rec.running ? rec.stop() : rec.start()
            }
            .buttonStyle(.borderedProminent)
            .tint(rec.running ? .red : .blue)

            Text(rec.status).font(.footnote).foregroundStyle(.secondary)
            Text(rec.live).frame(maxWidth: .infinity, alignment: .leading)
                .padding().background(.thinMaterial).clipShape(RoundedRectangle(cornerRadius: 10))
            List(rec.log, id: \.self) { Text($0) }
        }
        .padding()
    }
}
