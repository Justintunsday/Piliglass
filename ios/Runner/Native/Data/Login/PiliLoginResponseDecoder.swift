import Foundation

enum PiliLoginResponseDecoder {
  static func decode(_ body: Data, operation: PiliLoginOperation) throws -> PiliLoginResult {
    guard body.count <= 2 * 1024 * 1024 else { throw PiliLoginError.invalidResponse }
    let value = try PiliBridgeValue(codecValue: JSONSerialization.jsonObject(with: body))
    guard case .dictionary(let envelope) = value, let code = integer(envelope["code"]) else {
      throw PiliLoginError.invalidResponse
    }
    let message = string(envelope["message"]) ?? string(envelope["msg"]) ?? ""
    let data = dictionary(envelope["data"])
    if case .qrPoll = operation, code != 0 {
      return code == 86038 ? .qrExpired : .qrWaiting(code: code, message: message)
    }
    if code != 0 {
      if code == -105 {
        let key: String
        switch operation {
        case .password: key = "url"
        case .smsSend: key = "recaptcha_url"
        default: return .failure(code: code, message: message)
        }
        if let url = string(data?[key]), let challenge = challengeURL(url) { return .challenge(challenge) }
        if case .smsSend = operation { return .challengeNeedsPreCapture }
      }
      return .failure(code: code, message: message)
    }
    switch operation {
    case .qrCreate:
      guard let auth = string(data?["auth_code"]), !auth.isEmpty,
            let raw = string(data?["url"]), let url = URL(string: raw), url.scheme == "https" else {
        throw PiliLoginError.invalidResponse
      }
      return .qr(.init(authCode: auth, url: url))
    case .webKey:
      guard let salt = string(data?["hash"]), let key = string(data?["key"]), !key.isEmpty else {
        throw PiliLoginError.invalidResponse
      }
      return .webKey(.init(salt: salt, publicKeyPEM: key))
    case .password:
      guard let data else { throw PiliLoginError.invalidResponse }
      if integer(data["status"]) == 2 {
        guard let raw = string(data["url"]), let phone = phoneURL(raw) else { throw PiliLoginError.invalidResponse }
        return .phoneVerification(phone)
      }
      return .credentials(try credentials(data, nestedToken: true))
    case .qrPoll:
      guard let data else { throw PiliLoginError.invalidResponse }
      // TV polling supplies token fields directly; password/SMS use token_info.
      return .credentials(try credentials(data, nestedToken: false))
    case .smsLogin, .oauthAccessToken:
      guard let data else { throw PiliLoginError.invalidResponse }
      return .credentials(try credentials(data, nestedToken: true))
    case .smsSend:
      guard let data else { throw PiliLoginError.invalidResponse }
      if string(data["recaptcha_url"]) != "" {
        if let raw = string(data["recaptcha_url"]), let challenge = challengeURL(raw) { return .challenge(challenge) }
        return .challengeNeedsPreCapture
      }
      guard let key = string(data["captcha_key"]), !key.isEmpty else { throw PiliLoginError.invalidResponse }
      return .smsSent(captchaKey: key)
    case .preCapture:
      guard let gt = string(data?["gee_gt"]), let challenge = string(data?["gee_challenge"]),
            let token = string(data?["recaptcha_token"]), !gt.isEmpty, !challenge.isEmpty, !token.isEmpty else {
        throw PiliLoginError.invalidResponse
      }
      return .challenge(.init(gt: gt, challenge: challenge, recaptchaToken: token))
    case .phoneInfo:
      guard let account = dictionary(data?["account_info"]), case .bool(let enabled)? = account["tel_verify"] else {
        throw PiliLoginError.invalidResponse
      }
      return .phoneInfo(hiddenTelephone: string(account["hide_tel"]), hiddenMail: string(account["hide_mail"]),
                        canVerifyTelephone: enabled)
    case .phoneSMSSend:
      guard let key = string(data?["captcha_key"]), !key.isEmpty else { throw PiliLoginError.invalidResponse }
      return .smsSent(captchaKey: key)
    case .phoneSMSVerify:
      guard let code = string(data?["code"]), !code.isEmpty else { throw PiliLoginError.invalidResponse }
      return .oauthCode(code)
    case .cookieValidate(let cookie):
      return .credentials(try cookieCredentials(cookie))
    case .logout: return .loggedOut
    }
  }

  static func challengeURL(_ raw: String) -> PiliLoginChallenge? {
    guard let values = parameters(raw), let gt = values["gee_gt"], let challenge = values["gee_challenge"],
          let token = values["recaptcha_token"], !gt.isEmpty, !challenge.isEmpty, !token.isEmpty else { return nil }
    return .init(gt: gt, challenge: challenge, recaptchaToken: token)
  }

  static func phoneURL(_ raw: String) -> PiliLoginPhoneVerification? {
    guard let values = parameters(raw), let url = URL(string: raw), url.host == "passport.bilibili.com",
          let token = values["tmp_token"], let request = values["request_id"], let source = values["source"],
          !token.isEmpty, !request.isEmpty, !source.isEmpty else { return nil }
    return .init(url: url, tmpToken: token, requestID: request, source: source)
  }

  /// Standard Cookie request syntax. The old controller loses '=' in values and
  /// keeps leading spaces; the new importer rejects ambiguous duplicate names.
  static func cookieCredentials(_ raw: String) throws -> PiliLoginCredentials {
    guard !raw.contains("\r"), !raw.contains("\n") else { throw PiliLoginError.invalidInput }
    var cookies: [PiliLoginCookie] = [], names = Set<String>()
    for part in raw.split(separator: ";", omittingEmptySubsequences: true) {
      let field = part.trimmingCharacters(in: .whitespaces)
      guard let equals = field.firstIndex(of: "=") else { throw PiliLoginError.invalidInput }
      let name = String(field[..<equals]), value = String(field[field.index(after: equals)...])
      guard !name.isEmpty, name.utf8.allSatisfy({ $0 > 32 && $0 < 127 && ![40,41,60,62,64,44,59,58,92,34,47,91,93,63,61,123,125].contains($0) }),
            names.insert(name).inserted else { throw PiliLoginError.invalidInput }
      cookies.append(.init(name: name, value: value, domain: "bilibili.com", path: "/",
                           expiresEpochSeconds: nil, secure: false, httpOnly: false))
    }
    return try validatedCredentials(access: nil, refresh: nil, cookies: cookies)
  }

  private static func credentials(_ data: [String: PiliBridgeValue], nestedToken: Bool) throws -> PiliLoginCredentials {
    let token = nestedToken ? dictionary(data["token_info"]) : data
    guard let token, let access = string(token["access_token"]), !access.isEmpty,
          let refresh = string(token["refresh_token"]),
          let cookieInfo = dictionary(data["cookie_info"]), case .array(let entries)? = cookieInfo["cookies"] else {
      throw PiliLoginError.invalidResponse
    }
    var cookies: [PiliLoginCookie] = []
    for entry in entries {
      guard let cookie = dictionary(entry), let name = string(cookie["name"]), !name.isEmpty,
            let value = string(cookie["value"]) else { throw PiliLoginError.invalidResponse }
      // LoginHttp's actual CookieJar factory uses parent domain and root path;
      // optional returned attributes are retained for the native sidecar.
      let domain = string(cookie["domain"]) ?? "bilibili.com"
      let path = string(cookie["path"]) ?? "/"
      guard (domain == "bilibili.com" || domain == ".bilibili.com"), path.hasPrefix("/"),
            !name.contains("\r"), !name.contains("\n"), !value.contains("\r"), !value.contains("\n") else {
        throw PiliLoginError.invalidResponse
      }
      cookies.append(.init(name: name, value: value, domain: domain, path: path,
                           expiresEpochSeconds: integer(cookie["expires"]),
                           secure: boolean(cookie["secure"]) ?? false, httpOnly: boolean(cookie["httpOnly"]) ?? false))
    }
    return try validatedCredentials(access: access, refresh: refresh, cookies: cookies)
  }

  private static func validatedCredentials(access: String?, refresh: String?, cookies: [PiliLoginCookie]) throws -> PiliLoginCredentials {
    guard !cookies.isEmpty, cookies.count <= 128,
          Set(cookies.map { $0.domain + "\u{0}" + $0.path + "\u{0}" + $0.name }).count == cookies.count,
          let id = cookies.first(where: { $0.name == "DedeUserID" && $0.path == "/" })?.value,
          let mid = Int64(id), mid > 0,
          cookies.contains(where: { $0.name == "SESSDATA" && !$0.value.isEmpty }),
          cookies.contains(where: { $0.name == "bili_jct" && !$0.value.isEmpty }) else {
      throw PiliLoginError.invalidResponse
    }
    return .init(mid: mid, accessToken: access, refreshToken: refresh, cookies: cookies)
  }

  private static func parameters(_ raw: String) -> [String: String]? {
    guard let url = URLComponents(string: raw), url.scheme == "https", url.user == nil, url.password == nil else { return nil }
    var result: [String: String] = [:]
    for item in url.queryItems ?? [] {
      guard let value = item.value, result[item.name] == nil else { return nil }
      result[item.name] = value
    }
    return result
  }
  private static func dictionary(_ value: PiliBridgeValue?) -> [String: PiliBridgeValue]? {
    guard case .dictionary(let values)? = value else { return nil }; return values
  }
  private static func integer(_ value: PiliBridgeValue?) -> Int64? {
    guard case .integer(let integer)? = value else { return nil }; return integer
  }
  private static func boolean(_ value: PiliBridgeValue?) -> Bool? {
    guard case .bool(let boolean)? = value else { return nil }; return boolean
  }
  private static func string(_ value: PiliBridgeValue?) -> String? {
    switch value { case .string(let string)?: return string; case .integer(let integer)?: return String(integer); default: return nil }
  }
}
