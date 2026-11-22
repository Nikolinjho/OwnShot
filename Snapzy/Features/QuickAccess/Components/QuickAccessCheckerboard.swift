//
//  QuickAccessCheckerboard.swift
//  Snapzy
//
//  Шахматка под прозрачными снимками в карточке Quick Access, нарисованная в коде
//

import SwiftUI

struct QuickAccessCheckerboard: View {
  let isDark: Bool
  var cellSize: CGFloat = QuickAccessLayout.checkerboardCellSize

  var body: some View {
    let colors = QuickAccessCheckerboardPalette.colors(isDark: isDark)
    let cellSize = cellSize
    Canvas { context, size in
      context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: colors.base)))
      let columns = Int((size.width / cellSize).rounded(.up))
      let rows = Int((size.height / cellSize).rounded(.up))
      var path = Path()
      for row in 0..<rows {
        for column in 0..<columns where QuickAccessCheckerboardPalette.isAlternate(row: row, column: column) {
          path.addRect(CGRect(x: CGFloat(column) * cellSize, y: CGFloat(row) * cellSize, width: cellSize, height: cellSize))
        }
      }
      context.fill(path, with: .color(Color(white: colors.alternate)))
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

nonisolated enum QuickAccessCheckerboardPalette {
  /// Яркость клеток для тёмной и светлой темы
  static func colors(isDark: Bool) -> (base: Double, alternate: Double) {
    isDark ? (0.16, 0.24) : (1.0, 0.88)
  }

  static func isAlternate(row: Int, column: Int) -> Bool {
    (row + column) % 2 == 1
  }
}
