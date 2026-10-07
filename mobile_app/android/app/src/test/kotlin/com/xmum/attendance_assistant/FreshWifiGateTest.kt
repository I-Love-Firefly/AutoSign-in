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

    @Test fun reconnectedValidatedNetworkDoesNotMeanLoginRequired() {
        val gate = FreshWifiGate(1)
        assertNull(gate.update(emptyList(), false, 0))
        assertNull(gate.update(listOf(portal.copy(captivePortal = false, validated = true)), true, 1000))
        assertNull(gate.update(listOf(portal.copy(captivePortal = false, validated = true)), true, 2000))
    }

    @Test fun loginRequirementWaitsForReturnToAppAndStableConnection() {
        val gate = FreshWifiGate(1)
        assertNull(gate.update(emptyList(), false, 0))
        assertNull(gate.update(listOf(portal), false, 100))
        assertNull(gate.update(listOf(portal), false, 1000))
        assertNull(gate.update(listOf(portal), true, 1100))
        assertNull(gate.update(listOf(portal), true, 1599))
        assertEquals(portal, gate.update(listOf(portal), true, 1600))
    }

    @Test fun portalDetectedBeforeReturnRemainsEvidenceAfterProbeValidation() {
        val gate = FreshWifiGate(1)
        assertNull(gate.update(listOf(old, portal), false, 0))
        val later = portal.copy(captivePortal = false, validated = true)
        assertNull(gate.update(listOf(later), true, 100))
        assertEquals(later, gate.update(listOf(later), true, 600))
    }

    @Test fun anotherNetworkCannotReuseEarlierPortalDetection() {
        val gate = FreshWifiGate(1)
        assertNull(gate.update(listOf(portal), false, 0))
        val other = portal.copy(id = 3, captivePortal = false, validated = true)
        assertNull(gate.update(listOf(other), true, 100))
        assertNull(gate.update(listOf(other), true, 1000))
        assertNull(gate.update(listOf(portal.copy(captivePortal = false, validated = true)), true, 2000))
    }

    @Test fun missingAddressAndAmbiguousWifiCannotComplete() {
        val gate = FreshWifiGate(1)
        assertNull(gate.update(emptyList(), false, 0))
        assertNull(gate.update(listOf(portal.copy(ipv4 = null)), true, 100))
        assertNull(gate.update(listOf(portal.copy(ipv4 = "192.168.1.2")), true, 1000))
        assertNull(gate.update(listOf(portal, portal.copy(id = 3)), true, 2000))
    }

    @Test fun settingsMustHaveBeenOpenedEvenForANewPortal() {
        val gate = FreshWifiGate(1)
        assertNull(gate.update(listOf(portal), true, 0))
        assertNull(gate.update(listOf(portal), true, 1000))
    }
}
