import Flutter
import UIKit

/// Flutter plugin for LiteRT-LM on iOS.
///
/// Talks to the LiteRT-LM C API through `LiteLmNativeBridge` (Objective-C++).
/// The underlying static library ships in `LiteRTLM.xcframework` which must
/// be built locally via `scripts/build_ios_frameworks.sh`.
public class FlutterLitertLmPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    private let bridge = LiteLmNativeBridge()
    private var eventSink: FlutterEventSink?

    private var engines: [String: NSValue] = [:]
    private var conversations: [String: NSValue] = [:]
    private var conversationEngineMap: [String: String] = [:]
    private let lock = NSLock()

    public static func register(with registrar: FlutterPluginRegistrar) {
        let methodChannel = FlutterMethodChannel(
            name: "flutter_litert_lm",
            binaryMessenger: registrar.messenger()
        )
        let eventChannel = FlutterEventChannel(
            name: "flutter_litert_lm/stream",
            binaryMessenger: registrar.messenger()
        )
        let instance = FlutterLitertLmPlugin()
        registrar.addMethodCallDelegate(instance, channel: methodChannel)
        eventChannel.setStreamHandler(instance)

        LiteLmNativeBridge.setMinLogLevel(2)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            switch call.method {
            case "createEngine":
                self.handleCreateEngine(call, result: result)
            case "disposeEngine":
                self.handleDisposeEngine(call, result: result)
            case "createConversation":
                self.handleCreateConversation(call, result: result)
            case "disposeConversation":
                self.handleDisposeConversation(call, result: result)
            case "sendMessage":
                self.handleSendMessage(call, result: result)
            case "startMessageStream":
                self.handleStartMessageStream(call, result: result)
            case "countTokens":
                DispatchQueue.main.async { result(-1) }
            default:
                DispatchQueue.main.async { result(FlutterMethodNotImplemented) }
            }
        }
    }

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        return nil
    }

    // MARK: - Engine

    private func handleCreateEngine(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let modelPath = args["modelPath"] as? String else {
            returnError(result, code: "BAD_ARGS", message: "modelPath missing")
            return
        }
        let backend = (args["backend"] as? String) ?? "cpu"
        let visionBackend = args["visionBackend"] as? String
        let audioBackend = args["audioBackend"] as? String
        let cacheDir = args["cacheDir"] as? String

        do {
            let handle = try bridge.createEngine(
                withModelPath: modelPath,
                backend: backend,
                visionBackend: visionBackend,
                audioBackend: audioBackend,
                cacheDir: cacheDir
            )
            let engineId = UUID().uuidString
            lock.lock()
            engines[engineId] = handle
            lock.unlock()
            DispatchQueue.main.async { result(engineId) }
        } catch {
            returnError(result, code: "ENGINE_ERROR", message: error.localizedDescription)
        }
    }

    private func handleDisposeEngine(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let engineId = args["engineId"] as? String else {
            returnError(result, code: "BAD_ARGS", message: "engineId missing")
            return
        }

        lock.lock()
        for (convId, ownerEngineId) in conversationEngineMap where ownerEngineId == engineId {
            if let conv = conversations.removeValue(forKey: convId) {
                bridge.deleteConversation(conv)
            }
            conversationEngineMap.removeValue(forKey: convId)
        }
        if let engine = engines.removeValue(forKey: engineId) {
            bridge.deleteEngine(engine)
        }
        lock.unlock()

        DispatchQueue.main.async { result(nil) }
    }

    // MARK: - Conversation

    private func handleCreateConversation(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let engineId = args["engineId"] as? String else {
            returnError(result, code: "BAD_ARGS", message: "engineId missing")
            return
        }

        lock.lock()
        let engine = engines[engineId]
        lock.unlock()

        guard let engine = engine else {
            returnError(result, code: "ENGINE_NOT_FOUND", message: "Engine not found: \(engineId)")
            return
        }

        let configMap = args["config"] as? [String: Any]
        let systemInstruction = configMap?["systemInstruction"] as? String
        let samplerMap = configMap?["samplerConfig"] as? [String: Any]
        let topK = Int32((samplerMap?["topK"] as? Int) ?? 40)
        let topP = Float((samplerMap?["topP"] as? Double) ?? 0.95)
        let temperature = Float((samplerMap?["temperature"] as? Double) ?? 0.8)

        do {
            let handle = try bridge.createConversation(
                withEngine: engine,
                systemInstruction: systemInstruction,
                topK: topK,
                topP: topP,
                temperature: temperature
            )
            let convId = UUID().uuidString
            lock.lock()
            conversations[convId] = handle
            conversationEngineMap[convId] = engineId
            lock.unlock()
            DispatchQueue.main.async { result(convId) }
        } catch {
            returnError(result, code: "CONVERSATION_ERROR", message: error.localizedDescription)
        }
    }

    private func handleDisposeConversation(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let convId = args["conversationId"] as? String else {
            returnError(result, code: "BAD_ARGS", message: "conversationId missing")
            return
        }

        lock.lock()
        let conv = conversations.removeValue(forKey: convId)
        conversationEngineMap.removeValue(forKey: convId)
        lock.unlock()

        if let conv = conv {
            bridge.deleteConversation(conv)
        }
        DispatchQueue.main.async { result(nil) }
    }

    // MARK: - Messaging

    private func handleSendMessage(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let convId = args["conversationId"] as? String,
              let contents = args["contents"] as? [[String: Any]] else {
            returnError(result, code: "BAD_ARGS", message: "conversationId or contents missing")
            return
        }
        let extraContext = args["extraContext"] as? String

        lock.lock()
        let conv = conversations[convId]
        lock.unlock()

        guard let conv = conv else {
            returnError(result, code: "CONVERSATION_NOT_FOUND", message: "Conversation not found")
            return
        }

        let messageJson = buildMessageJson(contents: contents)
        do {
            let responseJson = try bridge.sendMessage(
                messageJson,
                toConversation: conv,
                extraContext: extraContext
            )
            let text = extractTextFromResponseJson(responseJson)
            DispatchQueue.main.async {
                result([
                    "role": "model",
                    "text": text,
                    "toolCalls": [] as [[String: Any]],
                ])
            }
        } catch {
            returnError(result, code: "MESSAGE_ERROR", message: error.localizedDescription)
        }
    }

    private func handleStartMessageStream(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let convId = args["conversationId"] as? String,
              let contents = args["contents"] as? [[String: Any]] else {
            returnError(result, code: "BAD_ARGS", message: "conversationId or contents missing")
            return
        }
        let extraContext = args["extraContext"] as? String

        lock.lock()
        let conv = conversations[convId]
        lock.unlock()

        guard let conv = conv else {
            returnError(result, code: "CONVERSATION_NOT_FOUND", message: "Conversation not found")
            return
        }

        let messageJson = buildMessageJson(contents: contents)

        bridge.sendMessageStream(
            messageJson,
            toConversation: conv,
            extraContext: extraContext,
            onChunk: { [weak self] chunk in
                // On iOS, the native C API emits each streaming chunk wrapped
                // in a JSON envelope like:
                //   [{"role":"assistant","content":[[{"type":"text","text":"May"}]]}]
                // Parse it to extract just the new text delta and hand that
                // to Dart, which expects delta-per-event (the chat UI does
                // reply.text += msg.text for accumulation).
                let delta = FlutterLitertLmPlugin.extractTextDelta(fromStreamChunk: chunk)
                DispatchQueue.main.async {
                    self?.eventSink?([
                        "role": "model",
                        "text": delta,
                        "toolCalls": [] as [[String: Any]],
                    ])
                }
            },
            onComplete: { [weak self] error in
                DispatchQueue.main.async {
                    if let error = error {
                        self?.eventSink?(FlutterError(
                            code: "STREAM_ERROR",
                            message: error.localizedDescription,
                            details: nil
                        ))
                    }
                    self?.eventSink?(FlutterEndOfEventStream)
                }
            }
        )

        DispatchQueue.main.async { result(nil) }
    }

    // MARK: - JSON helpers

    private func buildMessageJson(contents: [[String: Any]]) -> String {
        var parts: [[String: Any]] = []
        for item in contents {
            guard let type = item["type"] as? String else { continue }
            switch type {
            case "text":
                if let text = item["text"] as? String {
                    parts.append(["type": "text", "text": text])
                }
            case "imageFile":
                if let path = item["path"] as? String {
                    parts.append(["type": "image", "path": path])
                }
            case "audioFile":
                if let path = item["path"] as? String {
                    parts.append(["type": "audio", "path": path])
                }
            default:
                break
            }
        }

        let content: Any
        if parts.count == 1,
           let only = parts.first,
           only["type"] as? String == "text",
           let text = only["text"] as? String {
            content = text
        } else {
            content = parts
        }

        let message: [String: Any] = ["role": "user", "content": content]
        guard let data = try? JSONSerialization.data(withJSONObject: message, options: []),
              let str = String(data: data, encoding: .utf8) else {
            return "{\"role\":\"user\",\"content\":\"\"}"
        }
        return str
    }

    /// Parse a streaming chunk that the LiteRT-LM C API emits on iOS and
    /// return just the delta text. The C API returns one of several formats
    /// depending on the model:
    ///   - A plain text delta like "May " (happy path)
    ///   - A JSON array of message parts:
    ///     `[{"role":"assistant","content":[[{"type":"text","text":"May"}]]}]`
    ///   - A single message object:
    ///     `{"role":"assistant","content":[[{"type":"text","text":"May"}]]}`
    /// If the chunk doesn't look like JSON, return it as-is.
    static func extractTextDelta(fromStreamChunk chunk: String) -> String {
        let trimmed = chunk.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else {
            return chunk
        }
        guard let data = trimmed.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) else {
            return chunk
        }
        return collectText(from: parsed)
    }

    /// Walk any JSON structure produced by LiteRT-LM and collect every
    /// "text" field value into a single concatenated string. This is robust
    /// to arrays, nested arrays, and nested dicts.
    private static func collectText(from node: Any) -> String {
        if let s = node as? String {
            return s
        }
        if let arr = node as? [Any] {
            return arr.map { collectText(from: $0) }.joined()
        }
        if let dict = node as? [String: Any] {
            // Preferred path: a content-part object with "type":"text".
            if let type = dict["type"] as? String,
               type == "text",
               let text = dict["text"] as? String {
                return text
            }
            // A message envelope with a "content" field — unwrap it.
            if let content = dict["content"] {
                return collectText(from: content)
            }
            // A standalone {"text": "..."} object.
            if let text = dict["text"] as? String {
                return text
            }
        }
        return ""
    }

    private func extractTextFromResponseJson(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) else {
            return json
        }
        if let dict = parsed as? [String: Any] {
            if let content = dict["content"] as? String {
                return content
            }
            if let parts = dict["content"] as? [[String: Any]] {
                return parts.compactMap { $0["text"] as? String }.joined()
            }
        }
        return json
    }

    private func returnError(_ result: @escaping FlutterResult, code: String, message: String) {
        DispatchQueue.main.async {
            result(FlutterError(code: code, message: message, details: nil))
        }
    }
}

private final class TextAccumulator {
    private var buffer: String = ""
    private let lock = NSLock()

    func append(_ chunk: String) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(chunk)
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }
}
