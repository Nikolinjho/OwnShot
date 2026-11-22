//
//  RecordingOverlayOptions.swift
//  Snapzy
//
//  Параметры подсветки кликов и показа клавиш в составе эталона:
//  именованные цвета, стиль, анимация, оформление и фильтр клавиш.
//

import AppKit
import Foundation

nonisolated enum RecordingOverlayPreferenceKeys {
  static let clickColor = "ownshot.recording.click.color"
  static let clickStyle = "ownshot.recording.click.style"
  static let clickAnimate = "ownshot.recording.click.animate"
  static let keystrokeSize = "ownshot.recording.keystroke.size"
  static let keystrokeAppearance = "ownshot.recording.keystroke.appearance"
  static let keystrokeKeys = "ownshot.recording.keystroke.keys"
  static let keystrokeBlur = "ownshot.recording.keystroke.blur"
}

/// Цвет подсветки кликов. Порядок совпадает с меню эталона.
nonisolated enum RecordingClickColor: String, CaseIterable, Identifiable {
  case system, blue, purple, pink, red, orange, yellow, green, gray

  var id: String { rawValue }

  var title: String {
    switch self {
    case .system: return L10n.RecordingParity.systemAccentColor
    case .blue: return L10n.RecordingParity.blue
    case .purple: return L10n.RecordingParity.purple
    case .pink: return L10n.RecordingParity.pink
    case .red: return L10n.RecordingParity.red
    case .orange: return L10n.RecordingParity.orange
    case .yellow: return L10n.RecordingParity.yellow
    case .green: return L10n.RecordingParity.green
    case .gray: return L10n.RecordingParity.gray
    }
  }

  var nsColor: NSColor {
    switch self {
    case .system: return .controlAccentColor
    case .blue: return .systemBlue
    case .purple: return .systemPurple
    case .pink: return .systemPink
    case .red: return .systemRed
    case .orange: return .systemOrange
    case .yellow: return .systemYellow
    case .green: return .systemGreen
    case .gray: return .systemGray
    }
  }
}

nonisolated enum RecordingClickStyle: String, CaseIterable, Identifiable {
  case outline, filled

  var id: String { rawValue }

  var title: String {
    self == .outline ? L10n.RecordingParity.outline : L10n.RecordingParity.filled
  }
}

nonisolated enum KeystrokeOverlayAppearance: String, CaseIterable, Identifiable {
  case dark, light

  var id: String { rawValue }

  var title: String {
    self == .dark ? L10n.RecordingParity.dark : L10n.RecordingParity.light
  }
}

nonisolated enum KeystrokeOverlayKeysMode: String, CaseIterable, Identifiable {
  case all, commandOnly

  var id: String { rawValue }

  var title: String {
    self == .all ? L10n.RecordingParity.showAllKeys : L10n.RecordingParity.showOnlyCommandKeys
  }
}

nonisolated enum RecordingOverlayOptions {
  /// Шкала Size у кликов в эталоне: 25…75, значение по умолчанию 50.
  static let clickSizeRange: ClosedRange<Double> = 25...75
  /// Шкала Size у клавиш в эталоне: 18…72 с семью делениями, по умолчанию 45.
  static let keystrokeSizeRange: ClosedRange<Double> = 18...72
  static let defaultKeystrokeSize: Double = 45
  /// Кегль, который отвечает краям шкалы Size у клавиш.
  static let keystrokeFontRange: ClosedRange<Double> = 12...36

  static func clampedClickSize(_ value: Double) -> Double {
    guard value.isFinite else { return 50 }
    return min(clickSizeRange.upperBound, max(clickSizeRange.lowerBound, value))
  }

  static func clampedKeystrokeSize(_ value: Double) -> Double {
    guard value.isFinite else { return defaultKeystrokeSize }
    return min(keystrokeSizeRange.upperBound, max(keystrokeSizeRange.lowerBound, value))
  }

  /// Переводит условную шкалу Size в кегль бейджа линейно.
  static func keystrokeFontSize(forSize size: Double) -> Double {
    let clamped = clampedKeystrokeSize(size)
    let progress = (clamped - keystrokeSizeRange.lowerBound)
      / (keystrokeSizeRange.upperBound - keystrokeSizeRange.lowerBound)
    return keystrokeFontRange.lowerBound + progress * (keystrokeFontRange.upperBound - keystrokeFontRange.lowerBound)
  }

  /// Обратный перевод: старый сохранённый кегль в шкалу Size.
  static func keystrokeSize(forFontSize fontSize: Double) -> Double {
    guard fontSize.isFinite else { return defaultKeystrokeSize }
    let font = min(keystrokeFontRange.upperBound, max(keystrokeFontRange.lowerBound, fontSize))
    let progress = (font - keystrokeFontRange.lowerBound)
      / (keystrokeFontRange.upperBound - keystrokeFontRange.lowerBound)
    return keystrokeSizeRange.lowerBound + progress * (keystrokeSizeRange.upperBound - keystrokeSizeRange.lowerBound)
  }

  // MARK: - Чтение сохранённых значений

  /// Именованный цвет. nil – пользователь раньше выбрал произвольный цвет, его сохраняем.
  static func clickColor(defaults: UserDefaults = .standard) -> RecordingClickColor? {
    if let raw = defaults.string(forKey: RecordingOverlayPreferenceKeys.clickColor),
       let color = RecordingClickColor(rawValue: raw) {
      return color
    }
    return defaults.data(forKey: PreferencesKeys.mouseHighlightColor) == nil ? .system : nil
  }

  static func clickStyle(defaults: UserDefaults = .standard) -> RecordingClickStyle {
    defaults.string(forKey: RecordingOverlayPreferenceKeys.clickStyle).flatMap(RecordingClickStyle.init) ?? .outline
  }

  static func clickAnimate(defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: RecordingOverlayPreferenceKeys.clickAnimate) as? Bool ?? true
  }

  /// Размер клавиш по шкале эталона. Без новой настройки берётся старый кегль.
  static func keystrokeSize(defaults: UserDefaults = .standard) -> Double {
    if let size = defaults.object(forKey: RecordingOverlayPreferenceKeys.keystrokeSize) as? Double {
      return clampedKeystrokeSize(size)
    }
    if let font = defaults.object(forKey: PreferencesKeys.keystrokeFontSize) as? Double {
      return keystrokeSize(forFontSize: font)
    }
    return defaultKeystrokeSize
  }

  static func keystrokeAppearance(defaults: UserDefaults = .standard) -> KeystrokeOverlayAppearance {
    defaults.string(forKey: RecordingOverlayPreferenceKeys.keystrokeAppearance)
      .flatMap(KeystrokeOverlayAppearance.init) ?? .dark
  }

  static func keystrokeKeysMode(defaults: UserDefaults = .standard) -> KeystrokeOverlayKeysMode {
    defaults.string(forKey: RecordingOverlayPreferenceKeys.keystrokeKeys)
      .flatMap(KeystrokeOverlayKeysMode.init) ?? .commandOnly
  }

  static func keystrokeBlur(defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: RecordingOverlayPreferenceKeys.keystrokeBlur) as? Bool ?? true
  }
}
