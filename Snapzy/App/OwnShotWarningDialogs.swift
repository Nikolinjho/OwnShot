//
//  OwnShotWarningDialogs.swift
//  Snapzy
//
//  Reset All Warning Dialogs из Advanced: возвращает все диалоги с флажками
//  «Don't ask again», «Don't warn me again» и «Don't ask for confirmation».
//  Тексты подтверждения – эталона (binary-strings.txt:9805–9806).
//

import Foundation

enum OwnShotWarningDialogs {
  /// Ключи, которые флажок диалога ставит в true. Сброс удаляет их.
  static let suppressionKeys: [String] = [
    RecordingLifecycleKeys.suppressLowDiskWarning,
    RecordingLifecycleKeys.suppressNoMicrophoneWarning,
    HistoryDeleteConfirmationPolicy.suppressKey,
    QuickAccessCloseAllConfirmation.skipConfirmationKey,
  ]

  /// Ключи «предупреждать», которые флажок ставит в false. По умолчанию они включены,
  /// поэтому сброс тоже удаляет значение.
  static let enabledByDefaultWarningKeys: [String] = [
    RecordingLifecycleKeys.warnAboutMutedMicrophone,
  ]

  static var allKeys: [String] { suppressionKeys + enabledByDefaultWarningKeys }

  /// Сбрасывает все запомненные ответы. Вставка изображения из буфера в пустом редакторе
  /// («Don't ask again» в AnnotateWindowController) снова спрашивает.
  static func resetAll(defaults: UserDefaults = .standard) {
    for key in allKeys {
      defaults.removeObject(forKey: key)
    }
    AnnotateClipboardImageBehavior.ask.persist(to: defaults)
    DiagnosticLogger.shared.log(.info, .preferences, "All warning dialogs reset", context: [
      "keys": "\(allKeys.count + 1)",
    ])
  }

  static let resetTitle = L10n.string(
    "preferences-advanced.reset-warnings.title",
    defaultValue: "All warning dialogs are now enabled.",
    comment: "Alert title after resetting all warning dialogs"
  )

  static let resetMessage = L10n.string(
    "preferences-advanced.reset-warnings.message",
    defaultValue: "All warning dialogs that can be disabled by checking \"Don't show again\" are now enabled, and will be shown the next time they are applicable.",
    comment: "Alert message after resetting all warning dialogs"
  )
}
