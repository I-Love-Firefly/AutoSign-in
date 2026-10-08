import CommonCrypto
import CryptoKit
import Flutter
import Foundation
import Security
import UIKit
import UniformTypeIdentifiers

enum AccountArchiveCrypto {
  static let maxBytes = 4 * 1024 * 1024
  static let iterations: UInt32 = 310_000
  static let aad = Data("XMUM_ACCOUNT_ARCHIVE_V1".utf8)

  private static func random(_ count: Int) throws -> Data {
    var value = Data(count: count)
    let status = value.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
    guard status == errSecSuccess else { throw CocoaError(.coderInvalidValue) }
    return value
  }

  private static func key(_ password: String, salt: Data) throws -> SymmetricKey {
    var passwordBytes = Data(password.utf8)
    var output = Data(count: 32)
    defer {
      passwordBytes.resetBytes(in: 0..<passwordBytes.count)
      output.resetBytes(in: 0..<output.count)
    }
    let status = output.withUnsafeMutableBytes { destination in
      passwordBytes.withUnsafeBytes { passwordBuffer in
        salt.withUnsafeBytes { saltBuffer in
          CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                              passwordBuffer.bindMemory(to: Int8.self).baseAddress!, passwordBytes.count,
                              saltBuffer.bindMemory(to: UInt8.self).baseAddress!, salt.count,
                              CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                              destination.bindMemory(to: UInt8.self).baseAddress!, 32)
        }
      }
    }
    guard status == kCCSuccess else { throw CocoaError(.coderInvalidValue) }
    return SymmetricKey(data: output)
  }

  static func encrypt(_ plaintext: Data, password: String) throws -> Data {
    guard password.utf16.count >= 12, plaintext.count <= 2 * 1024 * 1024 else { throw CocoaError(.coderInvalidValue) }
    let salt = try random(16), nonce = try random(12)
    let box = try AES.GCM.seal(plaintext, using: key(password, salt: salt),
                               nonce: AES.GCM.Nonce(data: nonce), authenticating: aad)
    // Android's Cipher.doFinal returns ciphertext || 16-byte GCM tag.
    let archive: [String: Any] = ["format": "xmum-attendance-accounts-encrypted", "version": 1,
                                "kdf": "PBKDF2-HMAC-SHA256", "iterations": Int(iterations),
                                "cipher": "AES-256-GCM", "salt": salt.base64EncodedString(),
                                "nonce": nonce.base64EncodedString(),
                                "data": (box.ciphertext + box.tag).base64EncodedString()]
    let output = try JSONSerialization.data(withJSONObject: archive, options: [.sortedKeys])
    guard output.count <= maxBytes else { throw CocoaError(.coderInvalidValue) }
    return output
  }

  static func decrypt(_ bytes: Data, password: String) throws -> Data {
    guard bytes.count <= maxBytes, password.utf16.count >= 12,
          let archive = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
          archive["format"] as? String == "xmum-attendance-accounts-encrypted",
          archive["version"] as? Int == 1,
          archive["kdf"] as? String == "PBKDF2-HMAC-SHA256",
          archive["iterations"] as? Int == Int(iterations),
          archive["cipher"] as? String == "AES-256-GCM",
          let saltString = archive["salt"] as? String, let salt = Data(base64Encoded: saltString), salt.count == 16,
          let nonceString = archive["nonce"] as? String, let nonce = Data(base64Encoded: nonceString), nonce.count == 12,
          let text = archive["data"] as? String, let ciphertext = Data(base64Encoded: text),
          ciphertext.count >= 16, ciphertext.count <= maxBytes else { throw CocoaError(.coderInvalidValue) }
    let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce),
                                    ciphertext: ciphertext.dropLast(16), tag: ciphertext.suffix(16))
    let plaintext = try AES.GCM.open(box, using: key(password, salt: salt), authenticating: aad)
    guard plaintext.count <= 2 * 1024 * 1024 else { throw CocoaError(.coderInvalidValue) }
    return plaintext
  }
}

@MainActor
final class AccountArchiveChannel: NSObject, UIDocumentPickerDelegate {
  private var pending: FlutterResult?
  private var exporting = false
  private var temporary: URL?

  func register(messenger: FlutterBinaryMessenger) {
    FlutterMethodChannel(name: "com.xmum.attendance_assistant/archive", binaryMessenger: messenger)
      .setMethodCallHandler { [weak self] call, result in
        guard let self = self else { return }
        switch call.method {
        case "encrypt", "decrypt": self.crypto(call, result: result)
        case "save", "open": self.pick(call, result: result)
        default: result(FlutterMethodNotImplemented)
        }
      }
  }

  private func crypto(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    guard let input = args["bytes"] as? FlutterStandardTypedData, input.data.count <= AccountArchiveCrypto.maxBytes,
          let password = args["password"] as? String, password.utf16.count >= 12 else {
      result(FlutterError(code: "INVALID_ARCHIVE", message: "文件或传输密码无效", details: nil))
      return
    }
    let encrypt = call.method == "encrypt"
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let bytes = try encrypt ? AccountArchiveCrypto.encrypt(input.data, password: password)
                                : AccountArchiveCrypto.decrypt(input.data, password: password)
        DispatchQueue.main.async { result(FlutterStandardTypedData(bytes: bytes)) }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: encrypt ? "ENCRYPT_FAILED" : "DECRYPT_FAILED",
                              message: encrypt ? "加密失败" : "传输密码错误或文件已损坏", details: nil))
        }
      }
    }
  }

  private func pick(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard pending == nil, let presenter = SchoolWiFi.presenter else {
      result(FlutterError(code: "BUSY", message: "已有文件操作或系统页面正在处理，请返回应用后重试", details: nil))
      return
    }
    let picker: UIDocumentPickerViewController
    do {
      exporting = call.method == "save"
      if exporting {
        let args = call.arguments as? [String: Any] ?? [:]
        guard let bytes = args["bytes"] as? FlutterStandardTypedData, !bytes.data.isEmpty,
              bytes.data.count <= AccountArchiveCrypto.maxBytes, let name = args["name"] as? String,
              name.range(of: #"^[a-zA-Z0-9._-]{1,100}\.xmumaccounts$"#, options: .regularExpression) != nil else {
          throw CocoaError(.coderInvalidValue)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporary = directory
        var url = directory.appendingPathComponent(name)
        // Only the already encrypted archive is written to temporary storage.
        try bytes.data.write(to: url, options: [.atomic, .completeFileProtection])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
      } else {
        picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: true)
      }
      picker.delegate = self
      picker.allowsMultipleSelection = false
      pending = result
      presenter.present(picker, animated: true)
    } catch {
      cleanup()
      result(FlutterError(code: "FILE_IO", message: "无法打开文件选择器或准备导出文件", details: nil))
    }
  }

  private func cleanup() {
    if let url = temporary { try? FileManager.default.removeItem(at: url) }
    temporary = nil
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    let result = pending
    pending = nil
    cleanup()
    result?(exporting ? false : nil)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let result = pending else { return }
    pending = nil
    if exporting { cleanup(); result(true); return }
    guard urls.count == 1 else {
      result(FlutterError(code: "FILE_IO", message: "请选择一个账号文件", details: nil))
      return
    }
    let url = urls[0]
    DispatchQueue.global(qos: .userInitiated).async {
      let access = url.startAccessingSecurityScopedResource()
      defer { if access { url.stopAccessingSecurityScopedResource() } }
      var coordinationError: NSError?
      var output: Data?
      var readFailed = false
      NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { file in
        do {
          let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
          guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= AccountArchiveCrypto.maxBytes,
                let stream = InputStream(url: file) else { throw CocoaError(.fileReadTooLarge) }
          stream.open()
          defer { stream.close() }
          var bytes = Data(), buffer = [UInt8](repeating: 0, count: 8192)
          while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw CocoaError(.fileReadUnknown) }
            if count == 0 { break }
            guard bytes.count + count <= AccountArchiveCrypto.maxBytes else { throw CocoaError(.fileReadTooLarge) }
            bytes.append(contentsOf: buffer.prefix(count))
          }
          output = bytes
        } catch { readFailed = true }
      }
      let loaded = output
      let failed = readFailed || coordinationError != nil
      DispatchQueue.main.async {
        if !failed, let bytes = loaded { result(FlutterStandardTypedData(bytes: bytes)) }
        else { result(FlutterError(code: "FILE_IO", message: "读取文件失败，请检查文件大小和存储位置", details: nil)) }
      }
    }
  }
}
