package com.write4me.llama_flutter_android

import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.IOException
import java.net.Socket
import java.security.GeneralSecurityException
import java.security.SecureRandom

/** The other side doesn't hold this worker's current secret (it was reset). */
class PlmcAuthException(message: String) : IOException(message)

/** An authenticated, encrypted PLMC v1 connection. */
class PlmcSession internal constructor(
    private val socket: Socket,
    private val input: DataInputStream,
    private val output: DataOutputStream,
    private val sealer: PlmcProtocol.FrameSealer,
    private val opener: PlmcProtocol.FrameOpener,
) {
    val remoteAddress: String get() = socket.inetAddress?.hostAddress ?: ""

    /** Sends [len] bytes as one or more frames of at most [PlmcProtocol.MAX_PLAINTEXT]. */
    @Synchronized
    fun write(buf: ByteArray, off: Int, len: Int) {
        var pos = off
        val end = off + len
        while (pos < end) {
            val n = minOf(PlmcProtocol.MAX_PLAINTEXT, end - pos)
            val sealed = sealer.seal(buf, pos, n)
            output.writeInt(sealed.size)
            output.write(sealed)
            pos += n
        }
        output.flush()
    }

    /** The next frame's plaintext, or null when the other side closed cleanly. */
    fun read(): ByteArray? {
        val first = input.read()
        if (first < 0) return null
        val length = (first shl 24) or (input.readUnsignedByte() shl 16) or
            (input.readUnsignedByte() shl 8) or input.readUnsignedByte()
        // Checked before allocating: a hostile length can't make us reserve memory.
        if (length <= PlmcProtocol.GCM_TAG_LEN || length > PlmcProtocol.MAX_PLAINTEXT + PlmcProtocol.GCM_TAG_LEN) {
            throw IOException("Bad PLMC frame length")
        }
        val sealed = ByteArray(length)
        input.readFully(sealed)
        return try {
            opener.open(sealed)
        } catch (e: GeneralSecurityException) {
            throw IOException("PLMC frame failed to open")
        }
    }

    fun close() {
        runCatching { socket.close() }
    }
}

object PlmcHandshake {
    private val random = SecureRandom()

    private fun nonce() = ByteArray(PlmcProtocol.NONCE_LEN).also { random.nextBytes(it) }

    /** Master side: proves it holds [key] and checks that the worker does too. */
    fun client(socket: Socket, key: ByteArray): PlmcSession {
        socket.soTimeout = PlmcProtocol.HANDSHAKE_TIMEOUT_MS
        socket.tcpNoDelay = true
        val input = DataInputStream(BufferedInputStream(socket.getInputStream()))
        val output = DataOutputStream(BufferedOutputStream(socket.getOutputStream()))
        val nc = nonce()
        output.write(PlmcProtocol.MAGIC)
        output.writeByte(PlmcProtocol.VERSION.toInt())
        output.write(nc)
        output.flush()

        val ns = ByteArray(PlmcProtocol.NONCE_LEN).also { input.readFully(it) }
        val serverTag = ByteArray(PlmcProtocol.TAG_LEN).also { input.readFully(it) }
        if (!PlmcProtocol.constantTimeEquals(serverTag, PlmcProtocol.serverTag(key, nc, ns))) {
            runCatching { socket.close() }
            throw PlmcAuthException("Worker doesn't hold this pairing key")
        }
        output.write(PlmcProtocol.clientTag(key, nc, ns))
        output.flush()

        socket.soTimeout = 0
        val keys = PlmcProtocol.deriveKeys(key, nc, ns)
        return PlmcSession(socket, input, output, PlmcProtocol.FrameSealer(keys.c2s), PlmcProtocol.FrameOpener(keys.s2c))
    }

    /**
     * Worker side. Throws (without answering) on anything but a master that
     * proves it holds the key [keySupplier] returns; null means no key yet.
     * The caller closes the socket on failure.
     */
    fun server(socket: Socket, keySupplier: () -> ByteArray?): PlmcSession {
        socket.soTimeout = PlmcProtocol.HANDSHAKE_TIMEOUT_MS
        socket.tcpNoDelay = true
        val input = DataInputStream(BufferedInputStream(socket.getInputStream()))
        val output = DataOutputStream(BufferedOutputStream(socket.getOutputStream()))
        try {
            val magic = ByteArray(PlmcProtocol.MAGIC.size).also { input.readFully(it) }
            val version = input.readByte()
            if (!magic.contentEquals(PlmcProtocol.MAGIC) || version != PlmcProtocol.VERSION) {
                throw IOException("Not a PLMC v1 client")
            }
            val nc = ByteArray(PlmcProtocol.NONCE_LEN).also { input.readFully(it) }
            val key = keySupplier() ?: throw IOException("No pairing key")
            val ns = nonce()
            output.write(ns)
            output.write(PlmcProtocol.serverTag(key, nc, ns))
            output.flush()

            val clientTag = ByteArray(PlmcProtocol.TAG_LEN).also { input.readFully(it) }
            if (!PlmcProtocol.constantTimeEquals(clientTag, PlmcProtocol.clientTag(key, nc, ns))) {
                throw IOException("Client doesn't hold the pairing key")
            }
            socket.soTimeout = 0
            val keys = PlmcProtocol.deriveKeys(key, nc, ns)
            return PlmcSession(socket, input, output, PlmcProtocol.FrameSealer(keys.s2c), PlmcProtocol.FrameOpener(keys.c2s))
        } catch (e: IOException) {
            runCatching { socket.close() }
            throw e
        }
    }
}
