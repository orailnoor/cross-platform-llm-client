package com.write4me.llama_flutter_android

import java.nio.ByteBuffer
import java.security.MessageDigest
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * PLMC v1: how a master and a worker phone prove they share the worker's
 * pairing secret (from its QR code) and then encrypt everything between them.
 *
 * Handshake: the client sends MAGIC, VERSION and a random nonce Nc; the
 * server answers with its nonce Ns and a tag over both; the client checks it
 * and answers with its own tag. Both sides then derive one AES-256-GCM key
 * per direction. Frames are numbered by a per-direction counter used as the
 * nonce, so a replayed, dropped or reordered frame fails to open.
 *
 * test_vectors/plmc_v1.json pins every value here; the Swift worker
 * (PlmcProtocol.swift) must produce the same bytes.
 */
object PlmcProtocol {
    val MAGIC: ByteArray = "PLMC".toByteArray(Charsets.US_ASCII)
    const val VERSION: Byte = 1
    const val NONCE_LEN = 32
    const val TAG_LEN = 32
    const val GCM_TAG_LEN = 16
    const val MAX_PLAINTEXT = 1 shl 20
    const val HANDSHAKE_TIMEOUT_MS = 5000

    data class SessionKeys(val c2s: ByteArray, val s2c: ByteArray)

    fun serverTag(key: ByteArray, nc: ByteArray, ns: ByteArray): ByteArray =
        hmac(key, "PLMC1 server".toByteArray() + nc + ns)

    fun clientTag(key: ByteArray, nc: ByteArray, ns: ByteArray): ByteArray =
        hmac(key, "PLMC1 client".toByteArray() + nc + ns)

    fun deriveKeys(key: ByteArray, nc: ByteArray, ns: ByteArray): SessionKeys = SessionKeys(
        c2s = hkdf(key, nc + ns, "PLMC1 c2s".toByteArray(), 32),
        s2c = hkdf(key, nc + ns, "PLMC1 s2c".toByteArray(), 32),
    )

    /** RFC 5869 HKDF-SHA256. */
    fun hkdf(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray {
        val prk = hmac(salt, ikm)
        val out = ByteArray(length)
        var block = ByteArray(0)
        var done = 0
        var i = 1
        while (done < length) {
            block = hmac(prk, block + info + byteArrayOf(i.toByte()))
            val n = minOf(block.size, length - done)
            System.arraycopy(block, 0, out, done, n)
            done += n
            i++
        }
        return out
    }

    fun constantTimeEquals(a: ByteArray, b: ByteArray): Boolean = MessageDigest.isEqual(a, b)

    private fun hmac(key: ByteArray, data: ByteArray): ByteArray =
        Mac.getInstance("HmacSHA256").run {
            init(SecretKeySpec(key, "HmacSHA256"))
            doFinal(data)
        }

    /** 4 zero bytes, then the frame counter big-endian. */
    private fun nonce(counter: Long): ByteArray =
        ByteBuffer.allocate(12).putInt(0).putLong(counter).array()

    /** Seals one direction's frames in order. Not thread-safe. */
    class FrameSealer(key: ByteArray) {
        private val key = SecretKeySpec(key, "AES")
        private val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        private var counter = 0L

        /** Ciphertext followed by the 16-byte tag. */
        fun seal(plain: ByteArray, off: Int, len: Int): ByteArray {
            check(counter != Long.MAX_VALUE) { "PLMC frame counter exhausted" }
            cipher.init(Cipher.ENCRYPT_MODE, key, GCMParameterSpec(GCM_TAG_LEN * 8, nonce(counter++)))
            return cipher.doFinal(plain, off, len)
        }
    }

    /** Opens one direction's frames in order. Not thread-safe. */
    class FrameOpener(key: ByteArray) {
        private val key = SecretKeySpec(key, "AES")
        private val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        private var counter = 0L

        /** Throws [javax.crypto.AEADBadTagException] if the frame was changed or is out of order. */
        fun open(sealed: ByteArray): ByteArray {
            check(counter != Long.MAX_VALUE) { "PLMC frame counter exhausted" }
            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(GCM_TAG_LEN * 8, nonce(counter++)))
            return cipher.doFinal(sealed)
        }
    }
}
