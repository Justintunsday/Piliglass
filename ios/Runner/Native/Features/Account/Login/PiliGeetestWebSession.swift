import Foundation
import WebKit

enum PiliGeetestResult: Sendable, Equatable {
  case success(PiliLoginChallengeAnswer), failed, closed
}

/// A native WK lifecycle adapter; presentation styling is left to the existing
/// account feature. A weak handler avoids WKUserContentController retaining its
/// owner. One challenge resolves once, including error/close/cancellation.
@MainActor
final class PiliGeetestWebSession {
  private let nonce = UUID().uuidString
  private let challenge: PiliLoginChallenge
  private var webView: WKWebView?
  private var waiter: CheckedContinuation<PiliGeetestResult, Never>?
  private var result: PiliGeetestResult?
  private var waiting = false

  init(challenge: PiliLoginChallenge) { self.challenge = challenge }

  func makeWebView() throws -> WKWebView {
    guard webView == nil, !challenge.gt.isEmpty, !challenge.challenge.isEmpty,
          !challenge.recaptchaToken.isEmpty else { throw PiliLoginError.invalidInput }
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    configuration.userContentController.add(PiliGeetestWeakHandler(owner: self), name: "piliGeetest")
    let view = WKWebView(frame: .zero, configuration: configuration)
    view.allowsLinkPreview = false
    view.loadHTMLString(try html(), baseURL: URL(string: "https://api.geetest.com"))
    webView = view
    return view
  }

  func value() async -> PiliGeetestResult {
    if let result { return result }
    guard !waiting else { return .failed }
    waiting = true
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        if let result { continuation.resume(returning: result) }
        else if Task.isCancelled { finish(.closed); continuation.resume(returning: .closed) }
        else { waiter = continuation }
      }
    } onCancel: { Task { @MainActor [weak self] in self?.finish(.closed) } }
  }

  func close() { finish(.closed) }

  fileprivate func receive(_ message: WKScriptMessage) {
    guard result == nil, message.frameInfo.isMainFrame,
          let body = message.body as? [String: Any], body["nonce"] as? String == nonce,
          let event = body["event"] as? String else { return }
    switch event {
    case "success":
      guard let payload = body["value"] as? [String: Any],
            let validate = payload["geetest_validate"] as? String, !validate.isEmpty, validate.count <= 4096,
            let seccode = payload["geetest_seccode"] as? String, !seccode.isEmpty, seccode.count <= 4096,
            let challenge = payload["geetest_challenge"] as? String, !challenge.isEmpty, challenge.count <= 4096 else {
        finish(.failed); return
      }
      finish(.success(.init(challenge: challenge, validate: validate, seccode: seccode,
                            recaptchaToken: self.challenge.recaptchaToken)))
    case "error": finish(.failed)
    case "close": finish(.closed)
    default: break
    }
  }

  private func finish(_ value: PiliGeetestResult) {
    guard result == nil else { return }
    result = value
    webView?.stopLoading()
    webView?.configuration.userContentController.removeScriptMessageHandler(forName: "piliGeetest")
    webView = nil
    let pending = waiter; waiter = nil; pending?.resume(returning: value)
  }

  private func html() throws -> String {
    func literal(_ string: String) throws -> String {
      String(decoding: try JSONEncoder().encode(string), as: UTF8.self)
        .replacingOccurrences(of: "<", with: "\\u003c").replacingOccurrences(of: ">", with: "\\u003e")
        .replacingOccurrences(of: "&", with: "\\u0026")
    }
    let gt = try literal(challenge.gt), code = try literal(challenge.challenge), nonce = try literal(nonce)
    let encodedGT = PiliNativeSigner.encodeComponent(challenge.gt)
    return """
      <!DOCTYPE html><html><head><meta name="viewport" content="width=device-width, initial-scale=1"></head><body>
      <script>
      let config,loaded,instance;
      const R=(event,value)=>window.webkit.messageHandlers.piliGeetest.postMessage({nonce:\(nonce),event,value});
      const T=()=>{if(config&&loaded&&!instance){instance=Geetest(config).onSuccess(()=>R('success',instance.getValidate())).onError(()=>R('error',null)).onClose(()=>R('close',null));instance.onReady(()=>instance.verify())}};
      const piliGeetestConfig=(d)=>{if(!d||d.status!=='success'){R('error',null);return};config=Object.assign({gt:\(gt),challenge:\(code),offline:false,new_captcha:true,product:'bind',width:'100%',https:true,protocol:'https://'},d.data);T()};
      </script>
      <script src="https://static.geetest.com/static/js/fullpage.0.0.0.js" onload="loaded=true;T()" onerror="R('error',null)"></script>
      <script src="https://api.geetest.com/gettype.php?gt=\(encodedGT)&amp;callback=piliGeetestConfig" onerror="R('error',null)"></script>
      </body></html>
      """
  }
}

@MainActor
private final class PiliGeetestWeakHandler: NSObject, WKScriptMessageHandler {
  weak var owner: PiliGeetestWebSession?
  init(owner: PiliGeetestWebSession) { self.owner = owner }
  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    owner?.receive(message)
  }
}
