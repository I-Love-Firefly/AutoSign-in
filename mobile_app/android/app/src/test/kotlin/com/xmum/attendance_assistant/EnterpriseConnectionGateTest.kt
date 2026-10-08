package com.xmum.attendance_assistant
import org.junit.Assert.*
import org.junit.Test
class EnterpriseConnectionGateTest {
 private val link=EnterpriseCandidate(2,"10.0.0.10","Student-5G",true)
 @Test fun sameHandleCannotCreditCredentialSwitch(){val g=EnterpriseConnectionGate(1);assertNull(g.update(listOf(link.copy(id=1)),true,0));assertNull(g.update(listOf(link.copy(id=1)),true,2000))}
 @Test fun sameIpWithFreshHandleMayPass(){val g=EnterpriseConnectionGate(1);assertNull(g.update(listOf(link),true,0));assertNull(g.update(listOf(link),true,749));assertEquals(link,g.update(listOf(link),true,750))}
 @Test fun differentSsidAndOpenNetworkNeverPass(){val g=EnterpriseConnectionGate(1);assertNull(g.update(listOf(link.copy(ssid="Student")),true,0));assertNull(g.update(listOf(link.copy(enterprise=false)),true,1000));assertNull(g.update(listOf(link.copy(ip="192.168.1.2")),true,2000))}
 @Test fun mustReturnToApp(){val g=EnterpriseConnectionGate(1);assertNull(g.update(listOf(link),false,0));assertNull(g.update(listOf(link),false,1000));assertNull(g.update(listOf(link),true,2000));assertEquals(link,g.update(listOf(link),true,2750))}
 @Test fun ipChangeAndAmbiguityResetStability(){val g=EnterpriseConnectionGate(1);assertNull(g.update(listOf(link),true,0));val other=link.copy(ip="10.0.0.11");assertNull(g.update(listOf(other),true,600));assertNull(g.update(listOf(other,link.copy(id=3)),true,1200));assertNull(g.update(listOf(other),true,2000));assertEquals(other,g.update(listOf(other),true,2750))}
 @Test fun noWifiDoesNotComplete(){assertNull(EnterpriseConnectionGate(-1).update(emptyList(),true,0))}
}
