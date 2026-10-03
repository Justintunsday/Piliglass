import SwiftUI
import UIKit

// Bilibili pink (#FB7299), shared by native navigation and account controls.
let piliAccent = Color(red: 251.0 / 255, green: 114.0 / 255, blue: 153.0 / 255)
let piliProfileAccent = piliAccent

// System surfaces and text styles keep every native destination consistent
// with iOS while the accent preserves PiliGlass's identity.
enum PiliNativeDesign {
  static let spaceXS: CGFloat = 4
  static let spaceS: CGFloat = 8
  static let spaceM: CGFloat = 16
  static let spaceL: CGFloat = 24
  static let spaceXL: CGFloat = 32

  static let radiusS: CGFloat = 8
  static let radiusM: CGFloat = 14
  static let radiusL: CGFloat = 18
  static let touchTarget: CGFloat = 44
  static let readableWidth: CGFloat = 960
  static let focusedWidth: CGFloat = 720

  static let background = Color(uiColor: .systemGroupedBackground)
  static let surface = Color(uiColor: .secondarySystemFill)
  static let elevatedSurface = Color(uiColor: .secondarySystemGroupedBackground)
  static let subtleFill = Color(uiColor: .tertiarySystemFill)
  static let divider = Color(uiColor: .separator).opacity(0.5)
  static let accentText = Color(uiColor: UIColor { traits in
    traits.userInterfaceStyle == .dark
      ? UIColor(red: 255 / 255, green: 151 / 255, blue: 178 / 255, alpha: 1)
      : UIColor(red: 165 / 255, green: 43 / 255, blue: 81 / 255, alpha: 1)
  })

  static let display = Font.system(.largeTitle, design: .default).weight(.bold)
  static let heading = Font.system(.title2, design: .default).weight(.semibold)
  static let subheading = Font.system(.headline, design: .default)
  static let body = Font.system(.body, design: .default)
  static let caption = Font.system(.caption, design: .default)
}
