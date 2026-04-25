package com.write4me.llama_flutter_android

/**
 * Internal chat message for template formatting
 * (Separate from Pigeon-generated ChatMessage to avoid conflicts)
 */
data class TemplateChatMessage(
    val role: String, // "system", "user", or "assistant"
    val content: String
)

/**
 * Interface for chat template formatters
 */
interface ChatTemplate {
    fun format(messages: List<TemplateChatMessage>): String
    val name: String
}

/**
 * ChatML format used by Qwen 2/2.5, Command-R, and others
 * Format:
 * <|im_start|>system
 * {content}<|im_end|>
 * <|im_start|>user
 * {content}<|im_end|>
 * <|im_start|>assistant
 * {content}<|im_end|>
 * 
 * Reference: https://github.com/QwenLM/Qwen
 */
class ChatMLTemplate : ChatTemplate {
    override val name = "chatml"
    
    override fun format(messages: List<TemplateChatMessage>): String {
        val builder = StringBuilder()
        
        for (message in messages) {
            builder.append("<|im_start|>${message.role}\n")
            builder.append("${message.content}<|im_end|>\n")
        }
        
        // Add the final assistant turn start for generation prompt
        builder.append("<|im_start|>assistant\n")
        
        return builder.toString()
    }
}

/**
 * Llama-3/3.1/3.3 format with header-based roles
 * Format:
 * <|begin_of_text|><|start_header_id|>system<|end_header_id|>
 * {content}<|eot_id|>
 * <|start_header_id|>user<|end_header_id|>
 * {content}<|eot_id|>
 * <|start_header_id|>assistant<|end_header_id|>
 * 
 * Reference: Meta Llama 3 documentation
 */
class Llama3Template : ChatTemplate {
    override val name = "llama3"
    
    override fun format(messages: List<TemplateChatMessage>): String {
        val builder = StringBuilder()
        builder.append("<|begin_of_text|>")
        
        for (message in messages) {
            builder.append("<|start_header_id|>${message.role}<|end_header_id|>\n\n")
            builder.append("${message.content.trim()}<|eot_id|>")
        }
        
        // Add the final assistant turn start for generation prompt
        builder.append("<|start_header_id|>assistant<|end_header_id|>\n\n")
        
        return builder.toString()
    }
}

/**
 * Llama-2 format
 * Format:
 * <s>[INST] <<SYS>>
 * {system_message}
 * <</SYS>>
 * 
 * {user_message} [/INST] {assistant_message}</s><s>[INST] {user_message} [/INST]
 * 
 * Reference: Meta Llama 2 documentation
 */
class Llama2Template : ChatTemplate {
    override val name = "llama2"
    
    override fun format(messages: List<TemplateChatMessage>): String {
        val builder = StringBuilder()
        builder.append("<s>")
        
        var isFirstUser = true
        var hasSystem = false
        var systemMessage = ""
        
        // Extract system message first
        for (message in messages) {
            if (message.role == "system") {
                systemMessage = message.content.trim()
                hasSystem = true
                break
            }
        }
        
        for (message in messages) {
            when (message.role) {
                "system" -> {
                    // Already handled, skip
                    continue
                }
                "user" -> {
                    if (!isFirstUser) {
                        builder.append("</s><s>")
                    }
                    
                    builder.append("[INST] ")
                    
                    if (isFirstUser && hasSystem) {
                        builder.append("<<SYS>>\n")
                        builder.append("$systemMessage\n")
                        builder.append("<</SYS>>\n\n")
                    }
                    
                    builder.append("${message.content.trim()} [/INST]")
                    isFirstUser = false
                }
                "assistant" -> {
                    builder.append(" ${message.content.trim()}")
                }
            }
        }
        
        return builder.toString()
    }
}

/**
 * Alpaca format
 * Format:
 * Below is an instruction that describes a task. Write a response that appropriately completes the request.
 * 
 * ### Instruction:
 * {user_message}
 * 
 * ### Response:
 */
class AlpacaTemplate : ChatTemplate {
    override val name = "alpaca"
    
    override fun format(messages: List<TemplateChatMessage>): String {
        val builder = StringBuilder()
        val systemMessage = messages.firstOrNull { it.role == "system" }?.content
            ?: "Below is an instruction that describes a task. Write a response that appropriately completes the request."
        
        builder.append("$systemMessage\\n\\n")
        
        for (message in messages) {
            when (message.role) {
                "user" -> {
                    builder.append("### Instruction:\\n")
                    builder.append("${message.content}\\n\\n")
                }
                "assistant" -> {
                    builder.append("### Response:\\n")
                    builder.append("${message.content}\\n\\n")
                }
            }
        }
        
        // Add final response prompt
        builder.append("### Response:\\n")
        
        return builder.toString()
    }
}

/**
 * Vicuna format
 * Format:
 * A chat between a curious user and an artificial intelligence assistant. The assistant gives helpful, detailed, and polite answers to the user's questions.
 * 
 * USER: {user_message}
 * ASSISTANT: {assistant_message}
 */
class VicunaTemplate : ChatTemplate {
    override val name = "vicuna"
    
    override fun format(messages: List<TemplateChatMessage>): String {
        val builder = StringBuilder()
        val systemMessage = messages.firstOrNull { it.role == "system" }?.content
            ?: "A chat between a curious user and an artificial intelligence assistant. The assistant gives helpful, detailed, and polite answers to the user's questions."
        
        builder.append("$systemMessage\\n\\n")
        
        for (message in messages) {
            when (message.role) {
                "user" -> {
                    builder.append("USER: ${message.content}\\n")
                }
                "assistant" -> {
                    builder.append("ASSISTANT: ${message.content}\\n")
                }
            }
        }
        
        // Add final assistant prompt
        builder.append("ASSISTANT:")
        
        return builder.toString()
    }
}

/**
 * Phi-2/Phi-3 format (similar to ChatML but with different tokens)
 */
class PhiTemplate : ChatTemplate {
    override val name = "phi"
    
    override fun format(messages: List<TemplateChatMessage>): String {
        val builder = StringBuilder()
        
        for (message in messages) {
            when (message.role) {
                "system" -> {
                    builder.append("<|system|>\\n${message.content}<|end|>\\n")
                }
                "user" -> {
                    builder.append("<|user|>\\n${message.content}<|end|>\\n")
                }
                "assistant" -> {
                    builder.append("<|assistant|>\\n${message.content}<|end|>\\n")
                }
            }
        }
        
        builder.append("<|assistant|>\\n")
        
        return builder.toString()
    }
}

/**
 * Gemma/Gemma 2 format with dual termination
 * Format:
 * <start_of_turn>user
 * {content}<end_of_turn>
 * <start_of_turn>model
 * {content}<end_of_turn><eos>
 * 
 * Note: Gemma 2 requires <end_of_turn><eos> for robust multi-turn stability
 * Reference: Google Gemma documentation
 */
/**
 * Gemma 2 format with BOS token and dual termination
 * Format:
 * <bos><start_of_turn>user
 * {content}<end_of_turn>
 * <start_of_turn>model
 * {content}<end_of_turn><eos>
 * 
 * Reference: Google Gemma 2 documentation
 */
class Gemma2Template : ChatTemplate {
    override val name = "gemma2"
    
    override fun format(messages: List<TemplateChatMessage>): String {
        val builder = StringBuilder()
        builder.append("<bos>")  // BOS token required
        
        var systemContent: String? = null
        
        for ((index, message) in messages.withIndex()) {
            when (message.role) {
                "system" -> {
                    systemContent = message.content
                    continue
                }
                "user" -> {
                    builder.append("<start_of_turn>user\n")
                    
                    // Prepend system to first user message if present
                    if (systemContent != null && index <= 1) {
                        builder.append("$systemContent\n\n")
                        systemContent = null
                    }
                    
                    builder.append("${message.content}<end_of_turn>\n")
                }
                "assistant" -> {
                    builder.append("<start_of_turn>model\n")
                    builder.append("${message.content}<end_of_turn>")
                    
                    // Gemma 2 dual termination (except last message)
                    if (index < messages.size - 1) {
                        builder.append("<eos>")
                    }
                    builder.append("\n")
                }
            }
        }
        
        builder.append("<start_of_turn>model\n")
        return builder.toString()
    }
}

/**
 * Gemma 3 format (text-only, for GGUF conversions)
 * Format:
 * <bos><start_of_turn>user
 * {content}<end_of_turn>
 * <start_of_turn>model
 * {content}<end_of_turn>
 * 
 * Note: Full multimodal Gemma 3 requires Transformers library.
 * GGUF conversions are text-only and use single termination.
 * 
 * Reference: Google Gemma 3 documentation
 */
class Gemma3Template : ChatTemplate {
    override val name = "gemma3"
    
    override fun format(messages: List<TemplateChatMessage>): String {
        val builder = StringBuilder()
        builder.append("<bos>")  // BOS token required
        
        var systemContent: String? = null
        
        for (message in messages) {
            when (message.role) {
                "system" -> {
                    systemContent = message.content
                    continue
                }
                "user" -> {
                    builder.append("<start_of_turn>user\n")
                    
                    // Prepend system to first user message if present
                    if (systemContent != null) {
                        builder.append("$systemContent\n\n")
                        systemContent = null
                    }
                    
                    builder.append("${message.content}<end_of_turn>\n")
                }
                "assistant" -> {
                    builder.append("<start_of_turn>model\n")
                    builder.append("${message.content}<end_of_turn>\n")
                    // Gemma 3 uses single termination (no <eos>)
                }
            }
        }
        
        builder.append("<start_of_turn>model\n")
        return builder.toString()
    }
}

/**
 * QwQ-32B Reasoning Model format
 * Uses ChatML base but with special thinking tag handling
 * Format:
 * <|im_start|>user
 * {content}<|im_end|>
 * <|im_start|>assistant
 * <think>
 * {reasoning}
 * </think>
 * {answer}<|im_end|>
 * 
 * CRITICAL: Reasoning blocks must be stripped from history for subsequent turns
 * Reference: Alibaba QwQ-32B-Preview documentation
 */
class QwQTemplate : ChatTemplate {
    override val name = "qwq"
    
    override fun format(messages: List<TemplateChatMessage>): String {
        val builder = StringBuilder()
        
        for (message in messages) {
            // Strip reasoning blocks from assistant messages in history
            val content = if (message.role == "assistant") {
                stripReasoningBlocks(message.content)
            } else {
                message.content
            }
            
            // Only add non-empty messages
            if (content.trim().isNotEmpty() || message.role != "assistant") {
                builder.append("<|im_start|>${message.role}\n")
                builder.append("$content<|im_end|>\n")
            }
        }
        
        // Add generation prompt with thinking prefix
        // Note: Client should inject <think>\n if model doesn't generate it
        builder.append("<|im_start|>assistant\n")
        
        return builder.toString()
    }
    
    private fun stripReasoningBlocks(content: String): String {
        // Remove <think>...</think> blocks (including nested content)
        return content.replace(Regex("<think>.*?</think>", setOf(RegexOption.DOT_MATCHES_ALL, RegexOption.MULTILINE)), "")
            .trim()
    }
}

/**
 * Mistral/Mixtral Instruction format (v0.1, v0.2, v0.3)
 * Format:
 * <s>[INST] {user_message} [/INST]{assistant_message}</s>[INST] {user_message} [/INST]
 * 
 * Note: v0.1/v0.2 don't have dedicated system token, system prompt goes in first [INST]
 * v0.3 supports function calling
 * Reference: Mistral AI documentation
 */
class MistralTemplate : ChatTemplate {
    override val name = "mistral"
    
    override fun format(messages: List<TemplateChatMessage>): String {
        val builder = StringBuilder()
        builder.append("<s>")
        
        var isFirst = true
        var systemMessage = messages.firstOrNull { it.role == "system" }?.content?.trim()
        
        for (message in messages) {
            when (message.role) {
                "system" -> continue // Already handled
                "user" -> {
                    if (!isFirst) {
                        builder.append("</s>")
                    }
                    
                    builder.append("[INST] ")
                    
                    // Prepend system message to first user message
                    if (isFirst && systemMessage != null) {
                        builder.append("$systemMessage\n\n")
                    }
                    
                    builder.append("${message.content.trim()} [/INST]")
                    isFirst = false
                }
                "assistant" -> {
                    builder.append("${message.content.trim()}")
                }
            }
        }
        
        return builder.toString()
    }
}

/**
 * DeepSeek Coder v2/v3.1 format
 * Format:
 * <｜begin▁of▁sentence｜>{system} User: {user} Assistant: {assistant}<｜end▁of▁sentence｜>User: {user} Assistant:
 * 
 * Note: Different from DeepSeek R1 reasoning format
 * Reference: DeepSeek Coder documentation
 */
class DeepSeekCoderTemplate : ChatTemplate {
    override val name = "deepseek-coder"
    
    override fun format(messages: List<TemplateChatMessage>): String {
        val builder = StringBuilder()
        builder.append("<｜begin▁of▁sentence｜>")
        
        val systemMessage = messages.firstOrNull { it.role == "system" }?.content?.trim()
        if (systemMessage != null) {
            builder.append("$systemMessage ")
        }
        
        var isFirst = true
        for (message in messages) {
            when (message.role) {
                "system" -> continue // Already handled
                "user" -> {
                    if (!isFirst) {
                        builder.append("<｜end▁of▁sentence｜>")
                    }
                    builder.append("User: ${message.content.trim()}\n")
                    isFirst = false
                }
                "assistant" -> {
                    builder.append("Assistant: ${message.content.trim()}\n")
                }
            }
        }
        
        // Add generation prompt
        builder.append("Assistant: ")
        
        return builder.toString()
    }
}

/**
 * DeepSeek R1/V3.1 Reasoning format (Non-thinking mode)
 * Format:
 * <｜begin▁of▁sentence｜>{system}<｜User｜>{query}<｜Assistant｜></think>{response}
 * 
 * Note: Includes </think> even in non-thinking mode
 * For thinking mode, model generates <think>reasoning</think> before answer
 * Reference: DeepSeek R1 documentation
 */
class DeepSeekR1Template : ChatTemplate {
    override val name = "deepseek-r1"
    
    override fun format(messages: List<TemplateChatMessage>): String {
        val builder = StringBuilder()
        builder.append("<｜begin▁of▁sentence｜>")
        
        val systemMessage = messages.firstOrNull { it.role == "system" }?.content?.trim()
        if (systemMessage != null) {
            builder.append(systemMessage)
        }
        
        for (message in messages) {
            when (message.role) {
                "system" -> continue // Already handled
                "user" -> {
                    builder.append("<｜User｜>${message.content.trim()}")
                }
                "assistant" -> {
                    builder.append("<｜Assistant｜></think>${message.content.trim()}")
                }
            }
        }
        
        // Add generation prompt with </think> prefix
        builder.append("<｜Assistant｜></think>")
        
        return builder.toString()
    }
}

/**
 * Raw template that uses user-provided string content with placeholders
 * Supports basic placeholder substitution: {system}, {user}, {assistant}
 */
class RawTemplate(
    override val name: String,
    private val content: String
) : ChatTemplate {
    
    override fun format(messages: List<TemplateChatMessage>): String {
        val builder = StringBuilder()
        
        for (message in messages) {
            val formatted = when (message.role) {
                "system" -> content.replace("{system}", message.content)
                "user" -> content.replace("{user}", message.content)
                "assistant" -> content.replace("{assistant}", message.content)
                else -> {
                    android.util.Log.w("RawTemplate", "Unknown role: ${message.role}, treating as user")
                    content.replace("{user}", message.content)
                }
            }
            builder.append(formatted)
        }
        
        return builder.toString()
    }
}

/**
 * Manager for chat templates
 * Handles template selection, detection, and message formatting
 * Supports both built-in and custom user-provided templates
 */
object ChatTemplateManager {
    // Built-in templates (immutable)
    private val builtInTemplates: Map<String, ChatTemplate> = mapOf(
        // ChatML variants
        "chatml" to ChatMLTemplate(),
        "qwen" to ChatMLTemplate(),
        "qwen2" to ChatMLTemplate(),
        "qwen2.5" to ChatMLTemplate(),
        "command-r" to ChatMLTemplate(),
        
        // Llama family
        "llama3" to Llama3Template(),
        "llama-3" to Llama3Template(),
        "llama3.1" to Llama3Template(),
        "llama3.3" to Llama3Template(),
        "llama2" to Llama2Template(),
        "llama-2" to Llama2Template(),
        
        // Reasoning models
        "qwq" to QwQTemplate(),
        "qwq-32b" to QwQTemplate(),
        "deepseek-r1" to DeepSeekR1Template(),
        "deepseek-v3" to DeepSeekR1Template(),
        
        // Mistral family
        "mistral" to MistralTemplate(),
        "mixtral" to MistralTemplate(),
        
        // DeepSeek Coder
        "deepseek-coder" to DeepSeekCoderTemplate(),
        
        // Other models
        "alpaca" to AlpacaTemplate(),
        "vicuna" to VicunaTemplate(),
        "phi" to PhiTemplate(),
        "phi-3" to PhiTemplate(),
        
        // Gemma family (separated by version)
        "gemma" to Gemma2Template(), // Default to Gemma 2 for legacy
        "gemma2" to Gemma2Template(),
        "gemma-2" to Gemma2Template(),
        "gemma3" to Gemma3Template(),
        "gemma-3" to Gemma3Template()
    )
    
    // Custom templates (mutable) - registered dynamically at runtime
    private val customTemplates: MutableMap<String, RawTemplate> = mutableMapOf()
    
    /**
     * Register a custom template with user-provided content
     * Template content should use placeholders: {system}, {user}, {assistant}
     * 
     * @param name Template name (case-insensitive)
     * @param content Template content with placeholders
     */
    @Synchronized
    fun registerCustomTemplate(name: String, content: String) {
        val key = name.lowercase()
        
        // Warn if overriding built-in template
        if (builtInTemplates.containsKey(key)) {
            android.util.Log.w(
                "ChatTemplateManager", 
                "Registering custom template '$name' that overrides built-in template"
            )
        }
        
        customTemplates[key] = RawTemplate(name, content)
        android.util.Log.i("ChatTemplateManager", "Registered custom template: $name")
    }
    
    /**
     * Unregister a custom template
     * 
     * @param name Template name to remove
     * @return true if template was removed, false if not found
     */
    @Synchronized
    fun unregisterCustomTemplate(name: String): Boolean {
        val key = name.lowercase()
        val removed = customTemplates.remove(key)
        
        if (removed != null) {
            android.util.Log.i("ChatTemplateManager", "Unregistered custom template: $name")
            return true
        }
        
        android.util.Log.w("ChatTemplateManager", "Custom template not found: $name")
        return false
    }
    
    /**
     * Get template by name
     * Checks custom templates first, then built-in templates
     * 
     * @param name Template name (case-insensitive)
     * @return Template instance or null if not found
     */
    fun getTemplate(name: String): ChatTemplate? {
        val key = name.lowercase()
        
        // Check custom templates first (allows user override)
        customTemplates[key]?.let { return it }
        
        // Fall back to built-in templates
        return builtInTemplates[key]
    }
    
    /**
     * Get list of all supported template names
     * Includes both custom and built-in templates
     * 
     * @return Sorted list of template names
     */
    fun getSupportedTemplates(): List<String> {
        val allTemplates = (customTemplates.keys + builtInTemplates.keys).toSet()
        return allTemplates.toList().sorted()
    }
    
    /**
     * Check if a template exists (custom or built-in)
     * 
     * @param name Template name (case-insensitive)
     * @return true if template exists
     */
    fun hasTemplate(name: String): Boolean {
        val key = name.lowercase()
        return customTemplates.containsKey(key) || builtInTemplates.containsKey(key)
    }
    
    /**
     * Get count of custom templates
     * 
     * @return Number of registered custom templates
     */
    fun getCustomTemplateCount(): Int = customTemplates.size
    
    /**
     * Auto-detect template based on model name/path
     * Uses pattern matching on filename for accurate detection
     */
    fun detectTemplate(modelPath: String): ChatTemplate {
        val lowerPath = modelPath.lowercase()
        
        return when {
            // Reasoning models (check first - more specific)
            lowerPath.contains("qwq") -> builtInTemplates["qwq"]!!
            lowerPath.contains("deepseek-r1") || lowerPath.contains("deepseek_r1") -> builtInTemplates["deepseek-r1"]!!
            
            // DeepSeek variants
            lowerPath.contains("deepseek-coder") || lowerPath.contains("deepseek_coder") -> builtInTemplates["deepseek-coder"]!!
            lowerPath.contains("deepseek") && (lowerPath.contains("v3") || lowerPath.contains("v3.1")) -> builtInTemplates["deepseek-r1"]!!
            
            // Qwen family (ChatML)
            lowerPath.contains("qwen2.5") || lowerPath.contains("qwen2_5") -> builtInTemplates["qwen2.5"]!!
            lowerPath.contains("qwen2") -> builtInTemplates["qwen2"]!!
            lowerPath.contains("qwen") -> builtInTemplates["qwen"]!!
            
            // Llama family
            lowerPath.contains("llama-3") || lowerPath.contains("llama3") || 
            lowerPath.contains("llama_3") -> builtInTemplates["llama3"]!!
            lowerPath.contains("llama-2") || lowerPath.contains("llama2") || 
            lowerPath.contains("llama_2") -> builtInTemplates["llama2"]!!
            
            // Mistral family
            lowerPath.contains("mixtral") -> builtInTemplates["mixtral"]!!
            lowerPath.contains("mistral") -> builtInTemplates["mistral"]!!
            
            // Command-R (uses ChatML)
            lowerPath.contains("command-r") || lowerPath.contains("command_r") -> builtInTemplates["command-r"]!!
            
            // Other models
            lowerPath.contains("phi-3") || lowerPath.contains("phi3") -> builtInTemplates["phi-3"]!!
            lowerPath.contains("phi") -> builtInTemplates["phi"]!!
            
            // Gemma family - detect version carefully
            lowerPath.contains("gemma-3") || lowerPath.contains("gemma3") || lowerPath.contains("gemma_3") -> {
                android.util.Log.i("ChatTemplateManager", "Detected Gemma 3 model - using gemma3 template")
                android.util.Log.w("ChatTemplateManager", "Note: Full multimodal Gemma 3 requires Transformers. GGUF is text-only.")
                builtInTemplates["gemma3"]!!
            }
            lowerPath.contains("gemma-2") || lowerPath.contains("gemma2") || lowerPath.contains("gemma_2") -> {
                android.util.Log.i("ChatTemplateManager", "Detected Gemma 2 model - using gemma2 template")
                builtInTemplates["gemma2"]!!
            }
            lowerPath.contains("gemma") -> {
                android.util.Log.i("ChatTemplateManager", "Detected legacy Gemma model - defaulting to gemma2 template")
                builtInTemplates["gemma2"]!!
            }
            
            lowerPath.contains("alpaca") -> builtInTemplates["alpaca"]!!
            lowerPath.contains("vicuna") -> builtInTemplates["vicuna"]!!
            
            // Default fallback to ChatML (most widely compatible)
            else -> {
                android.util.Log.w("ChatTemplateManager", "Unknown model format, defaulting to ChatML: $modelPath")
                builtInTemplates["chatml"]!!
            }
        }
    }
    
    /**
     * Format messages using specified or auto-detected template
     * 
     * @param messages List of chat messages to format
     * @param templateName Explicit template name (overrides auto-detection)
     * @param modelPath Model path for auto-detection
     * @return Formatted prompt string ready for inference
     */
    fun formatMessages(
        messages: List<TemplateChatMessage>,
        templateName: String? = null,
        modelPath: String? = null
    ): String {
        val template = when {
            templateName != null -> {
                getTemplate(templateName) ?: run {
                    android.util.Log.w("ChatTemplateManager", "Unknown template '$templateName', falling back to auto-detection")
                    detectTemplate(modelPath ?: "")
                }
            }
            modelPath != null -> detectTemplate(modelPath)
            else -> {
                android.util.Log.w("ChatTemplateManager", "No template or model path provided, using ChatML default")
                ChatMLTemplate()
            }
        }
        
        android.util.Log.d("ChatTemplateManager", "Using template: ${template.name} for formatting ${messages.size} messages")
        
        return template.format(messages)
    }
}