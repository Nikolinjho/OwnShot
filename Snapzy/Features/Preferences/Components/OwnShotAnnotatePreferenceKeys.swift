import Foundation
import CoreGraphics

nonisolated enum OwnShotAnnotatePreferenceKeys {
  static let inverseArrowDirection = "ownshot.annotate.inverseArrowDirection"
  static let smoothDrawing = "ownshot.annotate.smoothDrawing"
  static let rememberBackground = "ownshot.annotate.rememberBackground"
  static let backgroundWasOpen = "ownshot.annotate.backgroundWasOpen"
  static let drawObjectShadow = "ownshot.annotate.drawObjectShadow"
  static let automaticallyExpandCanvas = "ownshot.annotate.automaticallyExpandCanvas"
  static let alwaysOnTop = "ownshot.annotate.alwaysOnTop"
  static let showDockIcon = "ownshot.annotate.showDockIcon"
  static let showColorNames = "ownshot.annotate.showColorNames"
}

nonisolated struct OwnShotAnnotatePreferences {
  let defaults: UserDefaults
  init(defaults: UserDefaults = .standard) { self.defaults = defaults }
  private func value(_ key: String, fallback: Bool = false) -> Bool {
    defaults.object(forKey: key) as? Bool ?? fallback
  }
  var inverseArrowDirection: Bool { value(OwnShotAnnotatePreferenceKeys.inverseArrowDirection) }
  var smoothDrawing: Bool { value(OwnShotAnnotatePreferenceKeys.smoothDrawing, fallback: true) }
  var rememberBackground: Bool { value(OwnShotAnnotatePreferenceKeys.rememberBackground) }
  var drawObjectShadow: Bool { value(OwnShotAnnotatePreferenceKeys.drawObjectShadow, fallback: true) }
  var automaticallyExpandCanvas: Bool { value(OwnShotAnnotatePreferenceKeys.automaticallyExpandCanvas) }
  var alwaysOnTop: Bool { value(OwnShotAnnotatePreferenceKeys.alwaysOnTop) }
  var showDockIcon: Bool { value(OwnShotAnnotatePreferenceKeys.showDockIcon, fallback: true) }
  var showColorNames: Bool { value(OwnShotAnnotatePreferenceKeys.showColorNames) }
  func invertsArrow(optionHeld: Bool) -> Bool { inverseArrowDirection != optionHeld }
}

nonisolated enum OwnShotAnnotateDrawing {
  static func smooth(_ points: [CGPoint]) -> [CGPoint] {
    guard points.count > 2 else { return points }
    var result = [points[0]]
    for index in 0..<(points.count - 1) {
      let a = points[index], b = points[index + 1]
      result.append(CGPoint(x: a.x * 0.75 + b.x * 0.25, y: a.y * 0.75 + b.y * 0.25))
      result.append(CGPoint(x: a.x * 0.25 + b.x * 0.75, y: a.y * 0.25 + b.y * 0.75))
    }
    result.append(points[points.count - 1])
    return result
  }

  static func expandedBounds(source: CGRect, annotations: [CGRect]) -> CGRect {
    annotations.reduce(source) { bounds, annotation in
      guard !annotation.isNull, !annotation.isInfinite,
            annotation.minX.isFinite, annotation.minY.isFinite,
            annotation.width.isFinite, annotation.height.isFinite else { return bounds }
      return bounds.union(annotation)
    }.integral
  }
}

nonisolated enum OwnShotAnnotateColorName {
  static func name(red: Double, green: Double, blue: Double, alpha: Double) -> String {
    if alpha < 0.01 { return "Transparent" }
    let high = max(red, green, blue), low = min(red, green, blue)
    if high - low < 0.1 {
      if high > 0.9 { return "White" }
      if high < 0.15 { return "Black" }
      return "Gray"
    }
    let delta = high - low
    var hue: Double
    if high == red { hue = (green - blue) / delta }
    else if high == green { hue = 2 + (blue - red) / delta }
    else { hue = 4 + (red - green) / delta }
    hue = (hue * 60 + 360).truncatingRemainder(dividingBy: 360)
    switch hue {
    case 15..<45: return "Orange"
    case 45..<70: return "Yellow"
    case 70..<165: return "Green"
    case 165..<195: return "Cyan"
    case 195..<255: return "Blue"
    case 255..<290: return "Purple"
    case 290..<345: return "Pink"
    default: return "Red"
    }
  }
}
