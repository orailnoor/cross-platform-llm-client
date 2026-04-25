package com.write4me.llama_flutter_android

import org.junit.Assert.*
import org.junit.Test

/**
 * Unit tests for chat template formatting
 * Validates correct format generation for all supported model families
 */
class ChatTemplateTest {

    @Test
    fun testChatMLFormat() {
        val template = ChatMLTemplate()
        val messages = listOf(
            TemplateChatMessage("system", "You are a helpful assistant."),
            TemplateChatMessage("user", "Hello!"),
            TemplateChatMessage("assistant", "Hi there!"),
            TemplateChatMessage("user", "How are you?")
        )
        
        val expected = """
            <|im_start|>system
            You are a helpful assistant.<|im_end|>
            <|im_start|>user
            Hello!<|im_end|>
            <|im_start|>assistant
            Hi there!<|im_end|>
            <|im_start|>user
            How are you?<|im_end|>
            <|im_start|>assistant
            
        """.trimIndent()
        
        assertEquals(expected, template.format(messages))
    }
    
    @Test
    fun testChatMLWithoutSystem() {
        val template = ChatMLTemplate()
        val messages = listOf(
            TemplateChatMessage("user", "Hello!")
        )
        
        val expected = """
            <|im_start|>user
            Hello!<|im_end|>
            <|im_start|>assistant
            
        """.trimIndent()
        
        assertEquals(expected, template.format(messages))
    }

    @Test
    fun testLlama3Format() {
        val template = Llama3Template()
        val messages = listOf(
            TemplateChatMessage("system", "You are a helpful assistant."),
            TemplateChatMessage("user", "Hello!"),
            TemplateChatMessage("assistant", "Hi there!"),
            TemplateChatMessage("user", "How are you?")
        )
        
        val expected = """
            <|begin_of_text|><|start_header_id|>system<|end_header_id|>
            
            You are a helpful assistant.<|eot_id|><|start_header_id|>user<|end_header_id|>
            
            Hello!<|eot_id|><|start_header_id|>assistant<|end_header_id|>
            
            Hi there!<|eot_id|><|start_header_id|>user<|end_header_id|>
            
            How are you?<|eot_id|><|start_header_id|>assistant<|end_header_id|>
            
            
        """.trimIndent()
        
        assertEquals(expected, template.format(messages))
    }
    
    @Test
    fun testLlama3WithoutSystem() {
        val template = Llama3Template()
        val messages = listOf(
            TemplateChatMessage("user", "Hello!")
        )
        
        val expected = """
            <|begin_of_text|><|start_header_id|>user<|end_header_id|>
            
            Hello!<|eot_id|><|start_header_id|>assistant<|end_header_id|>
            
            
        """.trimIndent()
        
        assertEquals(expected, template.format(messages))
    }

    @Test
    fun testLlama2FormatWithSystem() {
        val template = Llama2Template()
        val messages = listOf(
            TemplateChatMessage("system", "You are a helpful assistant."),
            TemplateChatMessage("user", "Hello!"),
            TemplateChatMessage("assistant", "Hi there!"),
            TemplateChatMessage("user", "How are you?")
        )
        
        val result = template.format(messages)
        
        // Check key components
        assertTrue(result.startsWith("<s>[INST] <<SYS>>"))
        assertTrue(result.contains("<</SYS>>"))
        assertTrue(result.contains("Hello! [/INST]"))
        assertTrue(result.contains("Hi there!"))
        assertTrue(result.contains("</s><s>[INST]"))
        assertTrue(result.contains("How are you? [/INST]"))
    }
    
    @Test
    fun testLlama2FormatWithoutSystem() {
        val template = Llama2Template()
        val messages = listOf(
            TemplateChatMessage("user", "Hello!")
        )
        
        val result = template.format(messages)
        
        assertEquals("<s>[INST] Hello! [/INST]", result)
    }

    @Test
    fun testQwQTemplateStripsReasoning() {
        val template = QwQTemplate()
        val messages = listOf(
            TemplateChatMessage("user", "Why is the sky blue?"),
            TemplateChatMessage("assistant", "<think>\nLet me think about light scattering...\n</think>\nThe sky is blue because of Rayleigh scattering."),
            TemplateChatMessage("user", "What about sunsets?")
        )
        
        val result = template.format(messages)
        
        // Reasoning should be stripped from history
        assertFalse(result.contains("<think>"))
        assertFalse(result.contains("Let me think about light scattering"))
        assertTrue(result.contains("The sky is blue because of Rayleigh scattering"))
        assertTrue(result.contains("What about sunsets?"))
        assertTrue(result.contains("<|im_start|>assistant\n"))
    }

    @Test
    fun testMistralFormat() {
        val template = MistralTemplate()
        val messages = listOf(
            TemplateChatMessage("system", "You are a helpful assistant."),
            TemplateChatMessage("user", "Hello!"),
            TemplateChatMessage("assistant", "Hi there!"),
            TemplateChatMessage("user", "How are you?")
        )
        
        val result = template.format(messages)
        
        assertTrue(result.startsWith("<s>[INST]"))
        assertTrue(result.contains("You are a helpful assistant."))
        assertTrue(result.contains("Hello! [/INST]"))
        assertTrue(result.contains("Hi there!"))
        assertTrue(result.contains("</s>[INST]"))
        assertTrue(result.contains("How are you? [/INST]"))
    }

    @Test
    fun testGemmaFormat() {
        val template = GemmaTemplate()
        val messages = listOf(
            TemplateChatMessage("system", "You are a helpful assistant."),
            TemplateChatMessage("user", "Hello!"),
            TemplateChatMessage("assistant", "Hi there!"),
            TemplateChatMessage("user", "How are you?")
        )
        
        val result = template.format(messages)
        
        // System should be prepended to first user message
        assertTrue(result.contains("You are a helpful assistant."))
        assertTrue(result.contains("<start_of_turn>user"))
        assertTrue(result.contains("<start_of_turn>model"))
        assertTrue(result.contains("<end_of_turn>"))
        
        // Should have dual termination for assistant messages (except last)
        assertTrue(result.contains("<end_of_turn><eos>"))
    }

    @Test
    fun testDeepSeekCoderFormat() {
        val template = DeepSeekCoderTemplate()
        val messages = listOf(
            TemplateChatMessage("system", "You are an expert programmer."),
            TemplateChatMessage("user", "Write a hello world"),
            TemplateChatMessage("assistant", "print('Hello World')"),
            TemplateChatMessage("user", "Now in Java")
        )
        
        val result = template.format(messages)
        
        assertTrue(result.startsWith("<｜begin▁of▁sentence｜>"))
        assertTrue(result.contains("You are an expert programmer."))
        assertTrue(result.contains("User: Write a hello world"))
        assertTrue(result.contains("Assistant: print('Hello World')"))
        assertTrue(result.contains("<｜end▁of▁sentence｜>"))
        assertTrue(result.endsWith("Assistant: "))
    }

    @Test
    fun testDeepSeekR1Format() {
        val template = DeepSeekR1Template()
        val messages = listOf(
            TemplateChatMessage("system", "You are helpful."),
            TemplateChatMessage("user", "Hello"),
            TemplateChatMessage("assistant", "Hi there")
        )
        
        val result = template.format(messages)
        
        assertTrue(result.startsWith("<｜begin▁of▁sentence｜>"))
        assertTrue(result.contains("You are helpful."))
        assertTrue(result.contains("<｜User｜>Hello"))
        assertTrue(result.contains("<｜Assistant｜></think>Hi there"))
        assertTrue(result.endsWith("<｜Assistant｜></think>"))
    }

    @Test
    fun testPhiFormat() {
        val template = PhiTemplate()
        val messages = listOf(
            TemplateChatMessage("system", "You are a helpful assistant."),
            TemplateChatMessage("user", "Hello!")
        )
        
        val expected = """
            <|system|>
            You are a helpful assistant.<|end|>
            <|user|>
            Hello!<|end|>
            <|assistant|>
            
        """.trimIndent()
        
        assertEquals(expected, template.format(messages))
    }

    @Test
    fun testAlpacaFormat() {
        val template = AlpacaTemplate()
        val messages = listOf(
            TemplateChatMessage("user", "Hello!"),
            TemplateChatMessage("assistant", "Hi there!")
        )
        
        val result = template.format(messages)
        
        assertTrue(result.contains("### Instruction:"))
        assertTrue(result.contains("### Response:"))
        assertTrue(result.contains("Hello!"))
        assertTrue(result.contains("Hi there!"))
        assertTrue(result.endsWith("### Response:\n"))
    }

    @Test
    fun testVicunaFormat() {
        val template = VicunaTemplate()
        val messages = listOf(
            TemplateChatMessage("user", "Hello!"),
            TemplateChatMessage("assistant", "Hi there!")
        )
        
        val result = template.format(messages)
        
        assertTrue(result.contains("USER: Hello!"))
        assertTrue(result.contains("ASSISTANT: Hi there!"))
        assertTrue(result.endsWith("ASSISTANT:"))
    }

    @Test
    fun testTemplateManagerDetection() {
        // Test Qwen detection
        assertEquals("chatml", ChatTemplateManager.detectTemplate("Qwen2-7B-Instruct.gguf").name)
        assertEquals("chatml", ChatTemplateManager.detectTemplate("qwen2.5-14b-instruct-q4_k_m.gguf").name)
        
        // Test Llama-3 detection
        assertEquals("llama3", ChatTemplateManager.detectTemplate("Llama-3-8B-Instruct.gguf").name)
        assertEquals("llama3", ChatTemplateManager.detectTemplate("llama3.1-70b-instruct-q4_k_m.gguf").name)
        
        // Test Llama-2 detection
        assertEquals("llama2", ChatTemplateManager.detectTemplate("Llama-2-7B-Chat.gguf").name)
        
        // Test QwQ detection
        assertEquals("qwq", ChatTemplateManager.detectTemplate("QwQ-32B-Preview-Q4_K_M.gguf").name)
        
        // Test Mistral detection
        assertEquals("mistral", ChatTemplateManager.detectTemplate("Mistral-7B-Instruct-v0.3.gguf").name)
        assertEquals("mistral", ChatTemplateManager.detectTemplate("Mixtral-8x7B-Instruct-v0.1.gguf").name)
        
        // Test DeepSeek detection
        assertEquals("deepseek-coder", ChatTemplateManager.detectTemplate("DeepSeek-Coder-V2-Lite-Instruct.gguf").name)
        assertEquals("deepseek-r1", ChatTemplateManager.detectTemplate("DeepSeek-R1-Distill-Qwen-7B.gguf").name)
        
        // Test Gemma detection
        assertEquals("gemma", ChatTemplateManager.detectTemplate("gemma-2-9b-it-Q4_K_M.gguf").name)
        
        // Test Phi detection
        assertEquals("phi", ChatTemplateManager.detectTemplate("Phi-3-mini-4k-instruct.gguf").name)
        
        // Test default fallback
        assertEquals("chatml", ChatTemplateManager.detectTemplate("unknown-model.gguf").name)
    }

    @Test
    fun testTemplateManagerFormatMessages() {
        val messages = listOf(
            TemplateChatMessage("user", "Hello!")
        )
        
        // Test explicit template name
        val chatMLResult = ChatTemplateManager.formatMessages(messages, templateName = "chatml")
        assertTrue(chatMLResult.contains("<|im_start|>"))
        
        // Test auto-detection via model path
        val llama3Result = ChatTemplateManager.formatMessages(messages, modelPath = "Llama-3-8B.gguf")
        assertTrue(llama3Result.contains("<|begin_of_text|>"))
        
        // Test template name override
        val overrideResult = ChatTemplateManager.formatMessages(
            messages, 
            templateName = "llama2", 
            modelPath = "Llama-3-8B.gguf" // Should use llama2 despite path
        )
        assertTrue(overrideResult.contains("[INST]"))
    }

    @Test
    fun testGetSupportedTemplates() {
        val templates = ChatTemplateManager.getSupportedTemplates()
        
        assertTrue(templates.isNotEmpty())
        assertTrue(templates.contains("chatml"))
        assertTrue(templates.contains("llama3"))
        assertTrue(templates.contains("llama2"))
        assertTrue(templates.contains("qwq"))
        assertTrue(templates.contains("mistral"))
        assertTrue(templates.contains("gemma"))
        assertTrue(templates.contains("phi"))
    }

    @Test
    fun testEmptyMessages() {
        val template = ChatMLTemplate()
        val result = template.format(emptyList())
        
        // Should still have generation prompt
        assertEquals("<|im_start|>assistant\n", result)
    }

    @Test
    fun testSingleUserMessage() {
        val template = ChatMLTemplate()
        val messages = listOf(TemplateChatMessage("user", "Hello!"))
        
        val expected = """
            <|im_start|>user
            Hello!<|im_end|>
            <|im_start|>assistant
            
        """.trimIndent()
        
        assertEquals(expected, template.format(messages))
    }

    @Test
    fun testMultiTurnConversation() {
        val template = Llama3Template()
        val messages = listOf(
            TemplateChatMessage("system", "You are a helpful assistant."),
            TemplateChatMessage("user", "What is 2+2?"),
            TemplateChatMessage("assistant", "2+2 equals 4."),
            TemplateChatMessage("user", "What about 3+3?"),
            TemplateChatMessage("assistant", "3+3 equals 6."),
            TemplateChatMessage("user", "And 4+4?")
        )
        
        val result = template.format(messages)
        
        // Verify all turns are present
        assertTrue(result.contains("What is 2+2?"))
        assertTrue(result.contains("2+2 equals 4."))
        assertTrue(result.contains("What about 3+3?"))
        assertTrue(result.contains("3+3 equals 6."))
        assertTrue(result.contains("And 4+4?"))
        
        // Verify proper structure
        assertTrue(result.startsWith("<|begin_of_text|>"))
        assertTrue(result.contains("<|eot_id|>"))
        assertTrue(result.endsWith("<|start_header_id|>assistant<|end_header_id|>\n\n"))
    }

    @Test
    fun testSpecialCharactersInContent() {
        val template = ChatMLTemplate()
        val messages = listOf(
            TemplateChatMessage("user", "What about <special> tags & symbols?"),
            TemplateChatMessage("assistant", "They should work: < > & \" ' \n newlines too!")
        )
        
        val result = template.format(messages)
        
        // Special characters should be preserved
        assertTrue(result.contains("<special>"))
        assertTrue(result.contains("&"))
        assertTrue(result.contains("\""))
        assertTrue(result.contains("'"))
    }

    @Test
    fun testWhitespaceHandling() {
        val template = Llama3Template()
        val messages = listOf(
            TemplateChatMessage("user", "  Extra spaces  "),
            TemplateChatMessage("assistant", "\nNewline at start")
        )
        
        val result = template.format(messages)
        
        // Whitespace should be trimmed appropriately
        assertFalse(result.contains("  Extra spaces  <|eot_id|>"))
        assertTrue(result.contains("Extra spaces<|eot_id|>"))
    }
}
