import SwiftUI

private struct PiliVideoTransitionNamespaceKey: EnvironmentKey {
  static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
  var piliVideoTransitionNamespace: Namespace.ID? {
    get { self[PiliVideoTransitionNamespaceKey.self] }
    set { self[PiliVideoTransitionNamespaceKey.self] = newValue }
  }
}

private struct PiliVideoTransitionSource: ViewModifier {
  @Environment(\.piliVideoTransitionNamespace) private var namespace
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let id: String

  func body(content: Content) -> some View {
    if #available(iOS 18.0, *), let namespace, !reduceMotion {
      content.matchedTransitionSource(id: id, in: namespace)
    } else {
      content
    }
  }
}

extension View {
  func piliVideoTransitionSource(id: String) -> some View {
    modifier(PiliVideoTransitionSource(id: id))
  }
}
