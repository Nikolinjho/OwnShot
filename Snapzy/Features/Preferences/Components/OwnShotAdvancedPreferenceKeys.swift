import Foundation
import CoreGraphics

/// Ключи Advanced общие для интерфейса и обработчиков захвата.
enum OwnShotAdvancedPreferenceKeys {
  static let askForName = "capture.askForName"
  static let addRetinaSuffix = "screenshot.addRetinaSuffix"
  static let recognitionLanguage = "ocr.recognitionLanguage"
  static let keepLineBreaks = "ocr.keepLineBreaks"
  static let rememberAllInOneSelection = "allInOne.rememberLastSelection"
  static let pinnedRoundedCorners = "pinnedScreenshot.roundedCorners"
  static let pinnedShadow = "pinnedScreenshot.shadow"
  static let pinnedBorder = "pinnedScreenshot.border"
  /// Customize… → Use UTC time zone: даты в имени файла по UTC.
  static let fileNameUsesUTC = "fileName.useUTCTimeZone"
  /// Customize… → Remove illegal characters, по умолчанию включено.
  static let fileNameRemovesIllegalCharacters = "fileName.removeIllegalCharacters"
  /// Следующее значение токена %i (Auto-increment next number).
  static let fileNameNextAutoIncrement = "fileName.nextAutoIncrement"
}

/// Поведение настроек без зависимости от окон и глобального UserDefaults.
enum OwnShotAdvancedPreferences {
  static func initialSelection(previous: CGRect?, screenFrame: CGRect, defaults: UserDefaults = .standard) -> CGRect {
    let remembers = defaults.object(forKey: OwnShotAdvancedPreferenceKeys.rememberAllInOneSelection) as? Bool ?? true
    if remembers, let previous { return previous }
    return CGRect(x: screenFrame.midX - 320, y: screenFrame.midY - 180, width: 640, height: 360)
  }

  static func recognitionLanguage(fallback: String?, defaults: UserDefaults = .standard) -> String? {
    guard let language = defaults.string(forKey: OwnShotAdvancedPreferenceKeys.recognitionLanguage),
          language != "auto", !language.isEmpty else { return fallback }
    return language
  }

  static func keepsLineBreaks(defaults: UserDefaults) -> Bool {
    defaults.object(forKey: OwnShotAdvancedPreferenceKeys.keepLineBreaks) as? Bool ?? false
  }

  static func recognizedText(_ text: String, contentType: OCRContentType, defaults: UserDefaults = .standard) -> String {
    guard contentType != .code, !keepsLineBreaks(defaults: defaults) else { return text }
    // Границы абзацев сохраняются, мягкие переносы строк объединяются.
    return text.replacingOccurrences(of: "(?<!\\n)\\n(?!\\n)", with: " ", options: .regularExpression)
  }
}
