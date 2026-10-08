package com.xmum.attendance_assistant

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class FreshWifiGateTest {
    private val old = WifiResetCandidate(1, "10.72.99.123", false, true)
    private val portal = WifiResetCandidate(2, "10.72.99.123", true, false)

    @Test fun savedConnectionNeverCompletes() {
        val gate = FreshWifiGate(1)
        assertNull(gate.update(listOf(old), false, 0))
        assertNull(gate.update(listOf(old.copy(captivePortal = true, validated = false)), true, 1000))
    }

    @Test fun freshValidatedNetworkReturnsForAuthoritativeCampusOfflineCheck() {
        val gate = FreshWifiGate(1)
        assertNull(gate.update(emptyList(), false, 0))
        assertNull(gate.update(listOf(portal.copy(captivePortal = false, validated = true)), true, 1000))
        assertEquals(portal.copy(captivePortal = false, validated = true), gate.update(listOf(portal.copy(captivePortal = false, validated = true)), true, 2000))
    }

    @Test fun freshLinkWaitsForReturnToAppAndStableConnection() {
        val gate = FreshWifiGate(1)
        assertNull(gate.update(emptyList(), false, 0))
        assertNull(gate.update(listOf(portal), false, 100))
        assertNull(gate.update(listOf(portal), false, 1000))
        assertNull(gate.update(listOf(portal), true, 1100))
        assertNull(gate.update(listOf(portal), true, 1599))
        assertEquals(portal, gate.update(listOf(portal), true, 1600))
    }

    @Test fun overlappingOldAndNewNetworksWaitUntilOldConnectionDisappears() {
        val gate = FreshWifiGate(1)
        assertNull(gate.update(listOf(old, portal), false, 0))
        val later = portal.copy(captivePortal = false, validated = true)
        assertNull(gate.update(listOf(later), true, 100))
        assertEquals(later, gate.update(listOf(later), true, 600))
    }

    @Test fun connectionChangeResetsStabilityEvenWithoutPortalPrompt() {
        val gate = FreshWifiGate(1)
        assertNull(gate.update(listOf(portal), false, 0))
        val other = portal.copy(id = 3, captivePortal = false, validated = true)
        assertNull(gate.update(listOf(other), true, 100))
        assertEquals(other, gate.update(listOf(other), true, 1000))
        assertNull(gate.update(listOf(portal.copy(captivePortal = false, validated = true)), true, 2000))
    }

    @Test fun missingAddressAndAmbiguousWifiCannotComplete() {
        val gate = FreshWifiGate(1)
        assertNull(gate.update(emptyList(), false, 0))
        assertNull(gate.update(listOf(portal.copy(ipv4 = null)), true, 100))
        assertNull(gate.update(listOf(portal.copy(ipv4 = "192.168.1.2")), true, 1000))
        assertNull(gate.update(listOf(portal, portal.copy(id = 3)), true, 2000))
    }

    @Test fun changedAddressMustBecomeStableAgain() {
        val gate = FreshWifiGate(1)
        assertNull(gate.update(emptyList(), false, 0))
        assertNull(gate.update(listOf(portal), true, 100))
        val changed = portal.copy(ipv4 = "10.72.219.32", captivePortal = false, validated = true)
        assertNull(gate.update(listOf(changed), true, 400))
        assertNull(gate.update(listOf(changed), true, 899))
        assertEquals(changed, gate.update(listOf(changed), true, 900))
    }

    @Test fun oldConnectionMustDisappearEvenWhenNewNetworkIsValidated() {
        val gate = FreshWifiGate(1)
        val fresh = portal.copy(captivePortal = false, validated = true)
        assertNull(gate.update(listOf(old, fresh), false, 0))
        assertNull(gate.update(listOf(old, fresh), true, 1000))
        assertNull(gate.update(listOf(fresh), true, 1200))
        assertEquals(fresh, gate.update(listOf(fresh), true, 1700))
    }

    @Test fun settingsMustHaveBeenOpenedEvenForANewPortal() {
        val gate = FreshWifiGate(1)
        assertNull(gate.update(listOf(portal), true, 0))
        assertNull(gate.update(listOf(portal), true, 1000))
    }
}
