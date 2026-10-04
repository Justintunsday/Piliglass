import CryptoKit
import Foundation

struct PiliLoginEnvironment: Sendable {
  let buvid: String
  let deviceID: String
  let epochMilliseconds: Int64
  let appKey: String
  let appSecret: String
  var signingEpochSeconds: Int64? = nil
  static let defaultAppKey = "dfca71928277209b"
  static let defaultAppSecret = "b5475a8825547a4fc26c7d518eaaa02e"
  static let userAgent = "Mozilla/5.0 BiliDroid/2.0.1 (bbcallen@gmail.com) os/android model/android_hd mobi_app/android_hd build/2001100 channel/master innerVer/2001100 osVer/15 network/2"
  static let statistics = "{\"appId\":5,\"platform\":3,\"version\":\"2.0.1\",\"abtest\":\"\"}"
}

enum PiliLoginAccountRouting: Sendable, Equatable {
  case currentMain, anonymous, explicit(PiliLoginAccountOwner)
}

/// Transport must apply account ownership and Cookie finalization before API
/// decoding. This descriptor cannot authorize requests through a trending lease.
struct PiliLoginHTTPRequest: Sendable, Equatable {
  let method: String
  let url: URL
  let headers: [String: String]
  let body: Data?
  let routing: PiliLoginAccountRouting
}

protocol PiliLoginHTTPExecuting: Sendable {
  func execute(_ request: PiliLoginHTTPRequest) async throws -> Data
}

enum PiliLoginRequestBuilder {
  static func build(_ operation: PiliLoginOperation,
                    environment: PiliLoginEnvironment) throws -> PiliLoginHTTPRequest {
    let env = environment
    guard !env.buvid.isEmpty, !env.deviceID.isEmpty, env.epochMilliseconds >= 0 else {
      throw PiliLoginError.invalidInput
    }
    var path = "", method = "POST", signed = true, query = false, appHeaders = false
    var fields: [PiliSigningField] = []
    var routing = PiliLoginAccountRouting.currentMain
    var headers: [String: String] = [:]
    func field(_ key: String, _ value: String) { fields.append(.init(key: key, value: .string(value))) }
    func challenge(_ answer: PiliLoginChallengeAnswer?) {
      guard let answer else { return }
      field("gee_challenge", answer.challenge); field("gee_seccode", answer.seccode)
      field("gee_validate", answer.validate); field("recaptcha_token", answer.recaptchaToken)
    }
    func common() {
      field("build", "2001100"); field("buvid", env.buvid); field("c_locale", "zh_CN")
      field("channel", "master"); field("disable_rcmd", "0"); field("local_id", env.buvid)
      field("mobi_app", "android_hd"); field("platform", "android"); field("s_locale", "zh_CN")
      field("statistics", PiliLoginEnvironment.statistics)
    }
    func device(_ encryptedToken: String) {
      field("bili_local_id", env.deviceID); field("device", "phone"); field("device_id", env.deviceID)
      field("device_name", "vivo"); field("device_platform", "Android14vivo")
      field("dt", PiliNativeSigner.encodeComponent(encryptedToken))
    }
    switch operation {
    case .qrCreate:
      path = "/x/passport-tv-login/qrcode/auth_code"; query = true
      field("local_id", "0"); field("platform", "android"); field("mobi_app", "android_hd")
    case .qrPoll(let authCode):
      guard !authCode.isEmpty else { throw PiliLoginError.invalidInput }
      path = "/x/passport-tv-login/qrcode/poll"; query = true
      field("auth_code", authCode); field("local_id", "0")
    case .webKey:
      path = "/x/passport-login/web/key"; method = "GET"; query = true; signed = false
    case .password(let username, let encryptedPassword, let token, let answer):
      guard !username.isEmpty, !encryptedPassword.isEmpty, !token.isEmpty else { throw PiliLoginError.invalidInput }
      path = "/x/passport-login/oauth2/login"; appHeaders = true
      common(); device(token); field("username", username); field("password", encryptedPassword)
      field("permission", "ALL"); field("from_pv", "main.homepage.avatar-nologin.all.click")
      field("from_url", PiliNativeSigner.encodeComponent("bilibili://pegasus/promo")); challenge(answer)
    case .smsSend(let country, let telephone, let answer):
      guard !country.isEmpty, !telephone.isEmpty else { throw PiliLoginError.invalidInput }
      path = "/x/passport-login/sms/send"; appHeaders = true
      common(); field("cid", country); field("tel", telephone); challenge(answer)
      let session = Insecure.MD5.hash(data: Data((env.buvid + String(env.epochMilliseconds)).utf8))
        .map { String(format: "%02x", $0) }.joined()
      field("login_session_id", session)
    case .smsLogin(let country, let telephone, let code, let key, let token):
      guard !country.isEmpty, !telephone.isEmpty, !code.isEmpty, !key.isEmpty, !token.isEmpty else {
        throw PiliLoginError.invalidInput
      }
      path = "/x/passport-login/login/sms"; appHeaders = true
      common(); device(token); field("cid", country); field("tel", telephone); field("code", code)
      field("captcha_key", key); field("from_pv", "main.my-information.my-login.0.click")
      field("from_url", PiliNativeSigner.encodeComponent("bilibili://user_center/mine"))
    case .cookieValidate(let cookie):
      guard !cookie.isEmpty, !cookie.contains("\r"), !cookie.contains("\n") else { throw PiliLoginError.invalidInput }
      path = "/x/member/web/account"; method = "GET"; signed = false; query = true; routing = .anonymous
      headers["cookie"] = cookie
    case .phoneInfo(let info):
      path = "/x/safecenter/user/info"; method = "GET"; signed = false; query = true
      field("tmp_code", info.tmpToken)
    case .preCapture:
      path = "/x/safecenter/captcha/pre"; signed = false
    case .phoneSMSSend(let info, let answer):
      path = "/x/safecenter/common/sms/send"
      field("disable_rcmd", "0"); field("sms_type", "loginTelCheck"); field("tmp_code", info.tmpToken)
      challenge(answer); headers["Referer"] = info.url.absoluteString
    case .phoneSMSVerify(let info, let code, let key):
      guard !code.isEmpty, !key.isEmpty else { throw PiliLoginError.invalidInput }
      path = "/x/safecenter/login/tel/verify"
      field("type", "loginTelCheck"); field("code", code); field("tmp_code", info.tmpToken)
      field("request_id", info.requestID); field("source", info.source); field("captcha_key", key)
      headers["Referer"] = info.url.absoluteString
    case .oauthAccessToken(let code):
      guard !code.isEmpty else { throw PiliLoginError.invalidInput }
      path = "/x/passport-login/oauth2/access_token"; appHeaders = true
      field("build", "2001100"); field("buvid", env.buvid); field("code", code)
      field("disable_rcmd", "0"); field("grant_type", "authorization_code"); field("local_id", env.buvid)
      field("mobi_app", "android_hd"); field("platform", "android")
    case .logout(let owner, let csrf):
      guard UUID(uuidString: owner.authorityEpoch) != nil, UUID(uuidString: owner.identity.ownerToken) != nil,
            owner.identity.generation > 0, !csrf.isEmpty else { throw PiliLoginError.invalidInput }
      path = "/login/exit/v2"; signed = false; routing = .explicit(owner)
      field("biliCSRF", csrf)
    }
    if signed {
      fields = try PiliNativeSigner.app(fields: fields, appKey: env.appKey, appSecret: env.appSecret,
                                       epochSeconds: env.signingEpochSeconds ?? env.epochMilliseconds / 1000).fields
    }
    let host = path == "/x/member/web/account" ? "api.bilibili.com" : "passport.bilibili.com"
    let encoded = try formQuery(fields)
    guard let url = URL(string: "https://" + host + path + (query && !encoded.isEmpty ? "?" + encoded : "")) else {
      throw PiliLoginError.invalidInput
    }
    if appHeaders {
      headers.merge(["buvid": env.buvid, "env": "prod", "app-key": "android_hd",
                     "user-agent": PiliLoginEnvironment.userAgent,
                     "x-bili-trace-id": "11111111111111111111111111111111:1111111111111111:0:0",
                     "x-bili-aurora-eid": "", "x-bili-aurora-zone": "", "bili-http-engine": "cronet"]) { _, value in value }
    }
    let body = method == "POST" && !query && !fields.isEmpty ? Data(encoded.utf8) : nil
    if body != nil { headers["content-type"] = "application/x-www-form-urlencoded" }
    return PiliLoginHTTPRequest(method: method, url: url, headers: headers, body: body, routing: routing)
  }

  /// Dio's form transformer uses Uri.encodeQueryComponent (space becomes +).
  /// Insertion order is retained; this is deliberately separate from AppSign.
  static func formQuery(_ fields: [PiliSigningField]) throws -> String {
    try fields.map { field in
      guard case .string(let value) = field.value else { throw PiliLoginError.invalidInput }
      return queryComponent(field.key) + "=" + queryComponent(value)
    }.joined(separator: "&")
  }

  private static func queryComponent(_ value: String) -> String {
    let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8)
    let hex = Array("0123456789ABCDEF".utf8)
    var result: [UInt8] = []
    for byte in value.utf8 {
      if allowed.contains(byte) { result.append(byte) }
      else if byte == 32 { result.append(43) }
      else { result.append(contentsOf: [37, hex[Int(byte >> 4)], hex[Int(byte & 15)]]) }
    }
    return String(decoding: result, as: UTF8.self)
  }
}
