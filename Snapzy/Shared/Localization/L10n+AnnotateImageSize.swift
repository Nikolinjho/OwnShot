//
//  L10n+AnnotateImageSize.swift
//  Snapzy
//
//  Строки поповера Image Size в редакторе.
//

import Foundation

extension L10n {
  nonisolated enum AnnotateImageSize {
    static let flattenAnnotations = string(
      "annotate.image-size.flatten-annotations",
      defaultValue: "Flatten Annotations",
      comment: "Checkbox in the annotate Image Size popover that bakes annotations into the image on resize"
    )
  }
}
