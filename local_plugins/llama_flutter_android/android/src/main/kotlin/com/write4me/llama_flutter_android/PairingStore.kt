package com.write4me.llama_flutter_android

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.io.File
import java.security.KeyStore
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Phone-cluster pairing secrets, kept out of Hive and app backups: each one
 * is encrypted with a key that never leaves this phone's Android Keystore,
 * so a copied or backed-up file is useless elsewhere.
 *
 * - Worker: this phone's own secret, shown in its QR code.
 * - Master: one secret per paired worker, by worker ID.
 *
 * Files, not SharedPreferences, and no caching: the app and the worker
 * (":cluster" process) both read them.
 */
class PairingStore(context: Context) {
    private val dir = File(context.filesDir, "pairing").apply { mkdirs() }

    companion object {
        private const val ALIAS = "privatelm_pairing"
        const val SECRET_LEN = 32
        private val random = SecureRandom()
    }

    /** This worker's secret; created on first use, or if it can't be read. */
    @Synchronized
    fun workerSecret(): ByteArray = read(workerFile()) ?: resetWorkerSecret()

    /** Replaces this worker's secret: every paired master must scan again. */
    @Synchronized
    fun resetWorkerSecret(): ByteArray {
        val secret = ByteArray(SECRET_LEN).also { random.nextBytes(it) }
        write(workerFile(), secret)
        return secret
    }

    fun setMasterKey(workerId: String, key: ByteArray) {
        require(key.size == SECRET_LEN) { "Pairing key must be $SECRET_LEN bytes" }
        write(masterFile(workerId), key)
    }

    fun masterKey(workerId: String): ByteArray? = read(masterFile(workerId))

    fun removeMasterKey(workerId: String) {
        masterFile(workerId).delete()
    }

    private fun workerFile() = File(dir, "worker.bin")

    private fun masterFile(workerId: String): File {
        val hash = MessageDigest.getInstance("SHA-256").digest(workerId.toByteArray())
        return File(dir, "m_" + hash.joinToString("") { "%02x".format(it) } + ".bin")
    }

    private fun keystoreKey(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(
                KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(256)
                    .build()
            )
            generateKey()
        }
    }

    /** iv(12) ‖ ciphertext, written to a temp file and renamed into place. */
    private fun write(file: File, secret: ByteArray) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, keystoreKey()) }
        val sealed = cipher.iv + cipher.doFinal(secret)
        val tmp = File(file.parentFile, file.name + ".tmp")
        tmp.writeBytes(sealed)
        if (!tmp.renameTo(file)) {
            tmp.delete()
            throw java.io.IOException("Couldn't save pairing key")
        }
    }

    /** Null if missing, or if it can't be decrypted (e.g. restored from another phone). */
    private fun read(file: File): ByteArray? {
        if (!file.exists()) return null
        return runCatching {
            val sealed = file.readBytes()
            val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply {
                init(Cipher.DECRYPT_MODE, keystoreKey(), GCMParameterSpec(128, sealed, 0, 12))
            }
            cipher.doFinal(sealed, 12, sealed.size - 12).takeIf { it.size == SECRET_LEN }
        }.getOrNull()
    }
}
