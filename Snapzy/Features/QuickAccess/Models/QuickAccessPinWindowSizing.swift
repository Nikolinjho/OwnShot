//
//  QuickAccessPinWindowSizing.swift
//  Snapzy
//
//  Sizing policy for pinned screenshot windows.
//

import AppKit
import Foundation

enum QuickAccessPinWindowSizing {
  static let minimumInteractiveSize = CGSize(width: 240, height: 180)
  /// Нижняя граница окна при уменьшении Zoom: эталон сжимает pin до 200×100 pt при 50%.
  static let minimumZoomedSize = CGSize(width: 120, height: 60)

  private static let absoluteMaxSize = CGSize(width: 1440, height: 920)
  private static let screenMaxRatio: CGFloat = 0.8
  private static let screenMargin: CGFloat = 24

  static func size(for imageSize: CGSize, visibleSize: CGSize, mode: QuickAccessPinZoomMode) -> CGSize {
    guard mode == .fixedViewport else { return size(for: imageSize, visibleSize: visibleSize) }
    let maxWidth = min(absoluteMaxSize.width, visibleSize.width * screenMaxRatio)
    let maxHeight = min(absoluteMaxSize.height, visibleSize.height * screenMaxRatio)
    let source = CGSize(width: max(imageSize.width, 1), height: max(imageSize.height, 1))
    let scale = min(1, maxWidth / source.width)
    let width = max(minimumInteractiveSize.width, source.width * scale)
    let imageHeight = source.height * scale
    let height = min(maxHeight, max(minimumInteractiveSize.height, imageHeight))
    return CGSize(width: min(width, maxWidth), height: height)
  }

  static func size(for imageSize: CGSize, visibleSize: CGSize) -> CGSize {
    let sourceSize = CGSize(width: max(imageSize.width, 1), height: max(imageSize.height, 1))
    let maxSize = CGSize(
      width: min(absoluteMaxSize.width, visibleSize.width * screenMaxRatio),
      height: min(absoluteMaxSize.height, visibleSize.height * screenMaxRatio)
    )
    let maxFitScale = min(maxSize.width / sourceSize.width, maxSize.height / sourceSize.height)
    let minFitScale = max(
      minimumInteractiveSize.width / sourceSize.width,
      minimumInteractiveSize.height / sourceSize.height
    )
    let preferredScale = max(1, minFitScale)
    let normalizedScale = min(preferredScale, maxFitScale)
    let fittedSize = CGSize(width: sourceSize.width * normalizedScale, height: sourceSize.height * normalizedScale)
    let baseSize = CGSize(
      width: min(max(fittedSize.width, minimumInteractiveSize.width), maxSize.width),
      height: min(max(fittedSize.height, minimumInteractiveSize.height), maxSize.height)
    )
    return baseSize
  }

  static func centeredFrame(size: CGSize, on screen: NSScreen) -> NSRect {
    initialFrame(size: size, screenFrame: screen.frame, visibleFrame: screen.visibleFrame)
  }

  /// Позиция появления пина эталона: по центру по горизонтали, по вертикали – золотое
  /// сечение свободного места всего экрана (сверху 0,382). Пин 900×560 на экране
  /// 1728×1117 встаёт в (414, 212) от верхнего левого угла (live 062). Окно не выходит
  /// за видимую область (строка меню, Dock).
  static func initialFrame(size: CGSize, screenFrame: CGRect, visibleFrame: CGRect) -> NSRect {
    let goldenTop: CGFloat = 0.381_966
    let x = screenFrame.midX - size.width / 2
    let freeHeight = screenFrame.height - size.height
    let y = (screenFrame.minY + freeHeight * (1 - goldenTop)).rounded(.up)
    let clampedX = min(max(x, visibleFrame.minX), max(visibleFrame.minX, visibleFrame.maxX - size.width))
    let clampedY = min(max(y, visibleFrame.minY), max(visibleFrame.minY, visibleFrame.maxY - size.height))
    return NSRect(x: clampedX, y: clampedY, width: size.width, height: size.height)
  }

  static func frame(size: CGSize, centeredAt center: CGPoint) -> NSRect {
    NSRect(
      x: center.x - size.width / 2,
      y: center.y - size.height / 2,
      width: size.width,
      height: size.height
    )
  }

  static func resizedFrame(
    _ frame: NSRect,
    to size: CGSize,
    within visibleFrame: NSRect
  ) -> NSRect {
    let fittedSize = CGSize(
      width: min(size.width, visibleFrame.width),
      height: min(size.height, visibleFrame.height)
    )
    let centeredFrame = self.frame(
      size: fittedSize,
      centeredAt: CGPoint(x: frame.midX, y: frame.midY)
    )
    return NSRect(
      x: min(max(centeredFrame.minX, visibleFrame.minX), visibleFrame.maxX - fittedSize.width),
      y: min(max(centeredFrame.minY, visibleFrame.minY), visibleFrame.maxY - fittedSize.height),
      width: fittedSize.width,
      height: fittedSize.height
    )
  }

  static func resizedFrame(
    _ frame: NSRect,
    to size: CGSize,
    preservingAnchorFraction fraction: CGPoint
  ) -> NSRect {
    let anchor = CGPoint(
      x: frame.minX + frame.width * fraction.x,
      y: frame.minY + frame.height * fraction.y
    )
    return NSRect(
      x: anchor.x - size.width * fraction.x,
      y: anchor.y - size.height * fraction.y,
      width: size.width,
      height: size.height
    )
  }

  static func constrainedFrame(_ frame: NSRect, on screen: NSScreen) -> NSRect {
    constrainedFrame(frame, visibleFrame: screen.visibleFrame)
  }

  static func constrainedFrame(_ frame: NSRect, visibleFrame: NSRect) -> NSRect {
    let bounds = visibleFrame.insetBy(dx: screenMargin, dy: screenMargin)
    let width = min(frame.width, max(bounds.width, 1))
    let height = min(frame.height, max(bounds.height, 1))
    return NSRect(
      x: min(max(frame.minX, bounds.minX), bounds.maxX - width),
      y: min(max(frame.minY, bounds.minY), bounds.maxY - height),
      width: width,
      height: height
    )
  }
}
