import Foundation

private final class StopRedirects: NSObject, URLSessionTaskDelegate {
  func urlSession(_ session: URLSession, task: URLSessionTask,
                  willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest,
                  completionHandler: @escaping (URLRequest?) -> Void) {
    // Dart checks each destination and never resends a POST on 307/308.
    completionHandler(nil)
  }
}

@MainActor
final class SchoolHTTP {
  private struct Session {
    let client: URLSession
    let hosts: Set<String>
    let wifiOnly: Bool
  }
  private let delegate = StopRedirects()
  private let wifi: any SchoolBindingChecking
  private var sessions: [String: Session] = [:]
  private let schoolHosts: Set<String> = ["cas.xmu.edu.my", "acad.xmu.edu.my", "ac.xmu.edu.my", "srun.xmu.edu.my"]

  init(wifi: any SchoolBindingChecking) { self.wifi = wifi }

  func close(_ id: String) {
    guard let session = sessions.removeValue(forKey: id) else { return }
    session.client.configuration.httpCookieStorage?.removeCookies(since: .distantPast)
    session.client.invalidateAndCancel()
  }

  func send(id: String, url: URL, method: String, body: String?,
            headers: [String: String], hosts: Set<String>, wifiOnly: Bool) async throws -> [String: Any] {
    guard !id.isEmpty, !hosts.isEmpty, hosts.isSubset(of: schoolHosts),
          url.scheme == "https", url.user == nil, url.password == nil,
          url.port == nil || url.port == 443, let host = url.host, hosts.contains(host),
          ["GET", "POST"].contains(method) else {
      throw SchoolError(code: "UNEXPECTED_REDIRECT", message: "学校请求地址或方法不受支持")
    }
    let session: Session
    if let existing = sessions[id] {
      guard existing.hosts == hosts, existing.wifiOnly == wifiOnly else {
        throw SchoolError(code: "NETWORK_ERROR", message: "网络会话配置已变化")
      }
      session = existing
    } else {
      let config = URLSessionConfiguration.ephemeral
      config.allowsCellularAccess = !wifiOnly
      config.waitsForConnectivity = false
      config.timeoutIntervalForRequest = 25
      config.timeoutIntervalForResource = 30
      config.requestCachePolicy = .reloadIgnoringLocalCacheData
      config.urlCache = nil
      session = Session(client: URLSession(configuration: config, delegate: delegate, delegateQueue: nil),
                        hosts: hosts, wifiOnly: wifiOnly)
      sessions[id] = session
    }
    // Register before awaiting Wi-Fi so close() can cancel this operation while
    // fetchCurrent is pending. A reused campus ID must not revive an old task.
    let savedLink = wifiOnly ? try await wifi.checkBinding() : nil
    try requireActive(id: id, session: session)
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.httpBody = body?.data(using: .utf8)
    request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
    request.setValue("XMUMAttendanceAssistant/0.8 iOS", forHTTPHeaderField: "User-Agent")
    for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
    do {
      let (data, response) = try await session.client.data(for: request)
      if wifiOnly, try await wifi.checkBinding() != savedLink {
        throw SchoolError(code: "ENTERPRISE_CONNECTION_CHANGED", message: "校园 Wi-Fi 已变化，已停止")
      }
      try requireActive(id: id, session: session)
      guard let http = response as? HTTPURLResponse, data.count <= 4 * 1024 * 1024,
            let text = String(data: data, encoding: .utf8) else {
        throw SchoolError(code: "SCHEMA_CHANGED", message: "学校响应格式不受支持或响应过大")
      }
      var value: [String: Any] = ["status": http.statusCode, "body": text]
      if let location = http.value(forHTTPHeaderField: "Location") { value["location"] = location }
      return value
    } catch let error as SchoolError { throw error }
    catch {
      // Never echo URL, POST payload, cookies, credentials or URLSession errors.
      throw SchoolError(code: "NETWORK_ERROR", message: "学校网络请求失败，请检查 Wi-Fi、网络权限和学校服务；提交不会自动重发")
    }
  }

  private func requireActive(id: String, session: Session) throws {
    guard sessions[id]?.client === session.client else {
      throw SchoolError(code: "NETWORK_ERROR", message: "网络会话已关闭，流程已停止")
    }
  }
}
