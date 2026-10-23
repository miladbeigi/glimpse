import Foundation

struct VoiceProfile: Codable, Sendable {
    var name: String
    var embedding: [Float]
}

/// Voice embeddings stored as `{name}.json` files in the configured speakers directory.
struct VoiceProfileStore: Sendable {
    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    func loadAll() -> [VoiceProfile] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let profile = try? JSONDecoder().decode(VoiceProfile.self, from: data),
                      !profile.embedding.isEmpty else { return nil }
                return profile
            }
            .sorted { $0.name < $1.name }
    }

    func names() -> [String] { loadAll().map(\.name) }

    func fileURL(for name: String) -> URL {
        let safe = name.replacingOccurrences(of: "/", with: "-")
        return directory.appendingPathComponent("\(safe).json")
    }

    func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: name).path)
    }

    /// Another person's profile that is (nearly) the same voice as `embedding`. Two names
    /// sharing one voice make both useless for matching (seen: three names stored with an
    /// identical embedding), so `save` refuses them.
    func duplicate(of embedding: [Float], excluding name: String) -> String? {
        loadAll().first { normalizeName($0.name) != normalizeName(name) && cosineSimilarity($0.embedding, embedding) >= Self.duplicateSimilarity }?.name
    }

    static let duplicateSimilarity: Float = 0.95

    func save(_ profile: VoiceProfile) throws {
        if let other = duplicate(of: profile.embedding, excluding: profile.name) {
            log("⚠️ Not saving voice profile '\(profile.name)': it is the same voice as '\(other)'")
            throw NSError(domain: "VoiceProfileStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "'\(profile.name)' has the same voice as '\(other)'"])
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        try encoder.encode(profile).write(to: fileURL(for: profile.name), options: .atomic)
        log("🎯 Saved voice profile '\(profile.name)'")
    }

    func delete(_ name: String) {
        let url = fileURL(for: name)
        do {
            try FileManager.default.removeItem(at: url)
            log("🗑️ Deleted voice profile '\(name)'")
        } catch {
            log("⚠️ Could not delete voice profile '\(name)': \(error.localizedDescription)")
        }
    }
}

/// True when `name` is one of `aliases`: every word of the alias appears in the name, so the
/// calendar attendee "alice.smith" (or "Alice Smith") is the user named "Alice".
func matchesAlias(_ name: String, aliases: [String]) -> Bool {
    let words = Set(normalizeName(name).split(separator: " "))
    return aliases.contains { alias in
        let aliasWords = normalizeName(alias).split(separator: " ")
        return !aliasWords.isEmpty && aliasWords.allSatisfy(words.contains)
    }
}

/// Calendar attendees are often email local parts: "bob" → "Bob", "jane.doe" → "Jane Doe".
/// Names with capitals are kept as they are.
func displayName(forAttendee attendee: String) -> String {
    let base = attendee.split(separator: "@").first.map(String.init) ?? attendee
    guard base == base.lowercased() else { return base }
    return base.split(whereSeparator: { $0 == "." || $0 == "_" || $0 == " " }).map { $0.capitalized }.joined(separator: " ")
}

/// Name normalization used for attendee ↔ profile matching.
func normalizeName(_ name: String) -> String {
    let base = name.split(separator: "@").first.map(String.init) ?? name
    return base
        .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        .replacingOccurrences(of: ".", with: " ")
        .replacingOccurrences(of: "_", with: " ")
        .split(whereSeparator: \.isWhitespace)
        .joined(separator: " ")
        .lowercased()
}

/// `displayName(forAttendee:)` under a name that type members called `displayName` don't shadow.
func attendeeDisplayName(_ attendee: String) -> String { displayName(forAttendee: attendee) }
