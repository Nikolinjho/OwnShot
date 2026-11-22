import AppKit
import SwiftUI

/// Растровые значки с вариантами для обычных и Retina-дисплеев из каталога приложения.
enum OwnShotIcons {
  static func image(_ name: String) -> Image {
    Image("OwnShot_" + name)
  }

  static func nsImage(_ name: String) -> NSImage? {
    NSImage(named: "OwnShot_" + name)
  }
}
