//
//  QuickAccessSettingsHints.swift
//  Snapzy
//
//  Подписи и шкала настроек Quick Access, зависящие от текущих значений
//

import Foundation

enum QuickAccessSettingsHints {
  /// Подпись под Close after dragging меняется вместе с настройкой, как в эталоне.
  static func closeAfterDragging(_ enabled: Bool) -> String {
    enabled
      ? L10n.PreferencesQuickAccess.closeAfterDraggingKeepHint
      : L10n.PreferencesQuickAccess.closeAfterDraggingCloseHint
  }

  /// Подсказка Save button behavior: Option переключает на противоположный режим.
  static func saveButton(behavior: String) -> String {
    behavior == "chooseDestination"
      ? L10n.PreferencesQuickAccess.saveButtonAskHint
      : L10n.PreferencesQuickAccess.saveButtonExportHint
  }
}

enum QuickAccessOverlaySizeScale {
  /// Пять положений шкалы Overlay size (0...4 у эталона), среднее – масштаб 1.0.
  static let range: ClosedRange<Double> = 0.5...1.5
  static let step: Double = 0.25

  static var positions: [Double] {
    stride(from: range.lowerBound, through: range.upperBound, by: step).map { $0 }
  }

  /// Приводит сохранённое значение к ближайшему положению шкалы.
  static func clamp(_ value: Double) -> Double {
    let bounded = min(max(value, range.lowerBound), range.upperBound)
    return (bounded / step).rounded() * step
  }
}
