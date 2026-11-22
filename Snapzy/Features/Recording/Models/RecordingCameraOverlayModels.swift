//
//  RecordingCameraOverlayModels.swift
//  Snapzy
//
//  Shape, size, and layout models for the recording camera overlay.
//

import AppKit
import Foundation
import QuartzCore

/// Порядок меню как у эталона: circle, square, rectangle, vertical.
nonisolated enum RecordingCameraShape: String, CaseIterable, Identifiable, Sendable {
  case circle
  case square
  case rectangle
  /// Вертикальный кадр 9:16, четвёртая форма эталона.
  case vertical

  var id: String {
    rawValue
  }

  var displayName: String {
    switch self {
    case .rectangle:
      L10n.Camera.shapeRectangle
    case .square:
      L10n.Camera.shapeSquare
    case .circle:
      L10n.Camera.shapeCircle
    case .vertical:
      L10n.RecordingParity.cameraShapeVertical
    }
  }

  var systemImage: String {
    switch self {
    case .rectangle:
      "rectangle"
    case .square:
      "square"
    case .circle:
      "circle"
    case .vertical:
      "rectangle.portrait"
    }
  }

  var aspectRatio: CGFloat? {
    switch self {
    case .rectangle:
      16.0 / 9.0
    case .vertical:
      9.0 / 16.0
    case .square, .circle:
      1.0
    }
  }

  func cornerRadius(for size: CGSize) -> CGFloat {
    switch self {
    case .rectangle, .vertical:
      18
    case .square:
      24
    case .circle:
      min(size.width, size.height) / 2.0
    }
  }

  var cornerCurve: CALayerCornerCurve {
    switch self {
    case .rectangle, .vertical, .square:
      .continuous
    case .circle:
      .circular
    }
  }
}

nonisolated enum RecordingCameraSize: String, CaseIterable, Identifiable, Sendable {
  case small
  case medium
  case large
  /// Четвёртый размер эталона.
  case huge

  var id: String {
    rawValue
  }

  var displayName: String {
    switch self {
    case .small:
      L10n.Camera.sizeSmall
    case .medium:
      L10n.Camera.sizeMedium
    case .large:
      L10n.Camera.sizeLarge
    case .huge:
      L10n.RecordingParity.cameraSizeHuge
    }
  }

  /// Высота вертикального кадра 9:16 для каждого размера.
  private var verticalHeight: CGFloat {
    switch self {
    case .small: 200
    case .medium: 260
    case .large: 320
    case .huge: 440
    }
  }

  func baseSize(for shape: RecordingCameraShape) -> CGSize {
    switch shape {
    case .rectangle:
      switch self {
      case .small:
        CGSize(width: 180, height: 180 / (16.0 / 9.0))
      case .medium:
        CGSize(width: 240, height: 240 / (16.0 / 9.0))
      case .large:
        CGSize(width: 300, height: 300 / (16.0 / 9.0))
      case .huge:
        CGSize(width: 420, height: 420 / (16.0 / 9.0))
      }
    case .vertical:
      CGSize(width: verticalHeight * 9.0 / 16.0, height: verticalHeight)
    case .square, .circle:
      switch self {
      case .small:
        CGSize(width: 140, height: 140)
      case .medium:
        CGSize(width: 180, height: 180)
      case .large:
        CGSize(width: 220, height: 220)
      case .huge:
        CGSize(width: 300, height: 300)
      }
    }
  }

  func clampedSize(
    for shape: RecordingCameraShape,
    in recordingRect: CGRect,
    edgeInset: CGFloat = RecordingCameraOverlayPlacement.defaultEdgeInset
  ) -> CGSize {
    let target = baseSize(for: shape)
    let usableWidth = max(1, recordingRect.width - edgeInset * 2)
    let usableHeight = max(1, recordingRect.height - edgeInset * 2)

    var width = target.width
    var height = target.height

    if width > usableWidth {
      width = usableWidth
      if let ratio = shape.aspectRatio {
        height = width / ratio
      }
    }
    if height > usableHeight {
      height = usableHeight
      if let ratio = shape.aspectRatio {
        width = height * ratio
      }
    }

    return CGSize(width: width, height: height)
  }
}

enum RecordingCameraSettingsProvider {
  static func storedShape(defaults: UserDefaults = .standard) -> RecordingCameraShape {
    guard let raw = defaults.string(forKey: PreferencesKeys.recordingCameraShape),
          let shape = RecordingCameraShape(rawValue: raw)
    else {
      return .rectangle
    }
    return shape
  }

  static func storedSize(defaults: UserDefaults = .standard) -> RecordingCameraSize {
    guard let raw = defaults.string(forKey: PreferencesKeys.recordingCameraSize),
          let size = RecordingCameraSize(rawValue: raw)
    else {
      return .medium
    }
    return size
  }

  static func storedMirrored(defaults: UserDefaults = .standard) -> Bool {
    guard let stored = defaults.object(forKey: PreferencesKeys.recordingCameraMirrored) as? NSNumber,
          CFGetTypeID(stored) == CFBooleanGetTypeID() else { return true }
    return stored.boolValue
  }
}
