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

}
