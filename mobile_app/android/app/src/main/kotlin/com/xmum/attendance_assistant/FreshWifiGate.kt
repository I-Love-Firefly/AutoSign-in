package com.xmum.attendance_assistant

data class WifiResetCandidate(
    val id: Long,
    val ipv4: String?,
    val captivePortal: Boolean,
    val validated: Boolean,
)

/** Confirms only a fresh stable link. Dart must verify SRun offline before login. */
class FreshWifiGate(private val previousId: Long) {
    private var settingsVisited = false
    private var previousLost = false
    private var readyKey: Pair<Long, String>? = null
    private var readySince = 0L

    fun update(candidates: List<WifiResetCandidate>, appFocused: Boolean, now: Long): WifiResetCandidate? {
        if (!appFocused) settingsVisited = true
        if (candidates.none { it.id == previousId }) previousLost = true
        val candidate = candidates.filter { it.id != previousId }.singleOrNull()?.takeIf { it.ipv4?.startsWith("10.") == true }
        if (candidate == null) {
            readyKey = null
            return null
        }
        // Android captive-portal/validation flags are connectivity probe results,
        // not the authoritative campus account state. Some classroom networks
        // validate while SRun explicitly reports this device offline.
        if (!settingsVisited || !previousLost || !appFocused || candidates.size != 1) {
            readyKey = null
            return null
        }
        val key = candidate.id to candidate.ipv4!!
        if (readyKey != key) {
            readyKey = key
            readySince = now
        }
        return if (now - readySince >= 500L) candidate else null
    }
}
