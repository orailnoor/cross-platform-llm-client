package com.write4me.llama_flutter_android

import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import java.io.IOException
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ExecutionException
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

class PlmcSessionTest {
    private val key = ByteArray(32) { it.toByte() }
    private val otherKey = ByteArray(32) { (it + 1).toByte() }
    private val listener = ServerSocket(0, 50, InetAddress.getLoopbackAddress())
    private val opened = mutableListOf<Socket>()

    @After
    fun tearDown() {
        opened.forEach { runCatching { it.close() } }
        listener.close()
    }

    /** Accepts one connection on [server] and runs the server handshake on it. */
    private fun serveOnce(server: ServerSocket = listener, serverKey: ByteArray? = key): CompletableFuture<PlmcSession> {
        val future = CompletableFuture<PlmcSession>()
        thread(isDaemon = true) {
            try {
                val s = server.accept().also { synchronized(opened) { opened += it } }
                future.complete(PlmcHandshake.server(s) { serverKey })
            } catch (e: Throwable) {
                future.completeExceptionally(e)
            }
        }
        return future
    }

    private fun connect(port: Int = listener.localPort): Socket =
        Socket(InetAddress.getLoopbackAddress(), port).also { synchronized(opened) { opened += it } }

    private fun <T> CompletableFuture<T>.await(): T = try {
        get(10, TimeUnit.SECONDS)
    } catch (e: ExecutionException) {
        throw e.cause!!
    }

    private fun assertServerFails(future: CompletableFuture<PlmcSession>) {
        try {
            future.await()
            fail("server handshake should have failed")
        } catch (e: IOException) {
            // expected
        }
    }

    /**
     * Forwards one connection to [listener], recording client→server bytes and
     * letting [transform] change a byte at a given absolute offset.
     */
    private inner class Proxy(val transform: (offset: Long, b: Int) -> Int = { _, b -> b }) {
        val server = ServerSocket(0, 50, InetAddress.getLoopbackAddress())
        val recorded = ByteArrayOutputStream()

        init {
            thread(isDaemon = true) {
                runCatching {
                    val down = server.accept()
                    val up = connect()
                    thread(isDaemon = true) { runCatching { up.getInputStream().copyTo(down.getOutputStream()) } }
                    val input = down.getInputStream()
                    val out = up.getOutputStream()
                    var offset = 0L
                    while (true) {
                        val b = input.read()
                        if (b < 0) break
                        synchronized(recorded) { recorded.write(b) }
                        out.write(transform(offset++, b))
                        out.flush()
                    }
                }
            }
        }
    }

    @Test
    fun roundTripBothDirections() {
        val serverSide = serveOnce()
        val client = PlmcHandshake.client(connect(), key)
        val server = serverSide.await()

        client.write("ping".toByteArray(), 0, 4)
        assertEquals("ping", String(server.read()!!))
        server.write("pong".toByteArray(), 0, 4)
        assertEquals("pong", String(client.read()!!))

        client.close()
        assertNull(server.read())
    }

    @Test
    fun wrongClientKeyIsClosedByServer() {
        val serverSide = serveOnce()
        try {
            PlmcHandshake.client(connect(), otherKey)
            fail("client handshake should have failed")
        } catch (e: IOException) {
            // PlmcAuthException or EOF: either way, no session
        }
        assertServerFails(serverSide)
    }

    @Test
    fun wrongServerKeyIsRejectedNotUnreachable() {
        serveOnce(serverKey = otherKey)
        try {
            PlmcHandshake.client(connect(), key)
            fail("client handshake should have failed")
        } catch (e: PlmcAuthException) {
            // expected: the worker's secret changed
        }
    }

    @Test
    fun serverWithoutKeyClosesConnection() {
        val serverSide = serveOnce(serverKey = null)
        try {
            PlmcHandshake.client(connect(), key)
            fail("client handshake should have failed")
        } catch (e: IOException) {
            assertTrue("no key is not a rejection", e !is PlmcAuthException)
        }
        assertServerFails(serverSide)
    }

    @Test
    fun badMagicClosedWithoutReply() {
        val serverSide = serveOnce()
        val raw = connect()
        raw.getOutputStream().apply {
            write("GET / HTTP/1.1\r\nHost: x\r\n\r\n".padEnd(64, ' ').toByteArray())
            flush()
        }
        assertServerFails(serverSide)
        raw.soTimeout = 5000
        assertEquals(-1, raw.getInputStream().read())
    }

    @Test
    fun oversizedFrameLengthRejected() {
        for (length in listOf(0x7FFFFFFF, -1, 16)) {
            val serverSide = serveOnce()
            val socket = connect()
            PlmcHandshake.client(socket, key)
            val server = serverSide.await()
            DataOutputStream(socket.getOutputStream()).apply {
                writeInt(length)
                write(ByteArray(64))
                flush()
            }
            try {
                server.read()
                fail("length $length should be rejected")
            } catch (e: IOException) {
                // expected
            }
        }
    }

    @Test
    fun tamperedFrameClosesSession() {
        val handshakeBytes = PlmcProtocol.MAGIC.size + 1 + PlmcProtocol.NONCE_LEN + PlmcProtocol.TAG_LEN
        // Flip a ciphertext byte of the first frame (after its 4-byte length).
        val proxy = Proxy { offset, b -> if (offset == handshakeBytes + 4L + 1) b xor 1 else b }
        val serverSide = serveOnce()
        val client = PlmcHandshake.client(connect(proxy.server.localPort), key)
        val server = serverSide.await()
        client.write("secret".toByteArray(), 0, 6)
        try {
            server.read()
            fail("tampered frame should not open")
        } catch (e: IOException) {
            // expected
        }
    }

    @Test
    fun replayedHandshakeFails() {
        val proxy = Proxy()
        val first = serveOnce()
        PlmcHandshake.client(connect(proxy.server.localPort), key).close()
        first.await()
        Thread.sleep(200)
        val captured = synchronized(proxy.recorded) { proxy.recorded.toByteArray() }
        assertTrue(captured.size >= PlmcProtocol.MAGIC.size + 1 + PlmcProtocol.NONCE_LEN + PlmcProtocol.TAG_LEN)

        val second = serveOnce()
        val raw = connect()
        raw.getOutputStream().apply { write(captured); flush() }
        assertServerFails(second)
    }

    @Test
    fun writeSplitsIntoMaxSizeFrames() {
        val serverSide = serveOnce()
        val client = PlmcHandshake.client(connect(), key)
        val server = serverSide.await()
        val data = ByteArray(PlmcProtocol.MAX_PLAINTEXT * 5 / 2) { (it * 31).toByte() }
        thread(isDaemon = true) { client.write(data, 0, data.size) }

        val frames = List(3) { server.read()!! }
        assertEquals(listOf(PlmcProtocol.MAX_PLAINTEXT, PlmcProtocol.MAX_PLAINTEXT, PlmcProtocol.MAX_PLAINTEXT / 2), frames.map { it.size })
        assertArrayEquals(data, frames.reduce { a, b -> a + b })
    }
}
