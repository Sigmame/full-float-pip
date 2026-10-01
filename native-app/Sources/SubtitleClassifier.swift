import CoreGraphics
import Foundation

public struct SubtitleTextHit {
    public let text: String
    public let box: CGRect

    public init(text: String, box: CGRect) {
        self.text = text
        self.box = box
    }
}

public enum SubtitleClassifier {
    private static let viDiacritics: Set<Character> = Set(
        "àáảãạăắằẳẵặâấầẩẫậèéẻẽẹêếềểễệìíỉĩịòóỏõọôốồổỗộơớờởỡợùúủũụưứừửữựỳýỷỹỵđÀÁẢÃẠĂẮẰẲẴẶÂẤẦẨẪẬÈÉẺẼẸÊẾỀỂỄỆÌÍỈĨỊÒÓỎÕỌÔỐỒỔỖỘƠỚỜỞỠỢÙÚỦŨỤƯỨỪỬỮỰỲÝỶỸỴĐ"
    )

    private static let englishStopWords: Set<String> = [
        "the", "and", "of", "to", "in", "is", "you", "that", "it", "he", "was", "for", "on", "are", "as", "with",
        "his", "they", "at", "be", "this", "from", "have", "or", "by", "one", "had", "not", "but", "what", "all",
        "were", "when", "we", "there", "can", "an", "your", "which", "their", "if", "do", "will", "each", "about",
        "how", "up", "out", "them", "then", "she", "many", "some", "so", "these", "would", "other", "into", "has",
        "more", "her", "like", "him", "see", "time", "could", "no", "make", "than", "first", "been", "its", "who",
        "now", "people", "my", "over", "did", "down", "only", "way", "find", "use", "may", "water", "long", "little",
        "very", "after", "words", "just", "where", "most", "get", "through", "back", "much", "go", "good", "new",
        "write", "our", "me", "too", "any", "day", "same", "right", "look", "think", "also", "around", "another",
        "came", "come", "work", "three", "must", "because", "does", "part", "even", "place", "well", "such", "here",
        "take", "why", "help", "put", "away", "again", "off", "went", "old", "great", "tell", "say", "small", "every",
        "found", "still", "between", "name", "should", "home", "big", "give", "air", "line", "set", "own", "under",
        "read", "last", "never", "us", "left", "end", "while", "might", "next", "sound", "below", "saw", "something",
        "thought", "both", "few", "those", "always", "show", "large", "often", "together", "asked", "house", "world",
        "going", "want", "school", "until", "quiet", "isolation", "drifts", "rhythms", "college", "secrets",
        "shifting", "circle", "classmates", "bleed", "nights", "subtle", "academia", "entangled", "lives",
        "kindle", "rate", "book", "edition", "chapter", "synopsis", "review", "rating"
    ]

    private static let commonViWords: Set<String> = [
        "anh", "em", "toi", "ta", "minh", "ong", "ba", "co", "chu", "bac", "con", "chau",
        "khong", "co", "la", "mot", "hai", "ba", "bon", "nam", "nguoi", "nay", "trong",
        "da", "duoc", "cho", "voi", "cua", "gi", "sao", "the", "nhung", "phai", "biet",
        "di", "ve", "o", "ra", "len", "xuong", "lai", "ma", "thi", "neu", "vi", "nen",
        "hay", "dung", "chua", "se", "dang", "cung", "de", "roi", "ca", "den", "dau",
        "muon", "thay", "noi", "nghe", "lam", "ay", "day", "gio", "luc", "viec", "chuyen",
        "nha", "tien", "troi", "song", "chet", "ai", "nao", "dau", "kia", "do", "qua"
    ]

    private static let adKeywords: [String] = [
        "kindle", "rate this book", "goodreads", "amazon", "shopee", "lazada", "tiki",
        "want to read", "chapter", "edition", "subscription", "price", "review",
        "rating", "sign in", "subscribe", "subtitles by", "kkphim", "ophim", "nguonc",
        "phimmoi", "phimapi", "resume", "loading", "tiếp tục xem", "bạn đang xem dở"
    ]

    public static func isSubtitleBoundingBox(_ box: CGRect) -> Bool {
        // Horizontally: center of text must be between 15% and 85% of strip width
        let midX = box.origin.x + box.width / 2.0
        guard midX >= 0.15 && midX <= 0.85 else { return false }
        // Vertically: text in bottom strip must sit in lower 78% (0 is bottom, 1 is top in Vision)
        guard box.origin.y <= 0.78 else { return false }
        // Height: a single subtitle line shouldn't take more than 45% of the strip height
        guard box.height <= 0.45 else { return false }
        return true
    }

    public static func cleanSubtitleText(_ raw: String) -> String {
        return raw
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\[[^\\]]+\\]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\([^\\)]+\\)", with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^[A-Z0-9\s_-]+:\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^["'“”—\-\s]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"["'”\s]+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func isLikelyVietnameseDialogue(_ text: String) -> Bool {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count >= 2, clean.count <= 220 else { return false }

        // Reject currency, price patterns, star ratings, URLs, domains
        if clean.range(of: #"[\$€£¥]|\b\d+\.\d{2}\b|\*{3,}|https?://|\.com\b|\.net\b|\.vn\b|www\."#,
                       options: [.regularExpression, .caseInsensitive]) != nil {
            return false
        }

        let lower = clean.lowercased()
        for kw in adKeywords {
            if lower.contains(kw) { return false }
        }

        // Extract letter sequences (words)
        let words = lower.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        guard !words.isEmpty else { return false }

        // Reject if English words dominate
        let enCount = words.filter { englishStopWords.contains($0) }.count
        if enCount >= 2 && (Double(enCount) / Double(words.count)) >= 0.20 {
            return false
        }

        // Must have Vietnamese diacritics or common Vietnamese syllables
        let hasDiacritics = clean.contains { viDiacritics.contains($0) }
        let viWordCount = words.filter { commonViWords.contains($0) }.count

        if !hasDiacritics && viWordCount == 0 {
            return false
        }

        return true
    }

    public static func extractCleanSubtitle(from hits: [SubtitleTextHit]) -> String? {
        let filtered = hits.filter { hit in
            let clean = hit.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard clean.count >= 2 else { return false }
            guard !AdClassifier.mentionsBrand(clean) else { return false }
            if clean.range(of: #"^\d{1,2}:\d{2}"#, options: .regularExpression) != nil { return false }
            let lower = clean.lowercased()
            if lower.contains("kkphim") || lower.contains("ophim") || lower.contains("nguonc") { return false }
            if clean.range(of: #"[\$€£¥]|\b\d+\.\d{2}\b|\*{3,}"#, options: .regularExpression) != nil { return false }
            for kw in adKeywords {
                if lower.contains(kw) { return false }
            }
            guard isSubtitleBoundingBox(hit.box) else { return false }
            return true
        }

        guard !filtered.isEmpty else { return nil }

        // Max 3 lines for a subtitle cue (more lines indicate a paragraph/synopsis/card)
        guard filtered.count <= 3 else { return nil }

        // Sort lines top-to-bottom
        let sorted = filtered.sorted(by: { $0.box.origin.y > $1.box.origin.y })
        let combined = sorted.map(\.text).joined(separator: " ")
        let clean = cleanSubtitleText(combined)

        guard isLikelyVietnameseDialogue(clean) else { return nil }
        return clean
    }

    public static func normalizedForDubbing(_ str: String) -> String {
        return str
            .replacingOccurrences(of: "đ", with: "d")
            .replacingOccurrences(of: "Đ", with: "d")
            .folding(options: .diacriticInsensitive, locale: Locale(identifier: "vi"))
            .lowercased()
            .replacingOccurrences(of: #"[^\w\s]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Computes Levenshtein similarity ratio [0.0 ... 1.0] between two strings.
    public static func similarity(_ s1: String, _ s2: String) -> Double {
        if s1 == s2 { return 1.0 }
        let c1 = Array(s1)
        let c2 = Array(s2)
        let n = c1.count
        let m = c2.count
        guard n > 0 && m > 0 else { return 0.0 }
        if abs(n - m) > max(n, m) / 2 { return 0.0 }

        var prev = Array(0...m)
        var curr = Array(repeating: 0, count: m + 1)

        for i in 1...n {
            curr[0] = i
            for j in 1...m {
                let cost = c1[i - 1] == c2[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            prev = curr
        }

        let dist = Double(prev[m])
        let maxLen = Double(max(n, m))
        return max(0.0, 1.0 - (dist / maxLen))
    }

    /// Checks if a candidate subtitle is essentially the same as previously dubbed dialogue.
    public static func isNearDuplicate(_ newText: String, of previousText: String, threshold: Double = 0.82) -> Bool {
        let n1 = normalizedForDubbing(newText)
        let n2 = normalizedForDubbing(previousText)
        if n1.isEmpty || n2.isEmpty { return false }
        if n1 == n2 { return true }
        if n1.contains(n2) || n2.contains(n1) {
            let minLen = min(n1.count, n2.count)
            let maxLen = max(n1.count, n2.count)
            if Double(minLen) / Double(maxLen) >= 0.50 { return true }
        }
        // Word overlap check (Jaccard similarity on meaningful words)
        let w1 = Set(n1.components(separatedBy: " ").filter { $0.count >= 2 })
        let w2 = Set(n2.components(separatedBy: " ").filter { $0.count >= 2 })
        let common = w1.intersection(w2)
        if !w1.isEmpty && !w2.isEmpty {
            let overlapRatio = Double(common.count) / Double(min(w1.count, w2.count))
            if overlapRatio >= 0.55 && common.count >= 2 { return true }
        }
        return similarity(n1, n2) >= threshold
    }

    /// OCR frames may differ by a character, but a new sentence must remain a
    /// new cue even when it repeats most words from the preceding sentence.
    public static func isSameDisplayedCue(_ text: String, as previous: String) -> Bool {
        let a = normalizedForDubbing(text)
        let b = normalizedForDubbing(previous)
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        let lengthRatio = Double(min(a.count, b.count)) / Double(max(a.count, b.count))
        return lengthRatio >= 0.85 && similarity(a, b) >= 0.92
    }
}

/// Thread-safe sliding-window history tracker to prevent duplicate, repeating,
/// or partial dialogue lines from multiple triggers (frames, cues, DOM mutations, OCR).
public final class SubtitleDeduplicator {
    public struct Entry {
        public let text: String
        public let normalized: String
        public let timestamp: Date
    }

    private var history: [Entry] = []
    private let lock = NSLock()
    public let windowSeconds: Double

    public init(windowSeconds: Double = 10.0) {
        self.windowSeconds = windowSeconds
    }

    /// Evaluates candidate text against the sliding window. Returns true if the text
    /// is new and should be dubbed (and automatically records it in history).
    /// Returns false if it is an exact, normalized, or near-duplicate of recent speech.
    public func shouldDub(text: String, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let clean = SubtitleClassifier.cleanSubtitleText(text)
        guard clean.count >= 2, SubtitleClassifier.isLikelyVietnameseDialogue(clean) else {
            return false
        }

        let norm = SubtitleClassifier.normalizedForDubbing(clean)
        guard !norm.isEmpty else { return false }

        // Prune entries older than the deduplication window
        history.removeAll { now.timeIntervalSince($0.timestamp) > windowSeconds }

        for entry in history {
            // 1. Exact or normalized match within window
            if clean == entry.text || norm == entry.normalized {
                return false
            }

            // 2. High similarity or near-duplicate within 7.5 seconds
            let age = now.timeIntervalSince(entry.timestamp)
            if age < 7.5 {
                if SubtitleClassifier.isNearDuplicate(clean, of: entry.text, threshold: 0.78) {
                    return false
                }
                // 3. Bi-directional substring check: if new text is a substring/prefix or superstring
                if entry.normalized.contains(norm) || norm.contains(entry.normalized) {
                    let minLen = min(norm.count, entry.normalized.count)
                    let maxLen = max(norm.count, entry.normalized.count)
                    if Double(minLen) / Double(maxLen) >= 0.50 {
                        return false
                    }
                }
                // 4. Consecutive frame burst cooldown: if spoken under 2.0s ago and shares >= 2 words
                if age < 2.0 {
                    let w1 = Set(norm.components(separatedBy: " ").filter { $0.count >= 2 })
                    let w2 = Set(entry.normalized.components(separatedBy: " ").filter { $0.count >= 2 })
                    if w1.intersection(w2).count >= 2 {
                        return false
                    }
                }
            }
        }

        history.append(Entry(text: clean, normalized: norm, timestamp: now))
        return true
    }

    public func isDuplicate(text: String, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let clean = SubtitleClassifier.cleanSubtitleText(text)
        guard clean.count >= 2 else { return true }
        let norm = SubtitleClassifier.normalizedForDubbing(clean)
        guard !norm.isEmpty else { return true }

        history.removeAll { now.timeIntervalSince($0.timestamp) > windowSeconds }

        for entry in history {
            if clean == entry.text || norm == entry.normalized {
                return true
            }
            let age = now.timeIntervalSince(entry.timestamp)
            if age < 7.5 {
                if SubtitleClassifier.isNearDuplicate(clean, of: entry.text, threshold: 0.80) {
                    return true
                }
                if entry.normalized.contains(norm) && norm.count <= entry.normalized.count {
                    return true
                }
            }
        }
        return false
    }

    public func record(text: String, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        let clean = SubtitleClassifier.cleanSubtitleText(text)
        guard clean.count >= 2 else { return }
        let norm = SubtitleClassifier.normalizedForDubbing(clean)
        history.append(Entry(text: clean, normalized: norm, timestamp: now))
    }

    public func reset() {
        lock.lock()
        history.removeAll()
        lock.unlock()
    }
}
