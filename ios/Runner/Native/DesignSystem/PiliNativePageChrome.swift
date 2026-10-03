import SwiftUI

struct PiliNativePageChrome: ViewModifier {
  func body(content: Content) -> some View {
    content
      .tint(piliAccent)
      .background(PiliNativeDesign.background.ignoresSafeArea())
  }
}
