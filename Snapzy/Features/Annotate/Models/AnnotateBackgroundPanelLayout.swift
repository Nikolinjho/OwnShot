//
//  AnnotateBackgroundPanelLayout.swift
//  Snapzy
//
//  Размеры панели Background, целые значения слайдеров, рост окна и меню Presets
//

import CoreGraphics
import Foundation

/// Геометрия панели Background по живому AX эталона (сверка 055).
/// Сайдбар 250 pt, слева отступ 11 pt, ширина списка 227 pt.
nonisolated enum AnnotateBackgroundPanelLayout {
  static let sidebarWidth: CGFloat = 250
  static let leadingPadding: CGFloat = 11
  static let trailingPadding: CGFloat = 12
  static let contentWidth: CGFloat = 227

  /// Плитки Gradients, Wallpapers и Blurred: 43 × 43 pt, шаг 46 pt, 5 колонок.
  static let tileSize: CGFloat = 43
  static let tileColumns = 5
  static var tileSpacing: CGFloat {
    spacing(itemSize: tileSize, columns: tileColumns)
  }

  /// Кружки Plain color: 24 × 24 pt, 9 колонок, ряды вплотную (шаг 24 pt).
  static let colorSwatchSize: CGFloat = 24
  static let colorColumns = 9
  static let colorRowSpacing: CGFloat = 0
  static var colorSpacing: CGFloat {
    spacing(itemSize: colorSwatchSize, columns: colorColumns)
  }

  /// Блок слайдеров Padding…Corners (live 062): x 384…604 – ширина 220 pt
  /// (отступ 4 pt слева и 3 pt справа от списка), колонки по 100 pt через 20 pt.
  static let slidersLeadingInset: CGFloat = 4
  static let slidersTrailingInset: CGFloat = 3
  static let sliderColumnSpacing: CGFloat = 20
  /// Подпись 13 pt (строка 16 pt), до слайдера 6 pt, слайдер 14 pt, до следующей подписи 11 pt:
  /// шаг строк 47 pt.
  static let sliderLabelFontSize: CGFloat = 13
  static let sliderLabelHeight: CGFloat = 16
  static let sliderLabelSpacing: CGFloat = 6
  static let sliderRowSpacing: CGFloat = 11
  /// Числовое поле у подписи: 28 × 16 pt.
  static let sliderValueFieldWidth: CGFloat = 28

  /// Зазор между колонками фиксированного размера, чтобы ряд занял ровно ширину списка.
  static func spacing(itemSize: CGFloat, columns: Int, width: CGFloat = contentWidth) -> CGFloat {
    guard columns > 1 else { return 0 }
    return max(0, (width - itemSize * CGFloat(columns)) / CGFloat(columns - 1))
  }
}

/// Поля и слайдеры Padding, Inset, Shadow и Corners у эталона целочисленные.
nonisolated enum AnnotateBackgroundSliderValue {
  /// Округляет значение слайдера до целого в пределах диапазона.
  static func integral(_ value: CGFloat, in range: ClosedRange<CGFloat>) -> CGFloat {
    guard value.isFinite else { return range.lowerBound }
    return min(max(value.rounded(), range.lowerBound), range.upperBound)
  }

  /// Шаг стрелкой: целое значение плюс delta в пределах диапазона.
  static func stepped(_ value: CGFloat, by delta: CGFloat, in range: ClosedRange<CGFloat>) -> CGFloat {
    integral(integral(value, in: range) + delta, in: range)
  }
}

/// Эталон при открытии Background увеличил окно с 990 × 753 до 990 × 875,
/// а после закрытия панели высоту не вернул.
nonisolated enum AnnotateBackgroundWindowSizing {
  /// Высота окна, при которой панель Background видна целиком.
  static let preferredWindowHeight: CGFloat = 875

  /// Рамка окна после открытия панели. Окно только растёт: верхний край остаётся на месте,
  /// если низ уходит за экран, окно поднимается, высота не больше видимой области.
  /// nil – менять рамку не нужно.
  static func grownFrame(
    current: CGRect,
    visibleFrame: CGRect,
    preferredHeight: CGFloat = preferredWindowHeight
  ) -> CGRect? {
    let targetHeight = min(preferredHeight, visibleFrame.height)
    guard targetHeight > current.height + 0.5 else { return nil }

    var frame = current
    frame.size.height = targetHeight
    frame.origin.y = current.maxY - targetHeight
    if frame.minY < visibleFrame.minY {
      frame.origin.y = visibleFrame.minY
    }
    if frame.maxY > visibleFrame.maxY {
      frame.origin.y = visibleFrame.maxY - targetHeight
    }
    return frame
  }
}

/// Содержимое меню Presets... эталона: пользовательские пресеты, подменю Default Preset
/// (Automatically apply preset to all screenshots: … None и пресеты), разделитель, Add New Preset...
nonisolated enum AnnotateBackgroundPresetMenu {
  struct Entry: Equatable {
    /// nil – пункт None.
    let presetId: UUID?
    let title: String
    let isChecked: Bool
  }

  /// Пункты списка пресетов: отмечен выбранный пресет.
  static func presetEntries(
    presets: [(id: UUID, name: String)],
    selectedId: UUID?
  ) -> [Entry] {
    presets.map { Entry(presetId: $0.id, title: $0.name, isChecked: $0.id == selectedId) }
  }

  /// Пункты подменю Default Preset: None и пресеты, отмечен пресет по умолчанию или None.
  static func defaultPresetEntries(
    presets: [(id: UUID, name: String)],
    defaultId: UUID?,
    noneTitle: String
  ) -> [Entry] {
    let hasDefault = defaultId.map { id in presets.contains(where: { $0.id == id }) } ?? false
    var entries = [Entry(presetId: nil, title: noneTitle, isChecked: !hasDefault)]
    entries += presets.map { Entry(presetId: $0.id, title: $0.name, isChecked: $0.id == defaultId) }
    return entries
  }

  /// Имя из поля Enter preset name: пустое после обрезки пробелов – nil.
  static func normalizedName(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
