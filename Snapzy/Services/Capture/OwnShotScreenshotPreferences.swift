import CoreGraphics
import Foundation

nonisolated enum OwnShotScreenshotPreferenceKeys {
  static let windowBackground = "ownshot.screenshot.windowBackground"
  static let windowPadding = "ownshot.screenshot.windowPadding"
  static let crosshairMode = "ownshot.screenshot.crosshairMode"
}

/// Значения по умолчанию оверлея выбора области. У эталона в покое только системный курсор:
/// Crosshair Mode = Disabled, без затемнения до начала выделения (CAP-109, CAP-111).
nonisolated enum OwnShotSelectionOverlayDefaults {
  static let crosshairMode: OwnShotCrosshairMode = .disabled
  static let showsSelectionAreaOverlay = false

  /// Затемнение и светлый прицел оверлея. При выключенном прицеле эталон экран не затемняет
  /// и показывает системный курсор, даже если в defaults осталось старое значение Snapzy (CAP-109).
  static func showsSelectionAreaOverlay(defaults: UserDefaults = .standard) -> Bool {
    guard OwnShotCrosshairMode.current(defaults: defaults) != .disabled else { return false }
    return defaults.object(forKey: PreferencesKeys.screenshotShowSelectionAreaOverlay) as? Bool ?? showsSelectionAreaOverlay
  }
}

nonisolated enum OwnShotWindowScreenshotBackground: String {
  case wallpaper
  case transparent
}

nonisolated struct OwnShotWindowScreenshotOptions {
  static let defaultPadding: Double = 40
  static let paddingRange: ClosedRange<Double> = 0...120

  var background: OwnShotWindowScreenshotBackground
  var padding: Double

  init(background: OwnShotWindowScreenshotBackground = .wallpaper, padding: Double = defaultPadding) {
    self.background = background
    self.padding = padding.isFinite ? min(max(padding, Self.paddingRange.lowerBound), Self.paddingRange.upperBound) : Self.defaultPadding
  }

  init(defaults: UserDefaults = .standard) {
    self.init(
      background: defaults.string(forKey: OwnShotScreenshotPreferenceKeys.windowBackground)
        .flatMap(OwnShotWindowScreenshotBackground.init(rawValue:)) ?? .wallpaper,
      padding: defaults.object(forKey: OwnShotScreenshotPreferenceKeys.windowPadding) as? Double ?? Self.defaultPadding
    )
  }
}

nonisolated enum OwnShotCrosshairMode: String, CaseIterable {
  case always
  case command
  case disabled

  var title: String {
    switch self {
    case .always: "Always enabled"
    case .command: "When ⌘ Command is pressed"
    case .disabled: "Disabled"
    }
  }

  func shouldShow(commandPressed: Bool) -> Bool {
    self == .always || (self == .command && commandPressed)
  }

  static func current(defaults: UserDefaults = .standard) -> Self {
    defaults.string(forKey: OwnShotScreenshotPreferenceKeys.crosshairMode).flatMap(Self.init(rawValue:)) ?? OwnShotSelectionOverlayDefaults.crosshairMode
  }
}

nonisolated enum OwnShotWindowScreenshotRenderer {
  static func render(
    foreground: CGImage,
    wallpaper: CGImage?,
    options: OwnShotWindowScreenshotOptions,
    scaleFactor: CGFloat,
    transparentOverride: Bool = false
  ) -> CGImage? {
    let scale = scaleFactor.isFinite && scaleFactor > 0 ? scaleFactor : 1
    let padding = Int((options.padding * Double(scale)).rounded())
    let padded: CGImage
    if padding == 0 {
      padded = foreground
    } else {
      let width = foreground.width + 2 * padding
      let height = foreground.height + 2 * padding
      guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: 0, space: foreground.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
      context.draw(foreground, in: CGRect(x: padding, y: padding, width: foreground.width, height: foreground.height))
      guard let image = context.makeImage() else { return nil }
      padded = image
    }
    guard options.background == .wallpaper, !transparentOverride, let wallpaper else { return padded }
    return OwnShotCaptureWallpaper.composite(foreground: padded, wallpaper: wallpaper)
  }
}

nonisolated enum OwnShotCrosshairGuides {
  static func paths(at point: CGPoint, bounds: CGRect) -> (horizontal: CGPath, vertical: CGPath) {
    let gap: CGFloat = 5
    let horizontal = CGMutablePath()
    horizontal.move(to: CGPoint(x: bounds.minX, y: point.y))
    horizontal.addLine(to: CGPoint(x: point.x - gap, y: point.y))
    horizontal.move(to: CGPoint(x: point.x + gap, y: point.y))
    horizontal.addLine(to: CGPoint(x: bounds.maxX, y: point.y))
    let vertical = CGMutablePath()
    vertical.move(to: CGPoint(x: point.x, y: bounds.minY))
    vertical.addLine(to: CGPoint(x: point.x, y: point.y - gap))
    vertical.move(to: CGPoint(x: point.x, y: point.y + gap))
    vertical.addLine(to: CGPoint(x: point.x, y: bounds.maxY))
    return (horizontal, vertical)
  }
}
