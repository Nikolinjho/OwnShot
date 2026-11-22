//
//  AnnotationFactory.swift
//  Snapzy
//
//  Factory for creating annotation items from drawing input
//

import CoreGraphics
import SwiftUI

/// Factory for creating annotation items
enum AnnotationFactory {
  struct CreationContext {
    var properties: AnnotationProperties
    var arrowStyle: ArrowStyle
    var arrowType: ArrowType = .tapered
    var arrowBendDirection: ArrowBendDirection = .primary
    var arrowStartHead: ArrowEndpointStyle = .none
    var arrowEndHead: ArrowEndpointStyle = .arrow
    var blurType: BlurType
    var counterValue: Int
    var watermarkText: String
    var activeAnnotationBounds: CGRect
    var inverseArrowDirection = false
    var smoothDrawing = false
    var counterArrowMinimumDragDistance: CGFloat = 4
  }

  static func createAnnotation(
    tool: AnnotationToolType,
    from start: CGPoint,
    to end: CGPoint,
    path: [CGPoint],
    state: AnnotateState,
    counterArrowMinimumDragDistance: CGFloat = 4,
    optionHeld: Bool = false
  ) -> AnnotationItem? {
    createAnnotation(
      tool: tool,
      from: start,
      to: end,
      path: path,
      context: CreationContext(
        properties: state.annotationCreationProperties(for: tool),
        arrowStyle: state.arrowStyle,
        arrowType: state.arrowType,
        arrowBendDirection: state.arrowBendDirection,
        arrowStartHead: state.arrowStartHead,
        arrowEndHead: state.arrowEndHead,
        blurType: state.blurType,
        counterValue: state.nextCounterValue(),
        watermarkText: state.watermarkText,
        activeAnnotationBounds: state.activeAnnotationBounds,
        inverseArrowDirection: state.annotatePreferences.invertsArrow(optionHeld: optionHeld),
        smoothDrawing: state.annotatePreferences.smoothDrawing,
        counterArrowMinimumDragDistance: counterArrowMinimumDragDistance
      )
    )
  }

  static func createAnnotation(
    tool: AnnotationToolType,
    from start: CGPoint,
    to end: CGPoint,
    path: [CGPoint],
    context: CreationContext
  ) -> AnnotationItem? {

    var properties = context.properties
    // Arrow targets belong to individual counters, never to a tool default.
    properties.counterArrowTarget = nil

    let type: AnnotationType?

    switch tool {
    case .rectangle:
      type = .rectangle

    case .filledRectangle:
      type = .filledRectangle

    case .oval:
      type = .oval

    case .arrow:
      let initialStyle = context.arrowStyle
      let resolvedStyle: ArrowStyle
      if context.arrowBendDirection == .alternate {
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
      let arrowStart = context.inverseArrowDirection ? end : start
      let arrowEnd = context.inverseArrowDirection ? start : end
      type = .arrow(ArrowGeometry(
        start: arrowStart,
        end: arrowEnd,
        style: resolvedStyle,
        bendDirection: resolvedDirection,
        // Curved и Double после drag прямые, как у эталона (ANN-097).
        controlPoint: ArrowGeometry.creationControlPoint(start: arrowStart, end: arrowEnd, style: resolvedStyle),
        arrowType: context.arrowType,
        startHead: context.arrowStartHead,
        endHead: context.arrowEndHead
      ))

    case .line:
      type = .line(start: start, end: end)

    case .pencil:
      // Click без движения у эталона ставит точку толщиной инструмента (ANN-126):
      // путь из одной точки рендерер рисует кружком диаметром strokeWidth.
      guard let first = path.first else { return nil }
      guard path.count > 1 else {
        type = .path([first])
        break
      }
      type = .path(context.smoothDrawing ? smoothedDrawPath(path) : path)

    case .highlighter:
      guard path.count > 1 else { return nil }
      type = .highlight(normalizedHighlighterPath(path, strokeWidth: properties.strokeWidth))

    case .blur:
      type = .blur(context.blurType)

    case .spotlight:
      if abs(end.x - start.x) < 8 || abs(end.y - start.y) < 8 { return nil }
      type = .spotlight

    case .counter:
      type = .counter(context.counterValue)

    case .watermark:
      let text = context.watermarkText.trimmingCharacters(in: .whitespacesAndNewlines)
      type = .watermark(text.isEmpty ? "Snapzy" : text)

    // Measure items come from a pixel scan (`AnnotateMeasureMapper`), not from drag geometry.
    case .selection, .crop, .cutOut, .text, .measure, .mockup:
      return nil
    }

    guard let annotationType = type else { return nil }
    let bounds: CGRect
    switch annotationType {
    case .arrow(let geometry):
      bounds = geometry.bounds()
    case .counter:
      let diameter = AnnotationProperties.counterDiameter(for: properties.strokeWidth)
      bounds = CGRect(
        x: start.x - diameter / 2,
        y: start.y - diameter / 2,
        width: diameter,
        height: diameter
      )
    case .watermark:
      let drawnBounds = CGRect(
        x: min(start.x, end.x),
        y: min(start.y, end.y),
        width: abs(end.x - start.x),
        height: abs(end.y - start.y)
      )
      bounds = watermarkBounds(
        drawnBounds: drawnBounds,
        center: start,
        canvasBounds: context.activeAnnotationBounds
      )
    case .path(let points), .highlight(let points):
      bounds = pathBounds(containing: points) ?? normalizedBounds(CGRect(
        x: min(start.x, end.x),
        y: min(start.y, end.y),
        width: abs(end.x - start.x),
        height: abs(end.y - start.y)
      ))
    default:
      bounds = CGRect(
        x: min(start.x, end.x),
        y: min(start.y, end.y),
        width: abs(end.x - start.x),
        height: abs(end.y - start.y)
      )
    }
    var item = AnnotationItem(type: annotationType, bounds: bounds, properties: properties)
    if case .counter = annotationType,
       hypot(end.x - start.x, end.y - start.y) >= context.counterArrowMinimumDragDistance {
      item.properties.counterArrowTarget = item.normalizedCounterArrowTarget(end)
    }
    return item
  }

  /// Build one highlight per snapped text-line segment. The bar height is
  /// carried by `strokeWidth` (highlights render at 3× stroke width), so these
  /// stay ordinary `.highlight` items — resize, undo, persistence, and export
  /// behave exactly like a freehand highlight.
  static func createTextSnappedHighlights(
    segments: [AnnotateTextSnapSegment],
    context: CreationContext
  ) -> [AnnotationItem] {
    segments.compactMap { segment in
      var properties = context.properties
      properties.strokeWidth = segment.strokeWidth
      properties.counterArrowTarget = nil

      // Точки уже описывают скруглённый прямоугольник плашки; выпрямление
      // свободного штриха (normalizedHighlighterPath) свернуло бы его в линию.
      let points = segment.highlightPoints
      guard !points.isEmpty, let bounds = pathBounds(containing: points) else { return nil }
      return AnnotationItem(type: .highlight(points), bounds: bounds, properties: properties)
    }
  }

  // MARK: - Draw

  /// Угол от горизонтали, до которого Draw с Shift у эталона ведёт строго
  /// горизонтальную линию (ANDraw.horizontalLine: путь под ~29° ложится на 0°).
  static let straightDrawHorizontalThreshold: CGFloat = 30 * .pi / 180

  /// Draw с Shift: прямая от точки нажатия. Малый наклон ложится на горизонталь,
  /// больший – на ближайшее из 45° и 90°; длина – проекция на это направление.
  static func straightDrawPath(from start: CGPoint, to end: CGPoint) -> [CGPoint] {
    let dx = end.x - start.x
    let dy = end.y - start.y
    guard hypot(dx, dy) > 0 else { return [start] }

    let angle = atan2(abs(dy), abs(dx))
    let direction: CGVector
    if angle < straightDrawHorizontalThreshold {
      direction = CGVector(dx: dx >= 0 ? 1 : -1, dy: 0)
    } else if angle < 67.5 * .pi / 180 {
      let component = CGFloat(0.5).squareRoot()
      direction = CGVector(dx: (dx >= 0 ? 1 : -1) * component, dy: (dy >= 0 ? 1 : -1) * component)
    } else {
      direction = CGVector(dx: 0, dy: dy >= 0 ? 1 : -1)
    }
    let length = dx * direction.dx + dy * direction.dy
    return [start, CGPoint(x: start.x + direction.dx * length, y: start.y + direction.dy * length)]
  }

  /// Smooth drawing (ANN-779): изломы штриха у эталона превращаются в плавные дуги.
  /// Дрожание мыши сначала прореживается (минимальный шаг и Douglas–Peucker), затем
  /// через середины оставшихся отрезков проводятся квадратичные кривые с вершинами
  /// ломаной в роли контрольных точек. Результат – снова точки: `.path` хранит
  /// полилинию, и правка, экспорт и сохранение работают без изменений.
  static func smoothedDrawPath(_ points: [CGPoint]) -> [CGPoint] {
    guard points.count > 2 else { return points }

    let thinned = simplifiedPath(thinnedPath(points, minimumStep: 2), tolerance: 1.5)
    guard thinned.count > 2 else { return thinned }

    var result = [thinned[0]]
    var segmentStart = thinned[0]
    for index in 1 ..< (thinned.count - 1) {
      let control = thinned[index]
      let next = thinned[index + 1]
      let segmentEnd = index == thinned.count - 2
        ? next
        : CGPoint(x: (control.x + next.x) / 2, y: (control.y + next.y) / 2)
      let length = hypot(control.x - segmentStart.x, control.y - segmentStart.y)
        + hypot(segmentEnd.x - control.x, segmentEnd.y - control.y)
      let steps = min(max(Int(length / 2), 4), 64)
      for step in 1 ... steps {
        let t = CGFloat(step) / CGFloat(steps)
        let u = 1 - t
        result.append(CGPoint(
          x: u * u * segmentStart.x + 2 * u * t * control.x + t * t * segmentEnd.x,
          y: u * u * segmentStart.y + 2 * u * t * control.y + t * t * segmentEnd.y
        ))
      }
      segmentStart = segmentEnd
    }
    return result
  }

  /// Отбрасывает точки ближе `minimumStep` к предыдущей оставленной; последняя
  /// точка штриха сохраняется всегда.
  private static func thinnedPath(_ points: [CGPoint], minimumStep: CGFloat) -> [CGPoint] {
    guard let first = points.first, let last = points.last else { return points }
    var result = [first]
    for point in points.dropFirst().dropLast() {
      guard let previous = result.last,
            hypot(point.x - previous.x, point.y - previous.y) >= minimumStep else { continue }
      result.append(point)
    }
    if let previous = result.last, previous != last || result.count == 1 {
      result.append(last)
    }
    return result
  }

  /// Douglas–Peucker: оставляет вершины, отклоняющиеся от хорды больше `tolerance`,
  /// то есть сами изломы, а мелкую дрожь убирает.
  private static func simplifiedPath(_ points: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
    guard points.count > 2 else { return points }
    var keep = [Bool](repeating: false, count: points.count)
    keep[0] = true
    keep[points.count - 1] = true
    var stack = [(0, points.count - 1)]
    while let (startIndex, endIndex) = stack.popLast() {
      guard endIndex - startIndex > 1 else { continue }
      let a = points[startIndex], b = points[endIndex]
      var farthest = (index: startIndex, distance: CGFloat(0))
      for index in (startIndex + 1) ..< endIndex {
        let distance = distanceFromPoint(points[index], toSegmentFrom: a, to: b)
        if distance > farthest.distance { farthest = (index, distance) }
      }
      guard farthest.distance > tolerance else { continue }
      keep[farthest.index] = true
      stack.append((startIndex, farthest.index))
      stack.append((farthest.index, endIndex))
    }
    return points.indices.filter { keep[$0] }.map { points[$0] }
  }

  private static func distanceFromPoint(_ point: CGPoint, toSegmentFrom a: CGPoint, to b: CGPoint) -> CGFloat {
    let dx = b.x - a.x, dy = b.y - a.y
    let lengthSquared = dx * dx + dy * dy
    guard lengthSquared > 0 else { return hypot(point.x - a.x, point.y - a.y) }
    let t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared))
    return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
  }

  private static func watermarkBounds(
    drawnBounds: CGRect,
    center: CGPoint,
    canvasBounds: CGRect
  ) -> CGRect {
    guard drawnBounds.width >= 24, drawnBounds.height >= 24 else {
      let width = min(max(canvasBounds.width * 0.42, 220), max(canvasBounds.width, 1))
      let height = min(max(canvasBounds.height * 0.18, 72), max(canvasBounds.height, 1))
      let origin = CGPoint(
        x: min(max(center.x - width / 2, canvasBounds.minX), max(canvasBounds.maxX - width, canvasBounds.minX)),
        y: min(max(center.y - height / 2, canvasBounds.minY), max(canvasBounds.maxY - height, canvasBounds.minY))
      )
      return CGRect(origin: origin, size: CGSize(width: width, height: height))
    }

    return drawnBounds.standardized
  }

  private static func normalizedHighlighterPath(_ path: [CGPoint], strokeWidth: CGFloat) -> [CGPoint] {
    guard path.count > 2,
          let first = path.first,
          let last = path.last else {
      return path
    }

    let dx = last.x - first.x
    let dy = last.y - first.y
    let length = hypot(dx, dy)
    guard length >= 24, abs(dx) >= 24 else { return path }

    let angle = abs(atan2(dy, dx))
    let angleFromHorizontal = min(angle, abs(.pi - angle))
    guard angleFromHorizontal <= 10 * .pi / 180 else { return path }

    let minY = path.map(\.y).min() ?? first.y
    let maxY = path.map(\.y).max() ?? first.y
    let maximumVerticalRange = max(8, strokeWidth * 3 * 0.6)
    guard maxY - minY <= maximumVerticalRange else { return path }

    let minX = path.map(\.x).min() ?? min(first.x, last.x)
    let maxX = path.map(\.x).max() ?? max(first.x, last.x)
    guard maxX - minX >= 24 else { return path }

    let y = medianY(in: path)
    return [
      CGPoint(x: minX, y: y),
      CGPoint(x: maxX, y: y),
    ]
  }

  private static func medianY(in path: [CGPoint]) -> CGFloat {
    let values = path.map(\.y).sorted()
    guard !values.isEmpty else { return 0 }

    let midpoint = values.count / 2
    if values.count.isMultiple(of: 2) {
      return (values[midpoint - 1] + values[midpoint]) / 2
    }
    return values[midpoint]
  }

  private static func pathBounds(containing points: [CGPoint]) -> CGRect? {
    guard let first = points.first else { return nil }

    var minX = first.x
    var maxX = first.x
    var minY = first.y
    var maxY = first.y

    for point in points.dropFirst() {
      minX = min(minX, point.x)
      maxX = max(maxX, point.x)
      minY = min(minY, point.y)
      maxY = max(maxY, point.y)
    }

    return normalizedBounds(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
  }

  private static func normalizedBounds(_ rect: CGRect, minimumDimension: CGFloat = 1) -> CGRect {
    var normalized = rect.standardized

    if normalized.width < minimumDimension {
      normalized.origin.x -= (minimumDimension - normalized.width) / 2
      normalized.size.width = minimumDimension
    }

    if normalized.height < minimumDimension {
      normalized.origin.y -= (minimumDimension - normalized.height) / 2
      normalized.size.height = minimumDimension
    }

    return normalized
  }
}
