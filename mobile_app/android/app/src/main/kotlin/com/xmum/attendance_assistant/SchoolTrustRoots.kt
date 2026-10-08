package com.xmum.attendance_assistant

/** School wildcard TLS currently uses Sectigo; select only platform-trusted roots. */
object SchoolTrustRoots {
 private val names=setOf("Sectigo Public Server Authentication Root R46","Sectigo Public Server Authentication Root E46","USERTrust RSA Certification Authority","USERTrust ECC Certification Authority","COMODO RSA Certification Authority","COMODO ECC Certification Authority","COMODO Certification Authority")
 fun accepts(subject:String):Boolean {
  val cn=Regex("(?:^|,)CN=([^,]+)").find(subject)?.groupValues?.get(1)
  return cn in names
 }
}
