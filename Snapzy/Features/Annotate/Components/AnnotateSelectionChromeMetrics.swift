//
//  AnnotateSelectionChromeMetrics.swift
//  Snapzy
//

import CoreGraphics

/// Converts editor-only selection chrome from screen points into the two
/// coordinate spaces used by the annotation canvas. Image-space drawing is
/// scaled by both fit and zoom; AppKit hit testing receives canvas-local points
/// after fit scale, so it only needs the inverse zoom factor.
struct AnnotateSelectionChromeMetrics {
  /// Ручки выделенного объекта эталона (spec-066 R22) – у всех фигур одинаковые синие круги:
  /// ядро 12 pt #3982F7, белая кайма 2 pt снаружи, всего 16 pt, с мягкой тенью.
  /// Кадр spec-063-live/ref-rect-selected-3eq.png (2×): ядро x 28…51 (24 px), кайма 24…27
  /// и 52…55 (по 4 px); b3r-handle-grid.png и b3r-ellipse-resize.png – то же у Line/Arrow и Ellipse.
  static let handleSize: CGFloat = 16
  static let handleCoreSize: CGFloat = 12
  static let handleBorderWidth: CGFloat = 2
  static let handleCoreRGB: UInt32 = 0x3982F7
  static let handleShadowAlpha: CGFloat = 0.3
  static let handleShadowBlur: CGFloat = 3
  static let selectionLineWidth: CGFloat = 1
  static let selectionDashLength: CGFloat = 4
  /// ANN-722…749: ref-mask-pixelate-light-active-native.png, полоса y607…614
  /// при 2× = 4 pt. По двум фонам RGB рамки соответствует selectedStrokeRGB
  /// с альфой 0,6: (92,151,244) на (78,128,238), (157,197,248) на (240,243,248).
  static let redactionFrameWidth: CGFloat = 4
  static let redactionFrameAlpha: CGFloat = 0.6
  /// Ручки концов Line/Arrow и боковые ручки текста – те же круги 16 pt.
  static let endpointHandleSize: CGFloat = handleSize
  /// Квадратик кегля в правом нижнем углу текста: синий 6 pt в белой кайме
  /// 2 pt, всего 10 pt (spec-063-live/b3r-text-ref-1.png, b5-text-resize-ref.png).
  static let textScaleHandleSize: CGFloat = 10
  static let textScaleHandleBorderWidth: CGFloat = 2
  /// Рамка текста эталона светло-синяя: сплошная в правке, пунктир у выделенного.
  static let textFrameAlpha: CGFloat = 0.4
  static let textFrameEditingLineWidth: CGFloat = 2
  /// Ореол вдоль контура выделенного объекта: #3982F7 по 3 pt с каждой стороны штриха
  /// (ref-rect-selected-3eq.png: #A2C9FA на белом, полосы y 23…29 и 50…56 вокруг штриха 30…49).
  /// По каналам R и G альфа 0,47 и 0,43, среднее 0,45. У Rectangle, Ellipse, Line и Arrow один (R22).
  static let lineSelectionBandInset: CGFloat = 3
  static let lineSelectionBandAlpha: CGFloat = 0.45
  /// Выделенный штрих Draw/Highlighter эталон перекрашивает в светло-синий.
  static let selectedStrokeRGB: (red: CGFloat, green: CGFloat, blue: CGFloat) = (0.40, 0.65, 1.0)

  private let fitScale: CGFloat
  private let zoomScale: CGFloat

  init(fitScale: CGFloat, zoomScale: CGFloat) {
    self.fitScale = max(fitScale, 0.0001)
    self.zoomScale = max(zoomScale, 0.0001)
  }

  /// Length for a Core Graphics context expressed in image coordinates.
  func imageLength(forScreenPoints length: CGFloat) -> CGFloat {
    length / (fitScale * zoomScale)
  }

  /// Length for an AppKit event point expressed in canvas-local coordinates.
  func canvasLength(forScreenPoints length: CGFloat) -> CGFloat {
    length / zoomScale
  }
}
