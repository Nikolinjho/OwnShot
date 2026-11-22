//
//  AnnotateImageDropEdge.swift
//  Snapzy
//
//  Сторона холста, к которой приставляется перетащенное изображение.
//  Повторяет ANDropZoneView.Edge эталона: top, bottom, left, right и
//  подписи «Place on the …».
//

import CoreGraphics
import Foundation

nonisolated enum AnnotateImageDropEdge: String, CaseIterable, Equatable {
  case top
  case bottom
  case left
  case right

  /// Ближайшая к курсору сторона области перетаскивания. Координаты локальные,
  /// начало слева сверху, как у DropInfo.location в SwiftUI.
  static func closest(to point: CGPoint, in size: CGSize) -> AnnotateImageDropEdge? {
    guard size.width > 0, size.height > 0 else { return nil }
    let distances: [(AnnotateImageDropEdge, CGFloat)] = [
      (.top, point.y),
      (.bottom, size.height - point.y),
      (.left, point.x),
      (.right, size.width - point.x),
    ]
    // При равенстве выигрывает первая сторона списка, результат детерминирован.
    return distances.min { $0.1 < $1.1 }?.0
  }

  /// Горизонтальные стороны дают склейку в ряд, вертикальные – в столбец.
  var combineDirection: CombineImagesDirection {
    switch self {
    case .left, .right: return .horizontal
    case .top, .bottom: return .vertical
    }
  }

  /// Новое изображение встаёт первым в порядке склейки. Ряд идёт слева направо,
  /// столбец – снизу вверх (y координат изображения растёт вверх), поэтому
  /// первыми становятся левая и нижняя стороны.
  var placesFirstInStitchOrder: Bool {
    self == .left || self == .bottom
  }

  /// Рамка нового изображения рядом с содержимым холста: по высоте содержимого
  /// для левой и правой стороны, по ширине – для верхней и нижней. Выравнивание
  /// по началу оси, дальше его меняют штатные контролы Combine.
  func placementBounds(imageSize: CGSize, contentBounds: CGRect, gap: CGFloat) -> CGRect {
    let safeGap = max(0, gap)
    guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
    switch self {
    case .left, .right:
      let height = max(contentBounds.height, 1)
      let width = imageSize.width * height / imageSize.height
      let x = self == .left
        ? contentBounds.minX - safeGap - width
        : contentBounds.maxX + safeGap
      return CGRect(x: x, y: contentBounds.minY, width: width, height: height)
    case .top, .bottom:
      let width = max(contentBounds.width, 1)
      let height = imageSize.height * width / imageSize.width
      // В координатах изображения начало слева снизу: top – большие y.
      let y = self == .top
        ? contentBounds.maxY + safeGap
        : contentBounds.minY - safeGap - height
      return CGRect(x: contentBounds.minX, y: y, width: width, height: height)
    }
  }

  var title: String {
    switch self {
    case .top: return L10n.AnnotateImageDrop.placeOnTop
    case .bottom: return L10n.AnnotateImageDrop.placeOnBottom
    case .left: return L10n.AnnotateImageDrop.placeOnLeft
    case .right: return L10n.AnnotateImageDrop.placeOnRight
    }
  }

  /// SF Symbol стрелки к выбранной стороне (ассеты эталона не используются).
  var arrowSymbolName: String {
    switch self {
    case .top: return "arrow.up"
    case .bottom: return "arrow.down"
    case .left: return "arrow.left"
    case .right: return "arrow.right"
    }
  }
}
