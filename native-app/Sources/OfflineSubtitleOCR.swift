import CoreGraphics
import Foundation
import Vision

/// Builds a timed subtitle track from captions burned into an HLS/MP4 picture.
/// ffmpeg decodes only a small bottom strip, so no full video copy is stored.
final class OfflineSubtitleOCR {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private let width = 960
    private let height = 160
    private let framesPerSecond = 2.0

    deinit { cancel() }

    enum ScanError: LocalizedError {
        case ffmpegMissing
        case decodeFailed
        case noSubtitles

        var errorDescription: String? {
            switch self {
            case .ffmpegMissing: return "Cần cài ffmpeg để đọc phụ đề gắn trong video"
            case .decodeFailed: return "Không đọc được khung hình từ nguồn video"
            case .noSubtitles: return "Không nhận diện được phụ đề trong video"
            }
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let running = process
        lock.unlock()
        if running?.isRunning == true { running?.terminate() }
    }

    func scan(url: URL, expectedDuration: Double,
              onProgress: @escaping (Double, Int, Int) -> Void,
              completion: @escaping (Result<[OfflineDubSession.Cue], Error>) -> Void) {
        guard let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            completion(.failure(ScanError.ffmpegMissing))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let duration = expectedDuration > 0 ? expectedDuration : (estimateDuration(of: url) ?? 0)
            let task = Process()
            task.executableURL = URL(fileURLWithPath: ffmpeg)
            task.arguments = ["-nostdin", "-hide_banner", "-loglevel", "error", "-i", url.absoluteString,
                              "-vf", "fps=2,crop=iw:ih*0.30:0:ih*0.70,scale=960:160,format=gray",
                              "-an", "-f", "rawvideo", "-pix_fmt", "gray", "pipe:1"]
            let output = Pipe()
            task.standardOutput = output
            task.standardError = FileHandle.nullDevice
            lock.lock()
            let stopped = cancelled
            if !stopped { process = task }
            lock.unlock()
            guard !stopped else { return }
            do { try task.run() } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }

            let frameBytes = width * height
            var frame = Data()
            var frameIndex = 0
            var cues: [OfflineDubSession.Cue] = []
            var activeText = ""
            var activeStart = 0.0
            var lastSeen = 0.0

            func finishActive(before nextStart: Double? = nil) {
                guard !activeText.isEmpty else { return }
                let naturalEnd = max(activeStart + 0.5, lastSeen + 0.5)
                let end = max(activeStart + 0.25, min(naturalEnd, nextStart ?? naturalEnd))
                cues.append(.init(start: activeStart, end: end, text: activeText))
                activeText = ""
            }

            while true {
                lock.lock()
                let shouldStop = cancelled
                lock.unlock()
                if shouldStop { break }
                while frame.count < frameBytes {
                    let chunk = output.fileHandleForReading.readData(ofLength: frameBytes - frame.count)
                    if chunk.isEmpty { break }
                    frame.append(chunk)
                }
                guard frame.count == frameBytes else { break }
                let time = Double(frameIndex) / framesPerSecond
                let text = recognize(frame)
                if let text {
                    if !activeText.isEmpty && SubtitleClassifier.isSameDisplayedCue(text, as: activeText) {
                        // Prefer the longer OCR reading when one frame drops a word.
                        if text.count > activeText.count { activeText = text }
                        lastSeen = time
                    } else {
                        finishActive(before: max(0, time - 0.25))
                        activeText = text
                        activeStart = max(0, time - 0.25)
                        lastSeen = time
                    }
                } else if !activeText.isEmpty && time - lastSeen > 1.0 {
                    finishActive()
                }
                frame.removeAll(keepingCapacity: true)
                frameIndex += 1
                if frameIndex % 4 == 0 {
                    let count = cues.count
                    DispatchQueue.main.async {
                        onProgress(time, count, duration > 0 ? Int(min(99, time / duration * 100)) : -1)
                    }
                }
            }
            finishActive()
            output.fileHandleForReading.closeFile()
            task.waitUntilExit()
            lock.lock()
            let wasCancelled = cancelled
            process = nil
            lock.unlock()
            guard !wasCancelled else { return }
            DispatchQueue.main.async {
                if frameIndex == 0 { completion(.failure(ScanError.decodeFailed)) }
                else if cues.isEmpty { completion(.failure(ScanError.noSubtitles)) }
                else { completion(.success(cues)) }
            }
        }
    }

    private func recognize(_ bytes: Data) -> String? {
        guard let provider = CGDataProvider(data: bytes as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                                  bitsPerPixel: 8, bytesPerRow: width,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["vi-VN", "en-US"]
        request.usesLanguageCorrection = true
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
            let hits = (request.results ?? []).compactMap { observation -> SubtitleTextHit? in
                guard let candidate = observation.topCandidates(1).first,
                      candidate.confidence >= 0.35 else { return nil }
                return SubtitleTextHit(text: candidate.string, box: observation.boundingBox)
            }
            return SubtitleClassifier.extractCleanSubtitle(from: hits)
        } catch {
            return nil
        }
    }

    private func estimateDuration(of url: URL) -> Double? {
        guard url.path.lowercased().hasSuffix(".m3u8") else { return nil }
        func get(_ address: URL) -> String? {
            var request = URLRequest(url: address)
            request.timeoutInterval = 8
            let signal = DispatchSemaphore(value: 0)
            var value: String?
            URLSession.shared.dataTask(with: request) { data, _, _ in
                if let data { value = String(data: data, encoding: .utf8) }
                signal.signal()
            }.resume()
            _ = signal.wait(timeout: .now() + 8)
            return value
        }
        guard let master = get(url) else { return nil }
        let nested = master.split(whereSeparator: \.isNewline)
            .map(String.init)
            .first { !$0.hasPrefix("#") && !$0.isEmpty && $0.contains(".m3u8") }
        let playlist: String
        if let nested, let variant = URL(string: nested, relativeTo: url)?.absoluteURL,
           variant.host == url.host, let data = get(variant) {
            playlist = data
        } else {
            playlist = master
        }
        let durations = playlist.split(whereSeparator: \.isNewline).compactMap { line -> Double? in
            guard line.hasPrefix("#EXTINF:") else { return nil }
            return Double(line.dropFirst(8).split(separator: ",").first ?? "")
        }
        return durations.isEmpty ? nil : durations.reduce(0, +)
    }
}
