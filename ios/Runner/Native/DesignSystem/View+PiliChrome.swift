import SwiftUI

extension View {
  func piliPageChrome() -> some View { modifier(PiliNativePageChrome()) }
  func piliFormChrome() -> some View { modifier(PiliNativeFormChrome()) }
  func piliPanel(radius: CGFloat = PiliNativeDesign.radiusM) -> some View {
    modifier(PiliNativePanelChrome(radius: radius))
  }
}
