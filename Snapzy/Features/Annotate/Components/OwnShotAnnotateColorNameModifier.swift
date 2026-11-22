import AppKit
import SwiftUI

extension OwnShotAnnotateColorName {
  static func name(for color: Color) -> String {
    guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return "Color" }
    return name(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent, alpha: rgb.alphaComponent)
  }
}

private struct OwnShotAnnotateColorNameModifier: ViewModifier {
  let color: Color
  @AppStorage(OwnShotAnnotatePreferenceKeys.showColorNames) private var showNames = false

  func body(content: Content) -> some View {
    VStack(spacing: 2) {
      content
      if showNames {
        Text(OwnShotAnnotateColorName.name(for: color))
          .font(.system(size: 8))
          .lineLimit(1)
          .minimumScaleFactor(0.6)
          .foregroundStyle(.secondary)
      }
    }
    .help(showNames ? OwnShotAnnotateColorName.name(for: color) : "")
    .accessibilityLabel(showNames ? OwnShotAnnotateColorName.name(for: color) : "Color")
  }
}

extension View {
  func ownShotAnnotateColorName(_ color: Color) -> some View {
    modifier(OwnShotAnnotateColorNameModifier(color: color))
  }
}
