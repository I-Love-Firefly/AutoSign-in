import Flutter
import UIKit
import XCTest
@testable import Runner

class RunnerTests: XCTestCase {

  private func vector() throws -> [String: String] {
    let url = try XCTUnwrap(Bundle(for: RunnerTests.self).url(forResource: "archive-interop", withExtension: "json"))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: String])
  }

  func testIndependentArchiveWithUnicodePassword() throws {
    let fixture = try vector()
    let plaintext = try AccountArchiveCrypto.decrypt(Data(fixture["archive"]!.utf8), password: fixture["password"]!)
    XCTAssertEqual(String(data: plaintext, encoding: .utf8), fixture["plaintext"])
  }

  func testRandomizedRoundTripAndWrongPassword() throws {
    let fixture = try vector()
    let input = Data(fixture["plaintext"]!.utf8), password = fixture["password"]!
    let first = try AccountArchiveCrypto.encrypt(input, password: password)
    let second = try AccountArchiveCrypto.encrypt(input, password: password)
    XCTAssertNotEqual(first, second)
    XCTAssertEqual(try AccountArchiveCrypto.decrypt(first, password: password), input)
    XCTAssertThrowsError(try AccountArchiveCrypto.decrypt(first, password: "wrong-passphrase-123"))
  }

  func testCorruptionAndKDFDowngradeRejected() throws {
    let fixture = try vector()
    var archive = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(fixture["archive"]!.utf8)) as? [String: Any])
    var ciphertext = try XCTUnwrap(Data(base64Encoded: archive["data"] as! String))
    ciphertext[ciphertext.count - 1] ^= 1
    archive["data"] = ciphertext.base64EncodedString()
    XCTAssertThrowsError(try AccountArchiveCrypto.decrypt(JSONSerialization.data(withJSONObject: archive), password: fixture["password"]!))
    archive["iterations"] = 1
    XCTAssertThrowsError(try AccountArchiveCrypto.decrypt(JSONSerialization.data(withJSONObject: archive), password: fixture["password"]!))
  }

  func testSizeAndNonceLimits() throws {
    let fixture = try vector()
    XCTAssertThrowsError(try AccountArchiveCrypto.encrypt(Data(count: 2 * 1024 * 1024 + 1), password: fixture["password"]!))
    var archive = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(fixture["archive"]!.utf8)) as? [String: Any])
    archive["nonce"] = Data(count: 11).base64EncodedString()
    XCTAssertThrowsError(try AccountArchiveCrypto.decrypt(JSONSerialization.data(withJSONObject: archive), password: fixture["password"]!))
  }

  @MainActor
  func testClosedSessionStopsBeforeSendingAfterWiFiCheck() async throws {
    let gate = SuspendedBinding()
    let http = SchoolHTTP(wifi: gate, makeConfiguration: {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.protocolClasses = [RejectTestNetwork.self]
      return configuration
    })
    let request = Task {
      try await http.send(id: "cancel-test", url: URL(string: "https://acad.xmu.edu.my/")!,
                          method: "POST", body: "fictional-test-only", headers: [:],
                          hosts: ["acad.xmu.edu.my"], wifiOnly: true)
    }
    await fulfillment(of: [gate.entered], timeout: 3)
    let continuation = try XCTUnwrap(gate.continuation)
    http.close("cancel-test")
    continuation.resume(returning: WiFiSnapshot(ip: "10.0.0.1", ssid: "Student-5G",
                                                bssid: "test-only", enterprise: true, generation: 1))
    do {
      _ = try await request.value
      XCTFail("A closed session must stop before starting the POST")
    } catch let error as SchoolError {
      XCTAssertEqual(error.code, "NETWORK_ERROR")
      XCTAssertEqual(error.message, "网络会话已关闭，流程已停止")
    }
  }

}

@MainActor
private final class SuspendedBinding: SchoolBindingChecking {
  let entered = XCTestExpectation(description: "Wi-Fi check suspended")
  var continuation: CheckedContinuation<WiFiSnapshot, Error>?
  func checkBinding() async throws -> WiFiSnapshot {
    try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation
      entered.fulfill()
    }
  }
}

// Even a regression must never send the fictional test POST to a live school.
private final class RejectTestNetwork: URLProtocol {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    client?.urlProtocol(self, didFailWithError: NSError(domain: "OfflineTests", code: 1))
  }
  override func stopLoading() {}
}
