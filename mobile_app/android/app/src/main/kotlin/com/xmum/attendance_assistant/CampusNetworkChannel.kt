package com.xmum.attendance_assistant

import android.app.Activity
import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.Uri
import android.content.Intent
import android.provider.Settings
import android.widget.Toast
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.net.HttpURLConnection
import java.net.Inet4Address
import java.net.URL
import java.io.ByteArrayOutputStream
import java.nio.charset.Charset
import java.util.concurrent.Executors

class CampusNetworkChannel(private val activity: Activity, messenger: BinaryMessenger) {
    private val manager = activity.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    private val executor = Executors.newSingleThreadExecutor()
    private var wifi: Network? = null
    private var ip: String? = null
    private val paths = setOf("/cgi-bin/rad_user_info", "/cgi-bin/get_challenge", "/cgi-bin/srun_portal", "/cgi-bin/rad_user_dm", "/v1/srun_portal_online")
    private data class Reply(val body: String, val redirect: String?)

    private fun request(selected: Network, url: URL, onlineList: Boolean = false, allowRedirect: Boolean = false): Reply {
        val connection = selected.openConnection(url) as HttpURLConnection
        try {
            connection.connectTimeout = 15000
            connection.readTimeout = 20000
            connection.instanceFollowRedirects = false
            connection.setRequestProperty("User-Agent", "Mozilla/5.0 (Linux; Android) XMUMAttendanceAssistant/0.6")
            if (onlineList) {
                connection.setRequestProperty("X-Requested-With", "XMLHttpRequest")
                connection.setRequestProperty("Referer", "https://srun.xmu.edu.my/srun_portal_phone")
                connection.setRequestProperty("Accept", "application/json, text/javascript, */*; q=0.01")
            }
            val status = connection.responseCode
            if (allowRedirect && status in listOf(301, 302, 303, 307, 308)) {
                return Reply("", connection.getHeaderField("Location") ?: error("学校认证入口缺少重定向地址"))
            }
            require(status == 200) { "校园网服务 HTTP $status" }
            val bytes = connection.inputStream.use { input ->
                val output = ByteArrayOutputStream()
                val buffer = ByteArray(4096)
                while (output.size() <= 65536) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    output.write(buffer, 0, count)
                }
                output.toByteArray()
            }
            require(bytes.size <= 65536) { "校园网响应过大" }
            val charsetName = Regex("(?i)charset\\s*=\\s*[\"']?([^\\s;\"']+)")
                .find(connection.contentType ?: "")?.groupValues?.get(1)
            val charset = if (charsetName == null) Charsets.UTF_8 else Charset.forName(charsetName)
            return Reply(String(bytes, charset).trim().removeSuffix(";"), null)
        } finally { connection.disconnect() }
    }

    private fun portalPage(selected: Network, initial: String): String {
        val acid = Regex("""\bacid\s*:\s*["']([^"']*)["']""").find(initial)?.groupValues?.get(1)
        if (acid != "") return initial
        val root = request(selected, URL("https://srun.xmu.edu.my/"), allowRedirect = true)
        val entry = if (root.redirect == null) root.body else {
            val path = PortalEntrySelection.entryPath(root.redirect)
            request(selected, URL("https://srun.xmu.edu.my$path")).body
        }
        val id = PortalEntrySelection.acId(entry)
        return request(selected, URL("https://srun.xmu.edu.my/srun_portal_phone?ac_id=$id")).body
    }
    init {
        MethodChannel(messenger, "com.xmum.attendance_assistant/network").setMethodCallHandler { call, result ->
            executor.execute {
                try {
                    val value: Any? = when (call.method) {
                        "bind" -> {
                            val networks = manager.allNetworks.filter {
                                manager.getNetworkCapabilities(it)?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
                            }
                            require(networks.size == 1) { "请连接 Student Wi-Fi；未找到唯一可用 Wi-Fi 网络" }
                            val selected = networks.single()
                            val address = manager.getLinkProperties(selected)?.linkAddresses?.firstOrNull {
                                it.address is Inet4Address && it.address.isSiteLocalAddress
                            }?.address?.hostAddress ?: error("无法读取 Wi-Fi IPv4 地址")
                            require(address.startsWith("10.")) { "当前 Wi-Fi 地址不属于已核验的校园网络" }
                            require(manager.bindProcessToNetwork(selected)) { "无法固定校园网请求到 Wi-Fi" }
                            wifi = selected
                            ip = address
                            address
                        }
                        "get", "portal" -> {
                            val selected = wifi ?: error("校园网连接尚未初始化")
                            require(manager.getNetworkCapabilities(selected)?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true) { "Wi-Fi 连接已断开" }
                            val current = manager.getLinkProperties(selected)?.linkAddresses?.any { it.address.hostAddress == ip } == true
                            require(current) { "Wi-Fi 地址已变化，请重新开始" }
                            val portal = call.method == "portal"
                            val path = if (portal) "/srun_portal_phone" else call.argument<String>("path") ?: ""
                            require(portal || path in paths) { "校园网接口不受支持" }
                            val builder = Uri.parse("https://srun.xmu.edu.my$path").buildUpon()
                            val params = if (portal) emptyMap<String, String>() else call.argument<Map<String, String>>("params") ?: emptyMap()
                            params.forEach { (key, value) -> builder.appendQueryParameter(key, value) }
                            if (!portal && path.startsWith("/cgi-bin/")) builder.appendQueryParameter("callback", "campusFlow")
                            builder.appendQueryParameter("_", System.currentTimeMillis().toString())
                            val body = request(selected, URL(builder.build().toString()), onlineList = path == "/v1/srun_portal_online").body
                            if (portal) portalPage(selected, body) else body
                        }
                        "reconnect" -> {
                            val previous = wifi ?: error("校园网连接尚未初始化")
                            manager.bindProcessToNetwork(null)
                            wifi = null
                            ip = null
                            activity.runOnUiThread {
                                Toast.makeText(activity, "请忽略 Student 后重新连接；出现需要登录后返回签到助手，不要在网页手动登录", Toast.LENGTH_LONG).show()
                                activity.startActivity(Intent(Settings.ACTION_WIFI_SETTINGS))
                            }
                            val deadline = android.os.SystemClock.elapsedRealtime() + 180000L
                            val gate = FreshWifiGate(previous.networkHandle)
                            var selected: Network? = null
                            var address: String? = null
                            while (android.os.SystemClock.elapsedRealtime() < deadline) {
                                val networks = manager.allNetworks.filter {
                                    manager.getNetworkCapabilities(it)?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
                                }
                                val snapshots = networks.map { network ->
                                    val caps = manager.getNetworkCapabilities(network)
                                    val candidateIp = manager.getLinkProperties(network)?.linkAddresses?.firstOrNull {
                                        it.address is Inet4Address && it.address.isSiteLocalAddress
                                    }?.address?.hostAddress
                                    WifiResetCandidate(network.networkHandle, candidateIp,
                                        caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_CAPTIVE_PORTAL) == true,
                                        caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true)
                                }
                                val ready = gate.update(snapshots, activity.hasWindowFocus(), android.os.SystemClock.elapsedRealtime())
                                if (ready != null) {
                                    selected = networks.firstOrNull { it.networkHandle == ready.id }
                                    if (selected != null) { address = ready.ipv4; break }
                                }
                                Thread.sleep(250)
                            }
                            require(selected != null && address != null) { "未检测到 Student 重新进入需要登录状态。请在 WLAN 设置中忽略 Student，再重新连接并返回应用；仅显示已连接不算完成" }
                            require(address!!.startsWith("10.")) { "重连后网络不属于已核验的校园网络，请选择 Student" }
                            require(manager.bindProcessToNetwork(selected)) { "无法固定请求到重连后的 Wi-Fi" }
                            wifi = selected
                            ip = address
                            address
                        }
                        "state" -> {
                            val selected = wifi ?: error("校园网连接尚未初始化")
                            val caps = manager.getNetworkCapabilities(selected) ?: error("Wi-Fi 连接已断开")
                            mapOf("ip" to ip,
                                "captivePortal" to caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_CAPTIVE_PORTAL),
                                "validated" to caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED))
                        }
                        "release" -> {
                            if (wifi != null) manager.bindProcessToNetwork(null)
                            wifi = null
                            ip = null
                            null
                        }
                        else -> error("校园网操作不受支持")
                    }
                    activity.runOnUiThread { result.success(value) }
                } catch (e: Exception) {
                    val message = if (e is IllegalArgumentException || e is IllegalStateException) e.message ?: "校园网状态异常"
                        else "校园网连接失败，请检查 Student 网络、学校认证服务和网络权限"
                    activity.runOnUiThread { result.error("CAMPUS_NETWORK_ERROR", message, null) }
                }
            }
        }
    }
}
