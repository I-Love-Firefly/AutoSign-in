package com.xmum.attendance_assistant
import org.junit.Assert.*
import org.junit.Test
class SchoolTrustRootsTest {
 @Test fun rootMatchingUsesExactCertificateCn(){assertTrue(SchoolTrustRoots.accepts("CN=Sectigo Public Server Authentication Root R46,O=Sectigo Limited,C=GB"));assertTrue(SchoolTrustRoots.accepts("C=US,O=The USERTRUST Network,CN=USERTrust RSA Certification Authority"))}
 @Test fun unrelatedOrSubstringRootIsNotSelected(){assertFalse(SchoolTrustRoots.accepts("CN=Unrelated Root,O=Sectigo Limited"));assertFalse(SchoolTrustRoots.accepts("CN=Fake USERTrust RSA Certification Authority,O=Other"));assertFalse(SchoolTrustRoots.accepts("CN=Sectigo Public Server Authentication Root R46 impostor,O=Other"))}
}
