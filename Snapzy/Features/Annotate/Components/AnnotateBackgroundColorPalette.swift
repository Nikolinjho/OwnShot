//
//  AnnotateBackgroundColorPalette.swift
//  Snapzy
//
//  Палитра Plain color для фона редактора: сетка 2 × 9 как в эталоне
//

import SwiftUI

/// Палитра сплошных цветов фона (ANN-535…552).
/// Первый ряд: 8 цветов и прозрачный фон (checkerboard), второй ряд: 8 светлых оттенков и свой цвет.
/// Пользовательские цвета, если есть, идут отдельными рядами ниже фиксированной сетки.
struct AnnotateBackgroundColorPalette: View {
  @Binding var selectedColor: Color?
  /// Жест в панели своего цвета: одна точка undo фона на перетаскивание.
  var onCustomColorEditingChanged: (Bool) -> Void = { _ in }
  @ObservedObject private var paletteStore = AnnotateColorPaletteStore.shared
  @State private var draftCustomColor = Color.red

  enum FixedCell: Equatable {
    case swatch(Color)
    case transparent
    case customPicker
  }

  static let columnCount = AnnotateBackgroundPanelLayout.colorColumns
  static let fixedCells = AnnotateBackgroundPalette.primaryRow.map(FixedCell.swatch)
    + [.transparent]
    + AnnotateBackgroundPalette.secondaryRow.map(FixedCell.swatch)
    + [.customPicker]

  // L10n.swift общий с другими зонами, поэтому строка объявлена здесь.
  private static let transparentTitle = String(
    localized: "annotate.background.transparent",
    defaultValue: "Transparent",
    comment: "Tooltip for the transparent cell in the Plain color background palette"
  )

  /// Эталон: кружки 24 × 24 pt, ряды вплотную, без растягивания на ширину сайдбара.
  private var columns: [GridItem] {
    AnnotateBackgroundTileGrid.colorColumns
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      LazyVGrid(columns: columns, alignment: .leading, spacing: AnnotateBackgroundPanelLayout.colorRowSpacing) {
        ForEach(Self.fixedCells.indices, id: \.self) { position in
          fixedCell(Self.fixedCells[position])
        }

        ForEach(paletteStore.customColors, id: \.self) { color in
          AnnotateColorSwatchButton(
            color: color,
            isSelected: AnnotateColorPaletteStore.colorsMatch(selectedColor, color),
            size: nil,
            onDelete: {
              paletteStore.removeColor(color)
            }
          ) {
            selectedColor = color
          }
        }
      }
    }
  }

  @ViewBuilder
  private func fixedCell(_ cell: FixedCell) -> some View {
    switch cell {
    case let .swatch(color):
      swatch(color)
    case .transparent:
      transparentSwatch
    case .customPicker:
      AnnotateCustomColorPickerControl(
        selectedColor: customColorBinding,
        draftColor: $draftCustomColor,
        swatchSize: nil,
        onEditingChanged: onCustomColorEditingChanged
      )
    }
  }

  private func swatch(_ color: Color) -> some View {
    Button {
      selectedColor = color
    } label: {
      Circle()
        .fill(color)
        .colorSwatchStyle(isSelected: AnnotateColorPaletteStore.colorsMatch(selectedColor, color))
    }
    .buttonStyle(.plain)
    .ownShotAnnotateColorName(color)
  }

  /// Ячейка прозрачного фона: шахматка вместо заливки.
  private var transparentSwatch: some View {
    let color = AnnotateBackgroundPalette.transparent
    return Button {
      selectedColor = color
    } label: {
      AnnotateCheckerboardPattern()
        .clipShape(Circle())
        .colorSwatchStyle(isSelected: isTransparentSelected)
    }
    .buttonStyle(.plain)
    .help(Self.transparentTitle)
    .accessibilityLabel(Self.transparentTitle)
  }

  private var isTransparentSelected: Bool {
    guard let selectedColor,
          let rgba = RGBAColor(color: selectedColor) else { return false }
    return rgba.alpha <= 0.001
  }

  private var customColorBinding: Binding<Color> {
    Binding(
      get: { selectedColor ?? draftCustomColor },
      set: { color in
        draftCustomColor = color
        selectedColor = color
      }
    )
  }
}

/// Шахматный узор для обозначения прозрачности.
struct AnnotateCheckerboardPattern: View {
  var cellCount: Int = 4

  var body: some View {
    Canvas { context, size in
      let cell = min(size.width, size.height) / CGFloat(max(cellCount, 1))
      context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
      for row in 0 ..< cellCount {
        for column in 0 ..< cellCount where (row + column).isMultiple(of: 2) {
          let rect = CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)
          context.fill(Path(rect), with: .color(Color(white: 0.78)))
        }
      }
    }
  }
}
