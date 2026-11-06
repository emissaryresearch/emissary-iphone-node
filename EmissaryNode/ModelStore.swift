// ModelStore - downloads ONE model file on the owner's tap (never silently), stores it in the app's
// own sandbox, and records its SHA-256 so every result says exactly which model produced it.
import Foundation
import CryptoKit

struct LocalModel: Codable, Equatable {
    let name: String
    let fileName: String
    let sha256: String
    var url: URL { ModelStore.folder.appendingPathComponent(fileName) }
}

@MainActor
final class ModelStore: ObservableObject {
    nonisolated static let folder: URL = {
        let f = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        var v = URLResourceValues(); v.isExcludedFromBackup = true
        var ff = f; try? ff.setResourceValues(v)
        return f
    }()

    /// Qwen2.5 1.5B Instruct (Apache-2.0), about 986 MB - clear, on-topic answers. Any other GGUF link can be entered.
    static let defaultURL = "https://huggingface.co/bartowski/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/Qwen2.5-1.5B-Instruct-Q4_K_M.gguf"

    @Published var current: LocalModel? = {
        guard let d = UserDefaults.standard.data(forKey: "currentModel"),
              let m = try? JSONDecoder().decode(LocalModel.self, from: d),
              FileManager.default.fileExists(atPath: m.url.path) else { return nil }
        return m
    }()
    @Published var progress: String = ""

    func download(from link: String, expectedSHA256: String?) async throws {
        guard let src = URL(string: link), src.scheme == "https", src.lastPathComponent.lowercased().hasSuffix(".gguf") else {
            throw NSError(domain: "ModelStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Link must be https and end in .gguf"])
        }
        progress = "Downloading \(src.lastPathComponent)..."
        let (dl, resp) = try await URLSession.shared.download(from: src)
        // Move the system's temporary file into our own folder right away, before anything else.
        let tmp = Self.folder.appendingPathComponent(src.lastPathComponent + ".partial")
        try? FileManager.default.removeItem(at: tmp)
        try FileManager.default.moveItem(at: dl, to: tmp)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            try? FileManager.default.removeItem(at: tmp)
            throw NSError(domain: "ModelStore", code: 2, userInfo: [NSLocalizedDescriptionKey: "Download failed"])
        }
        progress = "Checking the file (SHA-256)..."
        let digest = try await Task.detached { try ModelStore.sha256(of: tmp) }.value
        if let want = expectedSHA256?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !want.isEmpty, want != digest {
            try? FileManager.default.removeItem(at: tmp)
            throw NSError(domain: "ModelStore", code: 3, userInfo: [NSLocalizedDescriptionKey: "SHA-256 does not match - file rejected"])
        }
        let model = LocalModel(name: src.deletingPathExtension().lastPathComponent, fileName: src.lastPathComponent, sha256: digest)
        try? FileManager.default.removeItem(at: model.url)
        try FileManager.default.moveItem(at: tmp, to: model.url)
        if let old = current, old.fileName != model.fileName { try? FileManager.default.removeItem(at: old.url) }
        current = model
        UserDefaults.standard.set(try JSONEncoder().encode(model), forKey: "currentModel")
        progress = "Ready: \(model.name)"
    }

    func remove() {
        if let m = current { try? FileManager.default.removeItem(at: m.url) }
        current = nil
        UserDefaults.standard.removeObject(forKey: "currentModel")
        progress = "Model removed"
    }

    nonisolated static func sha256(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
