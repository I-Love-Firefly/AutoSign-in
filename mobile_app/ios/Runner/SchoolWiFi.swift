import CoreLocation
import Darwin
import Flutter
import Network
import NetworkExtension
import UIKit

struct SchoolError: Error {
  let code: String
  let message: String
  var flutter: FlutterError { FlutterError(code: code, message: message, details: nil) }
}

struct WiFiSnapshot: Equatable {
  let ip: String
  let ssid: String
  let bssid: String
  let enterprise: Bool
  let generation: Int
  var dictionary: [String: Any] {
    ["ip": ip, "ssid": ssid, "handle": generation, "enterprise": enterprise]
  }
}

// All mutable state is confined to the main queue. No GPS coordinates are read.
@MainActor
final class SchoolWiFi: NSObject, CLLocationManagerDelegate {
  private let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
  private let location = CLLocationManager()
  private var generation = 1
  private var lastPathStatus: Network.NWPath.Status?
  private var lastIdentity: String?
  private var permissionResult: FlutterResult?
  private var permissionTimer: Timer?
  private var approved = false
  private var reconnecting = false
  private var backgroundCount = 0
  private var backgroundObserver: NSObjectProtocol?
  private(set) var bound: WiFiSnapshot?

  override init() {
    super.init()
    location.delegate = self
    monitor.pathUpdateHandler = { [weak self] path in
      let status = path.status
      Task { @MainActor [weak self] in
        guard let self = self else { return }
        if let old = self.lastPathStatus, old != status { self.generation += 1 }
        self.lastPathStatus = status
      }
    }
    monitor.start(queue: .main)
    backgroundObserver = NotificationCenter.default.addObserver(
      forName: UIScene.didEnterBackgroundNotification, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in self?.backgroundCount += 1 }
    }
  }

  deinit {
    monitor.cancel()
    if let observer = backgroundObserver { NotificationCenter.default.removeObserver(observer) }
  }

  static var presenter: UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    var controller = scenes.first(where: { $0.activationState == .foregroundActive })?
      .windows.first(where: { $0.isKeyWindow })?.rootViewController
    while let presented = controller?.presentedViewController { controller = presented }
    return controller
  }

  private var foreground: Bool {
    UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
  }

  func permissions(_ result: @escaping FlutterResult) {
    guard CLLocationManager.locationServicesEnabled() else {
      result(SchoolError(code: "ENTERPRISE_LOCATION", message: "请在设置中开启定位服务，以核对 Wi-Fi 名称；应用不会读取 GPS 坐标").flutter)
      return
    }
    switch location.authorizationStatus {
    case .authorizedAlways, .authorizedWhenInUse:
      guard location.accuracyAuthorization == .fullAccuracy else {
        result(SchoolError(code: "ENTERPRISE_PERMISSION", message: "请在设置 → 签到助手 → 位置中开启精确位置，以读取 Wi-Fi 名称").flutter)
        return
      }
      result(nil)
    case .notDetermined:
      guard permissionResult == nil else {
        result(SchoolError(code: "ENTERPRISE_BUSY", message: "正在等待网络识别权限").flutter)
        return
      }
      permissionResult = result
      permissionTimer = Timer.scheduledTimer(withTimeInterval: 180, repeats: false) { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.finishPermission(SchoolError(code: "ENTERPRISE_PERMISSION", message: "权限确认超时，请重试").flutter)
        }
      }
      location.requestWhenInUseAuthorization()
    default:
      result(SchoolError(code: "ENTERPRISE_PERMISSION", message: "请在设置 → 签到助手 → 位置中允许使用 App 期间访问，并开启精确位置；仅用于核对 Wi-Fi 名称").flutter)
    }
  }

  private func finishPermission(_ value: Any?) {
    let result = permissionResult
    permissionResult = nil
    permissionTimer?.invalidate()
    permissionTimer = nil
    result?(value)
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    guard permissionResult != nil, manager.authorizationStatus != .notDetermined else { return }
    let result = permissionResult!
    finishPermissionWithoutReply()
    permissions(result)
  }

  private func finishPermissionWithoutReply() {
    permissionResult = nil
    permissionTimer?.invalidate()
    permissionTimer = nil
  }

  private func ipv4() -> String? {
    let names = Set(monitor.currentPath.availableInterfaces.filter { $0.type == .wifi }.map { $0.name })
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0, let first = list else { return nil }
    defer { freeifaddrs(list) }
    var node: UnsafeMutablePointer<ifaddrs>? = first
    while let current = node {
      let value = current.pointee
      node = value.ifa_next
      guard names.contains(String(cString: value.ifa_name)),
            let address = value.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
      var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      if getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer,
                     socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
        return String(cString: buffer)
      }
    }
    return nil
  }

  func snapshot() async throws -> WiFiSnapshot {
    guard monitor.currentPath.status == .satisfied,
          let network = await NEHotspotNetwork.fetchCurrent(),
          let ip = ipv4(), ip.hasPrefix("10.") else {
      throw SchoolError(code: "CAMPUS_NETWORK_ERROR", message: "请连接校园 Student 或 Student-5G Wi-Fi，并允许精确位置及本地网络访问")
    }
    guard ["Student", "Student-5G"].contains(network.ssid) else {
      throw SchoolError(code: "CAMPUS_NETWORK_ERROR", message: "当前 Wi-Fi 不是 Student 或 Student-5G")
    }
    let identity = "\(network.ssid)|\(network.bssid)|\(ip)|\(network.securityType.rawValue)"
    if let previous = lastIdentity, previous != identity { generation += 1 }
    lastIdentity = identity
    return WiFiSnapshot(ip: ip, ssid: network.ssid, bssid: network.bssid,
                        enterprise: network.securityType == .enterprise, generation: generation)
  }

  func bind() async throws -> String {
    let value = try await snapshot()
    bound = value
    return value.ip
  }

  func checkBinding() async throws -> WiFiSnapshot {
    guard let saved = bound, try await snapshot() == saved else {
      throw SchoolError(code: "ENTERPRISE_CONNECTION_CHANGED", message: "校园 Wi-Fi 连接已变化，请重新开始流程")
    }
    return saved
  }

  func release() { bound = nil; approved = false }

  func prepare(username: String, password: String, phase2: String) async throws -> [String: Any] {
    approved = false
    guard username.range(of: "^[A-Za-z0-9@._-]{1,100}$", options: .regularExpression) != nil,
          !password.isEmpty else {
      throw SchoolError(code: "ENTERPRISE_CREDENTIALS", message: "请检查 Campus ID 并填写校园网密码")
    }
    // Apple exposes TTLS inner authentication, but no PEAP phase-2 selector.
    guard phase2 == "MSCHAPV2" else {
      throw SchoolError(code: "ENTERPRISE_UNSUPPORTED", message: "iPhone 系统配置不支持选择 PEAP/GTC，请使用学校配置或手动切换")
    }
    let previous = (try? await snapshot().generation) ?? -1
    let eap = NEHotspotEAPSettings()
    eap.supportedEAPTypes = [NSNumber(value: NEHotspotEAPSettings.EAPType.EAPPEAP.rawValue)]
    eap.username = username
    eap.outerIdentity = username
    eap.password = password
    eap.isTLSClientCertificateRequired = false
    // Use system trust and restrict the authentication server's name.
    eap.trustedServerNames = ["*.xmu.edu.my", "xmu.edu.my"]
    let config = NEHotspotConfiguration(ssid: "Student-5G", eapSettings: eap)
    config.joinOnce = false
    do {
      try await NEHotspotConfigurationManager.shared.apply(config)
    } catch {
      let native = error as NSError
      // Already associated is not proof that new credentials were saved.
      throw SchoolError(code: native.code == NEHotspotConfigurationError.userDenied.rawValue
                        ? "ENTERPRISE_CANCELLED" : "ENTERPRISE_SAVE_FAILED",
                        message: "系统未确认更新 Student-5G 配置，请重试或选择手动切换；未继续登录或签到")
    }
    approved = true
    return ["previousHandle": previous, "result": 0]
  }

  func reconnect(ssid: String, manual: Bool) async throws -> [String: Any] {
    guard !reconnecting else {
      throw SchoolError(code: "ENTERPRISE_BUSY", message: "正在等待 Wi-Fi 重连")
    }
    guard manual || approved else {
      throw SchoolError(code: "ENTERPRISE_SAVE_FAILED", message: "未确认系统网络配置")
    }
    reconnecting = true
    defer { reconnecting = false; approved = false }
    bound = nil
    let start = Date(), initialBackground = backgroundCount
    var shown = false, cancelled = false
    var alert: UIAlertController?
    var stable: WiFiSnapshot?
    var stableSince = Date()
    let message = ssid == "Student"
      ? "请打开 iPhone 的设置 → Wi-Fi，关闭再开启 Wi-Fi，连接 Student 后返回应用。不要在网页手动登录。"
      : manual
        ? "请打开 iPhone 的设置 → Wi-Fi，为 Student-5G 修改当前学生的身份和校园网密码；必要时忘记网络后重新加入，再返回应用。"
        : "请打开 iPhone 的设置 → Wi-Fi，确认已连接 Student-5G，再返回应用。应用将通过学校接口核验实际账号。"
    defer { alert?.dismiss(animated: true) }
    while Date().timeIntervalSince(start) < 180 {
      if !shown && foreground && (manual || Date().timeIntervalSince(start) >= 10) {
        guard let presenter = Self.presenter else {
          throw SchoolError(code: "ENTERPRISE_CONNECT", message: "无法显示 Wi-Fi 重连提示，请返回应用重试")
        }
        shown = true
        let prompt = UIAlertController(title: "连接 \(ssid)", message: message, preferredStyle: .alert)
        prompt.addAction(UIAlertAction(title: "我去设置连接", style: .default))
        prompt.addAction(UIAlertAction(title: "取消流程", style: .cancel) { _ in cancelled = true })
        alert = prompt
        presenter.present(prompt, animated: true)
      }
      if cancelled { throw SchoolError(code: "ENTERPRISE_CANCELLED", message: "已取消网络切换") }
      let returned = !manual || backgroundCount > initialBackground
      if foreground && returned, let current = try? await snapshot(), current.ssid == ssid,
         (ssid != "Student-5G" || current.enterprise) {
        if current != stable { stable = current; stableSince = Date() }
        if Date().timeIntervalSince(stableSince) >= 2 {
          bound = current
          var reply = current.dictionary
          reply["evidence"] = manual ? "ios-settings-return" : "ios-system-approved"
          return reply
        }
      } else { stable = nil }
      try await Task.sleep(nanoseconds: 250_000_000)
    }
    throw SchoolError(code: "ENTERPRISE_CONNECT", message: "等待连接超时，请检查校园 Wi-Fi、权限及身份密码，连接后返回应用重试")
  }
}
