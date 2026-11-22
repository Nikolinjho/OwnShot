//
//  QuickAccessResizeDimensions.swift
//  Snapzy
//
//  Логика полей диалога Resize Image карточки Quick Access.
//

import CoreGraphics
import Foundation

enum QuickAccessResizeUnit: String, CaseIterable {
  case pixels
  case percent
}

/// Значения полей Width/Height. При связанных пропорциях правка одного поля
/// пересчитывает другое: в эталоне Width 400 у картинки 800×400 дал Height 200.
struct QuickAccessResizeDimensions: Equatable {
  let originalPixelSize: CGSize
  private(set) var unit: QuickAccessResizeUnit = .pixels
  var isLinked = true
  private(set) var width: Double
  private(set) var height: Double

  init(originalPixelSize: CGSize) {
    self.originalPixelSize = originalPixelSize
    width = Double(originalPixelSize.width)
    height = Double(originalPixelSize.height)
  }

  private var aspectRatio: Double {
    guard originalPixelSize.height > 0 else { return 1 }
    return Double(originalPixelSize.width / originalPixelSize.height)
  }

  mutating func setWidth(_ value: Double) {
    guard value.isFinite, value > 0 else { return }
    width = value
    guard isLinked else { return }
    height = unit == .percent ? value : Self.rounded(value / aspectRatio)
  }

  mutating func setHeight(_ value: Double) {
    guard value.isFinite, value > 0 else { return }
    height = value
    guard isLinked else { return }
    width = unit == .percent ? value : Self.rounded(value * aspectRatio)
  }

  /// Смена единиц переводит текущие значения, итоговый размер не меняется.
  mutating func setUnit(_ newUnit: QuickAccessResizeUnit) {
    guard newUnit != unit else { return }
    let target = targetPixelSize
    unit = newUnit
    switch newUnit {
    case .pixels:
      width = Double(target.width)
      height = Double(target.height)
    case .percent:
      width = Self.rounded(Double(target.width / max(originalPixelSize.width, 1)) * 100, places: 2)
      height = Self.rounded(Double(target.height / max(originalPixelSize.height, 1)) * 100, places: 2)
    }
  }

  /// Итоговый размер в пикселях, не меньше 1×1.
  var targetPixelSize: CGSize {
    let pixelWidth: Double
    let pixelHeight: Double
    switch unit {
    case .pixels:
      pixelWidth = width
      pixelHeight = height
    case .percent:
      pixelWidth = Double(originalPixelSize.width) * width / 100
      pixelHeight = Double(originalPixelSize.height) * height / 100
    }
    return CGSize(width: max(1, pixelWidth.rounded()), height: max(1, pixelHeight.rounded()))
  }

  var isUnchanged: Bool {
    targetPixelSize == CGSize(width: originalPixelSize.width.rounded(), height: originalPixelSize.height.rounded())
  }

  private static func rounded(_ value: Double, places: Int = 0) -> Double {
    let factor = pow(10, Double(places))
    return (value * factor).rounded() / factor
  }
}
