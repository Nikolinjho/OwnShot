//
//  AnnotateToolSizeShortcut.swift
//  Snapzy
//
//  Шаг размера инструмента для команд Increase/Decrease Tool Size (= и - по умолчанию).
//

import AppKit
import SwiftUI

extension AnnotateState {
  /// Меняет толщину выделенных объектов шагом по пунктам меню Thickness эталона
  /// (1 → 3 → 7 → 10 → 15 → 25 и обратно). Без выделения эталон толщину
  /// инструмента не трогает и не пищит (ANN-351/352), поэтому команда молчит.
  /// Знак `delta` задаёт направление. Использует ту же привязку, что и ползунок
  /// в панели свойств, поэтому undo работает так же.
  func adjustQuickStrokeWidth(by delta: CGFloat) {
    guard delta != 0, hasImage, hasSelectedAnnotations else { return }
    guard quickPropertiesSupportsStrokeWidth else {
      NSSound.beep()
      return
    }
    let binding = quickStrokeWidthBinding
    let current = binding.wrappedValue
    let next = Self.steppedStrokeWidth(from: current, increasing: delta > 0)
    guard next != current else { return }
    binding.wrappedValue = next
  }

  /// Следующий пункт меню Thickness в нужную сторону. Значение между пунктами
  /// переходит к ближайшему пункту в направлении шага; у края остаётся крайний пункт.
  nonisolated static func steppedStrokeWidth(
    from current: CGFloat,
    increasing: Bool,
    presets: [CGFloat] = AnnotationProperties.strokeWidthPresets
  ) -> CGFloat {
    let sorted = presets.sorted()
    guard let lowest = sorted.first, let highest = sorted.last else { return current }
    let epsilon: CGFloat = 0.0001
    if increasing {
      return sorted.first(where: { $0 > current + epsilon }) ?? highest
    }
    return sorted.last(where: { $0 < current - epsilon }) ?? lowest
  }
}
