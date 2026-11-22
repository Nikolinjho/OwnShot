//
//  HistoryOverflowMenu.swift
//  Snapzy
//
//  Меню ellipsis в шапке History: Keep History и Clear History..., как в эталоне
//

import AppKit
import SwiftUI

enum HistoryRetentionChoice: Equatable, CaseIterable {
  case never
  case oneDay
  case threeDays
  case oneWeek
  case oneMonth

  /// Срок хранения в днях, nil – история выключена
  var days: Int? {
    switch self {
    case .never: return nil
    case .oneDay: return 1
    case .threeDays: return 3
    case .oneWeek: return 7
    case .oneMonth: return 30
    }
  }

  var title: String {
    switch self {
    case .never: return L10n.PreferencesHistory.retentionNever
    case .oneDay: return L10n.PreferencesHistory.retentionOneDay
    case .threeDays: return L10n.PreferencesHistory.retentionThreeDays
    case .oneWeek: return L10n.PreferencesHistory.retentionOneWeek
    case .oneMonth: return L10n.PreferencesHistory.retentionOneMonth
    }
  }

  /// Пункт с галочкой для текущих настроек. Нестандартный срок не отмечается.
  static func current(historyEnabled: Bool, retentionDays: Int) -> HistoryRetentionChoice? {
    guard historyEnabled else { return .never }
    return allCases.first { $0.days == retentionDays }
  }

  /// Новые значения настроек после выбора пункта
  func apply(historyEnabled: inout Bool, retentionDays: inout Int) {
    if let days {
      historyEnabled = true
      retentionDays = days
    } else {
      historyEnabled = false
    }
  }
}

/// Цвета выбора History: у эталона фильтр, рамка карточки и Restore залиты акцентом темы.
enum HistoryChrome {
  /// R04: акцент зависит от темы, а не systemRed. Raw-байты кадра #CE4745 в светлой теме
  /// (spec-062-live/ref-history-full.png: чип All, рамка и Restore) и #EC5F5D в тёмной –
  /// это sRGB #E0383E и #FF5257 (решение C1 в spec-066-patterns/design-rules.md).
  static let accentLightHex: UInt32 = 0xE0383E
  static let accentDarkHex: UInt32 = 0xFF5257

  static func accentHex(isDark: Bool) -> UInt32 {
    isDark ? accentDarkHex : accentLightHex
  }

  static func accentHex(for appearance: NSAppearance) -> UInt32 {
    let match = appearance.bestMatch(from: [.aqua, .darkAqua, .vibrantDark, .vibrantLight])
    return accentHex(isDark: match == .darkAqua || match == .vibrantDark)
  }

  static let selectionAccentNSColor = NSColor(name: NSColor.Name("OwnShotHistoryAccent")) { appearance in
    let rgb = accentHex(for: appearance)
    return NSColor(
      srgbRed: CGFloat((rgb >> 16) & 255) / 255,
      green: CGFloat((rgb >> 8) & 255) / 255,
      blue: CGFloat(rgb & 255) / 255,
      alpha: 1
    )
  }

  static let selectionAccent = Color(nsColor: selectionAccentNSColor)

  /// R21: Restore – капсула 25 pt (50 px @2x), поля 10 pt, текст 12.5 pt semibold
  /// (ширина «Restore» по глифам 45 pt, ref-history-full.png), зазор значок–текст 6.5 pt
  static let restoreButtonHeight: CGFloat = 25
  static let restoreHorizontalPadding: CGFloat = 10
  static let restoreFontSize: CGFloat = 12.5
  static let restoreIconSpacing: CGFloat = 6.5

  /// Текст пустой панели: эталон пишет No files to restore... для любого фильтра
  /// и Capture History is disabled. при выключенной истории.
  static func emptyTitle(historyEnabled: Bool) -> String {
    historyEnabled ? L10n.PreferencesHistory.noFilesToRestore : L10n.PreferencesHistory.captureHistoryDisabled
  }
}
