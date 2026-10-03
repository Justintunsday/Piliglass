import SwiftUI

struct PiliNativePanelChrome: ViewModifier {
  var radius: CGFloat = PiliNativeDesign.radiusM

  func body(content: Content) -> some View {
    content
      .background(PiliNativeDesign.elevatedSurface)
      .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
  }
}
