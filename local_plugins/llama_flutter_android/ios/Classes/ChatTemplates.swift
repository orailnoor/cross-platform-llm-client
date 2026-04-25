import Foundation

// MARK: - Types

struct TemplateChatMessage {
    let role: String    // "system", "user", or "assistant"
    let content: String
}

protocol ChatTemplate {
    var name: String { get }
    func format(messages: [TemplateChatMessage]) -> String
}

// MARK: - Built-in Templates

class ChatMLTemplate: ChatTemplate {
    let name = "chatml"
    func format(messages: [TemplateChatMessage]) -> String {
        var result = ""
        for msg in messages {
            if !msg.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result += "<|im_start|>\(msg.role)\n\(msg.content)<|im_end|>\n"
            }
        }
        result += "<|im_start|>assistant\n"
        return result
    }
}

class Llama3Template: ChatTemplate {
    let name = "llama3"
    func format(messages: [TemplateChatMessage]) -> String {
        var result = "<|begin_of_text|>"
        for msg in messages {
            if !msg.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result += "<|start_header_id|>\(msg.role)<|end_header_id|>\n\n\(msg.content.trimmingCharacters(in: .whitespaces))<|eot_id|>"
            }
        }
        result += "<|start_header_id|>assistant<|end_header_id|>\n\n"
        return result
    }
}

class Llama2Template: ChatTemplate {
    let name = "llama2"
    func format(messages: [TemplateChatMessage]) -> String {
        var result = "<s>"
        var isFirstUser = true
        let systemMessage = messages.first(where: { $0.role == "system" })?.content.trimmingCharacters(in: .whitespaces) ?? ""
        let hasSystem = !systemMessage.isEmpty

        for msg in messages {
            switch msg.role {
            case "system": continue
            case "user":
                if !isFirstUser { result += "</s><s>" }
                result += "[INST] "
                if isFirstUser && hasSystem {
                    result += "<<SYS>>\n\(systemMessage)\n<</SYS>>\n\n"
                }
                result += "\(msg.content.trimmingCharacters(in: .whitespaces)) [/INST]"
                isFirstUser = false
            case "assistant":
                result += " \(msg.content.trimmingCharacters(in: .whitespaces))"
            default: break
            }
        }
        return result
    }
}

class AlpacaTemplate: ChatTemplate {
    let name = "alpaca"
    func format(messages: [TemplateChatMessage]) -> String {
        let system = messages.first(where: { $0.role == "system" })?.content
            ?? "Below is an instruction that describes a task. Write a response that appropriately completes the request."
        var result = "\(system)\n\n"
        for msg in messages {
            switch msg.role {
            case "user":      result += "### Instruction:\n\(msg.content)\n\n"
            case "assistant": result += "### Response:\n\(msg.content)\n\n"
            default: break
            }
        }
        result += "### Response:\n"
        return result
    }
}

class VicunaTemplate: ChatTemplate {
    let name = "vicuna"
    func format(messages: [TemplateChatMessage]) -> String {
        let system = messages.first(where: { $0.role == "system" })?.content
            ?? "A chat between a curious user and an artificial intelligence assistant. The assistant gives helpful, detailed, and polite answers to the user's questions."
        var result = "\(system)\n\n"
        for msg in messages {
            switch msg.role {
            case "user":      result += "USER: \(msg.content)\n"
            case "assistant": result += "ASSISTANT: \(msg.content)\n"
            default: break
            }
        }
        result += "ASSISTANT:"
        return result
    }
}

class PhiTemplate: ChatTemplate {
    let name = "phi"
    func format(messages: [TemplateChatMessage]) -> String {
        var result = ""
        for msg in messages {
            switch msg.role {
            case "system":    result += "<|system|>\n\(msg.content)<|end|>\n"
            case "user":      result += "<|user|>\n\(msg.content)<|end|>\n"
            case "assistant": result += "<|assistant|>\n\(msg.content)<|end|>\n"
            default: break
            }
        }
        result += "<|assistant|>\n"
        return result
    }
}

class Gemma2Template: ChatTemplate {
    let name = "gemma2"
    func format(messages: [TemplateChatMessage]) -> String {
        var result = "<bos>"
        var systemContent: String? = nil
        for (index, msg) in messages.enumerated() {
            switch msg.role {
            case "system":
                systemContent = msg.content
            case "user":
                result += "<start_of_turn>user\n"
                if let sys = systemContent, index <= 1 {
                    result += "\(sys)\n\n"
                    systemContent = nil
                }
                result += "\(msg.content)<end_of_turn>\n"
            case "assistant":
                result += "<start_of_turn>model\n\(msg.content)<end_of_turn>"
                if index < messages.count - 1 { result += "<eos>" }
                result += "\n"
            default: break
            }
        }
        result += "<start_of_turn>model\n"
        return result
    }
}

class Gemma3Template: ChatTemplate {
    let name = "gemma3"
    func format(messages: [TemplateChatMessage]) -> String {
        var result = "<bos>"
        var systemContent: String? = nil
        for msg in messages {
            switch msg.role {
            case "system":
                systemContent = msg.content
            case "user":
                result += "<start_of_turn>user\n"
                if let sys = systemContent {
                    result += "\(sys)\n\n"
                    systemContent = nil
                }
                result += "\(msg.content)<end_of_turn>\n"
            case "assistant":
                result += "<start_of_turn>model\n\(msg.content)<end_of_turn>\n"
            default: break
            }
        }
        result += "<start_of_turn>model\n"
        return result
    }
}

class QwQTemplate: ChatTemplate {
    let name = "qwq"
    func format(messages: [TemplateChatMessage]) -> String {
        var result = ""
        for msg in messages {
            let content = msg.role == "assistant" ? stripReasoningBlocks(msg.content) : msg.content
            if !content.trimmingCharacters(in: .whitespaces).isEmpty || msg.role != "assistant" {
                result += "<|im_start|>\(msg.role)\n\(content)<|im_end|>\n"
            }
        }
        result += "<|im_start|>assistant\n"
        return result
    }
    private func stripReasoningBlocks(_ content: String) -> String {
        let pattern = "<think>[\\s\\S]*?</think>"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return content }
        let range = NSRange(content.startIndex..., in: content)
        return regex.stringByReplacingMatches(in: content, range: range, withTemplate: "").trimmingCharacters(in: .whitespaces)
    }
}

class MistralTemplate: ChatTemplate {
    let name = "mistral"
    func format(messages: [TemplateChatMessage]) -> String {
        var result = "<s>"
        var isFirst = true
        let systemMessage = messages.first(where: { $0.role == "system" })?.content.trimmingCharacters(in: .whitespaces)
        for msg in messages {
            switch msg.role {
            case "system": continue
            case "user":
                if !isFirst { result += "</s>" }
                result += "[INST] "
                if isFirst, let sys = systemMessage { result += "\(sys)\n\n" }
                result += "\(msg.content.trimmingCharacters(in: .whitespaces)) [/INST]"
                isFirst = false
            case "assistant":
                result += msg.content.trimmingCharacters(in: .whitespaces)
            default: break
            }
        }
        return result
    }
}

class DeepSeekCoderTemplate: ChatTemplate {
    let name = "deepseek-coder"
    func format(messages: [TemplateChatMessage]) -> String {
        var result = "<｜begin▁of▁sentence｜>"
        if let sys = messages.first(where: { $0.role == "system" })?.content.trimmingCharacters(in: .whitespaces) {
            result += "\(sys) "
        }
        var isFirst = true
        for msg in messages {
            switch msg.role {
            case "system": continue
            case "user":
                if !isFirst { result += "<｜end▁of▁sentence｜>" }
                result += "User: \(msg.content.trimmingCharacters(in: .whitespaces))\n"
                isFirst = false
            case "assistant":
                result += "Assistant: \(msg.content.trimmingCharacters(in: .whitespaces))\n"
            default: break
            }
        }
        result += "Assistant: "
        return result
    }
}

class DeepSeekR1Template: ChatTemplate {
    let name = "deepseek-r1"
    func format(messages: [TemplateChatMessage]) -> String {
        var result = "<｜begin▁of▁sentence｜>"
        if let sys = messages.first(where: { $0.role == "system" })?.content.trimmingCharacters(in: .whitespaces) {
            result += sys
        }
        for msg in messages {
            switch msg.role {
            case "system": continue
            case "user":      result += "<｜User｜>\(msg.content.trimmingCharacters(in: .whitespaces))"
            case "assistant": result += "<｜Assistant｜></think>\(msg.content.trimmingCharacters(in: .whitespaces))"
            default: break
            }
        }
        result += "<｜Assistant｜></think>"
        return result
    }
}

class RawTemplate: ChatTemplate {
    let name: String
    private let content: String
    init(name: String, content: String) { self.name = name; self.content = content }
    func format(messages: [TemplateChatMessage]) -> String {
        var result = ""
        for msg in messages {
            let formatted: String
            switch msg.role {
            case "system":    formatted = content.replacingOccurrences(of: "{system}", with: msg.content)
            case "user":      formatted = content.replacingOccurrences(of: "{user}", with: msg.content)
            case "assistant": formatted = content.replacingOccurrences(of: "{assistant}", with: msg.content)
            default:          formatted = content.replacingOccurrences(of: "{user}", with: msg.content)
            }
            result += formatted
        }
        return result
    }
}

// MARK: - ChatTemplateManager

class ChatTemplateManager {
    static let shared = ChatTemplateManager()
    private init() {}

    private let builtIn: [String: any ChatTemplate] = {
        let chatml = ChatMLTemplate()
        let llama3 = Llama3Template()
        let llama2 = Llama2Template()
        let mistral = MistralTemplate()
        let qwq = QwQTemplate()
        let dsCoder = DeepSeekCoderTemplate()
        let dsR1 = DeepSeekR1Template()
        let gemma2 = Gemma2Template()
        let gemma3 = Gemma3Template()
        let alpaca = AlpacaTemplate()
        let vicuna = VicunaTemplate()
        let phi = PhiTemplate()
        return [
            "chatml": chatml, "qwen": chatml, "qwen2": chatml, "qwen2.5": chatml, "command-r": chatml,
            "llama3": llama3, "llama-3": llama3, "llama3.1": llama3, "llama3.3": llama3,
            "llama2": llama2, "llama-2": llama2,
            "qwq": qwq, "qwq-32b": qwq,
            "deepseek-r1": dsR1, "deepseek-v3": dsR1,
            "mistral": mistral, "mixtral": mistral,
            "deepseek-coder": dsCoder,
            "alpaca": alpaca, "vicuna": vicuna,
            "phi": phi, "phi-3": phi,
            "gemma": gemma2, "gemma2": gemma2, "gemma-2": gemma2,
            "gemma3": gemma3, "gemma-3": gemma3,
        ]
    }()

    private var custom: [String: RawTemplate] = [:]
    private let lock = NSLock()

    func registerCustomTemplate(name: String, content: String) {
        lock.lock(); defer { lock.unlock() }
        custom[name.lowercased()] = RawTemplate(name: name, content: content)
    }

    func unregisterCustomTemplate(name: String) {
        lock.lock(); defer { lock.unlock() }
        custom.removeValue(forKey: name.lowercased())
    }

    func getTemplate(name: String) -> (any ChatTemplate)? {
        let key = name.lowercased()
        return custom[key] ?? builtIn[key]
    }

    func getSupportedTemplates() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return (Array(custom.keys) + Array(builtIn.keys)).sorted()
    }

    func detectTemplate(modelPath: String) -> any ChatTemplate {
        let lower = modelPath.lowercased()
        if lower.contains("qwq")                                                        { return builtIn["qwq"]! }
        if lower.contains("deepseek-r1") || lower.contains("deepseek_r1")              { return builtIn["deepseek-r1"]! }
        if lower.contains("deepseek-coder") || lower.contains("deepseek_coder")        { return builtIn["deepseek-coder"]! }
        if lower.contains("deepseek") && (lower.contains("v3") || lower.contains("v3.1")) { return builtIn["deepseek-r1"]! }
        if lower.contains("qwen2.5") || lower.contains("qwen2_5")                      { return builtIn["qwen2.5"]! }
        if lower.contains("qwen2")                                                      { return builtIn["qwen2"]! }
        if lower.contains("qwen")                                                       { return builtIn["qwen"]! }
        if lower.contains("llama-3") || lower.contains("llama3") || lower.contains("llama_3") { return builtIn["llama3"]! }
        if lower.contains("llama-2") || lower.contains("llama2") || lower.contains("llama_2") { return builtIn["llama2"]! }
        if lower.contains("mixtral")                                                    { return builtIn["mixtral"]! }
        if lower.contains("mistral")                                                    { return builtIn["mistral"]! }
        if lower.contains("command-r") || lower.contains("command_r")                  { return builtIn["command-r"]! }
        if lower.contains("phi-3") || lower.contains("phi3")                           { return builtIn["phi-3"]! }
        if lower.contains("phi")                                                        { return builtIn["phi"]! }
        if lower.contains("gemma-3") || lower.contains("gemma3") || lower.contains("gemma_3") { return builtIn["gemma3"]! }
        if lower.contains("gemma-2") || lower.contains("gemma2") || lower.contains("gemma_2") { return builtIn["gemma2"]! }
        if lower.contains("gemma")                                                      { return builtIn["gemma2"]! }
        if lower.contains("smollm")                                                     { return builtIn["chatml"]! }
        if lower.contains("alpaca")                                                     { return builtIn["alpaca"]! }
        if lower.contains("vicuna")                                                     { return builtIn["vicuna"]! }
        return builtIn["chatml"]!
    }

    func formatMessages(messages: [TemplateChatMessage], templateName: String?, modelPath: String?) -> String {
        let template: any ChatTemplate
        if let name = templateName {
            template = getTemplate(name: name) ?? detectTemplate(modelPath: modelPath ?? "")
        } else if let path = modelPath {
            template = detectTemplate(modelPath: path)
        } else {
            template = ChatMLTemplate()
        }
        return template.format(messages: messages)
    }
}
