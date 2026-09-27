import Foundation

func testEdgeTTSVoices() {
    assert(EdgeTTSManager.Voice.allCases.count == 2, "Expected 2 Vietnamese voices")
    assert(EdgeTTSManager.Voice.hoaiMy.rawValue == "vi-VN-HoaiMyNeural", "HoaiMy ID mismatch")
    assert(EdgeTTSManager.Voice.namMinh.rawValue == "vi-VN-NamMinhNeural", "NamMinh ID mismatch")
    assert(EdgeTTSManager.Voice.hoaiMy.displayName == "Hoài My (Nữ)", "HoaiMy display name mismatch")
    assert(EdgeTTSManager.Voice.namMinh.displayName == "Nam Minh (Nam)", "NamMinh display name mismatch")
    print("  ok   voices enum and metadata verified")
}

func testEdgeTTSSynthesis() {
    let mgr = EdgeTTSManager.shared
    let sem = DispatchSemaphore(value: 0)
    var testResult: Result<URL, Error>?

    mgr.synthesize(text: "Kiểm tra chất lượng lồng tiếng Edge AI.", voice: .hoaiMy) { result in
        testResult = result
        sem.signal()
    }

    let waitResult = sem.wait(timeout: .now() + 6.0)
    assert(waitResult == .success, "Edge TTS synthesis timed out")

    switch testResult {
    case .success(let url):
        assert(FileManager.default.fileExists(atPath: url.path), "Synthesized file should exist")
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = attrs?[.size] as? UInt64 ?? 0
        assert(size > 500, "Synthesized MP3 file should be non-empty (was \(size) bytes)")
        print("  ok   synthesized Vietnamese speech with Edge TTS (\(size) bytes)")
    case .failure(let error):
        fatalError("Edge TTS synthesis failed: \(error.localizedDescription)")
    case .none:
        fatalError("No result received")
    }

    mgr.cleanupTempFiles()
}

func testEdgeTTSPrefetchAndCacheHit() {
    let mgr = EdgeTTSManager.shared
    let text = "Cảnh tiếp theo sẽ diễn ra rất nhanh."
    let sem1 = DispatchSemaphore(value: 0)

    // First synthesis (fills memory/disk cache)
    mgr.synthesize(text: text, voice: .hoaiMy) { _ in
        sem1.signal()
    }
    _ = sem1.wait(timeout: .now() + 8.0)

    // Second synthesis (hits instant cache)
    let sem2 = DispatchSemaphore(value: 0)
    let start = Date()
    var hitURL: URL?
    mgr.synthesize(text: text, voice: .hoaiMy) { result in
        if case .success(let url) = result {
            hitURL = url
        }
        sem2.signal()
    }

    _ = sem2.wait(timeout: .now() + 2.0)
    let elapsed = Date().timeIntervalSince(start)
    assert(hitURL != nil, "Cache hit synthesis should return a URL")
    assert(elapsed < 0.35, "Cache hit should return in < 350ms (took \(elapsed)s)")
    print("  ok   instant cache hit verified (\(String(format: "%.3f", elapsed))s)")

    let otherRate = DispatchSemaphore(value: 0)
    var otherRateURL: URL?
    mgr.synthesize(text: text, voice: .hoaiMy, rate: "+35%") { result in
        if case .success(let url) = result { otherRateURL = url }
        otherRate.signal()
    }
    assert(otherRate.wait(timeout: .now() + 8.0) == .success, "Different-rate synthesis timed out")
    assert(otherRateURL != nil && otherRateURL != hitURL, "Different speaking rates must not share cached audio")
    print("  ok   speaking rate is part of the audio cache key")

    mgr.cleanupTempFiles()
    mgr.terminateWorker()
}

func testConcurrentRequestsShareAudio() {
    let mgr = EdgeTTSManager.shared
    let text = "Hai yêu cầu cùng một câu phải dùng chung âm thanh."
    let first = DispatchSemaphore(value: 0)
    let second = DispatchSemaphore(value: 0)
    var firstURL: URL?
    var secondURL: URL?
    mgr.synthesize(text: text, voice: .hoaiMy, rate: "+24%") { result in
        if case .success(let url) = result { firstURL = url }
        first.signal()
    }
    mgr.synthesize(text: text, voice: .hoaiMy, rate: "+24%") { result in
        if case .success(let url) = result { secondURL = url }
        second.signal()
    }
    assert(first.wait(timeout: .now() + 8.0) == .success)
    assert(second.wait(timeout: .now() + 1.0) == .success)
    assert(firstURL != nil && firstURL == secondURL, "Concurrent prefetch and speech should share one MP3")
    print("  ok   concurrent requests share the in-flight MP3")
    mgr.cleanupTempFiles()
    mgr.terminateWorker()
}

print("edge-tts: unit tests")
testEdgeTTSVoices()
testEdgeTTSSynthesis()
testEdgeTTSPrefetchAndCacheHit()
testConcurrentRequestsShareAudio()
print("edge-tts scenarios passed")
exit(0)
