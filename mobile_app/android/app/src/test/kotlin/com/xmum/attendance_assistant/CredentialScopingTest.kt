package com.xmum.attendance_assistant
import org.junit.Assert.*
import org.junit.Test
class CredentialScopingTest {
 private class Box {private var stored="";val password:String get()=stored;fun setPassword(value:String){stored=value}}
 private fun receiverStyle(password:String)=Box().apply{setPassword(password)}
 @Test fun outerPasswordArgumentIsPreserved(){val box=receiverStyle("fixture-only");assertEquals("fixture-only",box.password)}
 @Test fun campusIdPreservesEnteredCaseAndTrimsOuterWhitespace(){assertEquals("student-001",EnterpriseCredentials.identity(" student-001 "));assertEquals("account@example.edu",EnterpriseCredentials.identity(" account@example.edu "))}
}
