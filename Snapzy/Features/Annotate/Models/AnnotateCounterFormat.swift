import CoreGraphics
import Foundation

/// Формат подписи счётчика. Набор и подписи пунктов меню повторяют CleanShot X 5.0.1.
nonisolated enum CounterNumberFormat: String, CaseIterable, Identifiable, Equatable, Codable {
  case decimal
  case upperAlpha
  case upperRoman
  case lowerAlpha

  var id: String { rawValue }

  /// Подпись пункта меню Counter.
  var menuTitle: String {
    switch self {
    case .decimal: "1, 2, 3, 4 ..."
    case .upperAlpha: "A, B, C, D ..."
    case .upperRoman: "I, II, III, IV ..."
    case .lowerAlpha: "a, b, c, d ..."
    }
  }

  /// Текст внутри кружка. Значения, которые формат не выражает (0 у букв и римских,
  /// больше 3999 у римских), остаются арабскими, чтобы номер не терялся.
  func label(for value: Int) -> String {
    switch self {
    case .decimal:
      return "\(value)"
    case .upperAlpha:
      return Self.alphabetic(value) ?? "\(value)"
    case .lowerAlpha:
      return Self.alphabetic(value)?.lowercased() ?? "\(value)"
    case .upperRoman:
      return Self.roman(value) ?? "\(value)"
    }
  }

  /// Биективная запись по основанию 26: 1 → A, 26 → Z, 27 → AA.
  private static func alphabetic(_ value: Int) -> String? {
    guard value > 0 else { return nil }
    var remainder = value
    var scalars: [Character] = []
    while remainder > 0 {
      remainder -= 1
      scalars.append(Character(UnicodeScalar(UInt8(65 + remainder % 26))))
      remainder /= 26
    }
    return String(scalars.reversed())
  }

  private static func roman(_ value: Int) -> String? {
    guard (1...3999).contains(value) else { return nil }
    let table: [(Int, String)] = [
      (1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"),
      (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I"),
    ]
    var remainder = value
    var result = ""
    for (number, symbol) in table {
      while remainder >= number {
        result += symbol
        remainder -= number
      }
    }
    return result
  }
}

/// Настройки меню Counter: Starting number и подменю Size.
nonisolated enum AnnotateCounterSettings {
  static let startingNumberRange: ClosedRange<Int> = 0 ... 9999
  static let defaultStartingNumber = 1
  /// Пункты подменю Size в CleanShot X. Значение – кегль цифры в кружке.
  static let sizePoints: [Int] = [11, 14, 20, 24, 31, 45]

  static func clampedStartingNumber(_ value: Int) -> Int {
    min(max(value, startingNumberRange.lowerBound), startingNumberRange.upperBound)
  }

  /// Поле Starting number эталона пропускает только цифры: минус и точка выбрасываются
  /// («-1» → «1», «1.5» → «15»), буквы не вводятся (ANN-502).
  static func sanitizedStartingNumberInput(_ text: String) -> String {
    String(text.filter { $0.isASCII && $0.isNumber })
  }

  /// Значение набранного текста. Пустое поле – nil: прежнее число остаётся.
  /// Длинное число не обнуляется, а прижимается к 9999.
  static func startingNumber(fromInput text: String) -> Int? {
    let digits = sanitizedStartingNumberInput(text)
    guard !digits.isEmpty else { return nil }
    guard let value = Int(digits) else { return startingNumberRange.upperBound }
    return clampedStartingNumber(value)
  }

  /// Рендерер рисует цифру кеглем в половину диаметра, поэтому диаметр = 2 × кегль.
  static func controlValue(forSize points: Int) -> CGFloat {
    AnnotationProperties.controlValue(forCounterDiameter: CGFloat(points) * 2)
  }

  /// Пункт подменю Size для текущего значения ползунка, nil – размер вне списка.
  static func size(forControlValue controlValue: CGFloat) -> Int? {
    let points = AnnotationProperties.counterDiameter(for: controlValue) / 2
    return sizePoints.first { abs(CGFloat($0) - points) < 0.01 }
  }
}
