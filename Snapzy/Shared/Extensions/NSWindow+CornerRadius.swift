//
//  NSWindow+CornerRadius.swift
//  Snapzy
//
//  Reusable NSWindow extension for custom corner radius
//

import AppKit

extension NSWindow {

  /// Радиус окон приложения ≈16 pt, как системный угол окна эталона (R10): профиль угла
  /// Settings @2x y+1 → x+21, y+8 → +9…10, y+20 → +2…3 (spec-050-visual/light/settings-general-on-000000.png)
  /// совпадает с дугой 32 px. Редактор эталона имеет тот же радиус (editor-idle-on-FFFFFF.png).
  static let defaultCornerRadius: CGFloat = 16

  /// Apply custom corner radius to the window
  /// - Parameter radius: The corner radius to apply (default: 16)
  func applyCornerRadius(_ radius: CGFloat = NSWindow.defaultCornerRadius) {
    // Apply corner radius to the window itself using setValue
    // This modifies the actual window frame corner radius
    setValue(radius, forKey: "cornerRadius")

    // Access the window's content view and apply corner radius
    if let contentView = contentView {
      contentView.wantsLayer = true
      contentView.layer?.cornerRadius = radius
      contentView.layer?.masksToBounds = true
    }

    // Apply to the window's frame view (NSThemeFrame) for border consistency
    if let frameView = contentView?.superview {
      frameView.wantsLayer = true
      frameView.layer?.cornerRadius = radius
      frameView.layer?.masksToBounds = true

      // Find and update any visual effect views within the frame
      for subview in frameView.subviews {
        if let visualEffectView = subview as? NSVisualEffectView {
          visualEffectView.wantsLayer = true
          visualEffectView.layer?.cornerRadius = radius
          visualEffectView.layer?.masksToBounds = true
        }
      }
    }
  }
}
