import Foundation
import CryptoKit

/// EdgeTTSManager manages Microsoft Edge neural text-to-speech synthesis
/// for Vietnamese movie dubbing. Uses a persistent Python worker with instant
/// memory/disk caching, concurrent request dispatch, pre-warming, and fast
/// cancellation to keep pace with rapid movie subtitles.
final class EdgeTTSManager {
    static let shared = EdgeTTSManager()

    enum Voice: String, CaseIterable {
        case hoaiMy = "vi-VN-HoaiMyNeural"
        case namMinh = "vi-VN-NamMinhNeural"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .hoaiMy: return "Hoài My (Nữ)"
            case .namMinh: return "Nam Minh (Nam)"
            }
        }

        var description: String {
            switch self {
            case .hoaiMy: return "Hoài My (Nữ - Truyền cảm, Tự nhiên)"
            case .namMinh: return "Nam Minh (Nam - Trầm ấm, Rõ ràng)"
            }
        }
    }

    private static let voicePrefKey = "vibe_edge_tts_voice"

    var selectedVoice: Voice {
        get {
            if let saved = UserDefaults.standard.string(forKey: Self.voicePrefKey),
               let voice = Voice(rawValue: saved) {
                return voice
            }
            return .hoaiMy
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.voicePrefKey)
        }
    }

    private var process: Process?
    private var inPipe: Pipe?
    private var outPipe: Pipe?
    private var readBuffer = Data()
    private var pendingRequests: [String: [(Result<URL, Error>) -> Void]] = [:]
    private var requestKeys: [String: String] = [:]
    private var requestByKey: [String: String] = [:]
    private var completedByKey: [String: URL] = [:]
    private var pendingTimeouts: [String: DispatchWorkItem] = [:]
    private let lock = NSRecursiveLock()
    private var pythonPath: String?
    private var tempFiles: Set<String> = []
    private let diskCacheDirectory: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        diskCacheDirectory = support.appendingPathComponent("FloatVideo/tts-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskCacheDirectory, withIntermediateDirectories: true)
        self.pythonPath = findWorkingPython()
    }

    private func cacheURL(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return diskCacheDirectory.appendingPathComponent(digest + ".mp3")
    }

    private func isUsableAudio(_ url: URL) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        return size > 100
    }

    deinit {
        terminateWorker()
    }

    // MARK: - Python & Script Setup

    private func findWorkingPython() -> String? {
        let candidates = [
            "/usr/bin/python3",
            "/usr/local/bin/python3",
            "/opt/homebrew/bin/python3"
        ]
        for candidate in candidates {
            guard FileManager.default.isExecutableFile(atPath: candidate) else { continue }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: candidate)
            proc.arguments = ["-c", "import edge_tts"]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            do {
                try proc.run()
                proc.waitUntilExit()
                if proc.terminationStatus == 0 {
                    return candidate
                }
            } catch {
                continue
            }
        }
        return nil
    }

    private func workerScriptPath() -> String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let floatDir = appSupport.appendingPathComponent("FloatVideo")
        try? FileManager.default.createDirectory(at: floatDir, withIntermediateDirectories: true)
        let scriptURL = floatDir.appendingPathComponent("edge_worker.py")
        let scriptContent = """
#!/usr/bin/env python3
import sys, json, asyncio, os, socket
import aiohttp
from edge_tts.communicate import (
    Communicate, _SSL_CTX, WSS_URL, WSS_HEADERS,
    SEC_MS_GEC_VERSION, DRM, connect_id, date_to_string,
    mkssml, ssml_headers_plus_data
)

cache = {}
session = None
sem = asyncio.Semaphore(6)

async def init_session():
    global session
    connector = aiohttp.TCPConnector(family=socket.AF_INET, limit=50, ttl_dns_cache=600, keepalive_timeout=120)
    session = aiohttp.ClientSession(connector=connector)

async def synthesize(req):
    global session
    req_id = req.get("id", "")
    text = req.get("text", "").strip()
    voice = req.get("voice", "vi-VN-HoaiMyNeural")
    rate = req.get("rate", "+22%")
    out_path = req.get("output", f"/tmp/vibe_edge_{req_id}.mp3")

    cache_key = (text, voice, rate)
    cache_path = req.get("cache_path")
    cached_path = cache.get(cache_key)
    if cached_path and os.path.exists(cached_path) and os.path.getsize(cached_path) > 100:
        res = {"id": req_id, "status": "ok", "path": cached_path, "cached": True}
        sys.stdout.write(json.dumps(res) + "\\n")
        sys.stdout.flush()
        return

    last_err = None
    async with sem:
        for attempt in range(2):
            try:
                url = f"{WSS_URL}&ConnectionId={connect_id()}&Sec-MS-GEC={DRM.generate_sec_ms_gec()}&Sec-MS-GEC-Version={SEC_MS_GEC_VERSION}"
                headers = DRM.headers_with_muid(WSS_HEADERS)
                async with session.ws_connect(url, compress=15, headers=headers, ssl=_SSL_CTX) as ws:
                    await ws.send_str(
                        f"X-Timestamp:{date_to_string()}\\r\\n"
                        "Content-Type:application/json; charset=utf-8\\r\\n"
                        "Path:speech.config\\r\\n\\r\\n"
                        '{"context":{"synthesis":{"audio":{"metadataoptions":{'
                        '"sentenceBoundaryEnabled":"false","wordBoundaryEnabled":"false"'
                        '},'
                        '"outputFormat":"audio-24khz-48kbitrate-mono-mp3"'
                        "}}}}\\r\\n"
                    )
                    cid = connect_id()
                    ssml = mkssml(Communicate(text, voice, rate=rate).tts_config, text)
                    await ws.send_str(ssml_headers_plus_data(cid, date_to_string(), ssml))

                    with open(out_path, "wb") as f:
                        async for msg in ws:
                            if msg.type == aiohttp.WSMsgType.BINARY:
                                if len(msg.data) > 2:
                                    header_len = int.from_bytes(msg.data[:2], "big")
                                    f.write(msg.data[2 + header_len:])
                            elif msg.type == aiohttp.WSMsgType.TEXT:
                                if b"turn.end" in msg.data.encode("utf-8"):
                                    break
                            elif msg.type in (aiohttp.WSMsgType.CLOSED, aiohttp.WSMsgType.ERROR):
                                raise Exception("WebSocket closed unexpectedly")

                if os.path.exists(out_path) and os.path.getsize(out_path) > 100:
                    if cache_path:
                        os.replace(out_path, cache_path)
                        out_path = cache_path
                    cache[cache_key] = out_path
                    res = {"id": req_id, "status": "ok", "path": out_path}
                    sys.stdout.write(json.dumps(res) + "\\n")
                    sys.stdout.flush()
                    return
                raise RuntimeError("No audio received from Edge TTS")
            except Exception as e:
                last_err = f"{type(e).__name__}: {e}"
                await asyncio.sleep(0.5 * (attempt + 1))

    res = {"id": req_id, "status": "error", "error": str(last_err or "No audio received from Edge TTS")}
    sys.stdout.write(json.dumps(res) + "\\n")
    sys.stdout.flush()

async def main():
    await init_session()
    sys.stdout.write(json.dumps({"status": "ready"}) + "\\n")
    sys.stdout.flush()

    loop = asyncio.get_running_loop()
    while True:
        line = await loop.run_in_executor(None, sys.stdin.readline)
        if not line:
            break
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
            action = req.get("action", "synthesize")
            if action == "clear_cache":
                cache.clear()
                continue
            asyncio.create_task(synthesize(req))
        except Exception as e:
            err_res = {"status": "error", "error": str(e)}
            sys.stdout.write(json.dumps(err_res) + "\\n")
            sys.stdout.flush()

if __name__ == "__main__":
    asyncio.run(main())
"""
        if !FileManager.default.fileExists(atPath: scriptURL.path) ||
           (try? String(contentsOf: scriptURL, encoding: .utf8)) != scriptContent {
            try? scriptContent.write(to: scriptURL, atomically: true, encoding: .utf8)
        }
        return scriptURL.path
    }

    // MARK: - Worker Lifecycle

    func warmup() {
        lock.lock()
        defer { lock.unlock() }
        ensureWorkerRunningLocked()
    }

    private func ensureWorkerRunningLocked() {
        if process != nil && process!.isRunning { return }
        guard let py = pythonPath ?? findWorkingPython() else { return }
        self.pythonPath = py

        let script = workerScriptPath()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: py)
        p.arguments = [script]

        let inP = Pipe()
        let outP = Pipe()
        p.standardInput = inP
        p.standardOutput = outP
        p.standardError = FileHandle.nullDevice

        p.terminationHandler = { [weak self] _ in
            guard let self = self else { return }
            self.lock.lock()
            self.process = nil
            self.inPipe = nil
            self.outPipe = nil
            let pending = self.pendingRequests
            self.pendingRequests.removeAll()
            self.requestKeys.removeAll()
            self.requestByKey.removeAll()
            for item in self.pendingTimeouts.values { item.cancel() }
            self.pendingTimeouts.removeAll()
            self.lock.unlock()

            let err = NSError(domain: "EdgeTTS", code: -2, userInfo: [NSLocalizedDescriptionKey: "Worker process terminated"])
            for callbacks in pending.values {
                for callback in callbacks { callback(.failure(err)) }
            }
        }

        outP.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self = self else { return }
            self.handleWorkerOutput(data)
        }

        do {
            try p.run()
            self.process = p
            self.inPipe = inP
            self.outPipe = outP
        } catch {
            self.process = nil
        }
    }

    private func handleWorkerOutput(_ data: Data) {
        lock.lock()
        readBuffer.append(data)
        var callbacksToExecute: [(Result<URL, Error>, [(Result<URL, Error>) -> Void])] = []

        while let newlineIdx = readBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = readBuffer.subdata(in: 0..<newlineIdx)
            readBuffer.removeSubrange(0...newlineIdx)
            guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }
            guard let id = json["id"] as? String, !id.isEmpty else {
                continue
            }
            pendingTimeouts[id]?.cancel()
            pendingTimeouts.removeValue(forKey: id)
            guard let callbacks = pendingRequests.removeValue(forKey: id) else {
                continue
            }
            let key = requestKeys.removeValue(forKey: id)
            if let key = key { requestByKey.removeValue(forKey: key) }

            let status = json["status"] as? String ?? ""
            if status == "ok", let path = json["path"] as? String {
                let url = URL(fileURLWithPath: path)
                if !url.path.hasPrefix(diskCacheDirectory.path + "/") { tempFiles.insert(path) }
                if let key = key { completedByKey[key] = url }
                callbacksToExecute.append((.success(url), callbacks))
            } else {
                let errMsg = json["error"] as? String ?? "Synthesis failed"
                let err = NSError(domain: "EdgeTTS", code: -1, userInfo: [NSLocalizedDescriptionKey: errMsg])
                callbacksToExecute.append((.failure(err), callbacks))
            }
        }
        lock.unlock()

        for (result, callbacks) in callbacksToExecute {
            for callback in callbacks { callback(result) }
        }
    }

    // MARK: - Subtitle Pacing Helper

    static func calculateSubtitleRate(text: String, duration: Double = 0) -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if duration > 0.4 {
            let charsPerSec = Double(clean.count) / duration
            if charsPerSec >= 15.0 {
                return "+35%"
            } else if charsPerSec >= 12.0 {
                return "+30%"
            } else if charsPerSec >= 9.0 {
                return "+24%"
            } else {
                return "+20%"
            }
        } else {
            if clean.count > 45 {
                return "+30%"
            } else if clean.count > 25 {
                return "+24%"
            } else {
                return "+20%"
            }
        }
    }

    // MARK: - Synthesis API

    func synthesize(
        text: String,
        voice: Voice? = nil,
        rate: String? = nil,
        timeoutSeconds: Double = 10.0,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        lock.lock()
        let v = voice ?? selectedVoice
        let r = rate ?? Self.calculateSubtitleRate(text: text)
        let key = "\(text)\u{0}\(v.rawValue)\u{0}\(r)"
        if let cached = completedByKey[key], FileManager.default.fileExists(atPath: cached.path) {
            lock.unlock()
            completion(.success(cached))
            return
        }
        completedByKey.removeValue(forKey: key)
        let persistent = cacheURL(for: key)
        if isUsableAudio(persistent) {
            completedByKey[key] = persistent
            lock.unlock()
            completion(.success(persistent))
            return
        }
        if let existingId = requestByKey[key] {
            pendingRequests[existingId, default: []].append(completion)
            lock.unlock()
            return
        }
        ensureWorkerRunningLocked()
        guard let inPipe = self.inPipe, process?.isRunning == true else {
            lock.unlock()
            completion(.failure(NSError(domain: "EdgeTTS", code: -3, userInfo: [NSLocalizedDescriptionKey: "Edge TTS worker not available"])))
            return
        }

        let reqId = "req_\(UUID().uuidString.prefix(8))_\(Int(Date().timeIntervalSince1970 * 1000))"
        let outPath = diskCacheDirectory.appendingPathComponent(".\(reqId).partial").path

        pendingRequests[reqId] = [completion]
        requestKeys[reqId] = key
        requestByKey[key] = reqId
        tempFiles.insert(outPath)

        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            guard let callbacks = self.pendingRequests.removeValue(forKey: reqId) else {
                self.lock.unlock()
                return
            }
            if let key = self.requestKeys.removeValue(forKey: reqId) {
                self.requestByKey.removeValue(forKey: key)
            }
            self.pendingTimeouts.removeValue(forKey: reqId)
            self.lock.unlock()
            let err = NSError(domain: "EdgeTTS", code: -4, userInfo: [NSLocalizedDescriptionKey: "Edge TTS timeout (> \(timeoutSeconds)s)"])
            for callback in callbacks { callback(.failure(err)) }
        }
        pendingTimeouts[reqId] = workItem
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: workItem)

        let reqDict: [String: Any] = [
            "id": reqId,
            "text": text,
            "voice": v.rawValue,
            "rate": r,
            "output": outPath,
            "cache_path": persistent.path
        ]
        if let data = try? JSONSerialization.data(withJSONObject: reqDict),
           var line = String(data: data, encoding: .utf8) {
            line.append("\n")
            if let writeData = line.data(using: .utf8) {
                inPipe.fileHandleForWriting.write(writeData)
            }
        }
        lock.unlock()
    }

    func prefetch(text: String, voice: Voice? = nil, rate: String? = nil) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count >= 2 else { return }
        let edgeRate = rate ?? Self.calculateSubtitleRate(text: clean)
        synthesize(text: clean, voice: voice, rate: edgeRate, timeoutSeconds: 12.0) { _ in }
    }

    func cancelAll() {
        lock.lock()
        let pending = pendingRequests
        pendingRequests.removeAll()
        requestKeys.removeAll()
        requestByKey.removeAll()
        for item in pendingTimeouts.values { item.cancel() }
        pendingTimeouts.removeAll()
        lock.unlock()

        let err = NSError(domain: "EdgeTTS", code: -5, userInfo: [NSLocalizedDescriptionKey: "Cancelled"])
        for callbacks in pending.values {
            for callback in callbacks { callback(.failure(err)) }
        }
    }

    func cleanupTempFiles() {
        lock.lock()
        let files = tempFiles
        tempFiles.removeAll()
        completedByKey.removeAll()
        lock.unlock()

        for path in files {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    func terminateWorker() {
        cancelAll()
        cleanupTempFiles()
        lock.lock()
        defer { lock.unlock() }
        outPipe?.fileHandleForReading.readabilityHandler = nil
        try? inPipe?.fileHandleForWriting.close()
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
        inPipe = nil
        outPipe = nil
    }
}
