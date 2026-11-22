//
//  MouseHighlightConfiguration.swift
//  Snapzy
//
//  Configuration for the mouse click highlight overlay.
//  Reads persisted values from UserDefaults with sensible defaults.
//

import AppKit
import Foundation

struct MouseHighlightConfiguration {

  /// Maximum diameter of each expanding ripple ring (px)
  let highlightSize: CGFloat

  /// Diameter of the persistent hold circle while mouse is pressed (px)
  let holdCircleSize: CGFloat

  /// Stroke width for rings and the hold circle
  let ringWidth: CGFloat

  /// Duration of each ripple ring's expand animation (seconds)
  let animationDuration: Double

  /// Number of concentric ripple rings spawned on each click
  let rippleCount: Int

  /// Stroke color for rings and the hold circle
  let highlightColor: NSColor

  /// Alpha applied to the highlight stroke color
  let highlightOpacity: Double

  /// Контур или заливка круга клика (Style в эталоне)
  let style: RecordingClickStyle

  /// Расходящиеся круги при клике (Animate clicks в эталоне)
  let animateClicks: Bool

  // MARK: - Defaults

  static let defaultHighlightSize: CGFloat = 50
  static let defaultHoldCircleSize: CGFloat = 36
  static let defaultRingWidth: CGFloat = 2
  static let defaultAnimationDuration: Double = 0.7
  static let defaultRippleCount: Int = 3
  static let defaultHighlightOpacity: Double = 0.5

  static let defaultHighlightColor = NSColor(
    displayP3Red: 0.068, green: 0.222, blue: 1.0, alpha: 1.0
  )

  // MARK: - Init from UserDefaults

  init(defaults: UserDefaults = .standard) {
    let ud = defaults

    // Шкала Size у эталона 25…75, старые значения 30…100 прижимаются к ней.
    let storedSize = ud.object(forKey: PreferencesKeys.mouseHighlightSize) as? Double
    self.highlightSize = CGFloat(RecordingOverlayOptions.clampedClickSize(storedSize ?? Self.defaultHighlightSize))

    // Hold circle is proportionally scaled from highlight size
    self.holdCircleSize = (self.highlightSize / Self.defaultHighlightSize) * Self.defaultHoldCircleSize

    self.ringWidth = Self.defaultRingWidth

    self.animationDuration = ud.object(forKey: PreferencesKeys.mouseHighlightAnimationDuration) as? Double
      ?? Self.defaultAnimationDuration

    let count = ud.integer(forKey: PreferencesKeys.mouseHighlightRippleCount)
    self.rippleCount = count > 0 ? count : Self.defaultRippleCount

    self.highlightOpacity = ud.object(forKey: PreferencesKeys.mouseHighlightOpacity) as? Double
      ?? Self.defaultHighlightOpacity

    self.style = RecordingOverlayOptions.clickStyle(defaults: ud)
    self.animateClicks = RecordingOverlayOptions.clickAnimate(defaults: ud)

    if let named = RecordingOverlayOptions.clickColor(defaults: ud) {
      self.highlightColor = named.nsColor
    } else if let colorData = ud.data(forKey: PreferencesKeys.mouseHighlightColor),
       let archived = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: colorData) {
      self.highlightColor = archived
    } else {
      self.highlightColor = Self.defaultHighlightColor
    }
  }
}
