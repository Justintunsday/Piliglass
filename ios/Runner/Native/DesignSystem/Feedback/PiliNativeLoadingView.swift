import SwiftUI

struct PiliNativeLoadingView: View {
  let title: String

  var body: some View {
    VStack(spacing: PiliNativeDesign.spaceM) {
      ProgressView()
        .controlSize(.large)
        .tint(piliAccent)
      Text(piliLocalizedDisplay(title))
        .font(PiliNativeDesign.body)
        .foregroundStyle(.secondary)
    }
    .padding(PiliNativeDesign.spaceL)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(PiliNativeDesign.background)
  }
}
