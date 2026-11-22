//
//  AnnotateTextSnapping.swift
//  Snapzy
//
//  Pure snap math: turn a highlighter drag into straight bars aligned to the
//  detected text lines underneath it (AnnotateTextLineProfile). Bottom-left
//  origin image points, the same space annotations are stored in.
//

import CoreGraphics
import Foundation

/// One snapped highlighter bar, expressed as the rect it paints.
///
/// Плашка эталона – скруглённый прямоугольник с небольшим радиусом
/// (b5-highlighter-snap-ref-top-own-bottom.png), а не капсула. Маркер хранит
/// полилинию со скруглёнными концами, поэтому плашка описывается обходом
/// контура, вдавленного на радиус, и змейкой по середине: штрих толщиной в два
/// радиуса закрывает весь прямоугольник, а углы получают радиус `cornerRadius`.
nonisolated struct AnnotateTextSnapSegment: Equatable {
  let rect: CGRect

  /// Радиус углов относительно высоты плашки: у эталона ≈6 pt при высоте 41 pt.
  static let cornerRadiusRatio: CGFloat = 0.15

  var cornerRadius: CGFloat {
    let radius = max(rect.height * Self.cornerRadiusRatio, 0.25)
    return min(radius, rect.width / 2, rect.height / 2)
  }

  /// Highlights render as a polyline stroked at `strokeWidth * 3`; the stroke
  /// spans two corner radii.
  var strokeWidth: CGFloat {
    max(cornerRadius * 2 / 3, 0.5 / 3)
  }

  /// Polyline of the stored highlight. Stroked at `strokeWidth * 3` with round
  /// caps and joins it paints exactly `rect` with corners of `cornerRadius`.
  var highlightPoints: [CGPoint] {
    let radius = cornerRadius
    let inner = rect.insetBy(dx: radius, dy: radius)
    guard !inner.isNull, inner.width > 0.0001, inner.height > 0.0001 else {
      let inset = min(rect.height / 2, rect.width / 2)
      return [
        CGPoint(x: rect.minX + inset, y: rect.midY),
        CGPoint(x: rect.maxX - inset, y: rect.midY)
      ]
    }

    // Контур закрывает полосу шириной 2r вдоль края и даёт скруглённые углы.
    var points = [
      CGPoint(x: inner.minX, y: inner.minY),
      CGPoint(x: inner.maxX, y: inner.minY),
      CGPoint(x: inner.maxX, y: inner.maxY),
      CGPoint(x: inner.minX, y: inner.maxY),
      CGPoint(x: inner.minX, y: inner.minY)
    ]
    // Середина: строки с шагом меньше 2r, чтобы полосы перекрывались без щелей.
    let rows = Int((inner.height / (radius * 1.9)).rounded(.up))
    if rows > 1 {
      let step = inner.height / CGFloat(rows)
      var atLeft = true
      for row in 1 ..< rows {
        let y = inner.minY + step * CGFloat(row)
        let fromX = atLeft ? inner.minX : inner.maxX
        let toX = atLeft ? inner.maxX : inner.minX
        points.append(CGPoint(x: fromX, y: y))
        points.append(CGPoint(x: toX, y: y))
        atLeft.toggle()
      }
    }
    return points
  }
}

enum AnnotateTextSnapping {
  /// Bar height relative to the detected line height — a little padding reads
  /// as a marker stroke rather than a tight underline box.
  /// Эталон: строка с глифами высотой 27 pt даёт плашку 41 pt (поля ≈7 pt сверху и снизу).
  static let defaultHeightScale: CGFloat = 1.5
  /// Поле плашки слева и справа от текста относительно высоты строки:
  /// у эталона ≈11 pt у строки 27 pt и ≈6 pt у мелкой строки.
  static let horizontalPaddingRatio: CGFloat = 0.4
  /// Насколько дальше конца строки может уйти правый край вслед за концом штриха
  /// (в высотах строки): эталон тянет плашку мелкой строки до конца штриха.
  static let trailingOvershootRatio: CGFloat = 2

  /// Drags shorter than this stay freehand; they are taps or nudges, not
  /// highlights over a run of text.
  private static let minimumDragWidth: CGFloat = 12
  /// Bars narrower than this are visual noise.
  private static let minimumSegmentWidth: CGFloat = 4
  /// Share of the drag path that must stay inside the candidate lines' band
  /// for the gesture to read as "highlighting this text".
  private static let requiredPathCoverage: CGFloat = 0.7

  /// Resolve a highlighter drag into snapped bars, or `[]` when the gesture
  /// should stay freehand.
  ///
  /// - Parameters:
  ///   - start: drag origin, image points.
  ///   - current: current pointer position, image points.
  ///   - path: sampled drag path, image points (shakiness lives here).
  ///   - profile: detected text lines, ordered top → bottom.
  ///   - pointerTolerance: pointer slack in image points (derived from zoom).
  ///   - heightScale: bar height relative to the detected line height.
  static func resolve(
    start: CGPoint,
    current: CGPoint,
    path: [CGPoint],
    profile: AnnotateTextLineProfile,
    pointerTolerance: CGFloat,
    heightScale: CGFloat = defaultHeightScale
  ) -> [AnnotateTextSnapSegment] {
    guard !profile.isEmpty,
          abs(current.x - start.x) >= minimumDragWidth else { return [] }

    let lines = profile.lines
    guard let anchorIndex = lineIndex(near: start, in: lines, pointerTolerance: pointerTolerance) else {
      return []
    }
    let focusIndex = lineIndex(near: current, in: lines, pointerTolerance: pointerTolerance) ?? anchorIndex

    guard pathStaysWithinBand(
      path + [current],
      lines: [lines[anchorIndex], lines[focusIndex]],
      pointerTolerance: pointerTolerance
    ) else { return [] }

    let chain = connectedChain(from: anchorIndex, to: focusIndex, in: lines)
    guard let firstIndex = chain.first, let lastIndex = chain.last else { return [] }

    // The chain is in document order; the drag may run either way through it.
    let isForward = anchorIndex <= focusIndex
    let leadPoint = isForward ? start : current
    let trailPoint = isForward ? current : start

    // One height for the whole drag: Vision line boxes grow with descenders, so
    // per-line heights would make a multi-line sweep look ragged.
    let lineHeight = medianHeight(of: chain, in: lines)
    let height = max(lineHeight * heightScale, 1)
    // Поля тоже общие для всех строк, чтобы края плашек шли ровно.
    let padding = lineHeight * horizontalPaddingRatio

    var segments: [AnnotateTextSnapSegment] = []
    for index in chain {
      let line = lines[index]
      let isFirst = index == firstIndex
      let isLast = index == lastIndex

      var minX = isFirst ? snappedX(leadPoint.x, in: line, pointerTolerance: pointerTolerance) : line.bounds.minX
      var maxX = isLast ? snappedX(trailPoint.x, in: line, pointerTolerance: pointerTolerance) : line.bounds.maxX
      if isFirst, isLast, minX > maxX {
        swap(&minX, &maxX)
      }
      guard maxX - minX >= minimumSegmentWidth else { continue }

      // Штрих, ушедший за конец строки, тянет правый край за собой, как у эталона.
      let rightmostPointer = isFirst ? max(leadPoint.x, trailPoint.x) : trailPoint.x
      if isLast, rightmostPointer > line.bounds.maxX, maxX >= line.bounds.maxX {
        maxX = min(rightmostPointer, line.bounds.maxX + line.bounds.height * trailingOvershootRatio)
      }

      segments.append(AnnotateTextSnapSegment(rect: CGRect(
        x: minX - padding,
        y: line.bounds.midY - height / 2,
        width: maxX - minX + padding * 2,
        height: height
      )))
    }

    return segments
  }

  // MARK: - Line matching

  /// Index of the line the point sits on (or closest to within slack), or nil.
  /// Lines whose horizontal extent covers the point win over merely nearby ones,
  /// so a pointer in the gutter never steals a neighbouring column's line.
  private static func lineIndex(
    near point: CGPoint,
    in lines: [AnnotateTextLine],
    pointerTolerance: CGFloat
  ) -> Int? {
    var best: (index: Int, covered: Bool, distance: CGFloat)?

    for (index, line) in lines.enumerated() {
      let slack = verticalSlack(for: line, pointerTolerance: pointerTolerance)
      guard point.y >= line.bounds.minY - slack, point.y <= line.bounds.maxY + slack else { continue }

      let covered = point.x >= line.bounds.minX - pointerTolerance
        && point.x <= line.bounds.maxX + pointerTolerance
      let distance = abs(point.y - line.bounds.midY)

      if let current = best {
        if current.covered && !covered { continue }
        if covered == current.covered, distance >= current.distance { continue }
      }
      best = (index, covered, distance)
    }

    return best?.index
  }

  /// Lines are walked outward from the anchor toward the focus, stopping as soon
  /// as two neighbours stop looking like consecutive lines of one text block —
  /// that keeps a downward drag from spilling into another column or section.
  private static func connectedChain(from anchor: Int, to focus: Int, in lines: [AnnotateTextLine]) -> [Int] {
    guard anchor != focus else { return [anchor] }

    let step = focus > anchor ? 1 : -1
    var chain = [anchor]
    var index = anchor

    while index != focus {
      let next = index + step
      guard areConsecutiveLines(lines[index], lines[next]) else { break }
      chain.append(next)
      index = next
    }

    return chain.sorted()
  }

  private static func medianHeight(of chain: [Int], in lines: [AnnotateTextLine]) -> CGFloat {
    let heights = chain.map { lines[$0].bounds.height }.sorted()
    guard !heights.isEmpty else { return 0 }

    let midpoint = heights.count / 2
    if heights.count.isMultiple(of: 2) {
      return (heights[midpoint - 1] + heights[midpoint]) / 2
    }
    return heights[midpoint]
  }

  private static func areConsecutiveLines(_ lhs: AnnotateTextLine, _ rhs: AnnotateTextLine) -> Bool {
    let horizontalOverlap = min(lhs.bounds.maxX, rhs.bounds.maxX) - max(lhs.bounds.minX, rhs.bounds.minX)
    guard horizontalOverlap > 0 else { return false }

    let verticalGap = max(0, max(lhs.bounds.minY, rhs.bounds.minY) - min(lhs.bounds.maxY, rhs.bounds.maxY))
    return verticalGap <= max(lhs.bounds.height, rhs.bounds.height) * 1.5
  }

  /// A shaky drag wobbles around the line; a deliberate freehand scribble leaves
  /// it. Sampling the whole path (not just its endpoints) separates the two.
  private static func pathStaysWithinBand(
    _ path: [CGPoint],
    lines: [AnnotateTextLine],
    pointerTolerance: CGFloat
  ) -> Bool {
    guard !path.isEmpty else { return true }

    var band = lines.reduce(CGRect.null) { partial, line in
      partial.union(line.bounds.insetBy(dx: 0, dy: -verticalSlack(for: line, pointerTolerance: pointerTolerance)))
    }
    guard !band.isNull else { return false }
    band = band.standardized

    let inBand = path.reduce(into: 0) { count, point in
      if point.y >= band.minY, point.y <= band.maxY { count += 1 }
    }
    return CGFloat(inBand) >= CGFloat(path.count) * requiredPathCoverage
  }

  private static func verticalSlack(for line: AnnotateTextLine, pointerTolerance: CGFloat) -> CGFloat {
    max(pointerTolerance, line.bounds.height * 0.6)
  }

  // MARK: - Horizontal snapping

  /// Nearest word edge within tolerance, otherwise the pointer clamped to the line.
  private static func snappedX(
    _ x: CGFloat,
    in line: AnnotateTextLine,
    pointerTolerance: CGFloat
  ) -> CGFloat {
    let clamped = max(line.bounds.minX, min(x, line.bounds.maxX))
    let tolerance = max(pointerTolerance, line.bounds.height * 0.75)

    var best: (edge: CGFloat, distance: CGFloat)?
    for edge in line.wordEdges {
      let distance = abs(edge - clamped)
      guard distance <= tolerance else { continue }
      if let current = best, distance >= current.distance { continue }
      best = (edge, distance)
    }

    return best?.edge ?? clamped
  }
}
