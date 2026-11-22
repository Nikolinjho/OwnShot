//
//  ScreenshotLastAreaStore.swift
//  Snapzy
//
//  Persists the last area-screenshot selection for instant repeat capture
//

import AppKit
import Foundation

/// Stores the most recent manual area-screenshot rect (AppKit global screen
/// coordinates, in points) so it can be re-captured without re-selecting.
/// Mirrors the recording area persistence in `RecordingCoordinator`.
@MainActor
enum ScreenshotLastAreaStore {
  /// Сохранённая область. screenID и local* необязательны: старые записи их не содержат.
  struct Stored: Equatable {
    var rect: CGRect
    var screenID: CGDirectDisplayID?
    /// Смещение области от начала кадра её дисплея.
    var localOrigin: CGPoint?
  }

  enum Lookup: Equatable {
    case missing
    case offscreen
    case available(CGRect)
  }

  struct ScreenInfo: Equatable {
    let id: CGDirectDisplayID
    let frame: CGRect
  }

  /// Save the last area screenshot rect to UserDefaults
  static func save(_ rect: CGRect) {
    var rectDict: [String: CGFloat] = [
      "x": rect.origin.x,
      "y": rect.origin.y,
      "width": rect.width,
      "height": rect.height
    ]
    // Как lastOneOverlayArea эталона: область привязана к дисплею.
    if let screen = screen(for: rect, in: currentScreens()) {
      rectDict["screenID"] = CGFloat(screen.id)
      rectDict["localX"] = rect.minX - screen.frame.minX
      rectDict["localY"] = rect.minY - screen.frame.minY
    }
    UserDefaults.standard.set(rectDict, forKey: PreferencesKeys.screenshotLastAreaRect)
  }

  /// Load the last area screenshot rect from UserDefaults.
  /// Returns nil when nothing is stored or the rect is no longer visible on
  /// any connected screen (e.g. an external display was disconnected).
  static func load() -> CGRect? {
    guard case .available(let rect) = lookup() else { return nil }
    return rect
  }

  static func lookup() -> Lookup {
    guard let stored = decode(UserDefaults.standard.dictionary(forKey: PreferencesKeys.screenshotLastAreaRect)) else {
      return .missing
    }
    guard let rect = resolve(stored, screens: currentScreens()) else { return .offscreen }
    return .available(rect)
  }

  static func decode(_ rectDict: [String: Any]?) -> Stored? {
    guard let rectDict,
          let x = rectDict["x"] as? CGFloat,
          let y = rectDict["y"] as? CGFloat,
          let width = rectDict["width"] as? CGFloat,
          let height = rectDict["height"] as? CGFloat,
          x.isFinite, y.isFinite, width.isFinite, height.isFinite, width > 0, height > 0 else {
      return nil
    }
    let rect = CGRect(x: x, y: y, width: width, height: height)
    guard rect.maxX.isFinite, rect.maxY.isFinite else { return nil }
    let screenID = (rectDict["screenID"] as? CGFloat).flatMap { CGDirectDisplayID(exactly: $0) }
    var localOrigin: CGPoint?
    if screenID != nil,
       let localX = rectDict["localX"] as? CGFloat, let localY = rectDict["localY"] as? CGFloat,
       localX.isFinite, localY.isFinite {
      localOrigin = CGPoint(x: localX, y: localY)
    }
    return Stored(rect: rect, screenID: screenID, localOrigin: localOrigin)
  }

  /// Дисплей из записи на месте: область переносится вслед за его текущим кадром,
  /// даже если дисплеи переставили. Без него остаётся проверка глобальной области.
  static func resolve(_ stored: Stored, screens: [ScreenInfo]) -> CGRect? {
    if let screenID = stored.screenID, let localOrigin = stored.localOrigin,
       let screen = screens.first(where: { $0.id == screenID }) {
      let size = CGSize(width: min(stored.rect.width, screen.frame.width),
                        height: min(stored.rect.height, screen.frame.height))
      var origin = CGPoint(x: screen.frame.minX + localOrigin.x, y: screen.frame.minY + localOrigin.y)
      origin.x = min(max(origin.x, screen.frame.minX), screen.frame.maxX - size.width)
      origin.y = min(max(origin.y, screen.frame.minY), screen.frame.maxY - size.height)
      return CGRect(origin: origin, size: size)
    }
    guard screens.contains(where: { $0.frame.intersects(stored.rect) }) else { return nil }
    return stored.rect
  }

  /// Дисплей с наибольшим пересечением.
  static func screen(for rect: CGRect, in screens: [ScreenInfo]) -> ScreenInfo? {
    OwnShotCaptureGeometry.screenIndex(for: rect, in: screens.map(\.frame)).map { screens[$0] }
  }

  private static func currentScreens() -> [ScreenInfo] {
    NSScreen.screens.compactMap { screen in
      guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
        return nil
      }
      return ScreenInfo(id: CGDirectDisplayID(number.uint32Value), frame: screen.frame)
    }
  }
}
