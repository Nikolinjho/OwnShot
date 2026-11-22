//
//  CaptureSourceApplication.swift
//  Snapzy
//
//  Приложение-источник захвата для бейджа в History
//

import AppKit
import Foundation

/// Запоминает приложение, из которого начат захват: владелец окна для захвата окна,
/// иначе приложение на переднем плане. History показывает его бейджем, как эталон.
@MainActor
enum CaptureSourceApplication {
  /// Bundle id текущего захвата; nil – источник неизвестен или это сам OwnShot.
  private(set) static var currentBundleID: String?

  /// Внешний bundle id: пустой и собственный bundle id OwnShot не считаются источником.
  nonisolated static func externalBundleID(_ candidate: String?, ownBundleID: String?) -> String? {
    guard let candidate = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
          !candidate.isEmpty,
          candidate != ownBundleID else { return nil }
    return candidate
  }

  static func note(bundleID: String?, ownBundleID: String? = Bundle.main.bundleIdentifier) {
    currentBundleID = externalBundleID(bundleID, ownBundleID: ownBundleID)
  }

  static func reset() {
    currentBundleID = nil
  }
}
