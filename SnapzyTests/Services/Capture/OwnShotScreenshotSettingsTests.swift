import AppKit
import XCTest
@testable import Snapzy

final class OwnShotScreenshotSettingsTests: XCTestCase {
  func testWindowDefaultsAndInvalidPadding() {
    let name = "OwnShotScreenshotSettingsTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let initial = OwnShotWindowScreenshotOptions(defaults: defaults)
    XCTAssertEqual(initial.background, .wallpaper)
    XCTAssertEqual(initial.padding, 40)
    defaults.set(-20, forKey: OwnShotScreenshotPreferenceKeys.windowPadding)
    XCTAssertEqual(OwnShotWindowScreenshotOptions(defaults: defaults).padding, 0)
    defaults.set(Double.infinity, forKey: OwnShotScreenshotPreferenceKeys.windowPadding)
    XCTAssertEqual(OwnShotWindowScreenshotOptions(defaults: defaults).padding, 40)
  }

  func testTransparentPaddingPreservesRetinaPixelsAndAlpha() throws {
    // Отступ в пунктах переводится в пиксели, содержимое окна не масштабируется.
    let image = solidImage(width: 4, height: 2, color: .red)
    let result = try XCTUnwrap(OwnShotWindowScreenshotRenderer.render(
      foreground: image, wallpaper: nil, options: .init(background: .transparent, padding: 3), scaleFactor: 2))
    XCTAssertEqual(result.width, 16)
    XCTAssertEqual(result.height, 14)
    XCTAssertEqual(pixel(result, x: 0, y: 0)[3], 0)
    XCTAssertEqual(pixel(result, x: 7, y: 7), [255, 0, 0, 255])
  }

  func testWallpaperAndShiftOverrideUseSameCanvas() throws {
    let image = solidImage(width: 4, height: 2, color: .red)
    let wallpaper = solidImage(width: 2, height: 2, color: .blue)
    let options = OwnShotWindowScreenshotOptions(background: .wallpaper, padding: 2)
    let normal = try XCTUnwrap(OwnShotWindowScreenshotRenderer.render(
      foreground: image, wallpaper: wallpaper, options: options, scaleFactor: 1))
    let shifted = try XCTUnwrap(OwnShotWindowScreenshotRenderer.render(
      foreground: image, wallpaper: wallpaper, options: options, scaleFactor: 1, transparentOverride: true))
    XCTAssertEqual(normal.width, 8)
    XCTAssertEqual(normal.height, 6)
    XCTAssertEqual(pixel(normal, x: 0, y: 0), [0, 0, 255, 255])
    XCTAssertEqual(pixel(normal, x: 3, y: 3), [255, 0, 0, 255])
    XCTAssertEqual(pixel(shifted, x: 0, y: 0)[3], 0)
    XCTAssertEqual(shifted.width, normal.width)
  }

  func testDisabledBackgroundDoesNotReadWallpaperPixels() throws {
    let image = solidImage(width: 4, height: 2, color: .red)
    let result = try XCTUnwrap(OwnShotWindowScreenshotRenderer.render(
      foreground: image, wallpaper: solidImage(width: 1, height: 1, color: .blue),
      options: .init(background: .transparent, padding: 0), scaleFactor: 1))
    XCTAssertTrue(result === image)
  }

  func testCrosshairModesFollowCommandState() {
    XCTAssertTrue(OwnShotCrosshairMode.always.shouldShow(commandPressed: false))
    XCTAssertTrue(OwnShotCrosshairMode.always.shouldShow(commandPressed: true))
    XCTAssertFalse(OwnShotCrosshairMode.command.shouldShow(commandPressed: false))
    XCTAssertTrue(OwnShotCrosshairMode.command.shouldShow(commandPressed: true))
    XCTAssertFalse(OwnShotCrosshairMode.disabled.shouldShow(commandPressed: false))
    XCTAssertFalse(OwnShotCrosshairMode.disabled.shouldShow(commandPressed: true))
  }

  private func solidImage(width: Int, height: Int, color: NSColor) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(color.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
  }

  private func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
    let bytes = CFDataGetBytePtr(image.dataProvider!.data!)!
    return Array(UnsafeBufferPointer(start: bytes + y * image.bytesPerRow + x * 4, count: 4))
  }
}
