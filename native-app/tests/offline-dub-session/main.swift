import Foundation

func waitFor(_ done: @autoclosure () -> Bool, timeout: TimeInterval = 12) {
    let deadline = Date().addingTimeInterval(timeout)
    while !done() && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    precondition(done(), "Offline Dub test timed out")
}

let cues = (0..<40).map { index in
    OfflineDubSession.Cue(start: Double(index), end: Double(index) + 0.8, text: "Câu số \(index)")
}
var active = 0
var peak = 0
var completed: Result<Int, Error>?
let session = OfflineDubSession(translate: { text, reply in reply(text) },
                                render: { _, _, _, reply in
    active += 1
    peak = max(peak, active)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) {
        active -= 1
        reply(.success(URL(fileURLWithPath: "/tmp/offline-dub-fixture.mp3")))
    }
})
session.prepare(cues: cues, completion: { completed = $0 })
waitFor(completed != nil)
if case .success(let count) = completed {
    precondition(count == 40 && session.isReady && peak == 4,
                 "Expected all cues rendered with at most four simultaneous requests")
} else {
    fatalError("Expected successful preparation")
}
print("offline dub bounded concurrency: passed")

var attempts = 0
var failedResult: Result<Int, Error>?
let failing = OfflineDubSession(translate: { text, reply in reply(text) },
                                render: { _, _, _, reply in
    attempts += 1
    reply(.failure(NSError(domain: "MockTTS", code: 1,
                           userInfo: [NSLocalizedDescriptionKey: "temporary failure"])))
}, localRender: { _, reply in
    reply(.failure(NSError(domain: "MockLocalVoice", code: 1)))
})
failing.prepare(cues: Array(cues.prefix(3)), completion: { failedResult = $0 })
waitFor(failedResult != nil)
if case .failure(let error) = failedResult {
    precondition(!failing.isReady && failing.cueCount == 0 && attempts == 9,
                 "Partial render must never become playable")
    precondition(error.localizedDescription.contains("0/3"), error.localizedDescription)
    precondition(OfflineDubSession.Progress(translated: 3, rendered: 3, failed: 3, total: 3).fraction < 1,
                 "Failed cues must never display 100%")
} else {
    fatalError("Expected preparation failure")
}
print("offline dub partial failure: passed")

// Three adjacent captions each have longer speech than their individual slot.
// The session must play all three in order without starting another voice on
// top of the one that is still speaking.
func appendLE<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var value = value.littleEndian
    withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
}
let sampleRate = 8_000
let sampleCount = sampleRate * 7 / 10
let byteCount = sampleCount * 2
var wav = Data("RIFF".utf8)
appendLE(UInt32(36 + byteCount), to: &wav)
wav.append(Data("WAVEfmt ".utf8))
appendLE(UInt32(16), to: &wav)
appendLE(UInt16(1), to: &wav)
appendLE(UInt16(1), to: &wav)
appendLE(UInt32(sampleRate), to: &wav)
appendLE(UInt32(sampleRate * 2), to: &wav)
appendLE(UInt16(2), to: &wav)
appendLE(UInt16(16), to: &wav)
wav.append(Data("data".utf8))
appendLE(UInt32(byteCount), to: &wav)
for i in 0..<sampleCount {
    let value = Int16(sin(Double(i) * 2 * .pi * 440 / Double(sampleRate)) * 1_000)
    appendLE(value, to: &wav)
}
let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
try wav.write(to: audioURL)
defer { try? FileManager.default.removeItem(at: audioURL) }
var fallbackReady: Result<Int, Error>?
var remoteAttempts = 0
var localAttempts = 0
var lastProgress: OfflineDubSession.Progress?
let recovered = OfflineDubSession(translate: { text, reply in reply(text) },
                                  render: { _, _, _, reply in
    remoteAttempts += 1
    reply(.failure(NSError(domain: "MockTTS", code: 1)))
}, localRender: { _, reply in
    localAttempts += 1
    reply(.success(audioURL))
})
recovered.prepare(cues: Array(cues.prefix(1)), onProgress: { lastProgress = $0 },
                  completion: { fallbackReady = $0 })
waitFor(fallbackReady != nil)
if case .success(let count) = fallbackReady {
    precondition(count == 1 && recovered.isReady && recovered.fallbackCount == 1)
    precondition(remoteAttempts == 3 && localAttempts == 1 && lastProgress?.fallback == 1)
} else {
    fatalError("Local Vietnamese voice should recover a failed Edge cue")
}
print("offline dub local voice recovery: passed")

let largeCues = (0..<1487).map { index in
    OfflineDubSession.Cue(start: Double(index), end: Double(index) + 0.8,
                          text: "Câu số \(index)")
}
let missing = Set((0..<24).map { $0 * 61 })
var largeResult: Result<Int, Error>?
let large = OfflineDubSession(translate: { text, reply in reply(text) },
                              render: { text, _, _, reply in
    let number = Int(text.split(separator: " ").last ?? "") ?? -1
    if missing.contains(number) {
        reply(.failure(NSError(domain: "MockTTS", code: 1)))
    } else {
        reply(.success(audioURL))
    }
}, localRender: { _, reply in reply(.success(audioURL)) })
large.prepare(cues: largeCues, completion: { largeResult = $0 })
waitFor(largeResult != nil, timeout: 30)
if case .success(let count) = largeResult {
    precondition(count == 1487 && large.isReady && large.fallbackCount == 24,
                 "A large dub with 24 Edge failures must still be fully playable")
} else {
    fatalError("Large dub should recover every failed cue")
}
print("offline dub 1487 cues with 24 recoveries: passed")

var realLocalResult: Result<Int, Error>?
let realLocal = OfflineDubSession(translate: { text, reply in reply(text) },
                                  render: { _, _, _, reply in
    reply(.failure(NSError(domain: "MockTTS", code: 1)))
})
realLocal.prepare(cues: [.init(start: 0, end: 2, text: "Xin chào, đây là giọng Việt dự phòng.")],
                  completion: { realLocalResult = $0 })
waitFor(realLocalResult != nil, timeout: 15)
if case .success(let count) = realLocalResult {
    precondition(count == 1 && realLocal.isReady && realLocal.fallbackCount == 1,
                 "macOS Vietnamese voice must produce a playable audio file")
} else {
    fatalError("macOS Vietnamese voice synthesis failed")
}
realLocal.stop()
print("offline dub macOS Vietnamese voice: passed")

let adjacent = (0..<3).map { index in
    OfflineDubSession.Cue(start: Double(index) * 0.25,
                          end: Double(index + 1) * 0.25, text: "Câu sát nhau \(index)")
}
var adjacentReady: Result<Int, Error>?
let adjacentSession = OfflineDubSession(translate: { text, reply in reply(text) },
                                        render: { _, _, _, reply in reply(.success(audioURL)) })
var starts: [(Double, Double)] = []
adjacentSession.onCueStarted = { cueStart in starts.append((cueStart, ProcessInfo.processInfo.systemUptime)) }
adjacentSession.prepare(cues: adjacent, completion: { adjacentReady = $0 })
waitFor(adjacentReady != nil)
precondition(adjacentSession.isReady)
adjacentSession.update(videoTime: 0, playing: false)
precondition(adjacentSession.isReady && adjacentSession.cueCount == 3,
             "Pausing dubbing must retain its completed audio")
adjacentSession.update(videoTime: 0, playing: true)
waitFor(starts.count == 3, timeout: 2)
precondition(starts.map(\.0) == [0, 0.25, 0.5], "Every adjacent caption must speak in order")
precondition(starts[1].1 - starts[0].1 > 0.20 && starts[2].1 - starts[1].1 > 0.20,
             "Consecutive speech must follow the caption timeline")
adjacentSession.stop()
print("offline dub adjacent cues: passed")
