package com.write4me.llama_flutter_android

import java.io.IOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.ConcurrentHashMap
import kotlin.concurrent.thread

/**
 * Pipes [plain] and [session] into each other until either side ends, then
 * closes both. Returns at once; the work runs on two daemon threads.
 */
private fun pump(plain: Socket, session: PlmcSession, onEnd: () -> Unit = {}) {
    plain.tcpNoDelay = true
    val closeBoth = {
        runCatching { plain.close() }
        session.close()
        onEnd()
    }
    thread(isDaemon = true, name = "plmc-seal") {
        try {
            val input = plain.getInputStream()
            val buf = ByteArray(64 * 1024)
            while (true) {
                val n = input.read(buf)
                if (n < 0) break
                session.write(buf, 0, n)
            }
        } catch (_: IOException) {
        } finally {
            closeBoth()
        }
    }
    thread(isDaemon = true, name = "plmc-open") {
        try {
            val output = plain.getOutputStream()
            while (true) {
                val frame = session.read() ?: break
                output.write(frame)
                output.flush()
            }
        } catch (_: IOException) {
        } finally {
            closeBoth()
        }
    }
}

/**
 * Worker side: the only door to this phone's llama.cpp RPC server, which
 * listens on loopback ([upstreamPort]). Lets in masters that hold the key
 * [keySupplier] returns (read per connection, so a reset applies at once).
 *
 * Other apps on this phone can still reach the loopback port directly; that
 * threat is out of scope (see docs/superpowers/specs/2026-11-06-cluster-secure-pairing-design.md).
 */
class WorkerRelay(
    private val publicPort: Int,
    private val upstreamPort: Int,
    private val keySupplier: () -> ByteArray?,
    private val bindAddress: InetAddress = InetAddress.getByName("0.0.0.0"),
    private val log: (String) -> Unit = {},
) {
    private var server: ServerSocket? = null
    private val live: MutableSet<Socket> = ConcurrentHashMap.newKeySet()
    private val masters = ConcurrentHashMap<Socket, String>()

    /** The port actually listened on (useful when [publicPort] is 0). */
    val localPort: Int get() = server?.localPort ?: -1

    /** IP of a master connected right now, or null. */
    val peer: String? get() = masters.values.lastOrNull()

    fun start() {
        if (server != null) return
        val s = ServerSocket()
        s.reuseAddress = true
        s.bind(InetSocketAddress(bindAddress, publicPort), 50)
        server = s
        thread(isDaemon = true, name = "plmc-worker-accept") {
            while (!s.isClosed) {
                val client = runCatching { s.accept() }.getOrNull() ?: break
                live += client
                // Own thread per connection: a silent client can't hold up others.
                thread(isDaemon = true, name = "plmc-worker-conn") { serve(client) }
            }
        }
    }

    private fun serve(client: Socket) {
        val from = client.inetAddress?.hostAddress ?: "?"
        val session = try {
            PlmcHandshake.server(client, keySupplier)
        } catch (e: IOException) {
            log("Refused connection from $from (${e.javaClass.simpleName})")
            live -= client
            runCatching { client.close() }
            return
        }
        val upstream = try {
            Socket(InetAddress.getLoopbackAddress(), upstreamPort)
        } catch (e: IOException) {
            log("Worker RPC server not reachable on loopback")
            session.close()
            live -= client
            return
        }
        live += upstream
        masters[client] = from
        log("Master $from connected")
        pump(upstream, session) {
            masters.remove(client)
            live -= client
            live -= upstream
        }
    }

    /** Closes every connection (after a pairing reset). Keeps listening. */
    fun dropAll() {
        live.forEach { runCatching { it.close() } }
        live.clear()
        masters.clear()
    }

    fun stop() {
        runCatching { server?.close() }
        server = null
        dropAll()
    }
}

/**
 * Master side, one per worker: llama.cpp connects to 127.0.0.1:<port> as if
 * the worker were local; this dials the real worker and runs PLMC.
 */
class MasterRelay(
    private val workerHost: String,
    private val workerPort: Int,
    private val key: ByteArray,
    private val log: (String) -> Unit = {},
) {
    private var server: ServerSocket? = null
    private val live: MutableSet<Socket> = ConcurrentHashMap.newKeySet()

    /** Starts listening on loopback; returns the local port. */
    fun start(): Int {
        server?.let { return it.localPort }
        val s = ServerSocket(0, 50, InetAddress.getLoopbackAddress())
        server = s
        thread(isDaemon = true, name = "plmc-master-accept") {
            while (!s.isClosed) {
                val local = runCatching { s.accept() }.getOrNull() ?: break
                live += local
                thread(isDaemon = true, name = "plmc-master-conn") { forward(local) }
            }
        }
        return s.localPort
    }

    private fun forward(local: Socket) {
        val remote = Socket()
        live += remote
        val session = try {
            remote.connect(InetSocketAddress(workerHost, workerPort), 2000)
            PlmcHandshake.client(remote, key)
        } catch (e: IOException) {
            log("Worker $workerHost:$workerPort: ${e.javaClass.simpleName}")
            runCatching { remote.close() }
            runCatching { local.close() }
            live -= remote
            live -= local
            return
        }
        pump(local, session) {
            live -= local
            live -= remote
        }
    }

    fun stop() {
        runCatching { server?.close() }
        server = null
        live.forEach { runCatching { it.close() } }
        live.clear()
    }
}

data class RelayTarget(val host: String, val port: Int, val key: ByteArray)

/** The master's relays for the current cluster. */
object MasterRelays {
    private val relays = mutableListOf<MasterRelay>()
    private val names = ConcurrentHashMap<String, String>()

    /** Replaces the relays; returns "127.0.0.1:<port>" per target, in order. */
    @Synchronized
    fun use(targets: List<RelayTarget>, log: (String) -> Unit = {}): List<String> {
        clear()
        return targets.map { t ->
            val relay = MasterRelay(t.host, t.port, t.key, log)
            relays += relay
            val local = "127.0.0.1:${relay.start()}"
            names[local] = "${t.host}:${t.port}"
            local
        }
    }

    @Synchronized
    fun clear() {
        relays.forEach { it.stop() }
        relays.clear()
        names.clear()
    }

    /** Replaces local relay endpoints in [text] with the workers' real addresses. */
    fun displayName(text: String): String =
        names.entries.fold(text) { acc, (local, worker) -> acc.replace(local, worker) }
}
