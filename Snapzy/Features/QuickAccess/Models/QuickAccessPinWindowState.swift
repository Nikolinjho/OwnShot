//
//  QuickAccessPinWindowState.swift
//  Snapzy
//
//  Observable state for independent pinned screenshot windows.
//

import AppKit
import Combine
import Foundation

@MainActor
final class QuickAccessPinWindowState: ObservableObject {
  let id: UUID

  @Published private(set) var url: URL
  @Published private(set) var image: NSImage
  @Published private(set) var thumbnail: NSImage
  @Published var isLocked = false
  @Published var isMouseInside = false
  @Published private(set) var zoomFactor: CGFloat = 1
  @Published private(set) var panOffset: CGPoint = .zero
  @Published private(set) var zoomMode: QuickAccessPinZoomMode
  /// Opacity из меню pin (20/50/100%), своя у каждого pin.
  @Published var opacity: Double = 1
  /// Shadow, Rounded Corners и Border: стартуют из Advanced, дальше переключаются меню pin.
  @Published var showsShadow: Bool
  @Published var roundedCorners: Bool
  @Published var showsBorder: Bool

  private(set) var baseSize: CGSize
  var onWindowResize: ((CGSize, CGPoint) -> Void)?

  static let minimumZoomFactor: CGFloat = 0.4
  static let maximumZoomFactor: CGFloat = 8

  static func windowFollowsImageDisplaySize(baseSize: CGSize, zoomFactor: CGFloat) -> CGSize {
    let factor = min(max(zoomFactor, minimumZoomFactor), maximumZoomFactor)
    let minimumSize = QuickAccessPinWindowSizing.minimumZoomedSize
    return CGSize(
      width: max(baseSize.width * factor, minimumSize.width),
      height: max(baseSize.height * factor, minimumSize.height)
    )
  }

  init(id: UUID, url: URL, image: NSImage, thumbnail: NSImage, baseSize: CGSize, zoomMode: QuickAccessPinZoomMode = .defaultMode) {
    self.id = id
    self.url = url
    self.image = image
    self.thumbnail = thumbnail
    self.baseSize = baseSize
    self.zoomMode = zoomMode
    let appearance = QuickAccessPinAppearanceDefaults.current()
    showsShadow = appearance.shadow
    roundedCorners = appearance.roundedCorners
    showsBorder = appearance.border
  }

  /// Итоговая прозрачность картинки: Opacity pin и затухание заблокированного pin под курсором.
  var contentOpacity: Double {
    Self.contentOpacity(opacity: opacity, isLocked: isLocked, isMouseInside: isMouseInside)
  }

  static func contentOpacity(opacity: Double, isLocked: Bool, isMouseInside: Bool) -> Double {
    let base = min(max(opacity, 0.05), 1)
    return isLocked && isMouseInside ? base * QuickAccessPinMenuLayout.lockedHoverOpacity : base
  }

  func setOpacityPercent(_ percent: Int) {
    opacity = Double(min(max(percent, 5), 100)) / 100
  }

  var opacityPercent: Int {
    Int((opacity * 100).rounded())
  }

  var displaySize: CGSize {
    zoomMode == .windowFollowsImage
      ? Self.windowFollowsImageDisplaySize(baseSize: baseSize, zoomFactor: zoomFactor)
      : baseSize
  }

  var imageDisplaySize: CGSize {
    if zoomMode == .windowFollowsImage {
      let fittedSize = QuickAccessPinImageGeometry.fittedContentSize(
        imageSize: image.size,
        viewportSize: baseSize
      )
      return CGSize(width: fittedSize.width * zoomFactor, height: fittedSize.height * zoomFactor)
    }
    return QuickAccessPinImageGeometry.fixedViewportContentSize(
      imageSize: image.size,
      viewportSize: baseSize,
      zoomFactor: zoomFactor
    )
  }

  var zoomPercent: Int {
    Int((zoomFactor * 100).rounded())
  }

  var zoomMenuPercents: [Int] {
    var percents = [40, 50, 75, 100, 125, 150, 200, 400, 800].filter { percent in
      let factor = CGFloat(percent) / 100
      return factor >= Self.minimumZoomFactor - 0.001 && factor <= Self.maximumZoomFactor + 0.001
    }
    if !percents.contains(zoomPercent) {
      percents.append(zoomPercent)
      percents.sort()
    }
    return percents
  }

  func setZoomPercent(_ percent: Int) {
    updateZoomFactor(CGFloat(percent) / 100)
  }

  func resetZoom() {
    zoomFactor = 1
    panOffset = .zero
    if zoomMode == .windowFollowsImage { onWindowResize?(baseSize, CGPoint(x: 0.5, y: 0.5)) }
  }

  @discardableResult
  func setZoomMode(_ mode: QuickAccessPinZoomMode, baseSize: CGSize) -> Bool {
    guard zoomMode != mode else { return false }
    zoomMode = mode
    self.baseSize = baseSize
    zoomFactor = 1
    panOffset = .zero
    return true
  }

  func update(url: URL, image: NSImage, thumbnail: NSImage, baseSize: CGSize) -> CGSize {
    self.url = url
    self.image = image
    self.thumbnail = thumbnail
    return updateSizing(baseSize: baseSize)
  }

  func updateSizing(baseSize: CGSize) -> CGSize {
    self.baseSize = baseSize
    zoomFactor = clampedZoomFactor(zoomFactor)
    panOffset = clampedPanOffset(panOffset)
    return displaySize
  }

  /// Пользователь тянет край окна pin: эталон меняет размер окна (FloatingOverlay windowDidResize).
  /// Zoom сохраняется, базовый размер пересчитывается под новое окно.
  func applyUserResize(_ size: CGSize) {
    guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
    baseSize = Self.baseSize(forUserResize: size, zoomMode: zoomMode, zoomFactor: zoomFactor)
    panOffset = clampedPanOffset(panOffset)
    objectWillChange.send()
  }

  static func baseSize(forUserResize size: CGSize, zoomMode: QuickAccessPinZoomMode, zoomFactor: CGFloat) -> CGSize {
    guard zoomMode == .windowFollowsImage, zoomFactor > 0 else { return size }
    return CGSize(width: size.width / zoomFactor, height: size.height / zoomFactor)
  }

  func updateZoomFactor(_ factor: CGFloat) {
    guard factor.isFinite else { return }
    zoomFactor = clampedZoomFactor(factor)
    panOffset = clampedPanOffset(panOffset)
    if zoomMode == .windowFollowsImage {
      onWindowResize?(displaySize, CGPoint(x: 0.5, y: 0.5))
    }
  }

  func updateViewport(magnification: CGFloat, panOffset: CGPoint) {
    guard magnification.isFinite, panOffset.x.isFinite, panOffset.y.isFinite else { return }
    let clampedMagnification = clampedZoomFactor(magnification)
    if abs(zoomFactor - clampedMagnification) > 0.000_1 {
      zoomFactor = clampedMagnification
    }
    let newPanOffset = clampedPanOffset(panOffset)
    if abs(self.panOffset.x - newPanOffset.x) > 0.000_1
      || abs(self.panOffset.y - newPanOffset.y) > 0.000_1 {
      self.panOffset = newPanOffset
    }
  }

  private func clampedPanOffset(_ offset: CGPoint) -> CGPoint {
    guard zoomMode == .fixedViewport else { return .zero }
    return QuickAccessPinImageGeometry.clampedPanOffset(
      offset,
      viewportSize: baseSize,
      contentSize: imageDisplaySize
    )
  }

  func clampedZoomFactor(_ factor: CGFloat) -> CGFloat {
    min(max(factor, Self.minimumZoomFactor), Self.maximumZoomFactor)
  }
}

/// Глобальные настройки внешнего вида pin из Advanced.
struct QuickAccessPinAppearanceDefaults: Equatable {
  var shadow: Bool
  var roundedCorners: Bool
  var border: Bool

  static func current(_ defaults: UserDefaults = .standard) -> QuickAccessPinAppearanceDefaults {
    QuickAccessPinAppearanceDefaults(
      shadow: defaults.object(forKey: OwnShotAdvancedPreferenceKeys.pinnedShadow) as? Bool ?? true,
      roundedCorners: defaults.object(forKey: OwnShotAdvancedPreferenceKeys.pinnedRoundedCorners) as? Bool ?? true,
      border: defaults.object(forKey: OwnShotAdvancedPreferenceKeys.pinnedBorder) as? Bool ?? true
    )
  }
}
