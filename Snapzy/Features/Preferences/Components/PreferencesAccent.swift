//
//  PreferencesAccent.swift
//  Snapzy
//
//  Акцент окна настроек: красный эталона зависит от темы и окрашивает только тумблеры.
//

import AppKit
import SwiftUI

enum PreferencesAccent {
  /// Включённый тумблер эталона: #D9373C в светлой теме, #FF5257 в тёмной.
  static let lightHex: UInt32 = 0xD9373C
  static let darkHex: UInt32 = 0xFF5257

  static func hex(isDark: Bool) -> UInt32 {
    isDark ? darkHex : lightHex
  }

  static func hex(for appearance: NSAppearance) -> UInt32 {
    let match = appearance.bestMatch(from: [.aqua, .darkAqua, .vibrantDark, .vibrantLight])
    return hex(isDark: match == .darkAqua || match == .vibrantDark)
  }

  static let nsColor = NSColor(name: NSColor.Name("OwnShotPreferencesAccent")) { appearance in
    makeNSColor(hex(for: appearance))
  }

  static let color = Color(nsColor: nsColor)

  private static func makeNSColor(_ rgb: UInt32) -> NSColor {
    NSColor(
      srgbRed: CGFloat((rgb >> 16) & 255) / 255,
      green: CGFloat((rgb >> 8) & 255) / 255,
      blue: CGFloat(rgb & 255) / 255,
      alpha: 1
    )
  }
}

/// Сохраняет текущий стиль тумблера и красит его акцентом. Popup и кнопки остаются
/// системными, как NSPopUpButton и NSButton эталона.
struct PreferencesAccentToggleStyle: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View {
    Toggle(configuration).tint(PreferencesAccent.color)
  }
}
