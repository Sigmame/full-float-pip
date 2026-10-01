import AVFoundation
import QuartzCore
import Foundation

/// Pre-renders subtitle cues and schedules the resulting audio beside the video.
/// The video remains the source of truth for seeking; audio players are rebuilt
/// whenever the video clock moves so a seek can never leave stale speech behind.
final class OfflineDubSession {
    typealias Translator = (String, @escaping (String) -> Void) -> Void
    typealias Synthesizer = (String, String, Double, @escaping (Result<URL, Error>) -> Void) -> Void
    typealias LocalSynthesizer = (String, @escaping (Result<URL, Error>) -> Void) -> Void

    struct Progress {
        let translated: Int
        let rendered: Int
        let failed: Int
        let fallback: Int
        let total: Int

        init(translated: Int, rendered: Int, failed: Int, total: Int, fallback: Int = 0) {
            self.translated = translated
            self.rendered = rendered
            self.failed = failed
            self.total = total
            self.fallback = fallback
        }

        var fraction: Double {
            guard total > 0 else { return 0 }
            let completed = Double(translated + rendered) / Double(total * 2)
            // 100% means the dub is playable, never merely that every request
            // returned (possibly with an error).
            return failed > 0 ? min(0.99, completed) : completed
        }
    }

    struct Cue: Sendable {
        let start: Double
        let end: Double
        let text: String
    }

    private struct PreparedCue {
        let start: Double
        let end: Double
        let url: URL
    }

    private var prepared: [PreparedCue] = []
    private var optimizedFiles: Set<URL> = []
    private var fallbackFiles: Set<URL> = []
    private var player: AVAudioPlayer?
    private var playbackTimer: Timer?
    private var nextCueIndex = 0
    private var seekCueIndex: Int?
    private var clockTime = 0.0
    private var clockUptime = 0.0
    private var videoRate = 1.0
    private var generation = 0
    private var isPlaying = false
    private var currentTime = 0.0
    private var preparing = false
    private var expectedCueCount = 0
    private let translate: Translator
    private let render: Synthesizer
    private let localRender: LocalSynthesizer
    private(set) var fallbackCount = 0
    var onCueStarted: ((Double) -> Void)?

    init(translate: @escaping Translator = { DubbingTranslator.shared.translateToVietnamese(text: $0, completion: $1) },
         render: @escaping Synthesizer = { text, rate, timeout, completion in
             EdgeTTSManager.shared.synthesize(text: text, rate: rate, timeoutSeconds: timeout,
                                              completion: completion)
         },
         localRender: @escaping LocalSynthesizer = OfflineDubSession.synthesizeLocally) {
        self.translate = translate
        self.render = render
        self.localRender = localRender
    }

    var isReady: Bool { expectedCueCount > 0 && prepared.count == expectedCueCount && !preparing }
    var cueCount: Int { prepared.count }

    func prepare(cues: [Cue], onProgress: ((Progress) -> Void)? = nil,
                 completion: @escaping (Result<Int, Error>) -> Void) {
        stop()
        generation += 1
        let token = generation
        prepared.removeAll()
        preparing = true
        let unique = cues
            .filter { $0.end > $0.start && $0.text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 }
            .sorted { $0.start < $1.start }
        expectedCueCount = unique.count
        guard !unique.isEmpty else {
            preparing = false
            completion(.success(0))
            return
        }

        var results: [PreparedCue] = []
        var firstError: Error?
        var translatedCount = 0
        var renderedCount = 0
        var failedCount = 0
        var consecutiveFailures = 0
        var nextIndex = 0
        var inFlight = 0
        let maxConcurrent = 4
        let maxAttempts = 3

        func publishProgress() {
            onProgress?(Progress(translated: translatedCount, rendered: renderedCount,
                                 failed: failedCount, total: unique.count,
                                 fallback: fallbackCount))
        }

        func fail(_ error: Error) {
            guard generation == token else { return }
            generation += 1
            preparing = false
            prepared.removeAll()
            cleanupOptimizedFiles()
            cleanupFallbackFiles()
            expectedCueCount = 0
            completion(.failure(error))
        }

        func finishRender(_ result: Result<URL, Error>, cue: Cue, usedFallback: Bool = false) {
            guard generation == token else { return }
            switch result {
            case .success(let url):
                results.append(PreparedCue(start: cue.start, end: cue.end, url: url))
                if usedFallback { fallbackCount += 1 }
                consecutiveFailures = 0
            case .failure(let error):
                firstError = firstError ?? error
                failedCount += 1
                consecutiveFailures += 1
                NSLog("[OfflineDub] TTS failed after %d attempts: %@", maxAttempts, error.localizedDescription)
            }
            renderedCount += 1
            inFlight -= 1
            publishProgress()
            if consecutiveFailures >= 8 {
                let message = "TTS lỗi liên tiếp; đã tạo \(results.count)/\(unique.count) câu. \(firstError?.localizedDescription ?? "")"
                fail(NSError(domain: "OfflineDub", code: -1,
                             userInfo: [NSLocalizedDescriptionKey: message]))
            } else if renderedCount == unique.count {
                preparing = false
                prepared = results.sorted { $0.start < $1.start }
                if failedCount > 0 {
                    let message = "Chỉ tạo được \(results.count)/\(unique.count) câu; \(failedCount) câu lỗi. \(firstError?.localizedDescription ?? "")"
                    prepared.removeAll()
                    expectedCueCount = 0
                    cleanupOptimizedFiles()
                    cleanupFallbackFiles()
                    completion(.failure(NSError(domain: "OfflineDub", code: -2,
                                                userInfo: [NSLocalizedDescriptionKey: message])))
                } else {
                    completion(.success(prepared.count))
                    if isPlaying { schedule(from: currentTime) }
                }
            } else {
                pump()
            }
        }

        func synthesize(_ text: String, cue: Cue, slot: Double, attempt: Int) {
            render(text, EdgeTTSManager.calculateSubtitleRate(text: text, duration: slot), 30) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self, self.generation == token else { return }
                    if case .failure(let error) = result, attempt < maxAttempts {
                        if attempt == 1 {
                            NSLog("[OfflineDub] TTS retry: %@", error.localizedDescription)
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + Double(attempt)) {
                            guard self.generation == token else { return }
                            synthesize(text, cue: cue, slot: slot, attempt: attempt + 1)
                        }
                        return
                    }
                    if case .success(let url) = result {
                        self.fitAudio(url, into: slot, generation: token) { fitted in
                            finishRender(.success(fitted), cue: cue)
                        }
                    } else {
                        self.localRender(text) { localResult in
                            DispatchQueue.main.async {
                                guard self.generation == token else { return }
                                switch localResult {
                                case .success(let url):
                                    self.fallbackFiles.insert(url)
                                    self.fitAudio(url, into: slot, generation: token) { fitted in
                                        finishRender(.success(fitted), cue: cue, usedFallback: true)
                                    }
                                case .failure(let localError):
                                    NSLog("[OfflineDub] Local voice failed: %@", localError.localizedDescription)
                                    finishRender(result, cue: cue)
                                }
                            }
                        }
                    }
                }
            }
        }

        func pump() {
            guard generation == token else { return }
            while inFlight < maxConcurrent && nextIndex < unique.count {
                let cueIndex = nextIndex
                let cue = unique[cueIndex]
                nextIndex += 1
                inFlight += 1
                let nextStart = cueIndex + 1 < unique.count ? unique[cueIndex + 1].start : cue.end
                let slot = max(0.15, min(cue.end, nextStart) - cue.start)
                translate(cue.text) { [weak self] translated in
                    DispatchQueue.main.async {
                        guard let self, self.generation == token else { return }
                        translatedCount += 1
                        publishProgress()
                        synthesize(translated, cue: cue, slot: slot, attempt: 1)
                    }
                }
            }
        }

        pump()
    }

    func update(videoTime: Double, playing: Bool, rate: Double = 1.0) {
        let now = CACurrentMediaTime()
        let predicted = clockTime + max(0, now - clockUptime) * videoRate
        let jumped = isPlaying && abs(videoTime - predicted) > 0.65
        let rateChanged = abs(rate - videoRate) > 0.01
        currentTime = videoTime
        clockTime = videoTime
        clockUptime = now
        videoRate = max(0.1, rate)
        if playing != isPlaying || jumped || rateChanged {
            isPlaying = playing
            if playing { schedule(from: videoTime) } else { stopPlayers() }
        }
    }

    func stop() {
        generation += 1
        preparing = false
        isPlaying = false
        stopPlayers()
        prepared.removeAll()
        cleanupOptimizedFiles()
        cleanupFallbackFiles()
        fallbackCount = 0
        expectedCueCount = 0
    }

    private func cleanupFallbackFiles() {
        fallbackFiles.forEach { try? FileManager.default.removeItem(at: $0) }
        fallbackFiles.removeAll()
    }

    private static func synthesizeLocally(_ text: String,
                                          completion: @escaping (Result<URL, Error>) -> Void) {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("float-dub-local-\(UUID().uuidString).aiff")
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            task.arguments = ["-v", "Linh", "-o", output.path]
            let input = Pipe()
            task.standardInput = input
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            var succeeded = false
            do {
                try task.run()
                input.fileHandleForWriting.write(Data(text.utf8))
                try? input.fileHandleForWriting.close()
                task.waitUntilExit()
                succeeded = task.terminationStatus == 0
            } catch {
                NSLog("[OfflineDub] Local voice launch failed: %@", error.localizedDescription)
            }
            DispatchQueue.main.async {
                if succeeded, let audio = try? AVAudioPlayer(contentsOf: output), audio.duration > 0 {
                    completion(.success(output))
                } else {
                    try? FileManager.default.removeItem(at: output)
                    completion(.failure(NSError(domain: "OfflineDub", code: -3,
                                                userInfo: [NSLocalizedDescriptionKey: "Giọng Việt trên máy không tạo được audio"])))
                }
            }
        }
    }

    private func cleanupOptimizedFiles() {
        optimizedFiles.forEach { try? FileManager.default.removeItem(at: $0) }
        optimizedFiles.removeAll()
    }

    private func fitAudio(_ source: URL, into slot: Double, generation token: Int,
                          completion: @escaping (URL) -> Void) {
        guard let original = try? AVAudioPlayer(contentsOf: source), original.duration > 0 else {
            completion(source)
            return
        }
        // AVAudioPlayer can speed up by at most 2x. Pre-stretch only the lines
        // that need more room, keeping the pitch stable with ffmpeg's atempo.
        let tempo = min(2.0, original.duration / max(0.15, slot) / 2.0 * 1.05)
        guard tempo > 1.05,
              let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
                .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            completion(source)
            return
        }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("float-dub-\(UUID().uuidString).m4a")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: ffmpeg)
            task.arguments = ["-nostdin", "-hide_banner", "-loglevel", "error", "-y",
                              "-i", source.path, "-vn", "-af", "atempo=\(tempo)",
                              "-c:a", "aac", "-b:a", "96k", output.path]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            var succeeded = false
            do {
                try task.run()
                task.waitUntilExit()
                succeeded = task.terminationStatus == 0
            } catch {
                NSLog("[OfflineDub] Could not fit audio: %@", error.localizedDescription)
            }
            DispatchQueue.main.async {
                guard let self, self.generation == token else {
                    try? FileManager.default.removeItem(at: output)
                    return
                }
                if succeeded, let fitted = try? AVAudioPlayer(contentsOf: output), fitted.duration > 0 {
                    self.optimizedFiles.insert(output)
                    completion(output)
                } else {
                    try? FileManager.default.removeItem(at: output)
                    completion(source)
                }
            }
        }
    }

    private func stopPlayers() {
        playbackTimer?.invalidate()
        playbackTimer = nil
        player?.stop()
        player = nil
    }

    private func schedule(from time: Double) {
        guard isPlaying, !prepared.isEmpty else { return }
        stopPlayers()
        nextCueIndex = prepared.firstIndex(where: { $0.end > time }) ?? prepared.count
        seekCueIndex = nextCueIndex
        playbackTimer = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in self?.tick() }
        if let playbackTimer { RunLoop.main.add(playbackTimer, forMode: .common) }
        tick()
    }

    private func tick() {
        guard isPlaying, nextCueIndex < prepared.count else {
            if player?.isPlaying == false {
                player = nil
                playbackTimer?.invalidate()
                playbackTimer = nil
            }
            return
        }
        let mediaTime = clockTime + max(0, CACurrentMediaTime() - clockUptime) * videoRate
        if let player, player.isPlaying {
            let nextStart = prepared[nextCueIndex].start
            let remaining = max(0, player.duration - player.currentTime) / Double(player.rate)
            // Decoder padding can keep a player "playing" after the words have
            // ended. Let the next caption take its slot when only a tail remains.
            guard mediaTime >= nextStart && remaining <= 0.05 else { return }
            player.stop()
        }
        player = nil
        // Keep a short backlog when two spoken lines cannot both fit their
        // caption windows. A long backlog would make every later line stale.
        while nextCueIndex < prepared.count && prepared[nextCueIndex].end + 1.5 < mediaTime {
            nextCueIndex += 1
        }
        guard nextCueIndex < prepared.count else { return }
        let cue = prepared[nextCueIndex]
        guard cue.start <= mediaTime + 0.02 else { return }
        nextCueIndex += 1
        do {
            let nextStart = nextCueIndex < prepared.count ? prepared[nextCueIndex].start : cue.end
            let slot = max(0.1, min(cue.end, nextStart) - max(cue.start, mediaTime)) / videoRate
            let audio = try AVAudioPlayer(contentsOf: cue.url)
            audio.enableRate = true
            audio.rate = Float(min(2.0, max(1.0, audio.duration / slot)))
            audio.volume = 1
            audio.prepareToPlay()
            // A seek into a cue resumes at the corresponding point in its speech.
            if seekCueIndex == nextCueIndex - 1 && mediaTime > cue.start && mediaTime < cue.end {
                let progress = min(0.99, (mediaTime - cue.start) / max(0.1, cue.end - cue.start))
                audio.currentTime = audio.duration * progress
            }
            guard audio.play() else {
                NSLog("[OfflineDub] Could not start audio cue %.3fs", cue.start)
                return
            }
            player = audio
            seekCueIndex = nil
            onCueStarted?(cue.start)
            if ProcessInfo.processInfo.environment["VIBEFLOAT_DUB_DEBUG"] == "1" {
                NSLog("[OfflineDub] audio scheduled cue %.3fs at %.3fs rate %.2f", cue.start, mediaTime, audio.rate)
            }
        } catch {
            NSLog("[OfflineDub] Could not load audio cue: %@", error.localizedDescription)
        }
    }
}
