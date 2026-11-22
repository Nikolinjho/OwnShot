//
//  HistorySourceAppBadge.swift
//  Snapzy
//
//  Бейдж приложения-источника на карточке History
//

import AppKit
import SwiftUI

/// Иконки приложений по bundle id; кэш, чтобы прокрутка ленты не ходила в NSWorkspace.
@MainActor
enum HistorySourceAppIconCache {
  private static var icons: [String: NSImage] = [:]
  private static var missing: Set<String> = []

  static func icon(
    for bundleID: String?,
    resolveURL: (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
  ) -> NSImage? {
    guard let bundleID, !bundleID.isEmpty, !missing.contains(bundleID) else { return nil }
    if let cached = icons[bundleID] { return cached }
    guard let url = resolveURL(bundleID) else {
      missing.insert(bundleID)
      return nil
    }
    let icon = NSWorkspace.shared.icon(forFile: url.path)
    icons[bundleID] = icon
    return icon
  }

  static func removeAll() {
    icons.removeAll()
    missing.removeAll()
  }
}

/// Бейдж в правом нижнем углу миниатюры: иконка приложения-источника, как у эталона
/// (19-history.png), иначе значок типа захвата.
struct HistorySourceAppBadge<Fallback: View>: View {
  let bundleID: String?
  let size: CGFloat
  @ViewBuilder let fallback: () -> Fallback

  var body: some View {
    if let icon = HistorySourceAppIconCache.icon(for: bundleID) {
      Image(nsImage: icon)
        .resizable()
        .interpolation(.high)
        .frame(width: size, height: size)
        .shadow(color: Color.black.opacity(0.25), radius: 2, y: 1)
        .accessibilityHidden(true)
    } else {
      fallback()
    }
  }
}
