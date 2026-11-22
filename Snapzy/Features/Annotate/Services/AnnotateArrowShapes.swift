//
//  AnnotateArrowShapes.swift
//  Snapzy
//
//  Контуры стрелок по живому замеру CleanShot X 5.0.1 (evidence/spec-064-live).
//

import CoreGraphics
import Foundation

/// Как рисуется стрелка на холсте. Стиль меню Arrow style эталона определяет вид:
/// Standard – залитый контур со скруглёнными углами, Fancy – залитый контур
/// с вогнутым наконечником, Curved и Double – линия с открытым шевроном.
nonisolated enum AnnotateArrowShapeKind: Equatable {
  /// Standard: тело расширяется от хвоста к залитому треугольному наконечнику.
  case standard
  /// Fancy: тело от острого хвоста, наконечник с отогнутыми назад «усами».
  case fancy
  /// Curved, Double и прочие классические: линия и шевроны из штрихов.
  case line
  /// Outlined – расширение OwnShot, прежний контур с белой обводкой.
  case outlined
}

/// Формулы контуров стрелок эталона. Толщина t – значение меню Thickness
/// (1, 3, 7, 10, 15, 25), длина L – хорда стрелки, все размеры в pt изображения.
///
/// Замер (spec-064-live/ref-arrows-style*.png, горизонтальные стрелки 300, 60 и 20 pt):
/// - Standard: хвост – круг диаметром (t + 5) / 3, у основания наконечника тело
///   втрое шире хвоста, внешняя полуширина наконечника 1,42t + 6,1, угол передних
///   кромок к оси atan(1 / 2,1) ≈ 25,5°. Углы скруглены обводкой толщиной хвоста.
/// - Fancy: полуширина «усов» в 1,25 раза больше, чем у Standard, ус на расстоянии
///   2,1 полуширины от острия, выемка на 1,75 полуширины, тело у выемки 0,39
///   полуширины, хвост почти острый (0,031 полуширины). Углы острые.
/// - Curved и Double: ширина линии 1 + 0,7t, плечо шеврона по нормали t + 3,5
///   и назад вдоль оси 1,05 от него (угол ≈ 44°), концы и сгиб скруглены.
/// Короткую стрелку эталон уменьшает: залитые – целиком, пока внешняя полуширина
/// Standard не станет 0,152L; у линейных множитель min(1, 0,235L / (t + 3,5))
/// уменьшает плечо шеврона и переменную часть ширины линии (1 + 0,7t·k).
nonisolated enum AnnotateArrowShapes {
  /// Тангенс угла передней кромки наконечника к оси стрелки.
  static let headEdgeSlope: CGFloat = 1 / 2.1

  /// Внешняя полуширина наконечника Standard без уменьшения.
  static func standardOuterHalfWidth(thickness t: CGFloat) -> CGFloat {
    1.42 * max(t, 0) + 6.1
  }

  /// Множитель уменьшения залитых стрелок (Standard и Fancy) для короткой хорды.
  static func filledScale(thickness t: CGFloat, chordLength: CGFloat) -> CGFloat {
    let base = standardOuterHalfWidth(thickness: t)
    guard base > 0 else { return 1 }
    return min(1, max(0, 0.152 * chordLength / base))
  }

  /// Множитель уменьшения линейных стрелок (Curved и Double) для короткой хорды.
  static func lineScale(thickness t: CGFloat, chordLength: CGFloat) -> CGFloat {
    min(1, max(0, 0.235 * chordLength / (max(t, 0) + 3.5)))
  }

  struct StandardMetrics: Equatable {
    /// Толщина скругляющей обводки и диаметр круглого хвоста.
    let outlineWidth: CGFloat
    /// Полуширина многоугольника у основания наконечника (без обводки).
    let neckHalfWidth: CGFloat
    /// Полуширина многоугольника наконечника (без обводки).
    let headHalfWidth: CGFloat
    /// Длина наконечника многоугольника от острия до основания.
    let headLength: CGFloat
  }

  static func standardMetrics(thickness t: CGFloat, chordLength: CGFloat) -> StandardMetrics {
    let k = filledScale(thickness: t, chordLength: chordLength)
    let outline = (max(t, 0) + 5) / 3 * k
    let outer = standardOuterHalfWidth(thickness: t) * k
    let head = max(outer - outline / 2, 0)
    return StandardMetrics(
      outlineWidth: outline,
      neckHalfWidth: outline,
      headHalfWidth: head,
      headLength: head / headEdgeSlope
    )
  }

  struct FancyMetrics: Equatable {
    /// Полуширина «уса» наконечника.
    let barbHalfWidth: CGFloat
    /// Расстояние от острия до уса вдоль оси.
    let barbDistance: CGFloat
    /// Расстояние от острия до выемки, где тело входит в наконечник.
    let notchDistance: CGFloat
    /// Полуширина тела у выемки.
    let neckHalfWidth: CGFloat
    /// Полуширина хвоста.
    let tailHalfWidth: CGFloat
  }

  static func fancyMetrics(thickness t: CGFloat, chordLength: CGFloat) -> FancyMetrics {
    let k = filledScale(thickness: t, chordLength: chordLength)
    let barb = 1.25 * standardOuterHalfWidth(thickness: t) * k
    return FancyMetrics(
      barbHalfWidth: barb,
      barbDistance: barb / headEdgeSlope,
      notchDistance: barb * 1.75,
      neckHalfWidth: barb * 0.39,
      tailHalfWidth: barb * 0.031
    )
  }

  struct LineMetrics: Equatable {
    /// Ширина линии и штрихов шеврона.
    let lineWidth: CGFloat
    /// Смещение конца плеча шеврона по нормали к оси.
    let armSpread: CGFloat
    /// Смещение конца плеча шеврона назад вдоль оси.
    let armBack: CGFloat
  }

  static func lineMetrics(thickness t: CGFloat, chordLength: CGFloat) -> LineMetrics {
    let thickness = max(t, 0)
    let k = lineScale(thickness: thickness, chordLength: chordLength)
    let spread = (thickness + 3.5) * k
    return LineMetrics(lineWidth: 1 + 0.7 * thickness * k, armSpread: spread, armBack: spread * 1.05)
  }
}

extension ArrowGeometry {
  /// Вид стрелки на холсте. Классическая прямая с одним наконечником в конце –
  /// Standard эталона; классическая с изгибом, двумя наконечниками или кругом –
  /// линейная (Curved, Double и расширения OwnShot).
  var shapeKind: AnnotateArrowShapeKind {
    switch arrowType {
    case .tapered: return .fancy
    case .outlined: return .outlined
    case .classic:
      if style == .straight, startHead == .none, endHead == .arrow { return .standard }
      return .line
    }
  }

  /// Длина хорды start–end.
  var chordLength: CGFloat {
    hypot(end.x - start.x, end.y - start.y)
  }

  /// Точки осевой линии с длиной дуги от начала. Для кривой – выборка Безье.
  private func centerline(steps: Int = 48) -> [(point: CGPoint, distance: CGFloat)] {
    var result: [(CGPoint, CGFloat)] = []
    let points: [CGPoint]
    if style != .straight, let control = resolvedControlPoint {
      points = (0...steps).map { index in
        let t = CGFloat(index) / CGFloat(steps)
        let u = 1 - t
        return CGPoint(
          x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
          y: u * u * start.y + 2 * u * t * control.y + t * t * end.y
        )
      }
    } else {
      points = [start, end]
    }
    var distance: CGFloat = 0
    for (index, point) in points.enumerated() {
      if index > 0 {
        distance += hypot(point.x - points[index - 1].x, point.y - points[index - 1].y)
      }
      result.append((point, distance))
    }
    return result
  }

  /// Единичная касательная в конце, направленная к острию.
  private var endDirection: CGPoint {
    let angle = tangentAngleAtEnd()
    return CGPoint(x: cos(angle), y: sin(angle))
  }

  /// Замкнутый контур тела от хвоста до основания наконечника и наконечника.
  /// `halfWidth(progress)` – полуширина тела, progress 0 у хвоста и 1 у основания.
  private func filledOutline(
    neckDistanceFromTip: CGFloat,
    halfWidth: (CGFloat) -> CGFloat,
    headPoints: (_ tip: CGPoint, _ along: CGPoint, _ normal: CGPoint) -> (left: [CGPoint], right: [CGPoint])
  ) -> CGPath {
    let path = CGMutablePath()
    let samples = centerline()
    guard let total = samples.last?.distance, total > 0.5 else { return path }
    let along = endDirection
    let normal = CGPoint(x: -along.y, y: along.x)
    let neckDistance = max(total - neckDistanceFromTip, 0)

    // Точки тела до основания наконечника, последняя – ровно на основании.
    var body: [(point: CGPoint, tangent: CGPoint, progress: CGFloat)] = []
    for index in samples.indices {
      let sample = samples[index]
      guard sample.distance < neckDistance else { break }
      let next = samples[min(index + 1, samples.count - 1)].point
      let previous = samples[max(index - 1, 0)].point
      var tangent = CGPoint(x: next.x - previous.x, y: next.y - previous.y)
      let length = hypot(tangent.x, tangent.y)
      tangent = length > 0.0001 ? CGPoint(x: tangent.x / length, y: tangent.y / length) : along
      body.append((sample.point, tangent, neckDistance > 0 ? sample.distance / neckDistance : 1))
    }
    let neckPoint = CGPoint(x: end.x - along.x * neckDistanceFromTip, y: end.y - along.y * neckDistanceFromTip)
    if style != .straight, let neckSample = samples.first(where: { $0.distance >= neckDistance }) {
      // На кривой основание лежит на дуге, наконечник ориентирован по касательной в конце.
      body.append((neckSample.point, along, 1))
    } else {
      body.append((neckPoint, along, 1))
    }

    let head = headPoints(end, along, normal)
    func offset(_ entry: (point: CGPoint, tangent: CGPoint, progress: CGFloat), _ sign: CGFloat) -> CGPoint {
      let n = CGPoint(x: -entry.tangent.y, y: entry.tangent.x)
      let w = halfWidth(entry.progress) * sign
      return CGPoint(x: entry.point.x + n.x * w, y: entry.point.y + n.y * w)
    }

    path.move(to: end)
    for point in head.left { path.addLine(to: point) }
    for entry in body.reversed() { path.addLine(to: offset(entry, 1)) }
    for entry in body { path.addLine(to: offset(entry, -1)) }
    for point in head.right.reversed() { path.addLine(to: point) }
    path.closeSubpath()
    return path
  }

  /// Многоугольник Standard без скругляющей обводки. Рисуется заливкой и обводкой
  /// толщиной `outlineWidth` с круглыми сгибами – так получаются круглый хвост
  /// и скруглённые углы наконечника эталона.
  func standardArrowPolygon(strokeWidth: CGFloat) -> (path: CGPath, outlineWidth: CGFloat) {
    let metrics = AnnotateArrowShapes.standardMetrics(thickness: strokeWidth, chordLength: chordLength)
    let path = filledOutline(
      neckDistanceFromTip: metrics.headLength,
      halfWidth: { metrics.neckHalfWidth * $0 },
      headPoints: { tip, along, normal in
        let base = CGPoint(x: tip.x - along.x * metrics.headLength, y: tip.y - along.y * metrics.headLength)
        let left = CGPoint(x: base.x + normal.x * metrics.headHalfWidth, y: base.y + normal.y * metrics.headHalfWidth)
        let right = CGPoint(x: base.x - normal.x * metrics.headHalfWidth, y: base.y - normal.y * metrics.headHalfWidth)
        return ([left], [right])
      }
    )
    return (path, metrics.outlineWidth)
  }

  /// Видимый контур Standard: многоугольник вместе со скругляющей обводкой.
  func standardArrowOutline(strokeWidth: CGFloat) -> CGPath {
    let polygon = standardArrowPolygon(strokeWidth: strokeWidth)
    let outline = CGMutablePath()
    outline.addPath(polygon.path)
    guard polygon.outlineWidth > 0 else { return outline }
    outline.addPath(polygon.path.copy(
      strokingWithWidth: polygon.outlineWidth,
      lineCap: .round,
      lineJoin: .round,
      miterLimit: 10
    ))
    return outline
  }

  /// Контур Fancy: острое начало, тело расширяется к выемке, «усы» отогнуты назад.
  func fancyArrowPath(strokeWidth: CGFloat) -> CGPath {
    let metrics = AnnotateArrowShapes.fancyMetrics(thickness: strokeWidth, chordLength: chordLength)
    return filledOutline(
      neckDistanceFromTip: metrics.notchDistance,
      halfWidth: { metrics.tailHalfWidth + (metrics.neckHalfWidth - metrics.tailHalfWidth) * $0 },
      headPoints: { tip, along, normal in
        func point(back: CGFloat, side: CGFloat) -> CGPoint {
          CGPoint(x: tip.x - along.x * back + normal.x * side, y: tip.y - along.y * back + normal.y * side)
        }
        let left = [point(back: metrics.barbDistance, side: metrics.barbHalfWidth),
                    point(back: metrics.notchDistance, side: metrics.neckHalfWidth)]
        let right = [point(back: metrics.barbDistance, side: -metrics.barbHalfWidth),
                     point(back: metrics.notchDistance, side: -metrics.neckHalfWidth)]
        return (left, right)
      }
    )
  }

  /// Шеврон линейной стрелки с острием в `tip`: плечо – сгиб – плечо.
  /// `outwardAngle` направлен от тела стрелки наружу.
  static func lineChevronPath(tip: CGPoint, outwardAngle angle: CGFloat, metrics: AnnotateArrowShapes.LineMetrics) -> CGPath {
    let along = CGPoint(x: cos(angle), y: sin(angle))
    let normal = CGPoint(x: -along.y, y: along.x)
    let path = CGMutablePath()
    path.move(to: CGPoint(
      x: tip.x - along.x * metrics.armBack + normal.x * metrics.armSpread,
      y: tip.y - along.y * metrics.armBack + normal.y * metrics.armSpread
    ))
    path.addLine(to: tip)
    path.addLine(to: CGPoint(
      x: tip.x - along.x * metrics.armBack - normal.x * metrics.armSpread,
      y: tip.y - along.y * metrics.armBack - normal.y * metrics.armSpread
    ))
    return path
  }

  /// Видимый контур стрелки для попадания курсором. Outlined не входит:
  /// у него прежний контур `taperedArrowPath`.
  func visibleOutline(strokeWidth: CGFloat) -> CGPath? {
    switch shapeKind {
    case .standard:
      return standardArrowOutline(strokeWidth: strokeWidth)
    case .fancy:
      return fancyArrowPath(strokeWidth: strokeWidth)
    case .outlined:
      return taperedArrowPath(strokeWidth: strokeWidth)
    case .line:
      return nil
    }
  }
}

extension ArrowGeometry {
  /// Ручка изгиба новой стрелки. Curved и Double у эталона после простого drag
  /// прямые, изгиб задаёт только ручка, поэтому она стоит в середине хорды.
  static func creationControlPoint(start: CGPoint, end: CGPoint, style: ArrowStyle) -> CGPoint? {
    guard style != .straight else { return nil }
    return CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
  }
}
