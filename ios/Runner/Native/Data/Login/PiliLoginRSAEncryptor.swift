import Foundation
import Security

protocol PiliLoginPasswordEncrypting: Sendable {
  func encrypt(_ plaintext: String, publicKeyPEM: String) throws -> String
}

/// encrypt 5.0.3 uses RSA/PKCS1 v1.5, not OAEP. SecKey stays local to the
/// operation and plaintext is never handed to Keychain or account persistence.
struct PiliLoginRSAEncryptor: PiliLoginPasswordEncrypting {
  func encrypt(_ plaintext: String, publicKeyPEM: String) throws -> String {
    let der = try Self.publicKeyDER(publicKeyPEM)
    let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                                    kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
    var error: Unmanaged<CFError>?
    guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &error),
          SecKeyIsAlgorithmSupported(key, .encrypt, .rsaEncryptionPKCS1) else {
      throw PiliLoginError.invalidPublicKey
    }
    guard let encrypted = SecKeyCreateEncryptedData(key, .rsaEncryptionPKCS1,
                                                    Data(plaintext.utf8) as CFData, &error) else {
      throw PiliLoginError.encryptionFailed
    }
    return (encrypted as Data).base64EncodedString()
  }

  static func publicKeyDER(_ pem: String) throws -> Data {
    let lines = pem.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
    guard let first = lines.first, let last = lines.last,
          (first == "-----BEGIN PUBLIC KEY-----" && last == "-----END PUBLIC KEY-----") ||
          (first == "-----BEGIN RSA PUBLIC KEY-----" && last == "-----END RSA PUBLIC KEY-----"),
          let data = Data(base64Encoded: lines.dropFirst().dropLast().joined()), data.count <= 8192 else {
      throw PiliLoginError.invalidPublicKey
    }
    let bytes = Array(data)
    var outerIndex = 0
    let outer = try read(bytes, index: &outerIndex, tag: 0x30)
    guard outerIndex == bytes.count else { throw PiliLoginError.invalidPublicKey }
    var index = outer.lowerBound
    if first == "-----BEGIN RSA PUBLIC KEY-----" {
      _ = try read(bytes, index: &index, tag: 0x02); _ = try read(bytes, index: &index, tag: 0x02)
      guard index == outer.upperBound else { throw PiliLoginError.invalidPublicKey }
      return data
    }
    let algorithm = try read(bytes, index: &index, tag: 0x30)
    // rsaEncryption OID followed by ASN.1 NULL; reject non-RSA SPKI headers.
    guard Array(bytes[algorithm]) == [0x06,0x09,0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x01,0x01,0x05,0x00] else {
      throw PiliLoginError.invalidPublicKey
    }
    let bits = try read(bytes, index: &index, tag: 0x03)
    guard index == outer.upperBound, bits.count > 1, bytes[bits.lowerBound] == 0 else {
      throw PiliLoginError.invalidPublicKey
    }
    let keyBytes = Array(bytes[(bits.lowerBound + 1)..<bits.upperBound])
    var keyIndex = 0
    let key = try read(keyBytes, index: &keyIndex, tag: 0x30)
    guard keyIndex == keyBytes.count else { throw PiliLoginError.invalidPublicKey }
    keyIndex = key.lowerBound
    _ = try read(keyBytes, index: &keyIndex, tag: 0x02); _ = try read(keyBytes, index: &keyIndex, tag: 0x02)
    guard keyIndex == key.upperBound else { throw PiliLoginError.invalidPublicKey }
    return Data(keyBytes)
  }

  private static func read(_ bytes: [UInt8], index: inout Int, tag: UInt8) throws -> Range<Int> {
    guard index + 2 <= bytes.count, bytes[index] == tag else { throw PiliLoginError.invalidPublicKey }
    index += 1
    let byte = bytes[index]; index += 1
    var length = Int(byte)
    if byte & 0x80 != 0 {
      let count = Int(byte & 0x7f)
      guard count > 0, count <= 3, index + count <= bytes.count else { throw PiliLoginError.invalidPublicKey }
      length = 0
      for _ in 0..<count { length = (length << 8) | Int(bytes[index]); index += 1 }
    }
    guard length > 0, length <= bytes.count - index else { throw PiliLoginError.invalidPublicKey }
    let range = index..<(index + length); index += length
    return range
  }

  static func deviceNonce() -> String {
    let characters = Array("0123456789abcdefghijklmnopqrstuvwxyz")
    var generator = SystemRandomNumberGenerator()
    return String((0..<16).map { _ in characters.randomElement(using: &generator)! })
  }
}
