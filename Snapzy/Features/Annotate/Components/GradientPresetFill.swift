//
//  GradientPresetFill.swift
//  Snapzy
//
//  Заливка градиентом фона для плиток сайдбара и превью холста
//

import SwiftUI

/// Рисует растр GradientPresetRasterizer как aspect fill. Ту же картинку рисует экспорт,
/// поэтому плитка, холст и сохранённый файл показывают один градиент.
struct GradientPresetFill: View {
  let preset: GradientPreset

  var body: some View {
    Color.clear
      .overlay {
        if let image = GradientPresetRasterizer.image(for: preset) {
          Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fill)
        }
      }
      .clipped()
      .contentShape(Rectangle())
  }
}
