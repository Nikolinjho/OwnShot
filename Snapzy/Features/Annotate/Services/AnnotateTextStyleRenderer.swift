//
//  AnnotateTextStyleRenderer.swift
//  Snapzy
//
//  Отрисовка стилей текста эталона: обводка Outlined и построчные подложки
//  Box, Mono Box, Rounded Box.
//

import AppKit
import CoreGraphics

/// Геометрия и цвета стилей текста. Пропорции сняты с одного settled PNG эталона
/// при 30 pt, zoom 100%, scale 2 (evidence/spec-043-live/text-*-settled.png) и
/// пересчитаны в доли кегля. Это один экземпляр, а не контракт для любых размеров.
nonisolated enum AnnotateTextStyleRenderer {
  // MARK: - Outlined

  /// Белая обводка выходит за glyph примерно на 3 pt при 30 pt (6 px на PNG
  /// text-outlined-settled.png), то есть на 10% кегля. Обводка центрирована по
  /// контуру, поэтому полная ширина штриха вдвое больше.
  /// TODO: ширина при других кеглях, joins и цвет обводки на светлом тексте не установлены.
  static let outlineOutsetRatio: CGFloat = 0.1

  /// Значение NSAttributedString.Key.strokeWidth (проценты кегля, положительное –
  /// только контур) для белой подложки-обводки.
  static var outlineStrokeWidthPercent: CGFloat { outlineOutsetRatio * 2 * 100 }

  static let outlineColor = NSColor.white

  // MARK: - Backdrop

  struct BackdropMetrics: Equatable {
    /// Поля подложки слева и справа от строки, в долях кегля.
    let horizontalPaddingRatio: CGFloat
    /// Поля сверху и снизу от line fragment, в долях кегля.
    let verticalPaddingRatio: CGFloat
    /// Радиус углов в долях кегля; nil – капсула (половина высоты строки).
    let cornerRadiusRatio: CGFloat?
  }

  /// Box: подложка на высоту line fragment (607…676 px ≈ 35 pt при 30 pt), поля
  /// по бокам ≈ 9 pt, небольшое скругление ≈ 3 pt.
  /// Mono Box: те же поля, углы прямые.
  /// Rounded Box: поля ≈ 20 pt по бокам и ≈ 7 pt сверху, концы полностью скруглены.
  /// TODO: padding, радиусы и слияние подложек нескольких строк эталон не измерял
  /// (ANN-770, ANN-771, ANN-772); значения ниже – замер одного кадра.
  static func metrics(for backdrop: AnnotationTextStyle.Backdrop) -> BackdropMetrics {
    switch backdrop {
    case .box:
      BackdropMetrics(horizontalPaddingRatio: 0.3, verticalPaddingRatio: 0, cornerRadiusRatio: 0.1)
    case .monoBox:
      BackdropMetrics(horizontalPaddingRatio: 0.3, verticalPaddingRatio: 0, cornerRadiusRatio: 0)
    case .roundedBox:
      BackdropMetrics(horizontalPaddingRatio: 0.65, verticalPaddingRatio: 0.23, cornerRadiusRatio: nil)
    }
  }

  /// Цвет подложки. На PNG эталона при зелёном тексте sRGB(72,217,99) подложка
  /// Box и Rounded Box имеет sRGB(244,251,244), то есть белый с примесью цвета текста
  /// около 6%; подложка Mono Box чисто белая sRGB(255,254,255).
  /// TODO: зависимость от цвета текста проверена на одном цвете, alpha не измерена.
  static func backdropColor(for backdrop: AnnotationTextStyle.Backdrop, textColor: NSColor) -> NSColor {
    switch backdrop {
    case .monoBox:
      return .white
    case .box, .roundedBox:
      let tint = textColor.usingColorSpace(.sRGB) ?? textColor
      return NSColor.white.blended(withFraction: 0.06, of: tint) ?? .white
    }
  }

  /// Прямоугольники строк текста (used rect каждого line fragment) в координатах
  /// холста. textRect – та же область, в которую NSString.draw(in:) рисует текст.
  static func lineRects(
    text: String,
    attributes: [NSAttributedString.Key: Any],
    in textRect: CGRect,
    isFlipped: Bool
  ) -> [CGRect] {
    guard !text.isEmpty, textRect.width > 0 else { return [] }

    let storage = NSTextStorage(string: text, attributes: attributes)
    let container = NSTextContainer(size: CGSize(width: textRect.width, height: .greatestFiniteMagnitude))
    container.lineFragmentPadding = 0
    let layoutManager = NSLayoutManager()
    layoutManager.addTextContainer(container)
    storage.addLayoutManager(layoutManager)
    layoutManager.ensureLayout(for: container)

    var rects: [CGRect] = []
    let glyphRange = layoutManager.glyphRange(for: container)
    layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { lineRect, usedRect, _, lineGlyphRange, _ in
      let characterRange = layoutManager.characterRange(forGlyphRange: lineGlyphRange, actualGlyphRange: nil)
      let lineText = (text as NSString).substring(with: characterRange)
      // Пустая строка (только перевод строки) подложку не получает.
      guard !lineText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

      let width = trimmedLineWidth(
        layoutManager: layoutManager,
        container: container,
        glyphRange: lineGlyphRange,
        text: text,
        lineMinX: usedRect.minX,
        fallback: usedRect.width
      )
      let y = isFlipped
        ? textRect.minY + lineRect.minY
        : textRect.maxY - lineRect.maxY
      rects.append(CGRect(x: textRect.minX + usedRect.minX, y: y, width: width, height: lineRect.height))
    }
    return rects
  }

  /// Ширина строки без хвостовых пробелов и перевода строки: подложка должна
  /// заканчиваться у последнего glyph.
  private static func trimmedLineWidth(
    layoutManager: NSLayoutManager,
    container: NSTextContainer,
    glyphRange: NSRange,
    text: String,
    lineMinX: CGFloat,
    fallback: CGFloat
  ) -> CGFloat {
    let nsText = text as NSString
    var characterRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
    while characterRange.length > 0 {
      let last = nsText.substring(with: NSRange(location: NSMaxRange(characterRange) - 1, length: 1))
      guard last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { break }
      characterRange.length -= 1
    }
    guard characterRange.length > 0 else { return fallback }
    let trimmedGlyphs = layoutManager.glyphRange(forCharacterRange: characterRange, actualCharacterRange: nil)
    let bounds = layoutManager.boundingRect(forGlyphRange: trimmedGlyphs, in: container)
    return max(0, bounds.maxX - lineMinX)
  }

  /// Контур подложки: объединение скруглённых прямоугольников строк. Заливка
  /// непрозрачная, поэтому перекрытие соседних строк даёт ступенчатый силуэт.
  static func backdropPath(
    lineRects: [CGRect],
    backdrop: AnnotationTextStyle.Backdrop,
    fontSize: CGFloat
  ) -> CGPath {
    let metrics = metrics(for: backdrop)
    let path = CGMutablePath()
    for lineRect in lineRects {
      let rect = lineRect.insetBy(
        dx: -fontSize * metrics.horizontalPaddingRatio,
        dy: -fontSize * metrics.verticalPaddingRatio
      )
      guard rect.width > 0, rect.height > 0 else { continue }
      let radius = min(
        metrics.cornerRadiusRatio.map { $0 * fontSize } ?? rect.height / 2,
        min(rect.width, rect.height) / 2
      )
      path.addRoundedRect(in: rect, cornerWidth: radius, cornerHeight: radius)
    }
    return path
  }

  /// Насколько подложка может выйти за рамку текста: используется для clip.
  static func backdropOutset(for backdrop: AnnotationTextStyle.Backdrop, fontSize: CGFloat) -> CGSize {
    let metrics = metrics(for: backdrop)
    return CGSize(
      width: fontSize * metrics.horizontalPaddingRatio,
      height: fontSize * metrics.verticalPaddingRatio
    )
  }
}
