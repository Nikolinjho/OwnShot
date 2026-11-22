//
//  QuickAccessPinZoomMode.swift
//  Snapzy
//

import Combine
import Foundation

enum QuickAccessPinZoomMode: String, CaseIterable, Identifiable {
  case windowFollowsImage
  case fixedViewport

  /// По умолчанию окно pin меняет размер вместе с Zoom: у эталона Zoom 50% и 200%
  /// превращают окно 400×200 pt в 200×100 и 800×400 pt (spec-039 pin-zoom50/200).
  nonisolated static let defaultMode: Self = .windowFollowsImage

  var id: String { rawValue }
}

@MainActor
final class QuickAccessPinZoomModeStore: ObservableObject {
  static let shared = QuickAccessPinZoomModeStore()

  @Published private(set) var mode: QuickAccessPinZoomMode
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    if let rawValue = defaults.string(forKey: PreferencesKeys.quickAccessPinZoomMode),
       let stored = QuickAccessPinZoomMode(rawValue: rawValue) {
      mode = stored
    } else {
      mode = .defaultMode
    }
  }

  func setMode(_ value: QuickAccessPinZoomMode) {
    guard mode != value else { return }
    mode = value
    defaults.set(value.rawValue, forKey: PreferencesKeys.quickAccessPinZoomMode)
  }
}
