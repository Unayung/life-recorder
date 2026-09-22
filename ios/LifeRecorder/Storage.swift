import AVFoundation
import CryptoKit
import Foundation
import Security

struct Chunk: Codable {
    let id: UUID
    let startedAt: Date
    let duration: Double
    let sha256: String
    var name: String { id.uuidString.lowercased() }
    var audioURL: URL { QueueStore.directory.appendingPathComponent(name + ".m4a") }
    var manifestURL: URL { QueueStore.directory.appendingPathComponent(name + ".json") }
}

struct RecordingJournal: Codable {
    let id: UUID
    let startedAt: Date
}

enum QueueStore {
    static let directory: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = support.appendingPathComponent("PendingAudio", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excludedURL = url
        try? excludedURL.setResourceValues(values)
        return url
    }()

    static var deviceID: String {
        if let value = UserDefaults.standard.string(forKey: "deviceID") { return value }
        let value = UUID().uuidString.lowercased()
        UserDefaults.standard.set(value, forKey: "deviceID")
        return value
    }

    static func pending() -> [Chunk] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" && !$0.lastPathComponent.contains(".recording.") }
            .compactMap { try? JSONDecoder().decode(Chunk.self, from: Data(contentsOf: $0)) }
            .sorted { $0.startedAt < $1.startedAt }
    }

    static func checksum(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 65536), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func seal(_ journal: RecordingJournal, duration: Double) throws -> Chunk {
        let name = journal.id.uuidString.lowercased()
        let audio = directory.appendingPathComponent(name + ".m4a")
        let chunk = Chunk(id: journal.id, startedAt: journal.startedAt, duration: duration,
                          sha256: try checksum(audio))
        try JSONEncoder().encode(chunk).write(to: chunk.manifestURL, options: .atomic)
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name + ".recording.json"))
        return chunk
    }

    /// Throw away a clip that was never sealed: silence nobody needs to keep.
    static func discardRecording(_ journal: RecordingJournal) {
        let name = journal.id.uuidString.lowercased()
        for suffix in [".m4a", ".recording.json"] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name + suffix))
        }
    }

    static let damagedDirectory: URL = directory.appendingPathComponent("Damaged", isDirectory: true)

    /// Clips whose audio could not be read; kept as bytes, not counted as pending work.
    static func damagedCount() -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: damagedDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "m4a" }.count
    }

    static func removeDamaged() {
        try? FileManager.default.removeItem(at: damagedDirectory)
    }

    private static func setAside(_ journal: URL, _ audio: URL) {
        // An unfinished AAC file has no index, so nothing can decode it. Keep the bytes
        // out of the way instead of asking for a recovery that cannot happen.
        try? FileManager.default.createDirectory(at: damagedDirectory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        for file in [journal, audio] where FileManager.default.fileExists(atPath: file.path) {
            try? FileManager.default.moveItem(at: file, to: damagedDirectory.appendingPathComponent(file.lastPathComponent))
        }
    }

    static func recoverInterruptedFiles() async -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasSuffix(".recording.json") {
            guard let journal = try? JSONDecoder().decode(RecordingJournal.self, from: Data(contentsOf: file)) else {
                try? FileManager.default.removeItem(at: file)  // A journal we cannot read names nothing.
                continue
            }
            let audio = directory.appendingPathComponent(journal.id.uuidString.lowercased() + ".m4a")
            guard FileManager.default.fileExists(atPath: audio.path) else {
                try? FileManager.default.removeItem(at: file)  // No audio was ever written.
                continue
            }
            let duration = (try? await AVURLAsset(url: audio).load(.duration).seconds) ?? .nan
            if duration.isFinite, duration > 0, (try? seal(journal, duration: duration)) != nil {
                continue
            }
            setAside(file, audio)
        }
        // Removal of an acknowledged manifest is the local commit point. Finish cleanup after a crash.
        for audio in files where audio.pathExtension == "m4a" {
            let stem = audio.deletingPathExtension().lastPathComponent
            if !FileManager.default.fileExists(atPath: directory.appendingPathComponent(stem + ".json").path)
                && !FileManager.default.fileExists(atPath: directory.appendingPathComponent(stem + ".recording.json").path) {
                try? FileManager.default.removeItem(at: audio)
            }
        }
        return damagedCount()
    }

    static func removeAcknowledged(_ chunk: Chunk) throws {
        // Only called after a verified durable receipt. Commit dequeue before deleting its audio.
        try FileManager.default.removeItem(at: chunk.manifestURL)
        if FileManager.default.fileExists(atPath: chunk.audioURL.path) {
            try FileManager.default.removeItem(at: chunk.audioURL)
        }
    }
}

enum Credentials {
    private static let service = "com.unayung.liferecorder.receiver"
    static func token() -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "token",
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func setToken(_ token: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "token"]
        let changes: [String: Any] = [kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(changes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}

struct ReceiverSettings {
    let baseURL: URL
    let token: String
    let certificateSHA256: String

    static func load() -> ReceiverSettings? {
        guard let raw = UserDefaults.standard.string(forKey: "receiverURL"),
              let url = URL(string: raw), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        let token = Credentials.token()
        guard !token.isEmpty else { return nil }
        return ReceiverSettings(baseURL: url, token: token,
            certificateSHA256: UserDefaults.standard.string(forKey: "certificateSHA256") ?? "")
    }

    static func save(url: String, token: String, pin: String) throws {
        guard let parsed = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
              parsed.scheme == "https", parsed.host != nil, parsed.user == nil, parsed.password == nil,
              parsed.query == nil, parsed.fragment == nil,
              parsed.path.isEmpty || parsed.path == "/", !token.isEmpty else {
            throw NSError(domain: "Settings", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Enter an HTTPS receiver address and its pairing token."])
        }
        let cleanPin = pin.lowercased().replacingOccurrences(of: ":", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanPin.isEmpty || (cleanPin.count == 64 && cleanPin.allSatisfy { $0.isHexDigit }) else {
            throw NSError(domain: "Settings", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "The certificate fingerprint must contain 64 hexadecimal characters."])
        }
        try Credentials.setToken(token)
        UserDefaults.standard.set(parsed.absoluteString, forKey: "receiverURL")
        UserDefaults.standard.set(cleanPin, forKey: "certificateSHA256")
    }
}

/// Most recorded minutes are an empty room. Dropping them on the phone keeps the upload queue
/// short, so the minutes that hold speech reach the desktop while they are still fresh.
enum SilenceGate {
    /// Speech across a room peaks well above this; room tone sits below it.
    static let threshold: Float = 0.0056  // -45 dBFS
    /// Below this the microphone is not producing sound at all, which is a fault, not a quiet room.
    static let deaf: Float = 0.0001  // -80 dBFS

    private static let defaults = UserDefaults.standard

    static var skipping: Bool {
        defaults.object(forKey: "skipSilentClips") as? Bool ?? true
    }

    static var skippedCount: Int { defaults.integer(forKey: "silentClipsSkipped") }

    /// How many clips in a row held no sound at all; a run means the microphone has gone deaf.
    static var deafRun: Int { defaults.integer(forKey: "silentClipsDeafRun") }

    static func shouldSkip(peak: Float) -> Bool {
        skipping && peak < threshold
    }

    static func recordSkipped(peak: Float) {
        defaults.set(skippedCount + 1, forKey: "silentClipsSkipped")
        defaults.set(peak < deaf ? deafRun + 1 : 0, forKey: "silentClipsDeafRun")
    }

    static func recordKept() {
        defaults.set(0, forKey: "silentClipsDeafRun")
    }

    static func reset() {
        defaults.set(0, forKey: "silentClipsSkipped")
        defaults.set(0, forKey: "silentClipsDeafRun")
    }
}
