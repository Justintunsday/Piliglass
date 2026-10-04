import Foundation

enum PiliLoginMethod: String, Sendable, Codable { case qr, password, sms, cookie }

struct PiliLoginCookie: Sendable, Equatable, Codable {
  let name: String
  let value: String
  let domain: String
  let path: String
  let expiresEpochSeconds: Int64?
  let secure: Bool
  let httpOnly: Bool
}

/// No password, phone verification code or Geetest result is persisted here.
struct PiliLoginCredentials: Sendable, Equatable, Codable {
  let mid: Int64
  let accessToken: String?
  let refreshToken: String?
  let cookies: [PiliLoginCookie]
}

struct PiliLoginChallenge: Sendable, Equatable {
  let gt: String
  let challenge: String
  let recaptchaToken: String
}

struct PiliLoginChallengeAnswer: Sendable, Equatable {
  let challenge: String
  let validate: String
  let seccode: String
  let recaptchaToken: String
}

struct PiliLoginPhoneVerification: Sendable, Equatable {
  let url: URL
  let tmpToken: String
  let requestID: String
  let source: String
}

struct PiliLoginQRCode: Sendable, Equatable { let authCode: String; let url: URL }
struct PiliLoginWebKey: Sendable, Equatable { let salt: String; let publicKeyPEM: String }

enum PiliLoginResult: Sendable, Equatable {
  case credentials(PiliLoginCredentials)
  case qr(PiliLoginQRCode)
  case qrWaiting(code: Int64, message: String)
  case qrExpired
  case challenge(PiliLoginChallenge)
  case challengeNeedsPreCapture
  case phoneVerification(PiliLoginPhoneVerification)
  case phoneInfo(hiddenTelephone: String?, hiddenMail: String?, canVerifyTelephone: Bool)
  case smsSent(captchaKey: String)
  case oauthCode(String)
  case webKey(PiliLoginWebKey)
  case loggedOut
  case failure(code: Int64, message: String)
}

enum PiliLoginError: Error, Sendable, Equatable {
  case invalidInput, invalidResponse, invalidPublicKey, encryptionFailed
  case staleOperation, unsupportedCookieAttribute, nativeTransportNotVerified
}

struct PiliLoginAccountOwner: Sendable, Equatable, Hashable, Codable {
  let authorityEpoch: String
  let identity: PiliAccountIdentity
}

enum PiliLoginInstallSelection: Sendable, Equatable {
  /// Existing Dart login preserves purposes of an account with the same MID.
  case preserveExisting
  /// The native QR flow explicitly chooses slots; it is not the Dart default.
  case assign(Set<PiliAccountPurpose>)
}

struct PiliLoginInstallReceipt: Sendable, Equatable {
  let owner: PiliLoginAccountOwner
  let needsPurposeSelection: Bool
}

/// The production adapter remains a single Dart/Hive writer until cutover.
/// Installation/deletion owns account selection, WK cookies, profile cache,
/// history status and anonymous reset; a View must not duplicate these effects.
protocol PiliLoginAccountAuthority: Sendable {
  func install(_ credentials: PiliLoginCredentials, method: PiliLoginMethod,
               selection: PiliLoginInstallSelection) async throws -> PiliLoginInstallReceipt
  func delete(_ owners: [PiliLoginAccountOwner]) async throws
}

enum PiliLoginOperation: Sendable, Equatable {
  case qrCreate, qrPoll(authCode: String), webKey
  case password(username: String, encryptedPassword: String, encryptedDeviceToken: String,
                challenge: PiliLoginChallengeAnswer?)
  case smsSend(countryID: String, telephone: String, challenge: PiliLoginChallengeAnswer?)
  case smsLogin(countryID: String, telephone: String, code: String, captchaKey: String,
                encryptedDeviceToken: String)
  case cookieValidate(String)
  case phoneInfo(PiliLoginPhoneVerification), preCapture
  case phoneSMSSend(PiliLoginPhoneVerification, challenge: PiliLoginChallengeAnswer)
  case phoneSMSVerify(PiliLoginPhoneVerification, code: String, captchaKey: String)
  case oauthAccessToken(code: String)
  case logout(owner: PiliLoginAccountOwner, csrf: String)
}

protocol PiliLoginRepository: Sendable {
  func perform(_ operation: PiliLoginOperation) async throws -> PiliLoginResult
}

enum PiliLoginPasswordRecovery {
  static let mobile = URL(string: "https://passport.bilibili.com/h5-app/passport/login/findPassword")!
  static let desktop = URL(string: "https://passport.bilibili.com/pc/passport/findPassword")!
}
