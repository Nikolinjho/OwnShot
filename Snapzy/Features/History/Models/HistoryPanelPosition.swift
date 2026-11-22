//
//  HistoryPanelPosition.swift
//  Snapzy
//
//  Position options for the floating history panel
//

import AppKit
import Foundation

/// Screen position for the floating history panel
enum HistoryPanelPosition: String, Codable {
  case topCenter
  case bottomCenter
  case center

  static let allCases: [HistoryPanelPosition] = [
    .topCenter,
    .bottomCenter,
  ]

  /// Calculate origin point for panel placement
  func calculateOrigin(for size: CGSize, on screen: NSScreen, padding: CGFloat = 20) -> CGPoint {
    let frame = screen.visibleFrame
    let x = frame.midX - size.width / 2

    switch self {
    case .topCenter:
      return CGPoint(x: x, y: frame.maxY - size.height - padding)
    case .bottomCenter:
      return CGPoint(x: x, y: frame.minY + padding)
    case .center:
      return CGPoint(x: x, y: frame.midY - size.height / 2)
    }
  }

  /// Плавающая панель эталона: отступ `padding` от краёв всего экрана, но не выше
  /// строки меню и не ниже Dock (live 062: scroll area от (40,40) на экране 1728 pt).
  func calculateOrigin(
    for size: CGSize,
    screenFrame: CGRect,
    visibleFrame: CGRect,
    padding: CGFloat
  ) -> CGPoint {
    let x = visibleFrame.midX - size.width / 2
    switch self {
    case .topCenter:
      return CGPoint(x: x, y: min(screenFrame.maxY - padding, visibleFrame.maxY) - size.height)
    case .bottomCenter:
      return CGPoint(x: x, y: max(screenFrame.minY + padding, visibleFrame.minY))
    case .center:
      return CGPoint(x: x, y: visibleFrame.midY - size.height / 2)
    }
  }

  /// Display name for UI
  var displayName: String {
    switch self {
    case .topCenter: return L10n.HistoryPanelPosition.topCenter
    case .bottomCenter: return L10n.HistoryPanelPosition.bottomCenter
    case .center: return L10n.HistoryPanelPosition.center
    }
  }
}

enum HistoryBackgroundStyle: String, CaseIterable, Codable, Identifiable {
  case hud
  case solid

  static let defaultStyle: HistoryBackgroundStyle = .hud

  var id: String { rawValue }

  static func currentStoredStyle(userDefaults: UserDefaults = .standard) -> HistoryBackgroundStyle {
    HistoryBackgroundStyle(
      rawValue: userDefaults.string(forKey: PreferencesKeys.historyBackgroundStyle) ?? ""
    ) ?? .defaultStyle
  }

  var displayName: String {
    switch self {
    case .hud: return L10n.HistoryBackgroundStyle.hud
    case .solid: return L10n.HistoryBackgroundStyle.solid
    }
  }
}
