package com.xmum.attendance_assistant

data class WifiResetCandidate(
    val id: Long,
    val ipv4: String?,
    val captivePortal: Boolean,
    val validated: Boolean,
)

/** A link alone is insufficient: a fresh connection must request authentication. */
class FreshWifiGate(private val previousId: Long) {
    private var settingsVisited = false
    private var previousLost = false
    private var portalId: Long? = null
    private var readyKey: Pair<Long, String>? = null
    private var readySince = 0L

    fun update(candidates: List<WifiResetCandidate>, appFocused: Boolean, now: Long): WifiResetCandidate? {
        if (!appFocused) settingsVisited = true
        if (candidates.none { it.id == previousId }) previousLost = true
        val candidate = candidates.filter { it.id != previousId }.singleOrNull()?.takeIf { it.ipv4?.startsWith("10.") == true }
        if (candidate == null) {
            readyKey = null
            portalId = null
            return null
        }
        if (portalId != candidate.id) portalId = null
        if (candidate.captivePortal && !candidate.validated) portalId = candidate.id
        // Remember the observed sign-in requirement even if Android's later
        // connectivity probe becomes validated. School account state is checked
        // separately before sending credentials.
        if (!settingsVisited || !previousLost || !appFocused || candidates.size != 1 || portalId != candidate.id) {
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
