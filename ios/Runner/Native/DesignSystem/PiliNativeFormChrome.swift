import SwiftUI

struct PiliNativeFormChrome: ViewModifier {
  func body(content: Content) -> some View {
    content
      .scrollContentBackground(.hidden)
      .background(PiliNativeDesign.background)
      .tint(piliAccent)
  }
}
