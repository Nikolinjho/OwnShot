//
//  RecordingRatioGlyph.swift
//  Snapzy
//
//  Глиф выбора соотношения в панели записи, на месте recorderRatio эталона:
//  монохромный 15×15 pt, две встречные скобки кадрирования. Рисуется кодом.
//

import SwiftUI

/// Две L-образные скобки: левая верхняя открыта вниз-вправо, правая нижняя – вверх-влево.
struct RecordingRatioGlyphShape: Shape {
  /// Размер холста эталона, точки ниже заданы в нём.
  static let canvas: CGFloat = 15

  func path(in rect: CGRect) -> Path {
    let scale = min(rect.width, rect.height) / Self.canvas
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
      CGPoint(x: rect.minX + x * scale, y: rect.minY + y * scale)
    }
    var path = Path()
    // Вертикаль слева и низ первой скобки.
    path.move(to: point(3.84, 0.77))
    path.addLine(to: point(3.84, 11.14))
    path.addLine(to: point(14.23, 11.14))
    // Верх и вертикаль справа второй скобки.
    path.move(to: point(0.77, 3.86))
    path.addLine(to: point(11.16, 3.86))
    path.addLine(to: point(11.16, 14.23))
    return path
  }
}

struct RecordingRatioGlyph: View {
  static let size: CGFloat = 15

  var body: some View {
    RecordingRatioGlyphShape()
      .stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
      .frame(width: Self.size, height: Self.size)
      .accessibilityHidden(true)
  }
}
