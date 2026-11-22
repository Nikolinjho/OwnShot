//
//  AnnotateTextFrameGeometry.swift
//  Snapzy
//
//  Геометрия рамки текста по эталону: новая рамка по клику (ANN-043),
//  ручки выделенного текста (ANN-801) и двойной клик в правке (ANN-104).
//

import CoreGraphics

/// Рамка текста эталона. Все размеры – в точках изображения, ось Y вверх.
enum AnnotateTextFrameGeometry {
  /// Новая рамка по клику у эталона ~100 pt шириной (spec-063-live/b3r-text-ref-1.png).
  static let newTextWidth: CGFloat = 100
  /// Левый край новой рамки на 10 pt левее точки клика, по вертикали рамка
  /// стоит центром в точке клика (b3r-text-ref-1, -6, -8). Drag размер не задаёт.
  static let newTextLeadingOffset: CGFloat = 10

  /// Кнопка эмодзи над рамкой в правке: круг 26 pt, центр на 24 pt выше
  /// верхнего края рамки, по центру по горизонтали (b3r-text-ref-1.png).
  static let emojiButtonDiameter: CGFloat = 26
  static let emojiButtonCenterAboveFrame: CGFloat = 24

  /// Рамка новой текстовой аннотации для клика в `point`. У края холста
  /// рамка сдвигается внутрь `area`, чтобы начало текста не уходило за край.
  static func newTextBounds(at point: CGPoint, height: CGFloat, within area: CGRect? = nil) -> CGRect {
    var bounds = CGRect(
      x: point.x - newTextLeadingOffset,
      y: point.y - height / 2,
      width: newTextWidth,
      height: height
    )
    guard let area = area?.standardized, !area.isEmpty else { return bounds }
    bounds.origin.x = max(bounds.minX, area.minX)
    if bounds.maxY > area.maxY {
      bounds.origin.y = area.maxY - height
    }
    if bounds.minY < area.minY {
      bounds.origin.y = min(area.minY, area.maxY - height)
    }
    return bounds
  }

  // MARK: - Ручки (ANN-801)

  /// Ручки текста эталона: круглые слева и справа посередине высоты меняют
  /// ширину (перенос строк), квадратик в правом нижнем углу меняет кегль.
  enum Handle: Equatable {
    case leftWidth
    case rightWidth
    case scale
  }

  /// Центры ручек для рамки в координатах изображения (Y вверх, низ – minY).
  static func handleCenters(for bounds: CGRect) -> [(Handle, CGPoint)] {
    [
      (.leftWidth, CGPoint(x: bounds.minX, y: bounds.midY)),
      (.rightWidth, CGPoint(x: bounds.maxX, y: bounds.midY)),
      (.scale, CGPoint(x: bounds.maxX, y: bounds.minY)),
    ]
  }

  /// Новая ширина и левый край при перетаскивании боковой ручки:
  /// противоположный край стоит на месте.
  static func widthResizedFrame(
    original: CGRect,
    handle: Handle,
    pointerX: CGFloat,
    minimumWidth: CGFloat = AnnotateTextLayout.minWidth,
    maximumWidth: CGFloat = AnnotateTextLayout.maxWidth
  ) -> (minX: CGFloat, width: CGFloat) {
    switch handle {
    case .leftWidth:
      let width = min(max(original.maxX - pointerX, minimumWidth), maximumWidth)
      return (original.maxX - width, width)
    case .rightWidth, .scale:
      let width = min(max(pointerX - original.minX, minimumWidth), maximumWidth)
      return (original.minX, width)
    }
  }

  /// Коэффициент кегля при перетаскивании угловой ручки: проекция указателя
  /// на диагональ рамки от неподвижного левого верхнего угла. Кегль после
  /// умножения остаётся в пределах меню Font size.
  static func scaleFactor(
    original: CGRect,
    pointer: CGPoint,
    fontSize: CGFloat,
    fontSizeRange: ClosedRange<CGFloat> = AnnotationProperties.fontSizeRange
  ) -> CGFloat {
    let width = max(original.width, 1)
    let height = max(original.height, 1)
    let dx = pointer.x - original.minX
    let dy = original.maxY - pointer.y
    let projected = (dx * width + dy * height) / (width * width + height * height)
    let safeFontSize = max(fontSize, 1)
    let lower = fontSizeRange.lowerBound / safeFontSize
    let upper = fontSizeRange.upperBound / safeFontSize
    return min(max(projected, lower), upper)
  }

  /// Текст после жеста ручки: ширина или кегль меняются, высота пересчитывается
  /// по переносу строк, верхний край рамки стоит на месте.
  static func resizedTextItem(
    _ item: AnnotationItem,
    original: CGRect,
    handle: Handle,
    pointer: CGPoint,
    maximumWidth: CGFloat = AnnotateTextLayout.maxWidth
  ) -> AnnotationItem? {
    guard case .text(let text) = item.type else { return nil }
    var properties = item.properties
    let minX: CGFloat
    let width: CGFloat
    switch handle {
    case .leftWidth, .rightWidth:
      (minX, width) = widthResizedFrame(
        original: original,
        handle: handle,
        pointerX: pointer.x,
        maximumWidth: maximumWidth
      )
    case .scale:
      let factor = scaleFactor(original: original, pointer: pointer, fontSize: properties.fontSize)
      properties.fontSize = AnnotationProperties.clampedFontSize(properties.fontSize * factor)
      minX = original.minX
      width = AnnotateTextLayout.clampedWidth(original.width * factor, maximumWidth: maximumWidth)
    }

    let font = AnnotateTextLayout.font(
      size: properties.fontSize,
      fontName: properties.fontName,
      textStyle: properties.textStyle
    )
    let laidOut = AnnotateTextLayout.bounds(
      text: text,
      font: font,
      origin: .zero,
      constrainedWidth: width,
      presentation: properties.textPresentation
    )
    let newBounds = CGRect(
      x: minX,
      y: original.maxY - laidOut.height,
      width: laidOut.width,
      height: laidOut.height
    )
    var resized = item.applyingResizeBounds(newBounds)
    resized.properties.fontSize = properties.fontSize
    return resized
  }

  // MARK: - Двойной клик в правке (ANN-104)

  /// Повторный клик серии, первый клик которой открыл правку на холсте:
  /// у эталона каретка остаётся в конце, слово не выделяется.
  static func keepsCaretAtEnd(clickCount: Int, hasReceivedMouseDown: Bool) -> Bool {
    clickCount >= 2 && !hasReceivedMouseDown
  }
}
