import Flutter
import Foundation

@MainActor
final class SchoolChannels {
  private let wifi = SchoolWiFi()
  private lazy var http = SchoolHTTP(wifi: wifi)
  private let archive = AccountArchiveChannel()
  private let preferences = UserDefaults.standard
  private let paths: Set<String> = ["/cgi-bin/rad_user_info", "/cgi-bin/get_challenge", "/cgi-bin/srun_portal", "/cgi-bin/rad_user_dm", "/v1/srun_portal_online"]

  init(messenger: FlutterBinaryMessenger) {
    let enterprise = FlutterMethodChannel(name: "com.xmum.attendance_assistant/enterprise", binaryMessenger: messenger)
    enterprise.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      if call.method == "permissions" { self.wifi.permissions(result); return }
      self.reply(result) { try await self.enterprise(call) }
    }
    let network = FlutterMethodChannel(name: "com.xmum.attendance_assistant/network", binaryMessenger: messenger)
    network.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      self.reply(result) { try await self.network(call) }
    }
    let requests = FlutterMethodChannel(name: "com.xmum.attendance_assistant/http", binaryMessenger: messenger)
    requests.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      self.reply(result) { try await self.request(call) }
    }
    archive.register(messenger: messenger)
  }

  private func reply(_ result: @escaping FlutterResult, operation: @escaping () async throws -> Any?) {
    Task { @MainActor in
      do { result(try await operation()) }
      catch let error as SchoolError { result(error.flutter) }
      catch { result(SchoolError(code: "CAMPUS_NETWORK_ERROR", message: "校园网络操作失败，请检查连接和权限").flutter) }
    }
  }

  private func enterprise(_ call: FlutterMethodCall) async throws -> Any? {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "preferences":
      return ["mode": preferences.string(forKey: "networkMode") ?? "student5g",
              "phase2": preferences.string(forKey: "phase2") ?? "MSCHAPV2",
              "automaticSupported": (preferences.string(forKey: "phase2") ?? "MSCHAPV2") == "MSCHAPV2"]
    case "setPreferences":
      guard let mode = args["mode"] as? String, ["student5g", "manual5g", "student"].contains(mode),
            let phase2 = args["phase2"] as? String, ["MSCHAPV2", "GTC"].contains(phase2),
            mode != "student5g" || phase2 == "MSCHAPV2" else {
        throw SchoolError(code: "ENTERPRISE_SETTINGS", message: "校园网设置不受支持；iPhone 的 PEAP/GTC 请使用手动模式")
      }
      preferences.set(mode, forKey: "networkMode")
      preferences.set(phase2, forKey: "phase2")
      return nil
    case "currentHandle": return (try? await wifi.snapshot().generation) ?? -1
    case "prepare":
      return try await wifi.prepare(username: args["username"] as? String ?? "",
                                    password: args["password"] as? String ?? "",
                                    phase2: preferences.string(forKey: "phase2") ?? "MSCHAPV2")
    case "connect": return try await wifi.reconnect(ssid: "Student-5G", manual: args["manual"] as? Bool ?? false)
    case "state": return try await wifi.checkBinding().dictionary
    case "legacyGuard":
      guard try await wifi.snapshot().ssid == "Student" else {
        throw SchoolError(code: "LEGACY_NETWORK_TYPE", message: "Student 旧版流程只能用于 Student 网络，请检查校园网方式")
      }
      return nil
    case "release": wifi.release(); return nil
    default: return FlutterMethodNotImplemented
    }
  }

  private func request(_ call: FlutterMethodCall) async throws -> Any? {
    let args = call.arguments as? [String: Any] ?? [:]
    guard let id = args["session"] as? String else {
      throw SchoolError(code: "NETWORK_ERROR", message: "缺少独立网络会话")
    }
    if call.method == "close" { http.close(id); return nil }
    guard call.method == "send" else { return FlutterMethodNotImplemented }
    guard let text = args["url"] as? String, let url = URL(string: text),
          let hosts = args["allowedHosts"] as? [String], let wifiOnly = args["wifiOnly"] as? Bool else {
      throw SchoolError(code: "NETWORK_ERROR", message: "网络请求参数无效")
    }
    return try await http.send(id: id, url: url, method: args["method"] as? String ?? "GET",
                               body: args["body"] as? String, headers: args["headers"] as? [String: String] ?? [:],
                               hosts: Set(hosts), wifiOnly: wifiOnly)
  }

  private func network(_ call: FlutterMethodCall) async throws -> Any? {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "bind": return try await wifi.bind()
    case "release": wifi.release(); http.close("campus"); return nil
    case "reconnect":
      _ = try await wifi.checkBinding()
      http.close("campus")
      let value = try await wifi.reconnect(ssid: "Student", manual: true)
      return value["ip"]
    case "state": return try await wifi.checkBinding().dictionary
    case "portal": return try await portalPage()
    case "get":
      guard let path = args["path"] as? String, paths.contains(path) else {
        throw SchoolError(code: "CAMPUS_NETWORK_ERROR", message: "校园网接口不受支持")
      }
      var params = args["params"] as? [String: String] ?? [:]
      if path.hasPrefix("/cgi-bin/") { params["callback"] = "campusFlow" }
      params["_"] = String(Int(Date().timeIntervalSince1970 * 1000))
      var url = URLComponents(string: "https://srun.xmu.edu.my\(path)")!
      url.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
      return try await campus(url.url!, onlineList: path == "/v1/srun_portal_online")["body"]
    default: return FlutterMethodNotImplemented
    }
  }

  private func campus(_ url: URL, onlineList: Bool = false, allowRedirect: Bool = false) async throws -> [String: Any] {
    let headers = onlineList ? ["X-Requested-With": "XMLHttpRequest",
                                "Referer": "https://srun.xmu.edu.my/srun_portal_phone"] : [:]
    var reply = try await http.send(id: "campus", url: url, method: "GET", body: nil,
                                    headers: headers, hosts: ["srun.xmu.edu.my"], wifiOnly: true)
    if allowRedirect, let status = reply["status"] as? Int, [301, 302, 303, 307, 308].contains(status) { return reply }
    guard reply["status"] as? Int == 200, var text = reply["body"] as? String, text.utf8.count <= 65536 else {
      throw SchoolError(code: "CAMPUS_NETWORK_ERROR", message: "学校校园网服务未返回有效响应")
    }
    text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.hasSuffix(";") { text.removeLast() }
    reply["body"] = text
    return reply
  }

  private func captures(_ pattern: String, _ text: String) -> [[String]] {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
    return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
      (0..<match.numberOfRanges).map { i in
        Range(match.range(at: i), in: text).map { String(text[$0]) } ?? ""
      }
    }
  }

  private func portalPage() async throws -> String {
    let origin = URL(string: "https://srun.xmu.edu.my/")!
    let first = try await campus(origin.appendingPathComponent("srun_portal_phone"))["body"] as! String
    if captures(#"\bacid\s*:\s*["']([^"']*)["']"#, first).first?[1] != "" { return first }
    let root = try await campus(origin, allowRedirect: true)
    var entry = root["body"] as? String ?? ""
    if let location = root["location"] as? String {
      guard let url = URL(string: location, relativeTo: origin)?.absoluteURL,
            validPortal(url), url.query == nil,
            url.path.range(of: #"^/index_[0-9]+\.html$"#, options: .regularExpression) != nil else {
        throw SchoolError(code: "NETWORK_CONFIG", message: "学校认证入口重定向不受支持")
      }
      entry = try await campus(url)["body"] as! String
    }
    let meta = captures(#"<meta\b(?=[^>]*\bhttp-equiv\s*=\s*["']refresh["'])[^>]*\bcontent\s*=\s*(["'])(.*?)\1[^>]*>"#, entry)
    guard meta.count == 1, let target = captures(#"(?:^|;)\s*url\s*=\s*(.+)$"#, meta[0][2]).first?[1],
          let url = URL(string: target.trimmingCharacters(in: .whitespacesAndNewlines)
                         .replacingOccurrences(of: "&amp;", with: "&"), relativeTo: origin)?.absoluteURL,
          validPortal(url), ["/srun_portal_pc", "/srun_portal_phone"].contains(url.path),
          let components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
      throw SchoolError(code: "NETWORK_CONFIG", message: "无法读取学校认证入口的 AC 参数")
    }
    let ids = (components.queryItems ?? []).filter { $0.name == "ac_id" }.compactMap { $0.value }
    guard ids.count == 1, ids[0].range(of: #"^[1-9][0-9]{0,9}$"#, options: .regularExpression) != nil else {
      throw SchoolError(code: "NETWORK_CONFIG", message: "学校认证入口的 AC 参数无效")
    }
    return try await campus(URL(string: "https://srun.xmu.edu.my/srun_portal_phone?ac_id=\(ids[0])")!)["body"] as! String
  }

  private func validPortal(_ url: URL) -> Bool {
    url.scheme == "https" && url.host == "srun.xmu.edu.my" && url.user == nil && url.password == nil
      && (url.port == nil || url.port == 443) && url.fragment == nil
  }
}
