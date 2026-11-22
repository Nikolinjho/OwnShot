//
//  KeystrokeOverlayConfiguration.swift
//  Snapzy
//
//  Configuration for the keystroke overlay badge.
//  Reads persisted values from UserDefaults with sensible defaults.
//

import Foundation

/// Position of the keystroke badge relative to the recording area
/// Порядок объявления задаёт порядок меню, как у эталона: сначала верхний ряд.
enum KeystrokeOverlayPosition: String, CaseIterable, Identifiable {
  case topLeft = "topLeft"
  case topCenter = "topCenter"
  case topRight = "topRight"
  case bottomLeft = "bottomLeft"
  case bottomCenter = "bottomCenter"
  case bottomRight = "bottomRight"

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .bottomCenter: return L10n.KeystrokePosition.bottomCenter
    case .bottomLeft: return L10n.KeystrokePosition.bottomLeft
    case .bottomRight: return L10n.KeystrokePosition.bottomRight
    case .topCenter: return L10n.KeystrokePosition.topCenter
    case .topLeft: return L10n.KeystrokePosition.topLeft
    case .topRight: return L10n.KeystrokePosition.topRight
    }
  }

  /// Подпись в меню эталона, через дефис: Bottom-Center.
  var hyphenatedTitle: String {
    switch self {
    case .topLeft: return L10n.RecordingParity.topLeft
    case .topCenter: return L10n.RecordingParity.topCenter
    case .topRight: return L10n.RecordingParity.topRight
    case .bottomLeft: return L10n.RecordingParity.bottomLeft
    case .bottomCenter: return L10n.RecordingParity.bottomCenter
    case .bottomRight: return L10n.RecordingParity.bottomRight
    }
  }
}

struct KeystrokeOverlayConfiguration {

  /// Font size for the keystroke text
  let fontSize: CGFloat

  /// Position of the badge within the recording area
  let position: KeystrokeOverlayPosition

  /// How long the badge remains visible before fading (seconds)
  let displayDuration: Double

  /// Distance from the nearest edge (px)
  let edgeOffset: CGFloat

  /// Тёмный или светлый бейдж (Appearance в эталоне)
  let appearance: KeystrokeOverlayAppearance

  /// Все клавиши или только сочетания с модификаторами (Keys в эталоне)
  let keysMode: KeystrokeOverlayKeysMode

  /// Размытие фона под бейджем (Blur background в эталоне)
  let blurBackground: Bool

  // MARK: - Defaults

  static let defaultFontSize: CGFloat = 16
  static let defaultPosition: KeystrokeOverlayPosition = .bottomCenter
  static let defaultDisplayDuration: Double = 1.5
  static let defaultEdgeOffset: CGFloat = 40

  // MARK: - Init from UserDefaults

  init(defaults: UserDefaults = .standard) {
    let ud = defaults

    // Кегль считается из шкалы Size эталона. Без неё действует старый кегль.
    if ud.object(forKey: RecordingOverlayPreferenceKeys.keystrokeSize) != nil {
      self.fontSize = CGFloat(RecordingOverlayOptions.keystrokeFontSize(
        forSize: RecordingOverlayOptions.keystrokeSize(defaults: ud)))
    } else {
      let size = ud.object(forKey: PreferencesKeys.keystrokeFontSize) as? CGFloat
      self.fontSize = size ?? Self.defaultFontSize
    }
    self.appearance = RecordingOverlayOptions.keystrokeAppearance(defaults: ud)
    self.keysMode = RecordingOverlayOptions.keystrokeKeysMode(defaults: ud)
    self.blurBackground = RecordingOverlayOptions.keystrokeBlur(defaults: ud)

    if let raw = ud.string(forKey: PreferencesKeys.keystrokePosition),
       let pos = KeystrokeOverlayPosition(rawValue: raw) {
      self.position = pos
    } else {
      self.position = Self.defaultPosition
    }

    self.displayDuration = ud.object(forKey: PreferencesKeys.keystrokeDisplayDuration) as? Double
      ?? Self.defaultDisplayDuration

    self.edgeOffset = Self.defaultEdgeOffset
  }
}
