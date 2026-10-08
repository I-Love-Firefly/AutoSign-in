package com.xmum.attendance_assistant

data class EnterpriseCandidate(val id:Long,val ip:String?,val ssid:String,val enterprise:Boolean)
/** Connection freshness is necessary; school-side identity remains a separate check. */
class EnterpriseConnectionGate(private val previousId:Long) {
 private var key:Pair<Long,String>?=null
 private var since=0L
 fun update(candidates:List<EnterpriseCandidate>,focused:Boolean,now:Long):EnterpriseCandidate? {
  val c=candidates.singleOrNull()
  if(!focused||c==null||c.id==previousId||c.ssid!="Student-5G"||!c.enterprise||c.ip?.startsWith("10.")!=true){key=null;return null}
  val next=c.id to c.ip!!
  if(key!=next){key=next;since=now}
  return if(now-since>=750)c else null
 }
}
