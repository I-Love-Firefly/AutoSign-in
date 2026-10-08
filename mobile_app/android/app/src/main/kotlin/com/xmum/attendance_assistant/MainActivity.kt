package com.xmum.attendance_assistant

import android.app.Activity
import android.content.Intent
import android.util.Base64
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.nio.charset.StandardCharsets
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec
import org.json.JSONObject

class MainActivity : FlutterActivity() {
    private val channelName = "com.xmum.attendance_assistant/archive"
    private val saveRequest = 4701
    private val openRequest = 4702
    private val maxBytes = 4 * 1024 * 1024
    private val iterations = 310_000
    private val aad = "XMUM_ACCOUNT_ARCHIVE_V1".toByteArray(StandardCharsets.UTF_8)
    private var pending: MethodChannel.Result? = null
    private var pendingBytes: ByteArray? = null
    private lateinit var enterprise: EnterpriseNetworkChannel

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        enterprise = EnterpriseNetworkChannel(this, flutterEngine.dartExecutor.binaryMessenger)
        CampusNetworkChannel(this, flutterEngine.dartExecutor.binaryMessenger)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "encrypt" -> crypto(call, result, true)
                    "decrypt" -> crypto(call, result, false)
                    "save" -> saveArchive(call, result)
                    "open" -> openArchive(result)
                    else -> result.notImplemented()
                }
            }
    }

    private fun key(password: String, salt: ByteArray): SecretKeySpec {
        val chars = password.toCharArray()
        val spec = PBEKeySpec(chars, salt, iterations, 256)
        return try {
            val bytes = SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256")
                .generateSecret(spec).encoded
            try {
                SecretKeySpec(bytes, "AES")
            } finally {
                bytes.fill(0)
            }
        } finally {
            chars.fill('\u0000')
            spec.clearPassword()
        }
    }

    private fun crypto(call: MethodCall, result: MethodChannel.Result, encrypt: Boolean) {
        val input = call.argument<ByteArray>("bytes")
        val password = call.argument<String>("password")
        if (input == null || input.size > maxBytes || password == null || password.length < 12) {
            result.error("INVALID_ARCHIVE", "文件或传输密码无效", null)
            return
        }
        try {
            val output = if (encrypt) {
                val random = SecureRandom()
                val salt = ByteArray(16).also(random::nextBytes)
                val nonce = ByteArray(12).also(random::nextBytes)
                val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                cipher.init(Cipher.ENCRYPT_MODE, key(password, salt), GCMParameterSpec(128, nonce))
                cipher.updateAAD(aad)
                val ciphertext = cipher.doFinal(input)
                JSONObject()
                    .put("format", "xmum-attendance-accounts-encrypted")
                    .put("version", 1)
                    .put("kdf", "PBKDF2-HMAC-SHA256")
                    .put("iterations", iterations)
                    .put("cipher", "AES-256-GCM")
                    .put("salt", Base64.encodeToString(salt, Base64.NO_WRAP))
                    .put("nonce", Base64.encodeToString(nonce, Base64.NO_WRAP))
                    .put("data", Base64.encodeToString(ciphertext, Base64.NO_WRAP))
                    .toString().toByteArray(StandardCharsets.UTF_8)
            } else {
                val archive = JSONObject(String(input, StandardCharsets.UTF_8))
                if (archive.optString("format") != "xmum-attendance-accounts-encrypted" ||
                    archive.optInt("version") != 1 ||
                    archive.optString("kdf") != "PBKDF2-HMAC-SHA256" ||
                    archive.optInt("iterations") != iterations ||
                    archive.optString("cipher") != "AES-256-GCM") {
                    throw IllegalArgumentException("unsupported format")
                }
                val salt = Base64.decode(archive.getString("salt"), Base64.NO_WRAP)
                val nonce = Base64.decode(archive.getString("nonce"), Base64.NO_WRAP)
                val ciphertext = Base64.decode(archive.getString("data"), Base64.NO_WRAP)
                if (salt.size != 16 || nonce.size != 12 || ciphertext.size < 16 ||
                    ciphertext.size > maxBytes) {
                    throw IllegalArgumentException("invalid sizes")
                }
                val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                cipher.init(Cipher.DECRYPT_MODE, key(password, salt), GCMParameterSpec(128, nonce))
                cipher.updateAAD(aad)
                cipher.doFinal(ciphertext)
            }
            result.success(output)
        } catch (_: Exception) {
            result.error(
                if (encrypt) "ENCRYPT_FAILED" else "DECRYPT_FAILED",
                if (encrypt) "加密失败" else "传输密码错误或文件已损坏",
                null,
            )
        }
    }

    private fun saveArchive(call: MethodCall, result: MethodChannel.Result) {
        if (pending != null) {
            result.error("BUSY", "已有文件操作正在进行", null)
            return
        }
        val bytes = call.argument<ByteArray>("bytes")
        val name = call.argument<String>("name")
        if (bytes == null || bytes.isEmpty() || bytes.size > maxBytes ||
            name == null || !name.matches(Regex("[a-zA-Z0-9._-]{1,100}\\.xmumaccounts"))) {
            result.error("INVALID_ARCHIVE", "导出文件无效", null)
            return
        }
        pending = result
        pendingBytes = bytes
        try {
            val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "application/octet-stream"
                putExtra(Intent.EXTRA_TITLE, name)
            }
            startActivityForResult(intent, saveRequest)
        } catch (_: Exception) {
            pending = null
            pendingBytes?.fill(0)
            pendingBytes = null
            result.error("NO_FILE_APP", "无法打开系统文件选择器", null)
        }
    }

    private fun openArchive(result: MethodChannel.Result) {
        if (pending != null) {
            result.error("BUSY", "已有文件操作正在进行", null)
            return
        }
        pending = result
        try {
            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "*/*"
            }
            startActivityForResult(intent, openRequest)
        } catch (_: Exception) {
            pending = null
            result.error("NO_FILE_APP", "无法打开系统文件选择器", null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (enterprise.onResult(requestCode, resultCode, data)) return
        if (requestCode != saveRequest && requestCode != openRequest) return
        val callback = pending ?: return
        pending = null
        try {
            if (resultCode != Activity.RESULT_OK || data?.data == null) {
                callback.success(null)
                return
            }
            if (requestCode == saveRequest) {
                val bytes = pendingBytes ?: throw IllegalStateException()
                contentResolver.openOutputStream(data.data!!, "w")?.use { it.write(bytes) }
                    ?: throw IllegalStateException()
                callback.success(true)
            } else {
                val input = contentResolver.openInputStream(data.data!!)
                    ?: throw IllegalStateException()
                val output = ByteArrayOutputStream()
                input.use { stream ->
                    val buffer = ByteArray(8192)
                    while (true) {
                        val count = stream.read(buffer)
                        if (count < 0) break
                        if (output.size() + count > maxBytes) throw IllegalArgumentException()
                        output.write(buffer, 0, count)
                    }
                }
                callback.success(output.toByteArray())
            }
        } catch (_: Exception) {
            callback.error("FILE_IO", "读取或保存文件失败；请检查文件大小和存储位置", null)
        } finally {
            pendingBytes?.fill(0)
            pendingBytes = null
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        enterprise.onPermissions(requestCode)
    }
}
