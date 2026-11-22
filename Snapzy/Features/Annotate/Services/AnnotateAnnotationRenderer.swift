//
//  AnnotateAnnotationRenderer.swift
//  Snapzy
//
//  Handles rendering annotations to CGContext
//

import AppKit
import CoreGraphics
import SwiftUI

/// Renders annotations to a CGContext
nonisolated struct AnnotationRenderer {
  private static let livePreviewFullQualityAreaThreshold: CGFloat = 120_000

  let context: CGContext
  var drawsObjectShadow: Bool
  var editingTextId: UUID?
  var sourceImage: NSImage?
  /// Pre-resolved `sourceImage` CGImage; avoids re-resolving per blur per frame.
  var sourceCGImage: CGImage?
  var blurCacheManager: BlurCacheManager?
  private var interactiveBlurAnnotationIds: Set<UUID>
  var interactiveEmbeddedImageAnnotationId: UUID?
  var embeddedImageProvider: ((UUID) -> NSImage?)?
  var embeddedCGImageProvider: ((UUID) -> CGImage?)?
  /// Соль сетки Secure для рендера экспорта. Ноль – сетка холста из UUID объекта.
  var secureExportSalt: UInt64

  init(
    context: CGContext,
    drawsObjectShadow: Bool = true,
    editingTextId: UUID? = nil,
    sourceImage: NSImage? = nil,
    sourceCGImage: CGImage? = nil,
    blurCacheManager: BlurCacheManager? = nil,
    interactiveBlurAnnotationId: UUID? = nil,
    interactiveBlurAnnotationIds: Set<UUID> = [],
    interactiveEmbeddedImageAnnotationId: UUID? = nil,
    embeddedImageProvider: ((UUID) -> NSImage?)? = nil,
    embeddedCGImageProvider: ((UUID) -> CGImage?)? = nil,
    secureExportSalt: UInt64 = 0
  ) {
    self.context = context
    self.drawsObjectShadow = drawsObjectShadow
    self.editingTextId = editingTextId
    self.sourceImage = sourceImage
    self.sourceCGImage = sourceCGImage
    self.blurCacheManager = blurCacheManager
    var normalizedInteractiveBlurIds = interactiveBlurAnnotationIds
    if let interactiveBlurAnnotationId {
      normalizedInteractiveBlurIds.insert(interactiveBlurAnnotationId)
    }
    self.interactiveBlurAnnotationIds = normalizedInteractiveBlurIds
    self.interactiveEmbeddedImageAnnotationId = interactiveEmbeddedImageAnnotationId
    self.embeddedImageProvider = embeddedImageProvider
    self.embeddedCGImageProvider = embeddedCGImageProvider
    self.secureExportSalt = secureExportSalt
  }

  func draw(_ annotation: AnnotationItem) {
    // Skip rendering text that is being edited (overlay handles display)
    if case .text = annotation.type, annotation.id == editingTextId {
      return
    }

    context.saveGState()
    defer { context.restoreGState() }
    if drawsObjectShadow {
      switch annotation.type {
      case .blur, .spotlight, .highlight, .embeddedImage, .measurement: break
      default:
        context.setShadow(offset: CGSize(width: 0, height: -1), blur: 2, color: NSColor.black.withAlphaComponent(0.2).cgColor)
      }
    }
    let strokeColor = NSColor(annotation.properties.strokeColor).cgColor
    let fillColor = NSColor(annotation.properties.fillColor).cgColor

    context.setStrokeColor(strokeColor)
    context.setFillColor(fillColor)
    context.setLineWidth(annotation.properties.strokeWidth)
    context.setLineCap(.round)
    context.setLineJoin(.round)

    switch annotation.type {
    case .rectangle:
      context.addPath(Self.roundedRectPath(in: annotation.bounds, cornerRadius: annotation.properties.cornerRadius))
      strokeCurrentPath(lineStyle: annotation.properties.lineStyle, strokeWidth: annotation.properties.strokeWidth)

    case .filledRectangle:
      context.addPath(Self.roundedRectPath(in: annotation.bounds, cornerRadius: annotation.properties.cornerRadius))
      strokeCurrentPath(lineStyle: annotation.properties.lineStyle, strokeWidth: annotation.properties.strokeWidth, mode: .fillStroke)

    case .oval:
      context.addEllipse(in: annotation.bounds)
      strokeCurrentPath(lineStyle: annotation.properties.lineStyle, strokeWidth: annotation.properties.strokeWidth)

    case .arrow(let geometry):
      drawArrow(
        geometry,
        strokeWidth: annotation.properties.strokeWidth,
        strokeColor: annotation.properties.strokeColor,
        lineStyle: annotation.properties.lineStyle
      )

    case .line(let start, let end):
      context.move(to: start)
      context.addLine(to: end)
      strokeCurrentPath(lineStyle: annotation.properties.lineStyle, strokeWidth: annotation.properties.strokeWidth)

    case .path(let points), .highlight(let points):
      drawPath(
        points: points,
        isHighlight: annotation.type.isHighlight,
        strokeWidth: annotation.properties.strokeWidth
      )

    case .counter(let value):
      if let geometry = annotation.counterArrowGeometry {
        drawArrow(
          geometry,
          strokeWidth: annotation.properties.strokeWidth,
          strokeColor: annotation.properties.strokeColor,
          isCounterArrow: true
        )
      }
      drawCounter(value: value, in: annotation.bounds, properties: annotation.properties)

    case .blur(let blurType):
      drawBlur(
        bounds: annotation.bounds,
        annotationId: annotation.id,
        blurType: blurType,
        controlValue: annotation.properties.strokeWidth
      )

    case .text(let content):
      drawText(content, in: annotation.bounds, properties: annotation.properties)

    case .watermark(let content):
      drawWatermark(content, in: annotation.bounds, properties: annotation.properties)

    case .embeddedImage(let assetId):
      drawEmbeddedImage(assetId: assetId, annotationId: annotation.id, in: annotation.bounds)

    case .spotlight:
      // Spotlight is rendered as a unified overlay pass, skip per-item drawing
      break

    case .measurement:
      AnnotateMeasureRenderer.draw(annotation, color: strokeColor, in: context)
    }
  }

  func drawCurrentStroke(
    tool: AnnotationToolType,
    start: CGPoint,
    currentPath: [CGPoint],
    strokeColor: Color,
    strokeWidth: CGFloat,
    fillColor: Color = .clear,
    arrowStyle: ArrowStyle = .straight,
    arrowType: ArrowType = .tapered,
    arrowBendDirection: ArrowBendDirection = .primary,
    arrowStartHead: ArrowEndpointStyle = .none,
    arrowEndHead: ArrowEndpointStyle = .arrow,
    lineStyle: LineDashStyle = .solid,
    rectangleCornerRadius: CGFloat = 0,
    watermarkText: String = "Snapzy",
    watermarkStyle: WatermarkStyle = .diagonal,
    watermarkOpacity: CGFloat = 0.22,
    watermarkRotationDegrees: CGFloat = -24,
    watermarkFontSize: CGFloat = 36
  ) {
    context.setStrokeColor(NSColor(strokeColor).cgColor)
    context.setLineWidth(strokeWidth)
    context.setLineCap(.round)

    switch tool {
    case .pencil, .highlighter:
      if tool == .highlighter {
        // Превью идёт тем же путём, что и готовый штрих (та же прозрачность).
        drawPath(points: currentPath, isHighlight: true, strokeWidth: strokeWidth)
        return
      }
      drawPath(points: currentPath, isHighlight: false, strokeWidth: strokeWidth)

    case .rectangle:
      let currentPoint = currentPath.last ?? start
      let rect = makeRect(from: start, to: currentPoint)
      context.addPath(Self.roundedRectPath(in: rect, cornerRadius: rectangleCornerRadius))
      strokeCurrentPath(lineStyle: lineStyle, strokeWidth: strokeWidth)

    case .filledRectangle:
      let currentPoint = currentPath.last ?? start
      let rect = makeRect(from: start, to: currentPoint)
      let resolvedFillColor = fillColor == .clear ? strokeColor.opacity(1) : fillColor
      context.setFillColor(NSColor(resolvedFillColor).cgColor)
      context.addPath(Self.roundedRectPath(in: rect, cornerRadius: rectangleCornerRadius))
      strokeCurrentPath(lineStyle: lineStyle, strokeWidth: strokeWidth, mode: .fillStroke)
      context.setFillColor(NSColor.clear.cgColor)

    case .oval:
      let currentPoint = currentPath.last ?? start
      let rect = makeRect(from: start, to: currentPoint)
      context.addEllipse(in: rect)
      strokeCurrentPath(lineStyle: lineStyle, strokeWidth: strokeWidth)

    case .line:
      let currentPoint = currentPath.last ?? start
      context.move(to: start)
      context.addLine(to: currentPoint)
      strokeCurrentPath(lineStyle: lineStyle, strokeWidth: strokeWidth)

    case .arrow:
      let currentPoint = currentPath.last ?? start
      let initialStyle = arrowStyle
      let resolvedStyle: ArrowStyle
      if arrowBendDirection == .alternate {
        if initialStyle == .curvedRight {
          resolvedStyle = .curvedLeft
        } else if initialStyle == .curvedLeft {
          resolvedStyle = .curvedRight
        } else {
          resolvedStyle = initialStyle
        }
      } else {
        resolvedStyle = initialStyle
      }
      let resolvedDirection: ArrowBendDirection = (resolvedStyle == .curvedLeft) ? .primary : .alternate
      drawArrow(
        ArrowGeometry(
          start: start,
          end: currentPoint,
          style: resolvedStyle,
          bendDirection: resolvedDirection,
          controlPoint: ArrowGeometry.creationControlPoint(start: start, end: currentPoint, style: resolvedStyle),
          arrowType: arrowType,
          startHead: arrowStartHead,
          endHead: arrowEndHead
        ),
        strokeWidth: strokeWidth,
        strokeColor: strokeColor,
        lineStyle: lineStyle
      )

    case .watermark:
      let currentPoint = currentPath.last ?? start
      let rect = makeRect(from: start, to: currentPoint)
      guard rect.width >= 24, rect.height >= 24 else { return }
      drawWatermark(
        watermarkText,
        in: rect,
        properties: AnnotationProperties(
          strokeColor: strokeColor,
          fillColor: .clear,
          strokeWidth: strokeWidth,
          fontSize: watermarkFontSize,
          opacity: watermarkOpacity,
          rotationDegrees: watermarkRotationDegrees,
          watermarkStyle: watermarkStyle
        )
      )

    default:
      break
    }
  }

  /// Live preview of text-snapped highlighter bars. Routed through the same
  /// path drawing the committed annotations use, so the preview is pixel
  /// identical to what `mouseUp` creates.
  func drawSnappedHighlightPreview(segments: [AnnotateTextSnapSegment], strokeColor: Color) {
    guard !segments.isEmpty else { return }
    context.setStrokeColor(NSColor(strokeColor).cgColor)
    context.setLineCap(.round)
    // Скруглённые углы плашки дают круглые соединения контура (AnnotateTextSnapSegment).
    context.setLineJoin(.round)
    for segment in segments {
      drawPath(points: segment.highlightPoints, isHighlight: true, strokeWidth: segment.strokeWidth)
    }
  }

  // MARK: - Private Drawing Helpers

  private func drawPath(points: [CGPoint], isHighlight: Bool, strokeWidth: CGFloat) {
    guard let first = points.first else { return }
    if !isHighlight, points.allSatisfy({ $0 == first }) {
      // Click инструментом Draw: круглая точка диаметром в толщину штриха,
      // как у эталона (ANN-126). Цвет заливки – цвет штриха.
      Self.strokeDot(at: first, diameter: strokeWidth, in: context)
      return
    }
    guard points.count > 1 else { return }
    if isHighlight {
      // Обычное смешивание с постоянной прозрачностью: живой замер эталона на чёрном и белом
      // фоне даёт α≈0,30, а не multiply. Opacity из свойств маркер не читает: у эталона
      // такой настройки нет, сохранённое старое значение не должно менять штрих.
      context.setAlpha(Self.highlightAlpha)
      context.setLineWidth(Self.highlightLineWidth(forStrokeWidth: strokeWidth))
    } else {
      context.setLineWidth(strokeWidth)
    }
    context.move(to: points[0])
    for point in points.dropFirst() {
      context.addLine(to: point)
    }
    context.strokePath()
    context.setAlpha(1.0)
  }

  /// Точка штриха Draw из одной позиции: круг цвета штриха диаметром `diameter`.
  /// Цвет заливки контекста у Draw не задан, поэтому круг рисуется обводкой
  /// текущим цветом штриха: кольцо радиусом d/4 и толщиной d/2 закрывает весь диск.
  static func strokeDot(at center: CGPoint, diameter: CGFloat, in context: CGContext) {
    let diameter = max(diameter, 0.5)
    let ringRadius = diameter / 4
    context.saveGState()
    context.setLineDash(phase: 0, lengths: [])
    context.setLineWidth(diameter / 2)
    context.addEllipse(in: CGRect(
      x: center.x - ringRadius,
      y: center.y - ringRadius,
      width: ringRadius * 2,
      height: ringRadius * 2
    ))
    context.strokePath()
    context.restoreGState()
  }

  /// Прозрачность штриха Highlighter (spec-062-live/ref-highlighter-bw.png: на чёрном
  /// (34,64,30), на белом (212,242,208) – зелёный пресет с α 0,3).
  static let highlightAlpha: CGFloat = 0.3

  /// Толщина Highlighter втрое больше значения Thickness: дефолт 7 даёт 21 pt,
  /// как штрих эталона (≈40 px на 2x-снимке).
  static func highlightLineWidth(forStrokeWidth strokeWidth: CGFloat) -> CGFloat {
    strokeWidth * 3
  }

  /// Corner radius the rectangle path actually uses: never negative and never
  /// more than half the shorter side.
  static func clampedCornerRadius(_ cornerRadius: CGFloat, in rect: CGRect) -> CGFloat {
    max(0, min(cornerRadius, min(rect.width, rect.height) / 2))
  }

  /// Outline of a (filled) rectangle annotation. Shared with hit testing so a
  /// click lands on the same rounded corners the canvas draws.
  static func roundedRectPath(in rect: CGRect, cornerRadius: CGFloat) -> CGPath {
    let clampedCornerRadius = Self.clampedCornerRadius(cornerRadius, in: rect)
    guard clampedCornerRadius > 0 else {
      return CGPath(rect: rect, transform: nil)
    }
    return CGPath(
      roundedRect: rect,
      cornerWidth: clampedCornerRadius,
      cornerHeight: clampedCornerRadius,
      transform: nil
    )
  }

  /// Strokes the current path, applying the dash pattern for `lineStyle`.
  /// Dash state is always reset so later drawing (counter, text, blur) stays solid.
  private func strokeCurrentPath(
    lineStyle: LineDashStyle,
    strokeWidth: CGFloat,
    mode: CGPathDrawingMode = .stroke
  ) {
    context.setLineDash(phase: 0, lengths: lineStyle.dashLengths(for: strokeWidth))
    context.drawPath(using: mode)
    context.setLineDash(phase: 0, lengths: [])
  }

  private func drawArrow(
    _ geometry: ArrowGeometry,
    strokeWidth: CGFloat,
    strokeColor: Color,
    lineStyle: LineDashStyle = .solid,
    isCounterArrow: Bool = false
  ) {
    guard geometry.isRenderable else { return }

    // Выносная стрелка счётчика – расширение OwnShot, у неё прежний контур.
    if isCounterArrow {
      drawLegacyTaperedArrow(geometry, strokeWidth: strokeWidth, strokeColor: strokeColor)
      return
    }

    let resolvedColor = NSColor(strokeColor).cgColor
    let opaqueColor = resolvedColor.copy(alpha: 1) ?? resolvedColor
    let kind = geometry.shapeKind
    if kind == .outlined {
      drawLegacyTaperedArrow(geometry, strokeWidth: strokeWidth, strokeColor: strokeColor)
      return
    }

    // Стрелка рисуется непрозрачным цветом в прозрачном слое, а прозрачность цвета
    // и тень применяются к слою целиком: при полупрозрачном цвете тело, обводка
    // и шеврон не дают тёмных наложений, как у эталона.
    context.saveGState()
    if drawsObjectShadow {
      if kind == .line {
        context.setShadow(offset: CGSize(width: 0, height: -1.0), blur: 2.0, color: NSColor.black.withAlphaComponent(0.20).cgColor)
      } else {
        context.setShadow(offset: CGSize(width: 0, height: -2.0), blur: 4.5, color: NSColor.black.withAlphaComponent(0.30).cgColor)
      }
    } else {
      context.setShadow(offset: .zero, blur: 0, color: nil)
    }
    context.setAlpha(resolvedColor.alpha)
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    context.setStrokeColor(opaqueColor)
    context.setFillColor(opaqueColor)
    context.setLineJoin(.round)
    context.setLineCap(.round)

    switch kind {
    case .standard:
      let polygon = geometry.standardArrowPolygon(strokeWidth: strokeWidth)
      context.addPath(polygon.path)
      context.setLineWidth(polygon.outlineWidth)
      context.drawPath(using: polygon.outlineWidth > 0 ? .fillStroke : .fill)

    case .fancy:
      context.addPath(geometry.fancyArrowPath(strokeWidth: strokeWidth))
      context.fillPath()

    case .line, .outlined:
      let metrics = AnnotateArrowShapes.lineMetrics(thickness: strokeWidth, chordLength: geometry.chordLength)
      context.setLineWidth(metrics.lineWidth)
      context.setLineDash(phase: 0, lengths: lineStyle.dashLengths(for: metrics.lineWidth))
      context.addPath(geometry.path())
      context.strokePath()
      // Наконечники всегда сплошные.
      context.setLineDash(phase: 0, lengths: [])
      drawArrowEndpoint(
        geometry.endHead,
        at: geometry.end,
        outwardAngle: geometry.tangentAngleAtEnd(),
        strokeWidth: strokeWidth,
        lineMetrics: metrics
      )
      drawArrowEndpoint(
        geometry.startHead,
        at: geometry.start,
        outwardAngle: geometry.tangentAngleAtStart(),
        strokeWidth: strokeWidth,
        lineMetrics: metrics
      )
    }

    context.endTransparencyLayer()
    context.restoreGState()
  }

  /// Прежний залитый контур с белой обводкой: Outlined и выносная стрелка счётчика.
  private func drawLegacyTaperedArrow(_ geometry: ArrowGeometry, strokeWidth: CGFloat, strokeColor: Color) {
    let arrowPath = geometry.taperedArrowPath(strokeWidth: strokeWidth)

    context.saveGState()

    if drawsObjectShadow { context.setShadow(
      offset: CGSize(width: 0, height: -2.0),
      blur: 4.5,
      color: NSColor.black.withAlphaComponent(0.30).cgColor
    ) }

    if geometry.arrowType == .outlined {
      context.addPath(arrowPath)
      context.setStrokeColor(NSColor.white.cgColor)
      context.setLineWidth(1.8 + strokeWidth * 0.3)
      context.setLineJoin(.round)
      context.setLineCap(.round)
      context.strokePath()
    }

    context.addPath(arrowPath)
    context.setFillColor(NSColor(strokeColor).cgColor)
    context.fillPath()

    context.restoreGState()
  }

  /// Наконечник линейной стрелки в точке `tip`: шеврон эталона или круг (расширение OwnShot).
  /// `outwardAngle` направлен от тела стрелки наружу.
  private func drawArrowEndpoint(
    _ style: ArrowEndpointStyle,
    at tip: CGPoint,
    outwardAngle angle: CGFloat,
    strokeWidth: CGFloat,
    lineMetrics: AnnotateArrowShapes.LineMetrics
  ) {
    switch style {
    case .none:
      break

    case .arrow:
      context.setLineWidth(lineMetrics.lineWidth)
      context.addPath(ArrowGeometry.lineChevronPath(tip: tip, outwardAngle: angle, metrics: lineMetrics))
      context.strokePath()

    case .circle:
      let radius = min(max(strokeWidth * 1.9, 5), 14)
      let rect = CGRect(
        x: tip.x - radius,
        y: tip.y - radius,
        width: radius * 2,
        height: radius * 2
      )
      context.fillEllipse(in: rect)
    }
  }

  private func drawCounter(value: Int, in bounds: CGRect, properties: AnnotationProperties) {
    let rect: CGRect
    if bounds.standardized.isEmpty {
      let size = AnnotationProperties.counterDiameter(for: properties.strokeWidth)
      rect = CGRect(x: bounds.origin.x - size / 2, y: bounds.origin.y - size / 2, width: size, height: size)
    } else {
      rect = bounds.standardized
    }

    context.setFillColor(NSColor(properties.strokeColor).cgColor)
    context.fillEllipse(in: rect)

    let fontSize = min(max(rect.height * 0.5, 11), 56)
    var attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
      .foregroundColor: NSColor.white,
    ]
    let text = properties.counterFormat.label(for: value) as NSString
    var textSize = text.size(withAttributes: attributes)
    // Длинные подписи (VIII, AA, 1000) ужимаем, чтобы они оставались внутри кружка.
    let maxTextWidth = rect.width * 0.8
    if textSize.width > maxTextWidth, textSize.width > 0 {
      attributes[.font] = NSFont.systemFont(ofSize: fontSize * maxTextWidth / textSize.width, weight: .bold)
      textSize = text.size(withAttributes: attributes)
    }
    let textPoint = CGPoint(
      x: rect.midX - textSize.width / 2,
      y: rect.midY - textSize.height / 2
    )
    text.draw(at: textPoint, withAttributes: attributes)
  }

  private func drawText(_ content: String, in bounds: CGRect, properties: AnnotationProperties) {
    let displayText = content.isEmpty ? "" : content
    let font = AnnotateTextLayout.font(
      size: properties.fontSize,
      fontName: properties.fontName,
      textStyle: properties.textStyle
    )

    // The text bounds are the bubble itself, so the surface grows in lockstep
    // with the text instead of leaving a separate, fixed-size background behind.
    if properties.textPresentation != .plain, properties.fillColor != .clear {
      context.setFillColor(NSColor(properties.fillColor).cgColor)
      let bgRect = bounds.standardized
      let cornerRadius = properties.cornerRadius > 0
        ? min(properties.cornerRadius, min(bgRect.width, bgRect.height) * 0.46)
        : TextBubbleGeometry.cornerRadius(in: bgRect, fontSize: font.pointSize)
      context.addPath(
        TextBubbleGeometry.bubblePath(
          in: bgRect,
          cornerRadius: cornerRadius,
          tailTarget: properties.textPresentation == .callout ? properties.calloutTailTarget : nil,
          fontSize: font.pointSize
        )
      )
      context.fillPath()
    }

    // Draw text with word wrapping within bounds
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.lineBreakMode = .byWordWrapping

    let attributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: NSColor(properties.strokeColor),
      .paragraphStyle: paragraphStyle,
    ]

    let textBounds = bounds.standardized
    let textRect = AnnotateTextLayout.textRect(
      for: content,
      font: font,
      in: textBounds,
      presentation: properties.textPresentation
    )
    let text = displayText as NSString
    let textColor = NSColor(properties.strokeColor)

    // Построчная подложка Box / Mono Box / Rounded Box рисуется под текстом и
    // может выходить за рамку на величину своих полей.
    if let backdrop = properties.textStyle.backdrop {
      let isFlipped = NSGraphicsContext.current?.isFlipped ?? false
      let lineRects = AnnotateTextStyleRenderer.lineRects(
        text: content,
        attributes: attributes,
        in: textRect,
        isFlipped: isFlipped
      ).filter { $0.intersects(textBounds) }
      if !lineRects.isEmpty {
        let outset = AnnotateTextStyleRenderer.backdropOutset(for: backdrop, fontSize: font.pointSize)
        context.saveGState()
        context.clip(to: textBounds.insetBy(dx: -outset.width, dy: -outset.height))
        context.addPath(
          AnnotateTextStyleRenderer.backdropPath(
            lineRects: lineRects,
            backdrop: backdrop,
            fontSize: font.pointSize
          )
        )
        context.setFillColor(AnnotateTextStyleRenderer.backdropColor(for: backdrop, textColor: textColor).cgColor)
        context.fillPath()
        context.restoreGState()
      }
    }

    context.saveGState()
    if properties.textStyle.isOutlined {
      // Outlined: сначала белый контур glyph, затем заливка поверх него, чтобы
      // обводка шла только наружу. Обводка может выйти за рамку на свою ширину.
      let outset = font.pointSize * AnnotateTextStyleRenderer.outlineOutsetRatio
      context.clip(to: textBounds.insetBy(dx: -outset, dy: -outset))
      var outlineAttributes = attributes
      outlineAttributes[.strokeColor] = AnnotateTextStyleRenderer.outlineColor
      outlineAttributes[.strokeWidth] = AnnotateTextStyleRenderer.outlineStrokeWidthPercent
      context.setLineJoin(.round)
      text.draw(in: textRect, withAttributes: outlineAttributes)
    } else {
      context.clip(to: textBounds)
    }
    text.draw(in: textRect, withAttributes: attributes)
    context.restoreGState()
  }

  private func drawWatermark(_ content: String, in bounds: CGRect, properties: AnnotationProperties) {
    let resolvedText = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !resolvedText.isEmpty else { return }

    let visibleBounds = bounds.standardized
    guard visibleBounds.width > 0, visibleBounds.height > 0 else { return }

    let font = NSFontManager.shared.convert(
      AnnotateTextLayout.font(size: properties.fontSize, fontName: properties.fontName),
      toHaveTrait: .boldFontMask
    )
    let alpha = AnnotationProperties.clampedOpacity(properties.opacity)
    let text = resolvedText as NSString
    let attributes = watermarkAttributes(
      font: font,
      color: NSColor(properties.strokeColor).withAlphaComponent(alpha)
    )
    let textSize = text.size(withAttributes: attributes)

    context.saveGState()
    context.clip(to: visibleBounds)

    switch properties.watermarkStyle {
    case .single:
      drawCenteredWatermarkText(
        text,
        textSize: textSize,
        attributes: attributes,
        in: visibleBounds,
        rotationDegrees: properties.rotationDegrees
      )

    case .diagonal:
      drawCenteredWatermarkText(
        text,
        textSize: textSize,
        attributes: attributes,
        in: visibleBounds,
        rotationDegrees: properties.rotationDegrees
      )

    case .tiled:
      drawTiledWatermarkText(
        text,
        textSize: textSize,
        attributes: attributes,
        in: visibleBounds,
        rotationDegrees: properties.rotationDegrees
      )
    }

    context.restoreGState()
  }

  private func watermarkAttributes(font: NSFont, color: NSColor) -> [NSAttributedString.Key: Any] {
    let shadow = NSShadow()
    shadow.shadowBlurRadius = 1.5
    shadow.shadowOffset = .zero
    shadow.shadowColor = NSColor.black.withAlphaComponent(min(color.alphaComponent * 0.35, 0.12))

    var attributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: color,
      .kern: font.pointSize * 0.04,
    ]
    if drawsObjectShadow { attributes[.shadow] = shadow }
    return attributes
  }

  private func drawCenteredWatermarkText(
    _ text: NSString,
    textSize: CGSize,
    attributes: [NSAttributedString.Key: Any],
    in bounds: CGRect,
    rotationDegrees: CGFloat
  ) {
    context.saveGState()
    context.translateBy(x: bounds.midX, y: bounds.midY)
    context.rotate(by: rotationDegrees * .pi / 180)
    text.draw(
      at: CGPoint(x: -textSize.width / 2, y: -textSize.height / 2),
      withAttributes: attributes
    )
    context.restoreGState()
  }

  private func drawTiledWatermarkText(
    _ text: NSString,
    textSize: CGSize,
    attributes: [NSAttributedString.Key: Any],
    in bounds: CGRect,
    rotationDegrees: CGFloat
  ) {
    let span = hypot(bounds.width, bounds.height)
    let xStep = max(textSize.width + textSize.height * 2.4, 120)
    let yStep = max(textSize.height * 3.4, 72)

    context.saveGState()
    context.translateBy(x: bounds.midX, y: bounds.midY)
    context.rotate(by: rotationDegrees * .pi / 180)

    var y = -span
    while y <= span {
      var x = -span
      while x <= span {
        text.draw(at: CGPoint(x: x - textSize.width / 2, y: y - textSize.height / 2), withAttributes: attributes)
        x += xStep
      }
      y += yStep
    }

    context.restoreGState()
  }

  private func drawEmbeddedImage(assetId: UUID, annotationId: UUID, in bounds: CGRect) {
    let isInteractive = interactiveEmbeddedImageAnnotationId == annotationId
    let interpolationQuality: CGInterpolationQuality = isInteractive ? .low : .high

    if let cgImage = embeddedCGImageProvider?(assetId) {
      context.saveGState()
      context.interpolationQuality = interpolationQuality
      context.draw(cgImage, in: bounds)
      context.restoreGState()
      return
    }

    guard let image = embeddedImageProvider?(assetId) else { return }
    let sourceRect = CGRect(origin: .zero, size: image.size)
    context.saveGState()
    context.interpolationQuality = interpolationQuality
    image.draw(
      in: bounds,
      from: sourceRect,
      operation: .sourceOver,
      fraction: 1.0
    )
    context.restoreGState()
  }

  private func makeRect(from start: CGPoint, to end: CGPoint) -> CGRect {
    CGRect(
      x: min(start.x, end.x),
      y: min(start.y, end.y),
      width: abs(end.x - start.x),
      height: abs(end.y - start.y)
    )
  }

  private func drawBlur(bounds: CGRect, annotationId: UUID, blurType: BlurType, controlValue: CGFloat) {
    let visibleBounds = bounds.standardized
    guard visibleBounds.width > 0, visibleBounds.height > 0 else { return }

    if blurType == .blackOut {
      context.saveGState()
      context.setFillColor(NSColor.black.cgColor)
      context.fill(visibleBounds)
      context.restoreGState()
      return
    }

    guard let sourceImage else {
      if blurType == .secure {
        context.setFillColor(NSColor.black.cgColor)
        context.fill(visibleBounds)
        return
      }
      // Fallback when no source image available
      BlurEffectRenderer.drawBlurPreview(
        in: context,
        region: visibleBounds,
        strokeColor: NSColor.gray.cgColor
      )
      return
    }

    let renderBounds = alignToSourcePixelGrid(visibleBounds, sourceImage: sourceImage)
    let effectValue = blurEffectValue(for: blurType, controlValue: controlValue)
    let shouldAllowApproximateReuse = interactiveBlurAnnotationIds.contains(annotationId)

    context.saveGState()
    context.clip(to: visibleBounds)
    defer { context.restoreGState() }

    // Editor preview path: never do exact work inside draw(). A cache miss schedules
    // async refinement and returns immediately with a friendly placeholder.
    // NOTE: the export path never passes a blurCacheManager, so this main-isolated
    // cache is only touched from the interactive (main-actor) canvas.
    if let cacheManager = blurCacheManager {
      if let cachedImage = MainActor.assumeIsolated({
        cacheManager.getCachedBlur(
          for: annotationId,
          bounds: renderBounds,
          sourceImage: sourceImage,
          blurType: blurType,
          effectValue: effectValue,
          allowApproximateReuse: shouldAllowApproximateReuse,
          renderSynchronously: false,
          quality: shouldAllowApproximateReuse ? .interactive : .settled,
          resolvedSourceCGImage: sourceCGImage
        )
      }) {
        switch blurType {
        case .pixelated:
          context.saveGState()
          context.setAllowsAntialiasing(false)
          context.setShouldAntialias(false)
          context.interpolationQuality = .none
          context.draw(cachedImage, in: renderBounds)
          context.restoreGState()
        case .gaussian, .secure, .blackOut, .hexagonal, .crystallized, .pointillism, .halftone, .tape, .washi:
          context.interpolationQuality = .high
          context.draw(cachedImage, in: renderBounds)
        }
      } else {
        if blurType == .secure {
          context.setFillColor(NSColor.black.cgColor)
          context.fill(visibleBounds)
        } else {
          BlurEffectRenderer.drawBlurPlaceholder(in: context, region: visibleBounds)
        }
      }
      return
    }

    // Путь экспорта без кэша холста. Сетку Secure задаёт secureExportSalt: 0 – сетка холста, иначе своя на рендер.
    switch blurType {
    case .secure:
      if let image = sourceCGImage ?? sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
        BlurEffectRenderer.drawSecureRegion(in: context, sourceCGImage: image,
          sourceSize: sourceImage.size, sourceRegion: renderBounds, destRegion: renderBounds, effectValue: Double(effectValue),
          seed: BlurEffectRenderer.secureSeed(for: annotationId, exportSalt: secureExportSalt))
      } else {
        context.setFillColor(NSColor.black.cgColor)
        context.fill(visibleBounds)
      }
    case .blackOut:
      break
    case .pixelated:
      // Случайная выборка блоков по сиду маски, соль экспорта – как у Secure (ANN-780).
      BlurEffectRenderer.drawPixelatedRegion(
        in: context,
        sourceImage: sourceImage,
        region: renderBounds,
        pixelSize: effectValue,
        seed: BlurEffectRenderer.secureSeed(for: annotationId, exportSalt: secureExportSalt)
      )
    case .gaussian:
      BlurEffectRenderer.drawGaussianRegion(
        in: context,
        sourceImage: sourceImage,
        region: renderBounds,
        radius: Double(effectValue)
      )
    case .hexagonal:
      BlurEffectRenderer.drawHexagonalRegion(
        in: context,
        sourceImage: sourceImage,
        region: renderBounds,
        scale: Double(effectValue)
      )
    case .crystallized:
      BlurEffectRenderer.drawCrystallizedRegion(
        in: context,
        sourceImage: sourceImage,
        region: renderBounds,
        radius: Double(effectValue)
      )
    case .pointillism:
      BlurEffectRenderer.drawPointillismRegion(
        in: context,
        sourceImage: sourceImage,
        region: renderBounds,
        radius: Double(effectValue)
      )
    case .halftone:
      BlurEffectRenderer.drawHalftoneRegion(
        in: context,
        sourceImage: sourceImage,
        region: renderBounds,
        width: Double(effectValue)
      )
    case .tape:
      BlurEffectRenderer.drawTapeRegion(
        in: context,
        region: renderBounds,
        patternSpacing: effectValue
      )
    case .washi:
      BlurEffectRenderer.drawWashiRegion(
        in: context,
        region: renderBounds,
        patternSpacing: effectValue
      )
    }
  }

  private func alignToSourcePixelGrid(_ rect: CGRect, sourceImage: NSImage) -> CGRect {
    let resolvedCGImage = sourceCGImage ?? sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
    guard sourceImage.size.width > 0,
          sourceImage.size.height > 0,
          let cgImage = resolvedCGImage,
          cgImage.width > 0,
          cgImage.height > 0 else {
      return rect
    }

    let scaleX = CGFloat(cgImage.width) / sourceImage.size.width
    let scaleY = CGFloat(cgImage.height) / sourceImage.size.height
    let minX = floor(rect.minX * scaleX) / scaleX
    let maxX = ceil(rect.maxX * scaleX) / scaleX
    let minY = floor(rect.minY * scaleY) / scaleY
    let maxY = ceil(rect.maxY * scaleY) / scaleY
    let aligned = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    return aligned.standardized
  }

  /// Draw blur preview during drag operation
  func drawBlurPreview(
    start: CGPoint,
    currentPoint: CGPoint,
    strokeColor: Color,
    blurType: BlurType,
    controlValue: CGFloat
  ) {
    let rect = makeRect(from: start, to: currentPoint)
    guard rect.width > 0, rect.height > 0 else { return }

    if blurType == .secure || blurType == .blackOut {
      context.saveGState()
      context.setFillColor((blurType == .blackOut ? NSColor.black : NSColor.gray).cgColor)
      context.fill(rect)
      context.restoreGState()
      return
    }

    if (rect.width * rect.height) >= Self.livePreviewFullQualityAreaThreshold {
      BlurEffectRenderer.drawBlurPreview(
        in: context,
        region: rect,
        strokeColor: NSColor(strokeColor).cgColor
      )
      return
    }

    if let sourceImage {
      let effectValue = blurEffectValue(for: blurType, controlValue: controlValue)
      // Show preview based on selected blur type
      switch blurType {
      case .secure:
        if let image = sourceCGImage ?? sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
          BlurEffectRenderer.drawSecureRegion(in: context, sourceCGImage: image,
            sourceSize: sourceImage.size, sourceRegion: rect, destRegion: rect, effectValue: Double(effectValue))
        }
      case .blackOut:
        context.setFillColor(NSColor.black.cgColor)
        context.fill(rect)
      case .pixelated:
        // Постоянный сид: превью растущей маски не мерцает между кадрами.
        BlurEffectRenderer.drawPixelatedRegion(
          in: context,
          sourceImage: sourceImage,
          region: rect,
          pixelSize: effectValue,
          seed: 0
        )
      case .gaussian:
        BlurEffectRenderer.drawGaussianRegion(
          in: context,
          sourceImage: sourceImage,
          region: rect,
          radius: Double(effectValue)
        )
      case .hexagonal:
        BlurEffectRenderer.drawHexagonalRegion(
          in: context,
          sourceImage: sourceImage,
          region: rect,
          scale: Double(effectValue)
        )
      case .crystallized:
        BlurEffectRenderer.drawCrystallizedRegion(
          in: context,
          sourceImage: sourceImage,
          region: rect,
          radius: Double(effectValue)
        )
      case .pointillism:
        BlurEffectRenderer.drawPointillismRegion(
          in: context,
          sourceImage: sourceImage,
          region: rect,
          radius: Double(effectValue)
        )
      case .halftone:
        BlurEffectRenderer.drawHalftoneRegion(
          in: context,
          sourceImage: sourceImage,
          region: rect,
          width: Double(effectValue)
        )
      case .tape:
        BlurEffectRenderer.drawTapeRegion(
          in: context,
          region: rect,
          patternSpacing: effectValue
        )
      case .washi:
        BlurEffectRenderer.drawWashiRegion(
          in: context,
          region: rect,
          patternSpacing: effectValue
        )
      }
    }

    // Draw border indicator
    BlurEffectRenderer.drawBlurPreview(
      in: context,
      region: rect,
      strokeColor: NSColor(strokeColor).cgColor
    )
  }

  private func blurEffectValue(for blurType: BlurType, controlValue: CGFloat) -> CGFloat {
    switch blurType {
    case .secure:
      AnnotationProperties.secureBlurStrength(for: controlValue)
    case .blackOut:
      0
    case .pixelated:
      AnnotationProperties.pixelatedBlurSize(for: controlValue)
    case .gaussian:
      AnnotationProperties.gaussianBlurRadius(for: controlValue)
    case .hexagonal:
      AnnotationProperties.hexagonalScale(for: controlValue)
    case .crystallized:
      AnnotationProperties.crystallizeRadius(for: controlValue)
    case .pointillism:
      AnnotationProperties.pointillismRadius(for: controlValue)
    case .halftone:
      AnnotationProperties.halftoneWidth(for: controlValue)
    case .tape:
      AnnotationProperties.tapePatternSpacing(for: controlValue)
    case .washi:
      AnnotationProperties.washiPatternSpacing(for: controlValue)
    }
  }
}

// MARK: - AnnotationType Extension

extension AnnotationType {
  nonisolated var isHighlight: Bool {
    if case .highlight = self { return true }
    return false
  }
}
