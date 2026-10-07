package com.xmum.attendance_assistant

import java.net.URI
import java.net.URLDecoder

/** Read the server's selected entry; do not guess AC IDs from an index filename. */
object PortalEntrySelection {
    private val origin = URI("https://srun.xmu.edu.my/")
    private fun sameOrigin(uri: URI) = uri.scheme == "https" &&
        uri.host == origin.host && uri.port in listOf(-1, 443) && uri.userInfo == null

    fun entryPath(location: String): String {
        val uri = origin.resolve(location)
        require(sameOrigin(uri) && uri.rawQuery == null &&
            Regex("^/index_[0-9]+\\.html$").matches(uri.path)) { "学校认证入口重定向不受支持" }
        return uri.path
    }

    fun acId(html: String): String {
        val meta = Regex("""<meta\b(?=[^>]*\bhttp-equiv\s*=\s*["']refresh["'])[^>]*\bcontent\s*=\s*(["'])(.*?)\1[^>]*>""",
            setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL)).findAll(html).toList()
        require(meta.size == 1) { "无法读取学校认证入口的 AC 选择" }
        val target = Regex("(?:^|;)\\s*url\\s*=\\s*(.+)$", RegexOption.IGNORE_CASE)
            .find(meta.single().groupValues[2])?.groupValues?.get(1)?.trim()?.replace("&amp;", "&")
        require(target != null) { "无法读取学校认证入口的 AC 选择" }
        val uri = origin.resolve(target)
        require(sameOrigin(uri) && uri.path in listOf("/srun_portal_pc", "/srun_portal_phone")) { "学校认证入口地址不受支持" }
        val ids = (uri.rawQuery ?: "").split('&').mapNotNull { pair ->
            val parts = pair.split('=', limit = 2)
            if (parts.size == 2 && URLDecoder.decode(parts[0], "UTF-8") == "ac_id") URLDecoder.decode(parts[1], "UTF-8") else null
        }
        require(ids.size == 1 && Regex("^[1-9][0-9]{0,9}$").matches(ids.single())) { "学校认证入口的 AC 参数无效" }
        return ids.single()
    }
}
