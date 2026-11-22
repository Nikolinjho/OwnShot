import XCTest
import CoreGraphics
@testable import Snapzy

final class OwnShotCaptureWallpaperTests: XCTestCase {
  func testОднотонныйФонЗагружаетсяКакНастоящееИзображение() throws {
    let name = "OwnShotWallpaperColorTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set("color", forKey: "ownshot.capture.wallpaper.mode")
    defaults.set([1.0, 0.0, 0.0], forKey: "ownshot.capture.wallpaper.colorRGB")
    let image = try XCTUnwrap(OwnShotCaptureWallpaper.load(defaults: defaults))
    let bytes = try XCTUnwrap(CFDataGetBytePtr(XCTUnwrap(image.dataProvider?.data)))
    XCTAssertEqual(Array(UnsafeBufferPointer(start: bytes, count: 4)), [255, 0, 0, 255])
  }

  func testОбоиФиксируютсяДляЭкранаИЛибоОбновляютсяПриСменеSpaces() throws {
    let name = "OwnShotWallpaperSpaceTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: directory) }
    let first = directory.appendingPathComponent("first.png")
    let second = directory.appendingPathComponent("second.png")
    try Data().write(to: first)
    try Data().write(to: second)
    XCTAssertEqual(OwnShotCaptureWallpaper.desktopURL(current: first, displayID: "1", defaults: defaults), first)
    XCTAssertEqual(OwnShotCaptureWallpaper.desktopURL(current: second, displayID: "1", defaults: defaults), first)
    XCTAssertEqual(OwnShotCaptureWallpaper.desktopURL(current: second, displayID: "2", defaults: defaults), second)
    defaults.set(true, forKey: "ownshot.capture.wallpaper.updateOnSpaces")
    XCTAssertEqual(OwnShotCaptureWallpaper.desktopURL(current: second, displayID: "1", defaults: defaults), second)
  }

  private func context(width: Int, height: Int) -> CGContext {
    CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  }

  func testCompositorPreservesOpaqueWindowAndFillsTransparentDesktop() throws {
    // Явный профиль исключает зависимость цветов от системного Device RGB.
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let wallpaper = context(width: 2, height: 2)
    wallpaper.setFillColor(CGColor(colorSpace: space, components: [0, 0, 1, 1])!)
    wallpaper.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
    let foreground = context(width: 6, height: 4)
    foreground.setFillColor(CGColor(colorSpace: space, components: [1, 0, 0, 1])!)
    foreground.fill(CGRect(x: 2, y: 1, width: 2, height: 2))
    let output = try XCTUnwrap(OwnShotCaptureWallpaper.composite(
      foreground: foreground.makeImage()!, wallpaper: wallpaper.makeImage()!))
    XCTAssertEqual(output.width, 6)
    XCTAssertEqual(output.height, 4)
    let data = try XCTUnwrap(output.dataProvider?.data)
    let bytes = try XCTUnwrap(CFDataGetBytePtr(data))
    XCTAssertEqual(Array(UnsafeBufferPointer(start: bytes, count: 4)), [0, 0, 255, 255])
    XCTAssertEqual(Array(UnsafeBufferPointer(start: bytes + output.bytesPerRow + 2 * 4, count: 4)), [255, 0, 0, 255])
  }

  func testSystemAndMissingImageSafelyUseOriginalDesktop() {
    let name = "OwnShotCaptureWallpaperTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    XCTAssertNil(OwnShotCaptureWallpaper.load(defaults: defaults))
    defaults.set("image", forKey: "ownshot.capture.wallpaper.mode")
    defaults.set("/missing/ownshot-wallpaper.png", forKey: "ownshot.capture.wallpaper.imagePath")
    XCTAssertNil(OwnShotCaptureWallpaper.load(defaults: defaults))
  }
}
