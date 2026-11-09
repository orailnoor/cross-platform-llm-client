package com.write4me.llama_flutter_android

/**
 * JNI entry points added on top of the Pigeon API: structured output
 * (grammars), generation stats, MTP speculative decoding, Jinja chat
 * templates with tool calls, embeddings and the tokenizer.
 */
object LlamaExtNative {
    init {
        System.loadLibrary("llama_jni")
    }

    /** GBNF grammar (root rule "root") for the next generation only; "" clears. */
    external fun nativeSetGrammar(grammar: String)

    /** JSON schema -> GBNF. Throws IllegalArgumentException on a bad schema. */
    external fun nativeJsonSchemaToGrammar(schema: String): String

    /** Last generation: prompt/completion tokens, finish reason, MTP counts (JSON). */
    external fun nativeLastStats(): String

    external fun nativeTokenize(text: String, addSpecial: Boolean, parseSpecial: Boolean): IntArray
    external fun nativeDetokenize(tokens: IntArray, special: Boolean): String

    /** Pooled embedding of [text] from the loaded model (clears the chat KV cache). */
    external fun nativeEmbed(text: String, normalize: Boolean): FloatArray

    external fun nativeHasVision(): Boolean

    /** Loads the vision projector now (lazy vision). Null on success. */
    external fun nativeLoadMmproj(path: String, nThreads: Long): String?

    /** Next model load: also load the model's own NextN (MTP) layers. */
    external fun nativeSetLoadMtp(loadLayers: Boolean, nDraft: Int)

    /** Creates the MTP draft head ("" = the model's own NextN layers). Null on success. */
    external fun nativeLoadMtp(draftPath: String, nDraft: Int, pMin: Float): String?
    external fun nativeFreeMtp()
    external fun nativeSetMtp(enabled: Boolean, nDraft: Int)
    external fun nativeMtpInfo(): String

    external fun nativeModelInfo(): String

    /** OpenAI chat request (JSON) -> prompt via the model's Jinja template (JSON). */
    external fun nativeChatPrepare(requestJson: String): String

    /** Model output -> OpenAI message with tool_calls (JSON). */
    external fun nativeChatParse(text: String, isPartial: Boolean): String
}
