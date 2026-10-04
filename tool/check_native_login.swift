import Foundation
import Security

@MainActor
private func require(_ condition: Bool, _ message: String) throws {
  guard condition else { throw FixtureError.failed(message) }; checks += 1
}
private enum FixtureError: Error { case failed(String) }
@MainActor private var checks = 0
private let phone = PiliLoginPhoneVerification(url: URL(string: "https://passport.bilibili.com/h5-app/passport/risk/verify?tmp_token=synthetic-tmp&request_id=synthetic-request&source=risk")!,
  tmpToken: "synthetic-tmp", requestID: "synthetic-request", source: "risk")
private let answer = PiliLoginChallengeAnswer(challenge: "synthetic-challenge", validate: "synthetic-validate", seccode: "synthetic-seccode", recaptchaToken: "synthetic-token")
private let ownerA = PiliLoginAccountOwner(authorityEpoch: "A0000000-0000-4000-8000-000000000001",
                                         identity: .init(ownerToken: "A0000000-0000-4000-8000-000000000002", generation: 1))
private let ownerB = PiliLoginAccountOwner(authorityEpoch: ownerA.authorityEpoch,
                                         identity: .init(ownerToken: "B0000000-0000-4000-8000-000000000002", generation: 2))

@main
@MainActor
struct CheckNativeLogin {
  static func main() async throws {
    let root = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
    let rsa = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))) as! [String: String]
    guard let cases = root["cases"] as? [[String: Any]], cases.count == 20 else { throw FixtureError.failed("missing actual Dart LoginHttp goldens") }
    for item in cases {
      let name = item["operation"] as! String, expected = item["request"] as! [String: Any]
      let fields = expected["fields"] as! [String: String]
      let operation = try operation(name, fields: fields, headers: expected["headers"] as! [String: String])
      let environment = PiliLoginEnvironment(buvid: root["buvid"] as! String, deviceID: root["deviceID"] as! String,
        epochMilliseconds: (item["epochMilliseconds"] as! NSNumber).int64Value,
        appKey: root["appKey"] as! String, appSecret: root["appSecret"] as! String,
        signingEpochSeconds: (item["epochSeconds"] as! NSNumber).int64Value)
      let request = try PiliLoginRequestBuilder.build(operation, environment: environment)
      try require(request.method == expected["method"] as? String, name + " method")
      let dartURL = URLComponents(string: expected["url"] as! String)!
      let nativeURL = URLComponents(url: request.url, resolvingAgainstBaseURL: false)!
      try require(nativeURL.scheme == dartURL.scheme && nativeURL.host == dartURL.host && nativeURL.path == dartURL.path, name + " endpoint")
      let expectedParameters = fields
      let actualParameters = try parameters(request.body.map { String(decoding: $0, as: UTF8.self) } ?? nativeURL.percentEncodedQuery ?? "")
      try require(actualParameters == expectedParameters, name + " actual Dart fields/sign/double encoding")
      let expectedBody = expected["body"] as! String
      if request.body != nil {
        // Field insertion order is not an API semantic; preserve actual encoding
        // of each field/value and repeated signs instead of sorting the body.
        let nativeParts = String(decoding: request.body!, as: UTF8.self).split(separator: "&").map(String.init).sorted()
        let dartParts = expectedBody.split(separator: "&").map(String.init).sorted()
        try require(nativeParts == dartParts, name + " raw Dio form field bytes")
      } else { try require(expectedBody.isEmpty, name + " no invented POST body") }
      let headers = expected["headers"] as! [String: String]
      for (key, value) in request.headers {
        try require(headers.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value == value, name + " header " + key)
      }
      if fields["password"] != nil {
        let plaintext = try decrypt(fields["password"]!, privatePEM: rsa["privatePKCS1PEM"]!)
        try require(plaintext == "synthetic-saltsynthetic-pwd", name + " actual Dart PKCS1 password")
        let nativeEncrypted = try PiliLoginRSAEncryptor().encrypt(plaintext, publicKeyPEM: rsa["publicPEM"]!)
        try require(try decrypt(nativeEncrypted, privatePEM: rsa["privatePKCS1PEM"]!) == plaintext, name + " native PKCS1 password")
      }
      if let token = fields["dt"]?.removingPercentEncoding {
        let nonce = try decrypt(token, privatePEM: rsa["privatePKCS1PEM"]!)
        try require(nonce.count == 16 && nonce.allSatisfy { "0123456789abcdefghijklmnopqrstuvwxyz".contains($0) }, name + " Dart nonce contract")
      }
      let response = try JSONSerialization.data(withJSONObject: item["response"]!)
      if name == "passwordMissingCredentials" {
        do { _ = try PiliLoginResponseDecoder.decode(response, operation: operation); throw FixtureError.failed("missing credentials accepted") }
        catch is PiliLoginError { checks += 1 }
      } else {
        let result = try PiliLoginResponseDecoder.decode(response, operation: operation)
        try require(resultName(result) == expectedResultName(name), name + " response/state mapping")
      }
    }
    try require(try PiliLoginRSAEncryptor.publicKeyDER(rsa["publicPEM"]!) == PiliLoginRSAEncryptor.publicKeyDER(rsa["publicPKCS1PEM"]!), "SPKI and PKCS1 import same public key")
    do { _ = try PiliLoginRSAEncryptor().encrypt("password", publicKeyPEM: "bad-key"); throw FixtureError.failed("bad RSA accepted") }
    catch is PiliLoginError { checks += 1 }
    let credentials = try PiliLoginResponseDecoder.cookieCredentials("DedeUserID=910001; bili_jct=synthetic-csrf; SESSDATA=synthetic=session==")
    try require(credentials.cookies.last?.value == "synthetic=session==", "Cookie '=' preserved")
    do { _ = try PiliLoginResponseDecoder.cookieCredentials("DedeUserID=1; DedeUserID=2; SESSDATA=s; bili_jct=c"); throw FixtureError.failed("duplicate Cookie accepted") }
    catch is PiliLoginError { checks += 1 }
    try require(PiliLoginResponseDecoder.phoneURL("https://evil.example/?tmp_token=t&request_id=r&source=s") == nil, "foreign phone referer rejected")
    try require(PiliLoginResponseDecoder.challengeURL("https://passport.bilibili.com/?gee_gt=a&gee_gt=b&gee_challenge=c&recaptcha_token=t") == nil, "duplicate challenge keys rejected")
    try await sessionChecks(credentials)
    print("\(checks) native login checks passed")
  }

  private static func operation(_ name: String, fields: [String: String], headers: [String: String]) throws -> PiliLoginOperation {
    switch name {
    case "qrCreate": return .qrCreate
    case "qrPoll", "qrWaiting", "qrExpired": return .qrPoll(authCode: "synthetic-auth")
    case "webKey": return .webKey
    case "password", "passwordPhone", "passwordChallenge", "passwordMissingCredentials", "passwordFailure":
      return .password(username: fields["username"]!, encryptedPassword: fields["password"]!,
                       encryptedDeviceToken: fields["dt"]!.removingPercentEncoding!, challenge: answer)
    case "smsSend", "smsChallengeFallback": return .smsSend(countryID: "86", telephone: "synthetic +%=&", challenge: answer)
    case "smsLogin": return .smsLogin(countryID: "86", telephone: "synthetic +%=&", code: "123456", captchaKey: "synthetic-sms-key",
                                      encryptedDeviceToken: fields["dt"]!.removingPercentEncoding!)
    case "phoneInfo": return .phoneInfo(phone)
    case "preCapture": return .preCapture
    case "phoneSMSSend": return .phoneSMSSend(phone, challenge: answer)
    case "phoneSMSVerify": return .phoneSMSVerify(phone, code: "123456", captchaKey: "synthetic-phone-key")
    case "oauthAccessToken": return .oauthAccessToken(code: "synthetic-oauth")
    case "logout": return .logout(owner: ownerA, csrf: "synthetic-csrf")
    case "cookieValidate": return .cookieValidate(headers.first { $0.key.lowercased() == "cookie" }!.value)
    default: throw FixtureError.failed(name)
    }
  }
  private static func parameters(_ query: String) throws -> [String: String] {
    var fields: [String: String] = [:]
    for part in query.split(separator: "&", omittingEmptySubsequences: true) {
      let pieces = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard let key = pieces[0].replacingOccurrences(of: "+", with: " ").removingPercentEncoding,
            let value = (pieces.count == 2 ? String(pieces[1]) : "").replacingOccurrences(of: "+", with: " ").removingPercentEncoding,
            fields[key] == nil else { throw FixtureError.failed("duplicate/invalid field") }
      fields[key] = value
    }
    return fields
  }
  private static func resultName(_ value: PiliLoginResult) -> String {
    switch value {
    case .credentials: return "credentials"
    case .qr: return "qr"
    case .qrWaiting: return "waiting"
    case .qrExpired: return "expired"
    case .webKey: return "webKey"
    case .challenge: return "challenge"
    case .challengeNeedsPreCapture: return "preCaptureNeeded"
    case .phoneVerification: return "phoneVerification"
    case .phoneInfo: return "phoneInfo"
    case .smsSent: return "smsSent"
    case .oauthCode: return "oauthCode"
    case .loggedOut: return "loggedOut"
    case .failure: return "failure"
    }
  }
  private static func expectedResultName(_ name: String) -> String {
    switch name {
    case "qrCreate": return "qr"
    case "qrWaiting": return "waiting"
    case "qrExpired": return "expired"
    case "webKey": return "webKey"
    case "passwordPhone": return "phoneVerification"
    case "passwordChallenge", "preCapture", "smsChallengeFallback": return "challenge"
    case "passwordFailure": return "failure"
    case "phoneInfo": return "phoneInfo"
    case "smsSend", "phoneSMSSend": return "smsSent"
    case "phoneSMSVerify": return "oauthCode"
    case "logout": return "loggedOut"
    default: return "credentials"
    }
  }
  private static func decrypt(_ ciphertext: String, privatePEM: String) throws -> String {
    let base64 = privatePEM.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("-----") }.joined()
    let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPrivate]
    var error: Unmanaged<CFError>?
    guard let bytes = Data(base64Encoded: base64), let key = SecKeyCreateWithData(bytes as CFData, attributes as CFDictionary, &error),
          let encrypted = Data(base64Encoded: ciphertext),
          let plain = SecKeyCreateDecryptedData(key, .rsaEncryptionPKCS1, encrypted as CFData, &error) else {
      throw FixtureError.failed("synthetic key decrypt")
    }
    return String(decoding: plain as Data, as: UTF8.self)
  }

  private static func sessionChecks(_ credentials: PiliLoginCredentials) async throws {
    let qr = PiliLoginQRCode(authCode: "a", url: URL(string: "https://passport.bilibili.com/qr")!)
    let authority = FixtureAuthority()
    let repo = FixtureRepository([.qr(qr), .qrWaiting(code: 86039, message: "waiting"), .credentials(credentials)])
    let session = PiliLoginSession(repository: repo, authority: authority)
    _ = try await session.createQR()
    let waiting = try await session.pollQR()
    try require(waiting == .qrWaiting(code: 86039, message: "waiting"), "QR waiting state")
    let installed = try await session.pollQR(selection: .assign([.main, .video]))
    try require(installed == .installed(.init(owner: ownerA, needsPurposeSelection: false)), "QR installation")
    let selections = await authority.selections()
    try require(selections == [.assign([.main, .video])], "explicit native QR purposes retained")
    await session.cancel()
    let cancelled = await session.current()
    try require(cancelled == .cancelled, "cancel resets state")
    let riskRepo = FixtureRepository([.webKey(.init(salt: "s", publicKeyPEM: "synthetic")), .phoneVerification(phone),
                                     .oauthCode("code"), .credentials(credentials)])
    let risk = PiliLoginSession(repository: riskRepo, authority: authority, encryptor: FixtureEncryptor())
    try require(try await risk.password(username: "u", password: "p") == .phoneVerification(phone), "password status2 preserved")
    _ = try await risk.phoneVerify(phone, code: "123456", captchaKey: "k")
    let operations = await riskRepo.operations()
    try require(operations.count == 4 && operations.last == .oauthAccessToken(code: "code"), "phone verification exchanges OAuth")
    let logoutRepo = FixtureRepository([.loggedOut, .failure(code: -1, message: "failed")])
    let logout = PiliLoginLogoutService(repository: logoutRepo, authority: authority)
    let receipt = try await logout.logout([.init(owner: ownerA, csrf: "a"), .init(owner: ownerB, csrf: "b")], remote: true)
    try require(receipt.removed.count == 1 && receipt.retained.count == 1, "partial remote logout preserves failed account")
    let local = try await logout.logout([.init(owner: ownerB, csrf: "b")], remote: false)
    try require(local.removed == [ownerB] && local.retained.isEmpty, "local logout bypasses remote network")
    let staleRepo = FixtureRepository([], blocked: .qr(qr))
    let stale = PiliLoginSession(repository: staleRepo, authority: authority)
    let pending = Task { try await stale.createQR() }
    await staleRepo.waitUntilEntered()
    await stale.cancel(); await staleRepo.release()
    do { _ = try await pending.value; throw FixtureError.failed("stale QR accepted") }
    catch PiliLoginError.staleOperation { checks += 1 }
    let testClock = FixtureClock(Date(timeIntervalSince1970: 1900000000))
    let expired = PiliLoginSession(repository: FixtureRepository([.qr(qr)]), authority: authority,
                                   clock: { testClock.now() })
    _ = try await expired.createQR(); testClock.advance(180)
    try require(try await expired.pollQR() == .qrExpired, "QR180s expiry does not make extra network call")
    let smsClock = FixtureClock(Date(timeIntervalSince1970: 1900000000))
    let smsRepo = FixtureRepository([.challengeNeedsPreCapture, .challenge(.init(gt: "g", challenge: "c", recaptchaToken: "t")),
                                    .smsSent(captchaKey: "k")])
    let smsSession = PiliLoginSession(repository: smsRepo, authority: authority, clock: { smsClock.now() })
    let smsChallenge = try await smsSession.sendSMS(countryID: "86", telephone: "synthetic")
    try require(smsChallenge == .challenge(.init(gt: "g", challenge: "c", recaptchaToken: "t")), "SMS fallback uses preCapture")
    await smsSession.challengeClosed()
    try require(await smsSession.current() == .idle, "Geetest close retains retryable login flow")
    _ = try await smsSession.sendSMS(countryID: "86", telephone: "synthetic", challenge: answer)
    do { _ = try await smsSession.sendSMS(countryID: "86", telephone: "synthetic"); throw FixtureError.failed("SMS60s cooldown bypassed") }
    catch PiliLoginError.invalidInput { checks += 1 }
    smsClock.advance(301)
    do { _ = try await smsSession.smsLogin(countryID: "86", telephone: "synthetic", code: "123456"); throw FixtureError.failed("expired SMS accepted") }
    catch PiliLoginError.invalidInput { checks += 1 }
    await smsSession.challengeFailed()
    try require(await smsSession.current() == .failure(code: nil, message: "captchaLoadFailed"), "Geetest error stops automatic retry")
    let body = Data("{\"code\":86038,\"message\":\"expired\",\"data\":null}".utf8)
    let native = PiliNativeLoginRepository(transport: FixtureHTTP(body: body), environment: {
      .init(buvid: "b", deviceID: "d", epochMilliseconds: 1900000000000, appKey: "k", appSecret: "s")
    })
    try require(try await native.perform(.qrPoll(authCode: "a")) == .qrExpired, "production repository executes and decodes native request")
  }
}

private struct FixtureEncryptor: PiliLoginPasswordEncrypting {
  func encrypt(_ plaintext: String, publicKeyPEM: String) throws -> String { "encrypted:" + plaintext }
}
private actor FixtureAuthority: PiliLoginAccountAuthority {
  private var installed: [PiliLoginInstallSelection] = []
  private var removed: [PiliLoginAccountOwner] = []
  func install(_ credentials: PiliLoginCredentials, method: PiliLoginMethod,
               selection: PiliLoginInstallSelection) async throws -> PiliLoginInstallReceipt {
    installed.append(selection); return .init(owner: ownerA, needsPurposeSelection: false)
  }
  func delete(_ owners: [PiliLoginAccountOwner]) async throws { removed += owners }
  func selections() -> [PiliLoginInstallSelection] { installed }
}
private actor FixtureRepository: PiliLoginRepository {
  private var results: [PiliLoginResult]
  private var calls: [PiliLoginOperation] = []
  private var blocked: PiliLoginResult?
  private var pending: CheckedContinuation<PiliLoginResult, Never>?
  private var entered: [CheckedContinuation<Void, Never>] = []
  init(_ results: [PiliLoginResult], blocked: PiliLoginResult? = nil) { self.results = results; self.blocked = blocked }
  func perform(_ operation: PiliLoginOperation) async throws -> PiliLoginResult {
    calls.append(operation)
    if blocked != nil {
      return await withCheckedContinuation { continuation in
        pending = continuation
        entered.forEach { $0.resume() }; entered = []
      }
    }
    guard !results.isEmpty else { throw PiliLoginError.invalidResponse }; return results.removeFirst()
  }
  func operations() -> [PiliLoginOperation] { calls }
  func waitUntilEntered() async {
    if pending != nil { return }; await withCheckedContinuation { entered.append($0) }
  }
  func release() { pending?.resume(returning: blocked!); pending = nil; blocked = nil }
}

private struct FixtureHTTP: PiliLoginHTTPExecuting {
  let body: Data
  func execute(_ request: PiliLoginHTTPRequest) async throws -> Data {
    guard request.method == "POST", request.url.path == "/x/passport-tv-login/qrcode/poll",
          request.body == nil, request.routing == .currentMain else { throw PiliLoginError.invalidInput }
    return body
  }
}
private final class FixtureClock: @unchecked Sendable {
  private let lock = NSLock()
  private var date: Date
  init(_ date: Date) { self.date = date }
  func now() -> Date { lock.lock(); defer { lock.unlock() }; return date }
  func advance(_ seconds: Double) { lock.lock(); defer { lock.unlock() }; date = date.addingTimeInterval(seconds) }
}
