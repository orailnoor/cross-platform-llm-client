package com.write4me.llama_flutter_android

import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.DataInputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread
import kotlin.random.Random

class PlmcRelaysTest {
    /** What llama.cpp uses on both sides: its RPC server and the master's endpoints are IPv4. */
    private val loopback = InetAddress.getByName("127.0.0.1")
    private val key = ByteArray(32) { it.toByte() }
    private val otherKey = ByteArray(32) { (it + 7).toByte() }

    /** Stands in for llama.cpp's RPC server: echoes everything back. */
    private val echo = ServerSocket(0, 50, loopback)
    private val echoAccepts = AtomicInteger()
    private val workerKey = AtomicReference(key)
    private val worker = WorkerRelay(0, echo.localPort, { workerKey.get() }, loopback)
    private val cleanup = mutableListOf<() -> Unit>()

    init {
        thread(isDaemon = true) {
            while (!echo.isClosed) {
                val s = runCatching { echo.accept() }.getOrNull() ?: break
                echoAccepts.incrementAndGet()
                thread(isDaemon = true) { runCatching { s.use { it.getInputStream().copyTo(it.getOutputStream(), 64 * 1024) } } }
            }
        }
        worker.start()
    }

    @After
    fun tearDown() {
        cleanup.forEach { runCatching(it) }
        worker.stop()
        echo.close()
    }

    private fun master(masterKey: ByteArray = key, port: Int = worker.localPort): Int {
        val relay = MasterRelay("127.0.0.1", port, masterKey)
        cleanup += { relay.stop() }
        return relay.start()
    }

    private fun connect(port: Int): Socket = Socket(loopback, port).also { s ->
        cleanup += { s.close() }
        s.soTimeout = 10_000
    }

    private fun roundTrip(localPort: Int, text: String) {
        val s = connect(localPort)
        s.getOutputStream().apply { write(text.toByteArray()); flush() }
        val back = ByteArray(text.length)
        DataInputStream(s.getInputStream()).readFully(back)
        assertEquals(text, String(back))
    }

    /** Closed by the other side: a clean EOF, or a reset if it closed with our bytes unread. */
    private fun assertClosed(s: Socket) {
        val result = try {
            s.getInputStream().read()
        } catch (e: java.net.SocketException) {
            -1
        }
        assertEquals(-1, result)
    }

    @Test
    fun echoThroughBothRelays() {
        roundTrip(master(), "abc")
    }

    @Test
    fun largeTransferIsByteExact() {
        val total = 64 shl 20
        val data = Random(42).nextBytes(total)
        val s = connect(master())
        val chunks = intArrayOf(7 * 1024, 1_363_148, 3)
        val started = System.nanoTime()
        thread(isDaemon = true) {
            val out = s.getOutputStream()
            var pos = 0
            var i = 0
            while (pos < total) {
                val n = minOf(chunks[i++ % chunks.size], total - pos)
                out.write(data, pos, n)
                pos += n
            }
            out.flush()
        }
        val digest = MessageDigest.getInstance("SHA-256")
        val input = s.getInputStream()
        val buf = ByteArray(256 * 1024)
        var received = 0
        while (received < total) {
            val n = input.read(buf)
            assertTrue("stream ended early at $received", n > 0)
            digest.update(buf, 0, n)
            received += n
        }
        val seconds = (System.nanoTime() - started) / 1e9
        println("PLMC relay round trip: %.0f MB/s each way".format(total / 1e6 / seconds))
        assertArrayEquals(MessageDigest.getInstance("SHA-256").digest(data), digest.digest())
    }

    @Test
    fun wrongKeyNeverReachesUpstream() {
        val s = connect(master(otherKey))
        s.getOutputStream().apply { write("hello".toByteArray()); flush() }
        assertClosed(s)
        Thread.sleep(200)
        assertEquals(0, echoAccepts.get())
    }

    @Test
    fun idleConnectionTimesOutAndDoesNotBlockOthers() {
        val idle = connect(worker.localPort)
        idle.soTimeout = 7_000

        val started = System.nanoTime()
        roundTrip(master(), "still works")
        assertTrue("a silent client blocked a real master", System.nanoTime() - started < 1_000_000_000L)

        val waitStart = System.nanoTime()
        val result = try {
            idle.getInputStream().read()
        } catch (e: SocketTimeoutException) {
            -2
        }
        assertEquals("idle connection should be closed by the worker", -1, result)
        assertTrue(System.nanoTime() - waitStart < 6_000_000_000L)
    }

    @Test
    fun dripFeedingClientIsDroppedAfterTotalHandshakeDeadline() {
        val drip = connect(worker.localPort)
        val started = System.nanoTime()
        val out = drip.getOutputStream()
        // A valid hello, one byte a second: never trips a per-read timeout,
        // but the 5 s budget is for the whole handshake.
        val hello = PlmcProtocol.MAGIC + byteArrayOf(PlmcProtocol.VERSION) + ByteArray(PlmcProtocol.NONCE_LEN)
        var closed = false
        for (i in 0 until 12) {
            try {
                out.write(hello[i].toInt())
                out.flush()
            } catch (e: java.io.IOException) {
                closed = true
                break
            }
            drip.soTimeout = 1000
            val r = try { drip.getInputStream().read() } catch (e: SocketTimeoutException) { -2 } catch (e: java.net.SocketException) { -1 }
            if (r == -1) {
                closed = true
                break
            }
        }
        val seconds = (System.nanoTime() - started) / 1e9
        assertTrue("drip-feeding client still open after %.1fs".format(seconds), closed && seconds < 7.5)
    }

    @Test
    fun dropAllClosesLiveSessions() {
        val s = connect(master())
        s.getOutputStream().apply { write("x".toByteArray()); flush() }
        assertEquals('x'.code, s.getInputStream().read())

        s.soTimeout = 1_000
        worker.dropAll()
        assertEquals(-1, s.getInputStream().read())
    }

    @Test
    fun keySupplierIsReadPerConnection() {
        roundTrip(master(key), "first")
        workerKey.set(otherKey)

        val stale = connect(master(key))
        stale.getOutputStream().apply { write("x".toByteArray()); flush() }
        assertClosed(stale)

        roundTrip(master(otherKey), "second")
    }

    @Test
    fun peerIsReportedWhileConnected() {
        val s = connect(master())
        s.getOutputStream().apply { write("x".toByteArray()); flush() }
        s.getInputStream().read()
        assertEquals("127.0.0.1", worker.peer)
    }

    @Test
    fun peerChangesAreReportedOnConnectAndDisconnect() {
        val changes = java.util.concurrent.LinkedBlockingQueue<String>()
        val relay = WorkerRelay(0, echo.localPort, { key }, loopback, onPeerChange = { changes.put(it ?: "none") })
        relay.start()
        cleanup += { relay.stop() }

        val s = connect(master(port = relay.localPort))
        s.getOutputStream().apply { write("x".toByteArray()); flush() }
        s.getInputStream().read()
        assertEquals("127.0.0.1", changes.poll(2, java.util.concurrent.TimeUnit.SECONDS))

        s.close()
        assertEquals("none", changes.poll(2, java.util.concurrent.TimeUnit.SECONDS))
    }

    @Test
    fun relaysUseIpv4LoopbackLikeLlamaCpp() {
        // The worker relay must reach an RPC server bound to 127.0.0.1, and
        // llama.cpp on the master connects to the "127.0.0.1:<port>" it's given.
        val endpoint = MasterRelays.use(listOf(RelayTarget("127.0.0.1", worker.localPort, key)))[0]
        cleanup += { MasterRelays.clear() }
        val host = endpoint.substringBeforeLast(':')
        val s = Socket(host, endpoint.substringAfterLast(':').toInt()).also { cleanup += { it.close() } }
        s.soTimeout = 10_000
        s.getOutputStream().apply { write("v4".toByteArray()); flush() }
        val back = ByteArray(2)
        DataInputStream(s.getInputStream()).readFully(back)
        assertEquals("v4", String(back))
    }

    @Test
    fun masterRelaysMapLocalEndpointsBackToWorkers() {
        val endpoints = MasterRelays.use(listOf(RelayTarget("127.0.0.1", worker.localPort, key)))
        cleanup += { MasterRelays.clear() }
        assertEquals(1, endpoints.size)
        assertTrue(endpoints[0].startsWith("127.0.0.1:"))
        assertEquals("127.0.0.1:${worker.localPort}", MasterRelays.displayName(endpoints[0]))
        assertEquals("RPC0[127.0.0.1:${worker.localPort}]", MasterRelays.displayName("RPC0[${endpoints[0]}]"))
        roundTrip(endpoints[0].substringAfterLast(':').toInt(), "mapped")
    }

    /** Runs against a Swift worker relay when PLMC_SWIFT_WORKER=host:port is set. */
    @Test
    fun interopWithSwiftWorker() {
        val target = System.getenv("PLMC_SWIFT_WORKER")
        assumeTrue(!target.isNullOrEmpty())
        val workerPort = target!!.substringAfterLast(':').toInt()
        val port = master(key, workerPort)
        roundTrip(port, "abc")

        // Byte-exact across many frames and uneven writes.
        val data = Random(7).nextBytes(4 shl 20)
        val s = connect(port)
        thread(isDaemon = true) {
            val out = s.getOutputStream()
            var pos = 0
            while (pos < data.size) {
                val n = minOf(1_300_001, data.size - pos)
                out.write(data, pos, n)
                pos += n
            }
            out.flush()
        }
        val back = ByteArray(data.size)
        DataInputStream(s.getInputStream()).readFully(back)
        assertArrayEquals(data, back)

        // A master with the wrong key gets nothing through.
        val stale = connect(master(otherKey, workerPort))
        stale.getOutputStream().apply { write("x".toByteArray()); flush() }
        assertClosed(stale)
    }
}
