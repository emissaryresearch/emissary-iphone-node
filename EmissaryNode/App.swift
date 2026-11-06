// EMISSARY iPhone Node - screen. The phone works only while this app is open (iOS rule),
// so "Start worker" keeps the screen awake. Plug the phone in while it works.
import SwiftUI

@main
struct EmissaryNodeApp: App {
    @StateObject private var worker = WorkerService()
    var body: some Scene {
        WindowGroup { ContentView().environmentObject(worker).environmentObject(worker.models) }
    }
}

struct ContentView: View {
    @EnvironmentObject var worker: WorkerService
    @EnvironmentObject var models: ModelStore
    @State private var modelLink = ModelStore.defaultURL
    @State private var expectedSHA = ""
    @State private var downloading = false

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Status")) {
                    HStack {
                        Circle().fill(worker.busy ? Color.orange : (worker.running ? Color.green : Color.gray)).frame(width: 12, height: 12)
                        Text(worker.status)
                    }
                    Text("Pieces completed: \(worker.completed)").font(.footnote)
                    Button(worker.running ? "Stop worker" : "Start worker") { worker.running ? worker.stop() : worker.start() }
                        .disabled(worker.nodeId == nil || models.current == nil)
                    Text("Keep this app open and the phone plugged in while it works.").font(.footnote).foregroundColor(.secondary)
                }
                Section(header: Text("1 · Model (runs on this phone)")) {
                    if let m = models.current {
                        Text(m.name).bold()
                        Text("SHA-256 \(String(m.sha256.prefix(16)))…").font(.caption).foregroundColor(.secondary)
                        Button("Test on this phone (try airplane mode)") { Task { await worker.benchmark() } }
                        Button("Remove model", role: .destructive) { models.remove() }
                    }
                    Button("Use recommended model (Qwen2.5 1.5B)") { modelLink = ModelStore.defaultURL }
                    TextField("Model link (.gguf)", text: $modelLink).autocapitalization(.none).disableAutocorrection(true).font(.caption)
                    TextField("Expected SHA-256 (optional)", text: $expectedSHA).autocapitalization(.none).font(.caption)
                    Button(downloading ? "Downloading…" : "Download model") {
                        downloading = true
                        Task {
                            do { try await models.download(from: modelLink, expectedSHA256: expectedSHA) }
                            catch { worker.note("Model download failed: \(error.localizedDescription)") }
                            downloading = false
                        }
                    }.disabled(downloading)
                    if !models.progress.isEmpty { Text(models.progress).font(.footnote) }
                }
                Section(header: Text("2 · Connect to EMISSARY (Tailscale must be on)")) {
                    TextField("Supervisor address", text: $worker.supervisorURL).autocapitalization(.none).disableAutocorrection(true)
                    TextField("Name for this phone", text: $worker.nodeName).autocapitalization(.none)
                    if let id = worker.nodeId {
                        Text("Registered as \(id)").font(.footnote)
                        Button("Forget registration", role: .destructive) { worker.forget() }
                    } else {
                        Button("Register with the Supervisor") { Task { await worker.register() } }
                    }
                    Text("Then on the MSI approve it for research, the same way as the other Workers.").font(.footnote).foregroundColor(.secondary)
                }
                Section(header: Text("Activity")) {
                    ForEach(worker.log, id: \.self) { Text($0).font(.caption2) }
                }
            }
            .navigationTitle("EMISSARY Node")
        }
        .navigationViewStyle(.stack)
    }
}
