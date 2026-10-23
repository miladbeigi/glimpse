import Foundation

/// Cluster-first, match-second speaker identification.
struct SpeakerIdentifier {
    struct Result {
        /// Diarization speaker id → display label (real name or "Unknown").
        var labels: [String: String]
        /// Names whose voice profile was created during this run (Step 5).
        var createdEmbeddings: [String]
    }

    static let unknown = "Unknown"
    static let minEmbeddingSegment = 1.0
    static let aliasSimilarity: Float = 0.95
    static let mergeFloor: Float = 0.3
    static let matchThreshold: Float = 0.6
    static let inferenceMinSpeakingTime = 5.0
    static let crosstalkSimilarity: Float = 0.4
    static let crosstalkMaxSpeakingTime = 3.0

    let embeddingProvider: SpeakerEmbeddingProvider
    let profileStore: VoiceProfileStore

    /// - Parameters:
    ///   - attendees: expected speakers on this audio (remote attendees, or everyone for mono)
    ///   - primaryAliases: the user's configured names
    ///   - allowPrimaryUser: false on the remote channel (the local user cannot be there)
    func identify(
        diarization: DiarizationOutput,
        audioPath: URL,
        attendees: [String],
        primaryAliases: [String],
        allowPrimaryUser: Bool
    ) async -> Result {
        let speakerIds = diarization.speakerIds
        var labels: [String: String] = [:]
        var created: [String] = []
        guard !speakerIds.isEmpty else { return Result(labels: [:], createdEmbeddings: []) }

        // Expected speakers on this channel.
        var expected = attendees
        if allowPrimaryUser {
            for alias in primaryAliases.prefix(1) where !expected.contains(where: { matchesAlias($0, aliases: [alias]) }) {
                expected.insert(alias, at: 0)
            }
        } else {
            expected.removeAll { matchesAlias($0, aliases: primaryAliases) }
        }

        // Step 0: restrict candidate profiles to attendees (+ primary aliases when allowed).
        var allowedNames = Set(attendees.map(normalizeName))
        if allowPrimaryUser { allowedNames.formUnion(primaryAliases.map(normalizeName)) }
        if !allowPrimaryUser { allowedNames = allowedNames.filter { !matchesAlias($0, aliases: primaryAliases) } }
        let candidates = profileStore.loadAll().filter { allowedNames.contains(normalizeName($0.name)) }
        log("🎯 Speaker candidates: \(candidates.map(\.name)) (expected \(expected.count) speaker(s) from \(attendees.count) attendee(s))")

        // Step 1: one embedding per speaker id from its longest segment (≥ 1 s).
        var speakerEmbedding: [String: [Float]] = [:]
        var speakingTime: [String: Double] = [:]
        for id in speakerIds {
            let turns = diarization.turns.filter { $0.speakerId == id }
            speakingTime[id] = turns.reduce(0) { $0 + $1.duration }
            guard let longest = turns.max(by: { $0.duration < $1.duration }), longest.duration >= Self.minEmbeddingSegment else { continue }
            do {
                speakerEmbedding[id] = try await embeddingProvider.extractEmbedding(audioPath: audioPath, start: longest.start, end: longest.end)
            } catch {
                log("⚠️ Embedding for \(id) failed: \(error.localizedDescription)")
            }
        }

        // Step 2: group profiles that are the same person (aliases).
        let groups = Self.aliasGroups(candidates, preferredOrder: expected, similarity: embeddingProvider.similarity)

        // Step 3: agglomerative clustering of speaker ids (average linkage).
        let embeddedIds = speakerIds.filter { speakerEmbedding[$0] != nil }
        let targetCount = max(1, expected.count)
        let clusters = Self.agglomerate(
            ids: embeddedIds, embeddings: speakerEmbedding, target: targetCount,
            floor: Self.mergeFloor, similarity: embeddingProvider.similarity)
        log("🔗 \(embeddedIds.count) speaker id(s) → \(clusters.count) cluster(s) (target \(targetCount))")

        // Step 4: match cluster centroids to known speakers (one-to-one, best first).
        let centroids = clusters.map { averageEmbedding($0.compactMap { speakerEmbedding[$0] }) }
        var pairs: [(cluster: Int, group: Int, sim: Float)] = []
        for (ci, centroid) in centroids.enumerated() {
            for (gi, group) in groups.enumerated() {
                let sim = group.profiles.map { embeddingProvider.similarity(centroid, $0.embedding) }.max() ?? 0
                if sim >= Self.matchThreshold { pairs.append((ci, gi, sim)) }
            }
        }
        pairs.sort { $0.sim > $1.sim }
        var clusterName: [Int: String] = [:]
        var usedGroups = Set<Int>()
        for p in pairs where clusterName[p.cluster] == nil && !usedGroups.contains(p.group) {
            clusterName[p.cluster] = groups[p.group].canonical
            usedGroups.insert(p.group)
            log("🎯 Cluster \(p.cluster) matched '\(groups[p.group].canonical)' (sim \(String(format: "%.2f", p.sim)))")
        }

        // Step 5: conservative inference — exactly one unmatched attendee left.
        let matchedNormalized = Set(clusterName.values.map(normalizeName))
        let aliasesOfMatched = Set(groups.filter { matchedNormalized.contains(normalizeName($0.canonical)) }.flatMap { $0.profiles.map { normalizeName($0.name) } })
        let unmatchedAttendees = expected.filter { name in
            let n = normalizeName(name)
            return !matchedNormalized.contains(n) && !aliasesOfMatched.contains(n)
        }
        if unmatchedAttendees.count == 1 {
            let unmatchedClusters = clusters.indices.filter { clusterName[$0] == nil }
            let best = unmatchedClusters
                .map { ci in (ci, clusters[ci].reduce(0) { $0 + (speakingTime[$1] ?? 0) }) }
                .max { $0.1 < $1.1 }
            if let (ci, time) = best, time > Self.inferenceMinSpeakingTime {
                let name = unmatchedAttendees[0]
                clusterName[ci] = name
                log("🎯 Inferred '\(name)' for cluster \(ci) (\(Int(time))s speaking)")
                if !profileStore.exists(name), !centroids[ci].isEmpty {
                    do {
                        try profileStore.save(VoiceProfile(name: name, embedding: centroids[ci]))
                        created.append(name)
                    } catch {
                        log("⚠️ Could not save inferred profile for \(name): \(error.localizedDescription)")
                    }
                }
            }
        }

        // Step 6: fallback + crosstalk filter.
        for (ci, members) in clusters.enumerated() {
            let name = clusterName[ci] ?? Self.unknown
            for id in members {
                var label = name
                if name != Self.unknown, let e = speakerEmbedding[id] {
                    let sim = embeddingProvider.similarity(e, centroids[ci])
                    if sim < Self.crosstalkSimilarity && (speakingTime[id] ?? 0) < Self.crosstalkMaxSpeakingTime {
                        label = Self.unknown
                    }
                }
                labels[id] = label
            }
        }
        for id in speakerIds where labels[id] == nil {
            labels[id] = Self.unknown
        }
        return Result(labels: labels, createdEmbeddings: created)
    }

    // MARK: - Algorithm pieces

    struct AliasGroup {
        var canonical: String
        var profiles: [VoiceProfile]
    }

    /// Group profiles with > 0.95 similarity as aliases. The canonical name is the one that
    /// appears earliest in `preferredOrder` (the attendee list), else the longest name.
    static func aliasGroups(_ profiles: [VoiceProfile], preferredOrder: [String], similarity: ([Float], [Float]) -> Float) -> [AliasGroup] {
        var groups: [[VoiceProfile]] = []
        for p in profiles {
            if let gi = groups.firstIndex(where: { g in g.contains { similarity($0.embedding, p.embedding) > aliasSimilarity } }) {
                groups[gi].append(p)
            } else {
                groups.append([p])
            }
        }
        let order = preferredOrder.map(normalizeName)
        return groups.map { g in
            let ranked = g.sorted { a, b in
                let ia = order.firstIndex(of: normalizeName(a.name)) ?? Int.max
                let ib = order.firstIndex(of: normalizeName(b.name)) ?? Int.max
                if ia != ib { return ia < ib }
                return a.name.count > b.name.count
            }
            let canonicalProfile = ranked[0]
            // Prefer the attendee's spelling for display.
            let display = preferredOrder.first { normalizeName($0) == normalizeName(canonicalProfile.name) } ?? canonicalProfile.name
            return AliasGroup(canonical: display, profiles: g)
        }
    }

    /// Average-linkage agglomerative clustering. Stops when `target` clusters remain or the
    /// best merge falls below `floor`.
    static func agglomerate(
        ids: [String], embeddings: [String: [Float]], target: Int, floor: Float,
        similarity: ([Float], [Float]) -> Float
    ) -> [[String]] {
        var clusters = ids.map { [$0] }
        func linkage(_ a: [String], _ b: [String]) -> Float {
            var total: Float = 0
            var n = 0
            for x in a { for y in b {
                if let ex = embeddings[x], let ey = embeddings[y] { total += similarity(ex, ey); n += 1 }
            } }
            return n > 0 ? total / Float(n) : -1
        }
        while clusters.count > target {
            var best: (Int, Int, Float)?
            for i in 0..<clusters.count {
                for j in (i + 1)..<clusters.count {
                    let s = linkage(clusters[i], clusters[j])
                    if best == nil || s > best!.2 { best = (i, j, s) }
                }
            }
            guard let (i, j, s) = best, s >= floor else { break }
            clusters[i].append(contentsOf: clusters[j])
            clusters.remove(at: j)
        }
        return clusters
    }

    /// Speaker changes are snapped to the largest pause between words within this window: the
    /// diarizer places changes on its processing-window grid, but people change at pauses.
    static let changeSnapWindow = 3.0
    static let minSnapPause = 0.15

    /// Assign speakers per word and split segments where the speaker changes, so a segment
    /// spanning two voices on the same channel is not given a single label. Falls back to
    /// segment-level assignment when the provider has no word timings.
    ///
    /// - Parameter samples16k: the channel's audio; used to measure real pauses between words
    ///   (ASR word timings are contiguous, so they carry no pause information).
    static func assign(output: TranscriptionOutput, turns: [SpeakerTurn], labels: [String: String], fallback: String, samples16k: [Float]? = nil) -> [LabeledSegment] {
        guard !output.words.isEmpty, !turns.isEmpty else {
            return assign(segments: output.segments, turns: turns, labels: labels, fallback: fallback)
        }
        let words = output.words.sorted { $0.start < $1.start }
        let pauses = samples16k.map { pausesBeforeWords(words, samples16k: $0) }
            ?? words.indices.map { $0 == 0 ? 0 : max(0, words[$0].start - words[$0 - 1].end) }
        var wordLabels = words.map { label(forStart: $0.start, end: $0.end, turns: turns, labels: labels, fallback: fallback) }

        // Smooth single-word flips between two words of the same speaker.
        if wordLabels.count >= 3 {
            for i in 1..<(wordLabels.count - 1) where wordLabels[i - 1] == wordLabels[i + 1] && wordLabels[i] != wordLabels[i - 1] {
                wordLabels[i] = wordLabels[i - 1]
            }
        }
        wordLabels = snapChanges(words: words, labels: wordLabels, pauses: pauses)

        // Segment boundaries: original ASR segment starts plus speaker changes.
        let segmentStarts = Set(output.segments.map { seg in
            words.firstIndex { ($0.start + $0.end) / 2 >= seg.start - 0.01 } ?? 0
        })
        var result: [LabeledSegment] = []
        var current = LabeledSegment(speaker: wordLabels[0], start: words[0].start, end: words[0].end, text: words[0].text)
        for i in 1..<words.count {
            if wordLabels[i] == current.speaker && !segmentStarts.contains(i) {
                current.text += words[i].text
                current.end = words[i].end
            } else {
                result.append(current.trimmed)
                current = LabeledSegment(speaker: wordLabels[i], start: words[i].start, end: words[i].end, text: words[i].text)
            }
        }
        result.append(current.trimmed)
        return result.filter { !$0.text.isEmpty }
    }

    /// Seconds of silence before each word, measured from audio energy in 20 ms frames between
    /// the previous word's start and this word's start.
    static func pausesBeforeWords(_ words: [TimedWord], samples16k: [Float]) -> [Double] {
        let frame = 320  // 20 ms at 16 kHz
        let frameCount = samples16k.count / frame
        guard frameCount > 0 else { return words.map { _ in 0 } }
        var rms = [Float](repeating: 0, count: frameCount)
        samples16k.withUnsafeBufferPointer { buf in
            for f in 0..<frameCount {
                var sum: Float = 0
                for k in (f * frame)..<((f + 1) * frame) { sum += buf[k] * buf[k] }
                rms[f] = (sum / Float(frame)).squareRoot()
            }
        }
        // Silence = 20 dB below loud speech (95th percentile frame).
        let sorted = rms.sorted()
        let loud = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        let threshold = max(loud * 0.1, 1e-4)
        let frameSeconds = Double(frame) / 16_000
        return words.indices.map { i in
            guard i > 0 else { return 0 }
            let lo = max(0, Int(words[i - 1].start / frameSeconds))
            let hi = min(frameCount, Int(words[i].start / frameSeconds))
            guard hi > lo else { return 0 }
            // Longest run of silent frames in the span (trailing pause after the previous word).
            var best = 0, run = 0
            for f in lo..<hi {
                if rms[f] < threshold { run += 1; best = max(best, run) } else { run = 0 }
            }
            return Double(best) * frameSeconds
        }
    }

    /// Move each label change to the largest pause before a word within ±`changeSnapWindow`.
    static func snapChanges(words: [TimedWord], labels: [String], pauses: [Double]) -> [String] {
        var labels = labels
        var i = 1
        while i < words.count {
            guard labels[i] != labels[i - 1] else { i += 1; continue }
            let changeTime = words[i].start
            // Only consider the stretch between the neighbouring changes.
            var lo = i
            while lo > 1 && labels[lo - 2] == labels[i - 1] && changeTime - words[lo - 1].start <= changeSnapWindow { lo -= 1 }
            var hi = i
            while hi + 1 < words.count && labels[hi + 1] == labels[i] && words[hi + 1].start - changeTime <= changeSnapWindow { hi += 1 }
            var best = i
            var bestGap = pauses[i]
            for j in lo...hi where j > 0 && pauses[j] > bestGap {
                bestGap = pauses[j]
                best = j
            }
            if best != i && bestGap >= minSnapPause {
                let before = labels[i - 1], after = labels[i]
                if best < i {
                    for k in best..<i { labels[k] = after }
                } else {
                    for k in i..<best { labels[k] = before }
                }
                i = max(best, i) + 1
            } else {
                i += 1
            }
        }
        return labels
    }

    private static func label(forStart start: Double, end: Double, turns: [SpeakerTurn], labels: [String: String], fallback: String) -> String {
        var bestId: String?
        var bestOverlap = 0.0
        for t in turns {
            let overlap = min(end, t.end) - max(start, t.start)
            if overlap > bestOverlap { bestOverlap = overlap; bestId = t.speakerId }
        }
        if bestId == nil {
            let mid = (start + end) / 2
            bestId = turns.min { abs(($0.start + $0.end) / 2 - mid) < abs(($1.start + $1.end) / 2 - mid) }?.speakerId
        }
        return bestId.flatMap { labels[$0] } ?? fallback
    }

    /// Assign each transcript segment the speaker id with the largest time overlap (nearest
    /// turn when nothing overlaps).
    static func assign(segments: [TranscriptSegment], turns: [SpeakerTurn], labels: [String: String], fallback: String) -> [LabeledSegment] {
        segments.map { seg in
            var bestId: String?
            var bestOverlap = 0.0
            for t in turns {
                let overlap = min(seg.end, t.end) - max(seg.start, t.start)
                if overlap > bestOverlap { bestOverlap = overlap; bestId = t.speakerId }
            }
            if bestId == nil {
                let mid = (seg.start + seg.end) / 2
                bestId = turns.min { abs(($0.start + $0.end) / 2 - mid) < abs(($1.start + $1.end) / 2 - mid) }?.speakerId
            }
            let label = bestId.flatMap { labels[$0] } ?? fallback
            return LabeledSegment(speaker: label, start: seg.start, end: seg.end, text: seg.text)
        }
    }
}

private extension LabeledSegment {
    var trimmed: LabeledSegment {
        var c = self
        c.text = c.text.trimmingCharacters(in: .whitespaces)
        return c
    }
}
