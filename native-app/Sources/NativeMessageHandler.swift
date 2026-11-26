import Foundation
import Cocoa

func logSafeURL(_ string: String) -> String {
    guard var components = URLComponents(string: string),
          components.scheme != nil, components.host != nil else {
        return "<invalid url>"
    }
    components.user = nil
    components.password = nil
    components.path = ""
    components.query = nil
    components.fragment = nil
    return components.string ?? "<invalid url>"
}

func logSafeError(_ error: Error) -> String {
    let error = error as NSError
    let text = error.userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
    return "\(error.domain) \(error.code): \(text)"
}

// MARK: - NativeMessageHandler — Chrome Native Messaging Protocol

/// Chrome Native Messaging protocol implementation
/// Format: 4-byte little-endian UInt32 length prefix + UTF-8 JSON body
class NativeMessageHandler {

    var onMessage: (([String: Any]) -> Void)?

    private let inputHandle = FileHandle.standardInput
    private let outputHandle = FileHandle.standardOutput
    private var isListening = false
    private let outputQueue = DispatchQueue(label: "com.aspect.floatvideo.output")

    private func truncated(_ value: String, maxLength: Int = 120) -> String {
        guard value.count > maxLength else { return value }
        return String(value.prefix(maxLength)) + "..."
    }

    private func summarizeIncomingMessage(_ message: [String: Any]) -> String {
        let action = message["action"] as? String ?? "unknown"
        switch action {
        case "open":
            let site = message["site"] as? String ?? "generic"
            let url = logSafeURL(message["url"] as? String ?? "")
            let width = message["width"] ?? "?"
            let height = message["height"] ?? "?"
            let currentTime = message["currentTime"] ?? 0
            let hasVideoSrc = !((message["videoSrc"] as? String ?? "").isEmpty)
            let hasEmbedURL = !((message["embedUrl"] as? String ?? "").isEmpty)
            let cookieCount = (message["cookies"] as? [[String: Any]])?.count ?? 0
            return "action=open site=\(site) size=\(width)x\(height) time=\(currentTime) videoSrc=\(hasVideoSrc) embedUrl=\(hasEmbedURL) cookies=\(cookieCount) url=\(url)"
        case "close", "ping":
            return "action=\(action)"
        default:
            return "action=\(action) keys=\(message.keys.sorted())"
        }
    }

    private func summarizeOutgoingMessage(_ message: [String: Any]) -> String {
        let type = message["type"] as? String ?? "unknown"
        switch type {
        case "status":
            let status = message["status"] as? String ?? "unknown"
            let title = truncated(message["title"] as? String ?? "")
            return title.isEmpty ? "type=status status=\(status)" : "type=status status=\(status) title=\(title)"
        case "error":
            let error = truncated(message["error"] as? String ?? "")
            return "type=error error=\(error)"
        default:
            return "type=\(type) keys=\(message.keys.sorted())"
        }
    }

    // MARK: - Listening

    func startListening() {
        guard !isListening else { return }
        isListening = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            NSLog("[FloatVideo] Native messaging: listening for messages...")

            while self?.isListening == true {
                guard let message = self?.readMessage() else {
                    // stdin closed (Chrome disconnected), exit
                    NSLog("[FloatVideo] stdin closed, exiting...")
                    DispatchQueue.main.async {
                        NSApp.terminate(nil)
                    }
                    return
                }
                self?.onMessage?(message)
            }
        }
    }

    func stopListening() {
        isListening = false
    }

    // MARK: - Read Message

    private func readMessage() -> [String: Any]? {
        // 1. Read 4-byte length prefix (little-endian UInt32)
        let lengthData = inputHandle.readData(ofLength: 4)
        guard lengthData.count == 4 else {
            return nil // EOF or error
        }

        let length: UInt32 = lengthData.withUnsafeBytes { ptr in
            ptr.load(as: UInt32.self)
        }

        guard length > 0, length < 1_048_576 else {
            NSLog("[FloatVideo] Invalid message length: \(length)")
            return nil
        }

        // 2. Read JSON message body
        var messageData = Data()
        var remaining = Int(length)

        while remaining > 0 {
            let chunk = inputHandle.readData(ofLength: remaining)
            guard chunk.count > 0 else {
                NSLog("[FloatVideo] Unexpected EOF while reading message body")
                return nil
            }
            messageData.append(chunk)
            remaining -= chunk.count
        }

        // 3. Parse JSON
        do {
            guard let json = try JSONSerialization.jsonObject(with: messageData) as? [String: Any] else {
                NSLog("[FloatVideo] Message is not a JSON object")
                return nil
            }
            NSLog("%@", "[FloatVideo] Received message summary: \(summarizeIncomingMessage(json))")
            return json
        } catch {
            NSLog("%@", "[FloatVideo] JSON parse error: \(error)")
            return nil
        }
    }

    // MARK: - Send Message

    func sendMessage(_ message: [String: Any]) {
        outputQueue.async { [weak self] in
            guard let self = self else { return }

            do {
                let jsonData = try JSONSerialization.data(withJSONObject: message)

                var length = UInt32(jsonData.count)
                let lengthData = Data(bytes: &length, count: 4)

                try self.outputHandle.write(contentsOf: lengthData + jsonData)

                NSLog("%@", "[FloatVideo] Sent message summary: \(self.summarizeOutgoingMessage(message))")
            } catch {
                NSLog("%@", "[FloatVideo] Failed to send message: \(error)")
            }
        }
    }
}
