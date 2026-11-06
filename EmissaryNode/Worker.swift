// EMISSARY Worker for iPhone - speaks the SAME Worker protocol as the Windows/Chromebook Workers
// (register -> owner authorizes on the MSI -> heartbeat -> poll -> start -> complete/fail).
// The MSI Supervisor stays the only authority: this app can only run LOCAL_MODEL_RESEARCH pieces
// the Supervisor assigned to THIS node, on this phone's own model. No shell, no files, no other tools.
import Foundation
import UIKit
import Security

let workerVersion = "iphone-1.0.0"

// MARK: - Keychain (the per-node credential the Supervisor issues once)
enum Keychain {
    static func set(_ value: String, _ key: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
    static func get(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func delete(_ key: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key] as CFDictionary)
    }
}

// MARK: - HTTP client for the existing Supervisor API
struct SupervisorClient {
    let baseURL: URL
    var nodeId: String?
    var token: String?

    private func call(_ method: String, _ path: String, _ body: [String: Any]? = nil, timeout: TimeInterval = 20) async -> [String: Any] {
        guard let url = URL(string: baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) else {
            return ["success": false, "error": "bad URL"]
        }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if var b = body {
            if let t = token { b["worker_token"] = t }
            req.httpBody = try? JSONSerialization.data(withJSONObject: b)
        }
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? ["success": false, "error": "unreadable reply"]
        } catch {
            return ["success": false, "error": "network_error: \(error.localizedDescription)"]
        }
    }

    func health() async -> Bool { (await call("GET", "/api/health"))["success"] as? Bool ?? false }

    func register(name: String, capabilities: [String: Any]) async -> [String: Any] {
        await call("POST", "/api/compute/nodes", ["node_type": "MOBILE", "node_name": name, "platform": "iOS",
                                                   "capabilities": capabilities, "transport": "TAILSCALE",
                                                   "issue_credential": true, "workspace_id": "ws-1"])
    }

    func node() async -> [String: Any] {
        guard let id = nodeId else { return [:] }
        return await call("GET", "/api/compute/nodes/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)")
    }

    func heartbeat(busy: Bool) async -> [String: Any] {
        guard let id = nodeId else { return [:] }
        return await call("POST", "/api/compute/nodes/\(id)/heartbeat",
                          ["health": ["healthy": true, "worker_version": workerVersion, "busy": busy]])
    }

    func reportCapabilities(_ caps: [String: Any]) async {
        guard let id = nodeId else { return }
        _ = await call("POST", "/api/compute/nodes/\(id)/capabilities", ["capabilities": caps])
    }

    func tasks(phase: String) async -> [[String: Any]] {
        guard let id = nodeId else { return [] }
        var c = URLComponents()
        c.queryItems = [URLQueryItem(name: "node_id", value: id), URLQueryItem(name: "phase", value: phase)]
        let r = await call("GET", "/api/compute/tasks?" + (c.percentEncodedQuery ?? ""))
        return (r["success"] as? Bool ?? false) ? (r["tasks"] as? [[String: Any]] ?? []) : []
    }

    func start(_ taskId: String) async -> [String: Any] {
        await call("POST", "/api/compute/tasks/\(taskId)/start", ["node_id": nodeId ?? ""])
    }
    func complete(_ taskId: String, result: [String: Any]) async -> [String: Any] {
        await call("POST", "/api/compute/tasks/\(taskId)/complete", ["node_id": nodeId ?? "", "result": result], timeout: 60)
    }
    func fail(_ taskId: String, reason: String) async -> [String: Any] {
        await call("POST", "/api/compute/tasks/\(taskId)/fail",
                   ["node_id": nodeId ?? "", "stopping_reason": "task_failure", "error": String(reason.prefix(500))])
    }
}

// MARK: - The worker loop
@MainActor
final class WorkerService: ObservableObject {
    @Published var supervisorURL: String = UserDefaults.standard.string(forKey: "supervisorURL") ?? "https://msi.tail21a0f7.ts.net"
    @Published var nodeName: String = UserDefaults.standard.string(forKey: "nodeName") ?? "iphone13-node"
    @Published var nodeId: String? = UserDefaults.standard.string(forKey: "nodeId")
    @Published var running = false
    @Published var busy = false
    @Published var status = "Stopped"
    @Published var log: [String] = []
    @Published var completed = 0

    let engine = LlamaEngine()
    let models = ModelStore()
    private var loop: Task<Void, Never>?
    private static let safeTaskId = try! NSRegularExpression(pattern: "^[A-Za-z0-9._:-]{1,160}$")

    func note(_ s: String) {
        let t = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        log.insert("\(t)  \(s)", at: 0)
        if log.count > 200 { log.removeLast() }
    }

    private var client: SupervisorClient? {
        guard let u = URL(string: supervisorURL), u.scheme == "https" else { return nil }
        return SupervisorClient(baseURL: u, nodeId: nodeId, token: Keychain.get("worker_token"))
    }

    func capabilities() async -> [String: Any] {
        var caps: [String: Any] = ["operating_system": "iOS \(UIDevice.current.systemVersion)",
                                   "device_model": deviceModel(), "cpu_cores": ProcessInfo.processInfo.processorCount,
                                   "total_ram_bytes": ProcessInfo.processInfo.physicalMemory,
                                   "architecture": "arm64", "worker_version": workerVersion,
                                   "inference_runtimes": (await engine.isLoaded) ? ["llama.cpp"] : [],
                                   "foreground_only": true]
        if let m = models.current { caps["registered_models"] = [m.name]; caps["model_sha256"] = m.sha256 }
        return caps
    }

    func deviceModel() -> String {
        var s = utsname(); uname(&s)
        return withUnsafeBytes(of: &s.machine) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
    }

    func register() async {
        UserDefaults.standard.set(supervisorURL, forKey: "supervisorURL")
        UserDefaults.standard.set(nodeName, forKey: "nodeName")
        guard let c = client else { note("Supervisor address must start with https://"); return }
        guard await c.health() else { note("Cannot reach the Supervisor - is Tailscale on?"); return }
        let r = await c.register(name: nodeName, capabilities: await capabilities())
        guard let id = r["node_id"] as? String else { note("Registration refused: \(r["error"] ?? "unknown")"); return }
        nodeId = id
        UserDefaults.standard.set(id, forKey: "nodeId")
        if let tok = r["worker_token"] as? String { Keychain.set(tok, "worker_token") }
        note("Registered as \(id). Now approve it on the MSI (authorize_research_worker.py).")
    }

    func forget() {
        stop(); nodeId = nil
        UserDefaults.standard.removeObject(forKey: "nodeId"); Keychain.delete("worker_token")
        note("This phone's registration was removed from the app.")
    }

    func start() {
        guard !running else { return }
        guard nodeId != nil else { note("Register with the Supervisor first."); return }
        guard models.current != nil else { note("Download or choose a model first."); return }
        running = true
        UIApplication.shared.isIdleTimerDisabled = true   // iOS only lets the worker run while on screen
        loop = Task { await runLoop() }
    }

    func stop() {
        running = false
        loop?.cancel(); loop = nil
        Task { await engine.cancel() }
        UIApplication.shared.isIdleTimerDisabled = false
        status = "Stopped"
    }

    private func runLoop() async {
        if !(await engine.isLoaded), let m = models.current {
            status = "Loading model..."
            do { try await engine.load(path: m.url.path); note("Model loaded: \(await engine.modelDescription)") }
            catch { note("Model load failed: \(error.localizedDescription)"); running = false; status = "Stopped"; return }
        }
        if let c = client { await c.reportCapabilities(await capabilities()) }
        var lastBeat = Date.distantPast
        while running && !Task.isCancelled {
            guard let c = client else { break }
            if Date().timeIntervalSince(lastBeat) > 30 {
                let hb = await c.heartbeat(busy: false)
                lastBeat = Date()
                if (hb["success"] as? Bool) == false { status = "Heartbeat refused: \(hb["error"] ?? "?")" }
                else { status = "Online - waiting for work" }
            }
            let assigned = await c.tasks(phase: "assigned")
            for task in assigned where running { await handle(task, client: c, recovering: false) }
            let mine = await c.tasks(phase: "running")
            for task in mine where running { await handle(task, client: c, recovering: true) }
            try? await Task.sleep(nanoseconds: 10_000_000_000)
        }
    }

    private func validate(_ task: [String: Any]) -> String? {
        guard let tid = task["task_id"] as? String,
              Self.safeTaskId.firstMatch(in: tid, range: NSRange(tid.startIndex..., in: tid)) != nil else { return "unsafe task id" }
        guard (task["assigned_node_id"] as? String) == nodeId else { return "task is not assigned to this node" }
        let prov = task["input_provenance"] as? [String: Any] ?? [:]
        guard (prov["capability"] as? String) == "LOCAL_MODEL_RESEARCH" else {
            return "capability \(prov["capability"] ?? "?") is not implemented on the iPhone worker"
        }
        guard (prov["execution_permission"] as? String) == "none" else { return "execution_permission must be 'none'" }
        guard let p = prov["summary"] as? String, !p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "research piece has no prompt"
        }
        return nil
    }

    private func handle(_ task: [String: Any], client c: SupervisorClient, recovering: Bool) async {
        let tid = task["task_id"] as? String ?? "?"
        if let reason = validate(task) { _ = await c.fail(tid, reason: reason); note("Rejected \(tid): \(reason)"); return }
        if !recovering {
            let ack = await c.start(tid)
            guard (ack["success"] as? Bool) == true else { note("Could not start \(tid): \(ack["error"] ?? "?")"); return }
        }
        let prov = task["input_provenance"] as? [String: Any] ?? [:]
        let prompt = String((prov["summary"] as? String ?? "").prefix(20000))
        let budget = min(max((prov["time_budget_seconds"] as? Double) ?? 900, 300), 3600)
        busy = true; status = "Working on \(tid)"
        note("Started \(tid)")
        let beat = Task { while !Task.isCancelled { try? await Task.sleep(nanoseconds: 30_000_000_000); _ = await c.heartbeat(busy: true) } }
        defer { beat.cancel(); busy = false; status = running ? "Online - waiting for work" : "Stopped" }
        let started = Date()
        do {
            let g = try await engine.generate(prompt: prompt, maxOutputTokens: 768, deadline: Date().addingTimeInterval(budget))
            guard !g.text.isEmpty else { throw LlamaEngineError.decodeFailed(-1) }
            let result: [String: Any] = [
                "worker_identity": nodeId ?? "", "worker_version": workerVersion, "worker_hostname": nodeName,
                "platform": "iOS \(UIDevice.current.systemVersion) (\(deviceModel()))",
                "capability": "LOCAL_MODEL_RESEARCH", "task_id": tid, "execution_permission": "none",
                "shell_execution": false, "internet_access": false, "execution_location": "device",
                "local_model": models.current?.name ?? "unknown", "model_sha256": models.current?.sha256 ?? "",
                "runtime": "llama.cpp", "total_ram_bytes": ProcessInfo.processInfo.physicalMemory,
                "cpu_cores": ProcessInfo.processInfo.processorCount,
                "duration_seconds": (Date().timeIntervalSince(started) * 10).rounded() / 10,
                "prompt_tokens": g.promptTokens, "model_eval_tokens": g.outputTokens,
                "tokens_per_second": g.generationSeconds > 0 ? (Double(g.outputTokens) / g.generationSeconds * 10).rounded() / 10 : 0,
                "prompt_truncated_to_fit_device": g.truncatedPrompt,
                "thermal_state": ProcessInfo.processInfo.thermalState.rawValue,
                "research_findings": String(g.text.prefix(60000)),
            ]
            let done = await c.complete(tid, result: result)
            if (done["success"] as? Bool) == true { completed += 1; note("Finished \(tid) (\(g.outputTokens) tokens)") }
            else { note("Result for \(tid) was refused: \(done["error"] ?? "?")") }
        } catch {
            _ = await c.fail(tid, reason: "iPhone worker could not complete LOCAL_MODEL_RESEARCH: \(error.localizedDescription)")
            note("Failed \(tid): \(error.localizedDescription)")
        }
    }

    /// Local benchmark: proves inference runs on the phone (try it in airplane mode).
    func benchmark() async {
        guard let m = models.current else { note("Choose a model first."); return }
        do {
            if !(await engine.isLoaded) { try await engine.load(path: m.url.path) }
            let g = try await engine.generate(prompt: "In three sentences, explain why lunar dust is a problem for spacecraft.",
                                              maxOutputTokens: 160, deadline: Date().addingTimeInterval(300))
            let tps = g.generationSeconds > 0 ? Double(g.outputTokens) / g.generationSeconds : 0
            note(String(format: "Benchmark: %d prompt tokens in %.1fs, %d output tokens at %.1f tok/s. Thermal %d.",
                        g.promptTokens, g.promptSeconds, g.outputTokens, tps, ProcessInfo.processInfo.thermalState.rawValue))
            note("Answer: \(g.text)")
        } catch { note("Benchmark failed: \(error.localizedDescription)") }
    }
}
