//
//  L10n+AnnotateColorPicker.swift
//  Snapzy
//
//  Строки собственной панели Custom Color в редакторе: поля цвета,
//  ячейки «My Colors», предупреждение о лимите и откреплённая панель.
//

import Foundation

extension L10n {
  nonisolated enum AnnotateColorPicker {
    static let addToMyColors = string(
      "annotate.color-picker.add-to-my-colors",
      defaultValue: "Add to My Colors",
      comment: "Button in the annotate custom color editor that saves the current color"
    )
    static let updateWithCurrentColor = string(
      "annotate.color-picker.update-with-current-color",
      defaultValue: "Update with Current Color",
      comment: "Context menu item of a saved color cell that replaces it with the current color"
    )
    static let delete = string(
      "annotate.color-picker.delete",
      defaultValue: "Delete",
      comment: "Context menu item and hover button that deletes a saved color"
    )
    static let limitTitle = string(
      "annotate.color-picker.limit-title",
      defaultValue: "Can't add new color",
      comment: "Alert title shown when all saved color cells are occupied"
    )
    static let limitMessage = string(
      "annotate.color-picker.limit-message",
      defaultValue: "You’ve reached the limit of saved colors. To add a new one, please delete an existing color first.",
      comment: "Alert message shown when all saved color cells are occupied"
    )
    static let ok = string(
      "annotate.color-picker.ok",
      defaultValue: "OK",
      comment: "Button that dismisses the saved colors limit alert"
    )
    static let hex = string(
      "annotate.color-picker.hex",
      defaultValue: "Hex",
      comment: "Label under the hexadecimal color field"
    )
    static let red = string(
      "annotate.color-picker.red",
      defaultValue: "R",
      comment: "Short label under the red component field"
    )
    static let green = string(
      "annotate.color-picker.green",
      defaultValue: "G",
      comment: "Short label under the green component field"
    )
    static let blue = string(
      "annotate.color-picker.blue",
      defaultValue: "B",
      comment: "Short label under the blue component field"
    )
    static let alpha = string(
      "annotate.color-picker.alpha",
      defaultValue: "Alpha",
      comment: "Label under the opacity field and accessibility name of the opacity slider"
    )
    static let hue = string(
      "annotate.color-picker.hue",
      defaultValue: "Hue",
      comment: "Accessibility name of the hue slider"
    )
    static let saturationBrightness = string(
      "annotate.color-picker.saturation-brightness",
      defaultValue: "Saturation and Brightness",
      comment: "Accessibility name of the saturation and brightness field"
    )
    static let pickFromScreen = string(
      "annotate.color-picker.pick-from-screen",
      defaultValue: "Pick Color from Screen",
      comment: "Tooltip of the eyedropper button"
    )
    static let showEditor = string(
      "annotate.color-picker.show-editor",
      defaultValue: "Show Color Editor",
      comment: "Tooltip of the button that expands the custom color editor"
    )
    static let hideEditor = string(
      "annotate.color-picker.hide-editor",
      defaultValue: "Hide Color Editor",
      comment: "Tooltip of the button that collapses the custom color editor"
    )
    static let detach = string(
      "annotate.color-picker.detach",
      defaultValue: "Drag to Detach",
      comment: "Tooltip of the handle at the bottom of the color palette"
    )
    static let close = string(
      "annotate.color-picker.close",
      defaultValue: "Close",
      comment: "Close button of the detached color palette"
    )
    static let emptySlot = string(
      "annotate.color-picker.empty-slot",
      defaultValue: "Empty Color Slot",
      comment: "Accessibility name of an empty saved color cell"
    )
    static let savedColor = string(
      "annotate.color-picker.saved-color",
      defaultValue: "Saved Color",
      comment: "Accessibility name of an occupied saved color cell"
    )
    static let currentColor = string(
      "annotate.color-picker.current-color",
      defaultValue: "Current Color",
      comment: "Accessibility name of the current color preview"
    )
  }
}
