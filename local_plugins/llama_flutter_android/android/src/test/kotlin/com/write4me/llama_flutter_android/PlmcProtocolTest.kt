package com.write4me.llama_flutter_android

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File
import javax.crypto.AEADBadTagException

/** Known answers shared with the Swift side (test_vectors/plmc_v1.json). */
object PlmcVectors {
    private val values: Map<String, String> by lazy {
        // Gradle runs unit tests from the plugin's android/ directory.
        val json = File(System.getProperty("user.dir"), "../test_vectors/plmc_v1.json").readText()
        Regex("\"(\\w+)\"\\s*:\\s*\"([0-9a-f]*)\"").findAll(json)
            .associate { it.groupValues[1] to it.groupValues[2] }
    }

    operator fun get(name: String): ByteArray = hex(values.getValue(name))

    fun hex(s: String): ByteArray = ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
}

class PlmcProtocolTest {
    private val v = PlmcVectors

    @Test
    fun serverAndClientTagsMatchVectors() {
        assertArrayEquals(v["server_tag"], PlmcProtocol.serverTag(v["key"], v["nc"], v["ns"]))
        assertArrayEquals(v["client_tag"], PlmcProtocol.clientTag(v["key"], v["nc"], v["ns"]))
    }

    @Test
    fun sessionKeysMatchVectors() {
        val keys = PlmcProtocol.deriveKeys(v["key"], v["nc"], v["ns"])
        assertArrayEquals(v["c2s"], keys.c2s)
        assertArrayEquals(v["s2c"], keys.s2c)
    }

    @Test
    fun hkdfMatchesRfc5869Case1() {
        val okm = PlmcProtocol.hkdf(
            ikm = ByteArray(22) { 0x0b },
            salt = PlmcVectors.hex("000102030405060708090a0b0c"),
            info = PlmcVectors.hex("f0f1f2f3f4f5f6f7f8f9"),
            length = 42
        )
        assertArrayEquals(
            PlmcVectors.hex("3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865"),
            okm
        )
    }

    @Test
    fun framesMatchVectorsInOrder() {
        val sealer = PlmcProtocol.FrameSealer(v["c2s"])
        val p0 = v["frame0_plaintext"]
        val p1 = v["frame1_plaintext"]
        assertArrayEquals(v["frame0_sealed"], sealer.seal(p0, 0, p0.size))
        assertArrayEquals(v["frame1_sealed"], sealer.seal(p1, 0, p1.size))

        val opener = PlmcProtocol.FrameOpener(v["c2s"])
        assertArrayEquals(p0, opener.open(v["frame0_sealed"]))
        assertArrayEquals(p1, opener.open(v["frame1_sealed"]))
    }

    @Test(expected = AEADBadTagException::class)
    fun tamperedFrameFailsToOpen() {
        val sealed = v["frame0_sealed"]
        sealed[0] = (sealed[0].toInt() xor 1).toByte()
        PlmcProtocol.FrameOpener(v["c2s"]).open(sealed)
    }

    @Test(expected = AEADBadTagException::class)
    fun openerRejectsOutOfOrderFrames() {
        PlmcProtocol.FrameOpener(v["c2s"]).open(v["frame1_sealed"])
    }

    @Test
    fun constantsMatchSpec() {
        assertEquals("PLMC", String(PlmcProtocol.MAGIC, Charsets.US_ASCII))
        assertEquals(1, PlmcProtocol.VERSION.toInt())
        assertEquals(1 shl 20, PlmcProtocol.MAX_PLAINTEXT)
        assertEquals(5000, PlmcProtocol.HANDSHAKE_TIMEOUT_MS)
    }
}
