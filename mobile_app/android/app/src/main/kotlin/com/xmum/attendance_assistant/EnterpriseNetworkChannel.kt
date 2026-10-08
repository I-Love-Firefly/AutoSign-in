package com.xmum.attendance_assistant

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.wifi.WifiEnterpriseConfig
import android.net.wifi.WifiInfo
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSuggestion
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.location.LocationManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.net.Inet4Address
import java.security.KeyStore
import java.security.cert.X509Certificate
import java.util.concurrent.Executors

class EnterpriseNetworkChannel(private val activity:Activity,messenger:BinaryMessenger) {
 private val manager=activity.getSystemService(ConnectivityManager::class.java)
 private val wifiManager=activity.applicationContext.getSystemService(WifiManager::class.java)
 private val prefs=activity.getSharedPreferences("campus_network_mode",0)
 private val worker=Executors.newSingleThreadExecutor()
 private val main=Handler(Looper.getMainLooper())
 private var permissionResult:MethodChannel.Result?=null
 private var configResult:MethodChannel.Result?=null
 private var previous=-1L
 private var bound:Network?=null
 private val expire=Runnable {configResult?.error("ENTERPRISE_CONFIRM_TIMEOUT","系统确认超过3分钟，请重试",null);configResult=null;runCatching{activity.finishActivity(SAVE)}}
 companion object {const val SAVE=4811;const val PERMISSION=4812}
 init {
  MethodChannel(messenger,"com.xmum.attendance_assistant/enterprise").setMethodCallHandler{call,result->
   when(call.method){
    "preferences"->result.success(mapOf("mode" to prefs.getString("mode","student5g"),"phase2" to prefs.getString("phase2","MSCHAPV2"),"automaticSupported" to (Build.VERSION.SDK_INT>=30)))
    "setPreferences"->{
     val mode=call.argument<String>("mode");val phase=call.argument<String>("phase2")
     if(mode !in listOf("student5g","manual5g","student")||phase !in listOf("MSCHAPV2","GTC")){result.error("ENTERPRISE_SETTINGS","校园网设置格式不正确",null)}
     else{prefs.edit().putString("mode",mode).putString("phase2",phase).apply();result.success(null)}
    }
    "permissions"->permissions(result)
    "prepare"->prepare(call.argument<String>("username")?:"",call.argument<String>("password")?:"",result)
    "connect"->{
     val old=call.argument<Number>("previousHandle")?.toLong()?:-1L
     val manual=call.argument<Boolean>("manual")?:false
     worker.execute{connect(old,manual,result)}
    }
    "state"->{
     val n=bound
     if(n==null)result.error("ENTERPRISE_DISCONNECTED","Student-5G尚未连接",null)
     else runCatching{candidate(n)}.onSuccess{c->result.success(mapOf("ip" to c.ip,"ssid" to c.ssid,"handle" to c.id,"enterprise" to c.enterprise))}.onFailure{result.error("ENTERPRISE_STATE","无法读取Student-5G状态",null)}
    }
    "legacyGuard"->{
     @Suppress("DEPRECATION") val name=wifiManager.connectionInfo.ssid?.trim('"')
     if(name!="Student")result.error("LEGACY_NETWORK_TYPE","Student旧版流程只能用于Student网络；当前如为Student-5G，请使用系统确认或手动切换方式",null)
     else result.success(null)
    }
    "currentHandle"->result.success(wifiNetworks().singleOrNull()?.networkHandle?:-1L)
    "release"->{if(bound!=null)manager.bindProcessToNetwork(null);bound=null;result.success(null)}
    else->result.notImplemented()
   }
  }
 }
 private fun permissions(result:MethodChannel.Result){
  if(activity.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION)==PackageManager.PERMISSION_GRANTED){result.success(null);return}
  if(permissionResult!=null){result.error("ENTERPRISE_BUSY","正在等待网络权限",null);return}
  permissionResult=result
  activity.requestPermissions(arrayOf(Manifest.permission.ACCESS_COARSE_LOCATION,Manifest.permission.ACCESS_FINE_LOCATION),PERMISSION)
 }
 fun onPermissions(code:Int):Boolean {
  if(code!=PERMISSION)return false
  val r=permissionResult;permissionResult=null
  if(activity.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION)==PackageManager.PERMISSION_GRANTED)r?.success(null)
  else r?.error("ENTERPRISE_PERMISSION","需要精确位置权限来核对Wi-Fi名称；应用不会读取GPS坐标。请在系统权限中允许后重试",null)
  return true
 }
 private fun prepare(username:String,campusPassword:String,result:MethodChannel.Result){
  if(Build.VERSION.SDK_INT<30){result.error("ENTERPRISE_UNSUPPORTED","系统不支持网络配置确认，请在校园网设置中选择Student-5G手动切换",null);return}
  if(configResult!=null){result.error("ENTERPRISE_BUSY","正在等待系统确认",null);return}
  if(!Regex("^[A-Za-z0-9@._-]{1,100}$").matches(username)||campusPassword.isEmpty()){result.error("ENTERPRISE_CREDENTIALS","请检查Campus ID并填写校园网密码",null);return}
  if(Build.VERSION.SDK_INT>=28&&!activity.getSystemService(LocationManager::class.java).isLocationEnabled){result.error("ENTERPRISE_LOCATION","请开启系统位置开关，以核对Student-5G连接；应用不会读取GPS坐标",null);return}
  configResult=result;previous=wifiNetworks().singleOrNull()?.networkHandle?:-1L
  worker.execute{
   try {
    val store=KeyStore.getInstance("AndroidCAStore");store.load(null,null)
    val roots=store.aliases().asSequence().filter{it.startsWith("system:")}.mapNotNull{store.getCertificate(it) as? X509Certificate}.filter{it.basicConstraints>=0 && SchoolTrustRoots.accepts(it.subjectX500Principal.name)}.toList()
    require(roots.isNotEmpty())
    val config=WifiEnterpriseConfig().apply{
     eapMethod=WifiEnterpriseConfig.Eap.PEAP
     phase2Method=if(prefs.getString("phase2","MSCHAPV2")=="GTC")WifiEnterpriseConfig.Phase2.GTC else WifiEnterpriseConfig.Phase2.MSCHAPV2
     // Saved enterprise profiles merge unspecified fields. Replace the outer
     // identity as well, otherwise switching accounts retains the prior user.
     identity=EnterpriseCredentials.identity(username)
     anonymousIdentity=EnterpriseCredentials.identity(username)
     setPassword(campusPassword)
     setCaCertificates(roots.toTypedArray())
     altSubjectMatch="DNS:*.xmu.edu.my;DNS:xmu.edu.my"
    }
    require(config.identity==EnterpriseCredentials.identity(username) && config.anonymousIdentity==config.identity && config.password==campusPassword) { "Credential conversion failed" }
    val network=WifiNetworkSuggestion.Builder().setSsid("Student-5G").setWpa2EnterpriseConfig(config).setCredentialSharedWithUser(true).build()
    require(network.enterpriseConfig?.password==campusPassword) { "Suggestion credential conversion failed" }
    val parcel=android.os.Parcel.obtain()
    try {
     network.writeToParcel(parcel,0);parcel.setDataPosition(0)
     val copy=WifiNetworkSuggestion.CREATOR.createFromParcel(parcel)
     require(copy.enterpriseConfig?.password==campusPassword && copy.enterpriseConfig?.identity==config.identity && copy.enterpriseConfig?.anonymousIdentity==config.identity) { "Parcelable credential conversion failed" }
    } finally { parcel.recycle() }
    val intent=Intent(Settings.ACTION_WIFI_ADD_NETWORKS).apply{putParcelableArrayListExtra(Settings.EXTRA_WIFI_NETWORK_LIST,arrayListOf(network))}
    main.post{
     if(configResult!==result)return@post
     try {activity.startActivityForResult(intent,SAVE);main.postDelayed(expire,180000)}
     catch(_:Exception){configResult=null;result.error("ENTERPRISE_UNSUPPORTED","系统无法打开配置确认页，请在校园网设置中选择Student-5G手动切换",null)}
    }
   }catch(_:Exception){main.post{if(configResult===result){configResult=null;result.error("ENTERPRISE_CONFIG","无法构建学校企业网络配置，请检查系统证书和校园网设置；未修改网络",null)}}}
  }
 }
 fun onResult(code:Int,status:Int,data:Intent?):Boolean {
  if(code!=SAVE)return false
  main.removeCallbacks(expire)
  val r=configResult?:return true;configResult=null
  if(status!=Activity.RESULT_OK){r.error("ENTERPRISE_CANCELLED","已取消系统网络配置，未继续登录或签到",null);return true}
  val codes=data?.getIntegerArrayListExtra(Settings.EXTRA_WIFI_NETWORK_RESULT_LIST)
  val c=codes?.singleOrNull()
  if(c !in listOf(Settings.ADD_WIFI_RESULT_SUCCESS,Settings.ADD_WIFI_RESULT_ALREADY_EXISTS))r.error("ENTERPRISE_SAVE_FAILED","系统未确认保存Student-5G配置，请改为手动切换模式",null)
  else r.success(mapOf("previousHandle" to previous,"result" to c))
  return true
 }
 @Suppress("DEPRECATION") private fun wifiNetworks()=manager.allNetworks.filter{manager.getNetworkCapabilities(it)?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)==true}
 @Suppress("DEPRECATION") private fun candidate(n:Network):EnterpriseCandidate {
  val caps=manager.getNetworkCapabilities(n)
  val supplied=caps?.transportInfo as? WifiInfo
  val info=if(supplied?.ssid?.trim('"')!=null&&supplied.ssid.trim('"')!="<unknown ssid>")supplied else wifiManager.connectionInfo
  val ip=manager.getLinkProperties(n)?.linkAddresses?.firstOrNull{it.address is Inet4Address}?.address?.hostAddress
  val ssid=info.ssid?.trim('"')?:"unknown"
  val enterprise=if(Build.VERSION.SDK_INT>=31) info.currentSecurityType in listOf(WifiInfo.SECURITY_TYPE_EAP,WifiInfo.SECURITY_TYPE_EAP_WPA3_ENTERPRISE,WifiInfo.SECURITY_TYPE_EAP_WPA3_ENTERPRISE_192_BIT) else wifiManager.scanResults.firstOrNull{it.BSSID==info.bssid && it.SSID==ssid}?.capabilities?.contains("EAP")==true
  return EnterpriseCandidate(n.networkHandle,ip,ssid,enterprise)
 }
 private fun connect(old:Long,manual:Boolean,result:MethodChannel.Result){
  try {
   if(Build.VERSION.SDK_INT>=28&&!activity.getSystemService(LocationManager::class.java).isLocationEnabled)throw IllegalStateException("请开启系统位置开关，以核对Student-5G连接")
   manager.bindProcessToNetwork(null);bound=null
   val start=android.os.SystemClock.elapsedRealtime();val gate=EnterpriseConnectionGate(old)
   var opened=false;var ready:EnterpriseCandidate?=null;var picked:Network?=null
   while(android.os.SystemClock.elapsedRealtime()-start<180000){
    val now=android.os.SystemClock.elapsedRealtime()
    if(!opened&&(manual||now-start>=10000)){
     opened=true
     main.post{android.widget.Toast.makeText(activity,if(manual)"请修改Student-5G的身份和密码，断开重连后返回应用" else "请关闭再开启Wi-Fi、连接Student-5G并返回应用，无需重新填写已确认的账号",android.widget.Toast.LENGTH_LONG).show();activity.startActivity(Intent(Settings.ACTION_WIFI_SETTINGS))}
    }
    val networks=wifiNetworks()
    // Manual mode must actually visit settings before it can complete.
    if(!manual||opened){
     ready=gate.update(networks.map{candidate(it)},activity.hasWindowFocus(),now)
     if(ready!=null){picked=networks.singleOrNull();if(picked!=null)break}
    }
    Thread.sleep(250)
   }
   require(ready!=null&&picked!=null){"未检测到新的Student-5G企业网络连接；请检查账号、校园网密码、认证设置，并断开重连后返回应用"}
   require(manager.bindProcessToNetwork(picked)){"无法将请求固定到Student-5G"}
   bound=picked
   main.post{result.success(mapOf("ip" to ready!!.ip,"handle" to ready!!.id,"ssid" to ready!!.ssid,"enterprise" to ready!!.enterprise))}
  }catch(e:Exception){main.post{result.error("ENTERPRISE_CONNECT",if(e is IllegalStateException||e is IllegalArgumentException)e.message else "Student-5G连接失败，请在系统Wi-Fi设置核验",null)}}
 }
}
