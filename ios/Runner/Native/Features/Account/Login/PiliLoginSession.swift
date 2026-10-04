import Foundation

enum PiliLoginState: Sendable, Equatable {
  case idle, working, cancelled
  case qr(PiliLoginQRCode, expiresAt: Date)
  case qrWaiting(code: Int64, message: String)
  case qrExpired
  case challenge(PiliLoginChallenge)
  case phoneVerification(PiliLoginPhoneVerification)
  case phoneInfo(hiddenTelephone: String?, hiddenMail: String?, canVerifyTelephone: Bool)
  case smsSent(captchaKey: String, sentAt: Date, cooldownUntil: Date)
  case installed(PiliLoginInstallReceipt)
  case failure(code: Int64?, message: String)
}

/// Business state is separate from the eventual account UI. A generation
/// prevents stale QR/Geetest/network callbacks from replacing a newer flow.
actor PiliLoginSession {
  private let repository: any PiliLoginRepository
  private let authority: any PiliLoginAccountAuthority
  private let encryptor: any PiliLoginPasswordEncrypting
  private let clock: @Sendable () -> Date
  private let nonce: @Sendable () -> String
  private var generation = UUID()
  private var busy = false
  private var qr: (code: PiliLoginQRCode, expiresAt: Date)?
  private var sms: (key: String, sentAt: Date)?
  private var state: PiliLoginState = .idle

  init(repository: any PiliLoginRepository, authority: any PiliLoginAccountAuthority,
       encryptor: any PiliLoginPasswordEncrypting = PiliLoginRSAEncryptor(),
       clock: @escaping @Sendable () -> Date = { Date() },
       nonce: @escaping @Sendable () -> String = { PiliLoginRSAEncryptor.deviceNonce() }) {
    self.repository = repository; self.authority = authority; self.encryptor = encryptor
    self.clock = clock; self.nonce = nonce
  }

  func current() -> PiliLoginState { state }
  func cancel() { generation = UUID(); busy = false; qr = nil; sms = nil; state = .cancelled }

  func createQR() async throws -> PiliLoginState {
    let token = try begin()
    do { return try await apply(try await repository.perform(.qrCreate), token: token, method: .qr) }
    catch { return try fail(error, token: token) }
  }

  func pollQR(selection: PiliLoginInstallSelection = .preserveExisting) async throws -> PiliLoginState {
    guard let qr else { throw PiliLoginError.invalidInput }
    guard clock() < qr.expiresAt else { self.qr = nil; state = .qrExpired; return state }
    let token = try begin()
    do { return try await apply(try await repository.perform(.qrPoll(authCode: qr.code.authCode)), token: token,
                               method: .qr, selection: selection) }
    catch { return try fail(error, token: token) }
  }

  func password(username: String, password: String, challenge: PiliLoginChallengeAnswer? = nil,
                selection: PiliLoginInstallSelection = .preserveExisting) async throws -> PiliLoginState {
    guard !username.isEmpty, !password.isEmpty else { throw PiliLoginError.invalidInput }
    let token = try begin()
    do {
      let keyResult = try await repository.perform(.webKey); try verify(token)
      guard case .webKey(let key) = keyResult else { return try await accept(keyResult, token: token, method: .password) }
      let encrypted = try encryptor.encrypt(key.salt + password, publicKeyPEM: key.publicKeyPEM)
      let deviceToken = try encryptor.encrypt(nonce(), publicKeyPEM: key.publicKeyPEM)
      return try await apply(try await repository.perform(.password(username: username, encryptedPassword: encrypted,
                              encryptedDeviceToken: deviceToken, challenge: challenge)), token: token,
                             method: .password, selection: selection)
    } catch { return try fail(error, token: token) }
  }

  func sendSMS(countryID: String, telephone: String,
               challenge: PiliLoginChallengeAnswer? = nil) async throws -> PiliLoginState {
    if let sms, clock().timeIntervalSince(sms.sentAt) < 60 { throw PiliLoginError.invalidInput }
    let token = try begin()
    do {
      var result = try await repository.perform(.smsSend(countryID: countryID, telephone: telephone, challenge: challenge))
      try verify(token)
      if result == .challengeNeedsPreCapture { result = try await repository.perform(.preCapture); try verify(token) }
      return try await accept(result, token: token, method: .sms)
    } catch { return try fail(error, token: token) }
  }

  func smsLogin(countryID: String, telephone: String, code: String,
                selection: PiliLoginInstallSelection = .preserveExisting) async throws -> PiliLoginState {
    guard let sms, clock().timeIntervalSince(sms.sentAt) <= 300, !code.isEmpty else { throw PiliLoginError.invalidInput }
    let token = try begin()
    do {
      let result = try await repository.perform(.webKey); try verify(token)
      guard case .webKey(let key) = result else { return try await accept(result, token: token, method: .sms) }
      let deviceToken = try encryptor.encrypt(nonce(), publicKeyPEM: key.publicKeyPEM)
      return try await apply(try await repository.perform(.smsLogin(countryID: countryID, telephone: telephone, code: code,
                                  captchaKey: sms.key, encryptedDeviceToken: deviceToken)), token: token,
                             method: .sms, selection: selection)
    } catch { return try fail(error, token: token) }
  }

  func cookie(_ raw: String, selection: PiliLoginInstallSelection = .preserveExisting) async throws -> PiliLoginState {
    let credentials = try PiliLoginResponseDecoder.cookieCredentials(raw)
    let header = credentials.cookies.map { $0.name + "=" + $0.value }.joined(separator: "; ")
    let token = try begin()
    do { return try await apply(try await repository.perform(.cookieValidate(header)), token: token, method: .cookie, selection: selection) }
    catch { return try fail(error, token: token) }
  }

  func phoneInfo(_ verification: PiliLoginPhoneVerification) async throws -> PiliLoginState {
    let token = try begin()
    do { return try await apply(try await repository.perform(.phoneInfo(verification)), token: token, method: .password) }
    catch { return try fail(error, token: token) }
  }

  func phoneChallenge() async throws -> PiliLoginState {
    let token = try begin()
    do { return try await apply(try await repository.perform(.preCapture), token: token, method: .password) }
    catch { return try fail(error, token: token) }
  }

  func phoneSendSMS(_ verification: PiliLoginPhoneVerification,
                    answer: PiliLoginChallengeAnswer) async throws -> PiliLoginState {
    let token = try begin()
    do { return try await apply(try await repository.perform(.phoneSMSSend(verification, challenge: answer)), token: token, method: .password) }
    catch { return try fail(error, token: token) }
  }

  func phoneVerify(_ verification: PiliLoginPhoneVerification, code: String, captchaKey: String,
                   selection: PiliLoginInstallSelection = .preserveExisting) async throws -> PiliLoginState {
    let token = try begin()
    do {
      let result = try await repository.perform(.phoneSMSVerify(verification, code: code, captchaKey: captchaKey)); try verify(token)
      guard case .oauthCode(let code) = result else { return try await accept(result, token: token, method: .password) }
      return try await apply(try await repository.perform(.oauthAccessToken(code: code)), token: token, method: .password, selection: selection)
    } catch { return try fail(error, token: token) }
  }

  func challengeClosed() { generation = UUID(); busy = false; state = .idle }
  func challengeFailed() { generation = UUID(); busy = false; state = .failure(code: nil, message: "captchaLoadFailed") }

  private func begin() throws -> UUID {
    guard !busy else { throw PiliLoginError.invalidInput }
    try Task.checkCancellation(); generation = UUID(); busy = true; state = .working; return generation
  }
  private func verify(_ token: UUID) throws {
    guard token == generation else { throw PiliLoginError.staleOperation }; try Task.checkCancellation()
  }
  private func apply(_ result: PiliLoginResult, token: UUID,
                     method: PiliLoginMethod, selection: PiliLoginInstallSelection = .preserveExisting) async throws -> PiliLoginState {
    try await accept(result, token: token, method: method, selection: selection)
  }
  private func accept(_ result: PiliLoginResult, token: UUID, method: PiliLoginMethod,
                      selection: PiliLoginInstallSelection = .preserveExisting) async throws -> PiliLoginState {
    try verify(token)
    switch result {
    case .credentials(let credentials):
      // Do not replay an authority write after a lost/cancelled acknowledgement.
      let receipt = try await authority.install(credentials, method: method, selection: selection)
      guard token == generation else { throw PiliLoginError.staleOperation }
      qr = nil; sms = nil; state = .installed(receipt)
    case .qr(let code):
      let expires = clock().addingTimeInterval(180); qr = (code, expires); state = .qr(code, expiresAt: expires)
    case .qrWaiting(let code, let message): state = .qrWaiting(code: code, message: message)
    case .qrExpired: qr = nil; state = .qrExpired
    case .challenge(let challenge): state = .challenge(challenge)
    case .phoneVerification(let phone): state = .phoneVerification(phone)
    case .phoneInfo(let tel, let mail, let canVerify): state = .phoneInfo(hiddenTelephone: tel, hiddenMail: mail, canVerifyTelephone: canVerify)
    case .smsSent(let key):
      let now = clock(); sms = (key, now); state = .smsSent(captchaKey: key, sentAt: now, cooldownUntil: now.addingTimeInterval(60))
    case .failure(let code, let message): state = .failure(code: code, message: message)
    case .challengeNeedsPreCapture, .oauthCode, .webKey, .loggedOut: throw PiliLoginError.invalidResponse
    }
    busy = false; return state
  }
  private func fail(_ error: Error, token: UUID) throws -> PiliLoginState {
    guard token == generation else { throw PiliLoginError.staleOperation }
    busy = false
    if error is CancellationError { state = .cancelled; throw error }
    state = .failure(code: nil, message: "loginOperationFailed"); throw error
  }
}
