import Foundation

/// DubbingTranslator provides high-throughput, low-latency translation of foreign
/// subtitle dialogue (English, etc.) into Vietnamese for Edge TTS movie dubbing.
/// Features in-memory caching and parallel batch translation.
public final class DubbingTranslator {
    public static let shared = DubbingTranslator()

    private var cache: [String: String] = [:]
    private var inFlight: [String: [(String) -> Void]] = [:]
    private let lock = NSLock()
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4.0
        config.timeoutIntervalForResource = 6.0
        self.session = URLSession(configuration: config)
    }

    private func normalizeKey(_ text: String) -> String {
        return text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public func cachedTranslation(for text: String) -> String? {
        let key = normalizeKey(text)
        lock.lock()
        defer { lock.unlock() }
        return cache[key]
    }

    public func translateToVietnamese(text: String, completion: @escaping (String) -> Void) {
        let clean = SubtitleClassifier.cleanSubtitleText(text)
        guard clean.count >= 2 else {
            completion(clean)
            return
        }

        // If dialogue is already authentic Vietnamese, return as-is
        if SubtitleClassifier.isLikelyVietnameseDialogue(clean) {
            completion(clean)
            return
        }

        let key = normalizeKey(clean)
        lock.lock()
        if let hit = cache[key] {
            lock.unlock()
            completion(hit)
            return
        }
        if inFlight[key] != nil {
            inFlight[key]?.append(completion)
            lock.unlock()
            return
        }
        inFlight[key] = [completion]
        lock.unlock()

        guard let url = translationURL(for: clean) else {
            finishTranslation(key: key, result: clean, shouldCache: false)
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")

        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self, let data = data, error == nil else {
                self?.finishTranslation(key: key, result: clean, shouldCache: false)
                return
            }

            if let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
               let sentences = json.first as? [[Any]] {
                let translated = sentences.compactMap { $0.first as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
                if !translated.isEmpty {
                    self.finishTranslation(key: key, result: translated, shouldCache: true)
                    return
                }
            }

            self.finishTranslation(key: key, result: clean, shouldCache: false)
        }
        task.resume()
    }

    public func translateBatch(texts: [String], completion: @escaping ([String: String]) -> Void) {
        guard !texts.isEmpty else { completion([:]); return }
        // Translating newline-joined cues can change or remove line boundaries,
        // assigning one character's dialogue to another cue. Keep each result keyed
        // to its own input while limiting concurrent requests.
        let group = DispatchGroup()
        let slots = DispatchSemaphore(value: 4)
        let resultLock = NSLock()
        var results: [String: String] = [:]

        DispatchQueue.global(qos: .userInitiated).async {
            for text in texts {
                slots.wait()
                group.enter()
                self.translateToVietnamese(text: text) { translated in
                    resultLock.lock()
                    results[text] = translated
                    resultLock.unlock()
                    slots.signal()
                    group.leave()
                }
            }
            group.notify(queue: .global(qos: .userInitiated)) {
                completion(results)
            }
        }
    }

    public func clearCache() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    private func translationURL(for text: String) -> URL? {
        var components = URLComponents(string: "https://translate.googleapis.com/translate_a/single")
        components?.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: "auto"),
            URLQueryItem(name: "tl", value: "vi"),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "q", value: text)
        ]
        return components?.url
    }

    private func finishTranslation(key: String, result: String, shouldCache: Bool) {
        lock.lock()
        if shouldCache { cache[key] = result }
        let callbacks = inFlight.removeValue(forKey: key) ?? []
        lock.unlock()
        for callback in callbacks { callback(result) }
    }
}
