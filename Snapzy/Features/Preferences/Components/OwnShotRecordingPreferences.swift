import Foundation
import SwiftUI

nonisolated enum OwnShotRecordingPreferenceKeys {
  static let doNotDisturb = "ownshot.recording.doNotDisturb"
  static let showCountdown = "ownshot.recording.showCountdown"
  static let scaleRetina = "ownshot.recording.scaleRetina"
  static let mono = "ownshot.recording.mono"
  static let separateTracks = "ownshot.recording.separateTracks"
  static let gifFPS = "ownshot.recording.gif.fps"
  static let gifWidth = "ownshot.recording.gif.width"
  static let gifOptimize = "ownshot.recording.gif.optimize"
  static let gifQuality = "ownshot.recording.gif.quality"
}

nonisolated enum OwnShotRecordingPreferences {
  /// UI показывает проценты без округления сохранённой дроби качества.
  @MainActor static func percentageBinding(_ stored: Binding<Double>) -> Binding<Double> {
    Binding(get: { stored.wrappedValue * 100 },
      set: { stored.wrappedValue = $0 / 100 })
  }

  static func outputScale(backingScale: CGFloat, scaleRetina: Bool) -> CGFloat {
    scaleRetina ? min(1, backingScale) : backingScale
  }

  /// Частоты видео в меню эталона.
  static let videoFrameRates = [10, 15, 24, 25, 30, 48, 50, 60]
  /// Частоты GIF в меню эталона.
  static let gifFrameRates = [5, 10, 15, 20, 25, 30, 40, 50, 60]
  /// Значение ширины GIF для пункта Original: кадр не уменьшается.
  static let gifOriginalWidth = 0
  /// Ширины GIF в меню эталона, Original первым.
  static let gifWidths = [gifOriginalWidth, 1200, 960, 800, 640, 500, 480, 320, 256, 200]
  static let defaultGIFFPS = 15
  static let defaultGIFWidth = 800

  /// Сохранённая частота GIF в набор эталона. Старые 24 и 48 fps уходят к ближайшему пункту.
  static func normalizedGIFFPS(_ stored: Int?) -> Int {
    guard let stored, stored > 0 else { return defaultGIFFPS }
    return nearest(stored, in: gifFrameRates)
  }

  /// Сохранённая ширина GIF в набор эталона. 0 – Original, старые 400/600/1000/1600/1920
  /// уходят к ближайшему пункту, отрицательные и пустые значения дают 800.
  static func normalizedGIFWidth(_ stored: Int?) -> Int {
    guard let stored, stored >= 0 else { return defaultGIFWidth }
    if stored == gifOriginalWidth { return gifOriginalWidth }
    return nearest(stored, in: gifWidths.filter { $0 != gifOriginalWidth })
  }

  private static func nearest(_ value: Int, in values: [Int]) -> Int {
    values.min { lhs, rhs in
      let lhsDistance = abs(lhs - value)
      let rhsDistance = abs(rhs - value)
      return lhsDistance == rhsDistance ? lhs > rhs : lhsDistance < rhsDistance
    } ?? value
  }

  static func gifOptions(defaults: UserDefaults = .standard) -> GIFConverter.Options {
    let storedFPS = defaults.object(forKey: OwnShotRecordingPreferenceKeys.gifFPS) as? Int
    let storedWidth = defaults.object(forKey: OwnShotRecordingPreferenceKeys.gifWidth) as? Int
    let storedQuality = defaults.object(forKey: OwnShotRecordingPreferenceKeys.gifQuality) as? Double ?? 1
    let width = normalizedGIFWidth(storedWidth)
    return GIFConverter.Options(
      fps: normalizedGIFFPS(storedFPS),
      // Original: ширина не ограничена, GIFConverter не увеличивает исходник.
      maxWidth: width == gifOriginalWidth ? GIFConverter.Options.originalWidth : CGFloat(width),
      optimize: defaults.object(forKey: OwnShotRecordingPreferenceKeys.gifOptimize) as? Bool ?? true,
      quality: storedQuality.isFinite ? min(1, max(0, storedQuality)) : 1
    )
  }
}
