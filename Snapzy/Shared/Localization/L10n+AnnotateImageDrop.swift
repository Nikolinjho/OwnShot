//
//  L10n+AnnotateImageDrop.swift
//  Snapzy
//
//  Строки редактора волны 060: зоны размещения перетащенного изображения
//  и собственная пипетка-лупа.
//

import Foundation

extension L10n {
  nonisolated enum AnnotateImageDrop {
    static let placeOnTop = string(
      "annotate.image-drop.place-on-top",
      defaultValue: "Place on the top",
      comment: "Drop zone label: the dragged image is placed above the canvas content"
    )
    static let placeOnBottom = string(
      "annotate.image-drop.place-on-bottom",
      defaultValue: "Place on the bottom",
      comment: "Drop zone label: the dragged image is placed below the canvas content"
    )
    static let placeOnLeft = string(
      "annotate.image-drop.place-on-left",
      defaultValue: "Place on the left",
      comment: "Drop zone label: the dragged image is placed left of the canvas content"
    )
    static let placeOnRight = string(
      "annotate.image-drop.place-on-right",
      defaultValue: "Place on the right",
      comment: "Drop zone label: the dragged image is placed right of the canvas content"
    )
  }

  nonisolated enum AnnotateScreenColorPicker {
    static let loupe = string(
      "annotate.screen-color-picker.loupe",
      defaultValue: "Color Picker",
      comment: "Accessibility name of the magnifier that follows the pointer while picking a color from the screen"
    )
  }
}
