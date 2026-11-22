//
//  RecordingRegionKeyboardGeometry.swift
//  Snapzy
//
//  Геометрия области записи для клавиатуры и Option, как в changelog эталона:
//  Option выделяет и меняет размер симметрично от центра,
//  стрелки двигают область, ⌘ со стрелками меняет размер, ⇧ даёт шаг 10 pt.
//

import AppKit

enum RecordingRegionGeometry {
  /// Новая область от точки нажатия. С Option точка нажатия становится центром.
  static func selectionRect(start: CGPoint, end: CGPoint, fromCenter: Bool) -> CGRect {
    guard fromCenter else {
      return CGRect(
        x: min(start.x, end.x), y: min(start.y, end.y),
        width: abs(end.x - start.x), height: abs(end.y - start.y)
      )
    }
    let halfWidth = abs(end.x - start.x)
    let halfHeight = abs(end.y - start.y)
    return CGRect(x: start.x - halfWidth, y: start.y - halfHeight, width: halfWidth * 2, height: halfHeight * 2)
  }

  /// Изменение размера с Option: сдвиг ручки повторяется зеркально на противоположной стороне.
  static func centeredResize(
    _ resized: CGRect,
    from start: CGRect,
    handle: RecordingResizeHandle,
    minimumSize: CGFloat
  ) -> CGRect {
    var rect = resized
    if handle.affectsHorizontalAxis {
      let width = max(minimumSize, start.width + (resized.width - start.width) * 2)
      rect.origin.x = start.midX - width / 2
      rect.size.width = width
    }
    if handle.affectsVerticalAxis {
      let height = max(minimumSize, start.height + (resized.height - start.height) * 2)
      rect.origin.y = start.midY - height / 2
      rect.size.height = height
    }
    return rect
  }

  /// Стрелки: сдвиг области. ⌘ – ширина и высота при закреплённом левом верхнем углу.
  /// ⇧ увеличивает шаг до 10 pt. nil – клавиша не стрелка.
  static func nudged(
    _ rect: CGRect,
    keyCode: UInt16,
    modifiers: NSEvent.ModifierFlags,
    minimumSize: CGFloat,
    bounds: CGRect
  ) -> CGRect? {
    let step: CGFloat = modifiers.contains(.shift) ? 10 : 1
    let resizes = modifiers.contains(.command)
    var result = rect
    switch (keyCode, resizes) {
    case (123, false): result.origin.x -= step
    case (124, false): result.origin.x += step
    case (125, false): result.origin.y -= step
    case (126, false): result.origin.y += step
    case (123, true): result.size.width = max(minimumSize, rect.width - step)
    case (124, true): result.size.width = rect.width + step
    case (125, true):
      // Растёт вниз, верхний край на месте (координаты AppKit, y вверх).
      result.size.height = rect.height + step
      result.origin.y = rect.maxY - result.height
    case (126, true):
      result.size.height = max(minimumSize, rect.height - step)
      result.origin.y = rect.maxY - result.height
    default:
      return nil
    }
    guard !bounds.isNull, !bounds.isEmpty else { return result }
    result.size.width = min(result.width, bounds.width)
    result.size.height = min(result.height, bounds.height)
    result.origin.x = min(max(result.minX, bounds.minX), bounds.maxX - result.width)
    result.origin.y = min(max(result.minY, bounds.minY), bounds.maxY - result.height)
    return result
  }
}

extension RecordingResizeHandle {
  var affectsHorizontalAxis: Bool {
    switch self {
    case .top, .bottom: false
    default: true
    }
  }

  var affectsVerticalAxis: Bool {
    switch self {
    case .left, .right: false
    default: true
    }
  }
}
