//
//  CaptureDelay.swift
//  Snapzy
//
//  Delayed Capture (self-timer): the countdown length setting and the pure
//  countdown state machine driven by CaptureDelayCountdownController.
//

import Foundation

/// Countdown length for Delayed Capture, stored in seconds under
/// `PreferencesKeys.screenshotDelayedCaptureSeconds`.
/// Набор как в CleanShot X: 2, 5, 10 и 15 секунд.
enum CaptureDelayOption: Int, CaseIterable, Identifiable {
  case twoSeconds = 2
  case fiveSeconds = 5
  case tenSeconds = 10
  case fifteenSeconds = 15

  static let defaultValue: CaptureDelayOption = .fiveSeconds

  /// Значения прежних версий OwnShot, которых больше нет в меню.
  /// 3 секунды были значением по умолчанию и переходят в новое значение по умолчанию.
  static func migrating(_ seconds: Int) -> CaptureDelayOption? {
    if let option = CaptureDelayOption(rawValue: seconds) { return option }
    return seconds == 3 ? defaultValue : nil
  }

  var id: Int { rawValue }
  var seconds: Int { rawValue }

  var displayName: String {
    L10n.PreferencesCapture.delayedCaptureSeconds(seconds)
  }

  /// Unset or unknown stored values (hand-edited defaults) fall back to the default.
  static func resolve(_ seconds: Int) -> CaptureDelayOption {
    CaptureDelayOption(rawValue: seconds) ?? defaultValue
  }

  static func current(defaults: UserDefaults = .standard) -> CaptureDelayOption {
    resolve(defaults.integer(forKey: PreferencesKeys.screenshotDelayedCaptureSeconds))
  }
}

/// What Delayed Capture does when the countdown ends. Both targets share the
/// countdown length in Preferences → Capture.
enum CaptureDelayTarget: Equatable {
  /// Frozen area selection, so a menu or hover opened during the countdown can be cropped.
  case area
  /// Fullscreen screenshot of the display the pointer is on.
  case fullscreen

  var logName: String {
    switch self {
    case .area: return "delayedArea"
    case .fullscreen: return "delayedFullscreen"
    }
  }

  /// Extra HUD line. Area capture keeps the original countdown layout.
  var hudDetail: String? {
    switch self {
    case .area: return nil
    case .fullscreen: return L10n.ScreenCapture.captureDelayFullscreenHint
    }
  }
}

/// Whole-second countdown. `tick()` is called once per second and reports
/// when the capture should fire.
struct CaptureDelayCountdown: Equatable {
  private(set) var remainingSeconds: Int

  init(seconds: Int) {
    remainingSeconds = max(0, seconds)
  }

  var isFinished: Bool { remainingSeconds == 0 }

  /// Advance one second. Returns `true` exactly once, on the tick that
  /// reaches zero.
  mutating func tick() -> Bool {
    guard remainingSeconds > 0 else { return false }
    remainingSeconds -= 1
    return remainingSeconds == 0
  }
}
