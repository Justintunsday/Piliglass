import SwiftUI

struct PiliNativeErrorView: View {
  let message: String
  let retry: () -> Void

  var body: some View {
    VStack(spacing: PiliNativeDesign.spaceM) {
      Image(systemName: "exclamationmark.triangle")
        .font(.system(.largeTitle, design: .default))
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(.secondary)
      Text(piliLocalizedDisplay(message))
        .font(PiliNativeDesign.body)
        .multilineTextAlignment(.center)
        .foregroundColor(.secondary)
        .padding(.horizontal, PiliNativeDesign.spaceL)
      Button("重试", action: retry)
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .tint(piliAccent)
    }
    .padding(PiliNativeDesign.spaceL)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(PiliNativeDesign.background)
  }
}
