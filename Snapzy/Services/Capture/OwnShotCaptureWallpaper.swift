import CoreGraphics
import Foundation
import ImageIO
import AppKit

nonisolated enum OwnShotCaptureWallpaper {
  /// Изображение полностью декодируется, пока открыт доступ по bookmark.
  static func load(defaults: UserDefaults = .standard) -> CGImage? {
    if defaults.string(forKey: "ownshot.capture.wallpaper.mode") == "color" {
      let values = defaults.array(forKey: "ownshot.capture.wallpaper.colorRGB") as? [Double] ?? [0, 0, 0]
      guard values.count == 3, values.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
            let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
      context.setFillColor(red: values[0], green: values[1], blue: values[2], alpha: 1)
      context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
      return context.makeImage()
    }
    guard defaults.string(forKey: "ownshot.capture.wallpaper.mode") == "image" else { return nil }
    let url: URL
    if let data = defaults.data(forKey: "ownshot.capture.wallpaper.imageBookmark") {
      var stale = false
      guard let resolved = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope],
        relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
      url = resolved
    } else {
      guard let path = defaults.string(forKey: "ownshot.capture.wallpaper.imagePath"), !path.isEmpty else { return nil }
      url = URL(fileURLWithPath: path)
    }
    let accessed = url.startAccessingSecurityScopedResource()
    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
  }

  static func desktopURL(current: URL?, displayID: String, defaults: UserDefaults) -> URL? {
    var paths = defaults.dictionary(forKey: "ownshot.capture.wallpaper.desktopPaths") as? [String: String] ?? [:]
    let updates = defaults.bool(forKey: "ownshot.capture.wallpaper.updateOnSpaces")
    if !updates, let path = paths[displayID], FileManager.default.fileExists(atPath: path) {
      return URL(fileURLWithPath: path)
    }
    guard let current else { return nil }
    paths[displayID] = current.path
    defaults.set(paths, forKey: "ownshot.capture.wallpaper.desktopPaths")
    return current
  }

  @MainActor
  static func loadDesktop(screen: NSScreen, defaults: UserDefaults = .standard) -> CGImage? {
    let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? "main"
    guard let url = desktopURL(current: NSWorkspace.shared.desktopImageURL(for: screen), displayID: displayID, defaults: defaults),
          let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
  }

  /// Обои заполняют холст с обрезкой по центру. Окна рисуются последними.
  static func composite(foreground: CGImage, wallpaper: CGImage) -> CGImage? {
    let width = foreground.width
    let height = foreground.height
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
      bytesPerRow: 0, space: foreground.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    let factor = max(CGFloat(width) / CGFloat(wallpaper.width), CGFloat(height) / CGFloat(wallpaper.height))
    let size = CGSize(width: CGFloat(wallpaper.width) * factor, height: CGFloat(wallpaper.height) * factor)
    context.draw(wallpaper, in: CGRect(x: (CGFloat(width) - size.width) / 2,
      y: (CGFloat(height) - size.height) / 2, width: size.width, height: size.height))
    context.draw(foreground, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()
  }
}
