//
//  OwnShotNotchCrop.swift
//  Snapzy
//
//  Обрезка полосы под вырезом экрана в снимках полноэкранных приложений
//

import AppKit
import CoreGraphics

/// Changelog 4.6 эталона: Auto-crop Notch from screenshots of fullscreen apps.
/// Полноэкранное приложение на дисплее с вырезом рисуется ниже выреза, верхняя
/// полоса остаётся чёрной. Снимок экрана в таком состоянии теряет эту полосу.
nonisolated enum OwnShotNotchCrop {
  /// Высота полосы в точках, если на дисплее открыто полноэкранное окно, занимающее
  /// всё пространство под вырезом. Координаты окон и дисплея – глобальные CG (верхний левый угол).
  static func topInset(
    displayBounds: CGRect,
    safeAreaTop: CGFloat,
    windowBounds: [CGRect],
    tolerance: CGFloat = 1
  ) -> CGFloat {
    guard safeAreaTop > 0, displayBounds.height > safeAreaTop else { return 0 }
    let belowNotch = CGRect(
      x: displayBounds.minX,
      y: displayBounds.minY + safeAreaTop,
      width: displayBounds.width,
      height: displayBounds.height - safeAreaTop
    )
    let matches = windowBounds.contains { bounds in
      abs(bounds.minX - belowNotch.minX) <= tolerance
        && abs(bounds.minY - belowNotch.minY) <= tolerance
        && abs(bounds.width - belowNotch.width) <= tolerance
        && abs(bounds.height - belowNotch.height) <= tolerance
    }
    return matches ? safeAreaTop : 0
  }

  /// Обрезает верх снимка на `topPoints` точек; nil – обрезать нечего или нельзя.
  static func crop(_ image: CGImage, topPoints: CGFloat, scale: CGFloat) -> CGImage? {
    guard topPoints > 0, scale > 0 else { return nil }
    let topPixels = Int((topPoints * scale).rounded())
    guard topPixels > 0, topPixels < image.height else { return nil }
    return image.cropping(to: CGRect(x: 0, y: topPixels, width: image.width, height: image.height - topPixels))
  }

  /// Полоса под вырезом для дисплея, если на нём сейчас полноэкранное окно приложения на переднем плане.
  @MainActor
  static func fullscreenAppTopInset(for screen: NSScreen, displayID: CGDirectDisplayID) -> CGFloat {
    let safeAreaTop = screen.safeAreaInsets.top
    guard safeAreaTop > 0,
          let frontmost = NSWorkspace.shared.frontmostApplication,
          frontmost.bundleIdentifier != Bundle.main.bundleIdentifier,
          let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return 0 }
    let windowBounds = info.compactMap { entry -> CGRect? in
      guard (entry[kCGWindowOwnerPID as String] as? pid_t) == frontmost.processIdentifier,
            (entry[kCGWindowLayer as String] as? Int) == 0,
            let dictionary = entry[kCGWindowBounds as String] as? NSDictionary else { return nil }
      return CGRect(dictionaryRepresentation: dictionary as CFDictionary)
    }
    return topInset(
      displayBounds: CGDisplayBounds(displayID),
      safeAreaTop: safeAreaTop,
      windowBounds: windowBounds
    )
  }
}
