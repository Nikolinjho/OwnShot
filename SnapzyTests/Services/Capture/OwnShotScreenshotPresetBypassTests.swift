import AppKit
import SwiftUI
import XCTest
@testable import Snapzy

@MainActor
final class OwnShotScreenshotPresetBypassTests: XCTestCase {
  private final class FileAccess: SandboxFileAccessing {
    let directory: URL
    var beforeDirectoryAccess: (() -> Void)?

    init(directory: URL) { self.directory = directory }

    func resolvedExportDirectoryURL() -> URL { directory }

    func beginAccessingURL(_ targetURL: URL) -> SandboxFileAccessManager.ScopedAccess {
      if targetURL == directory { beforeDirectoryAccess?() }
      return .init(url: targetURL, accessURL: targetURL, didStartAccessing: false)
    }
  }

  func testShiftBypassPreservesSourceAndDefaultPreset() throws {
    let defaults = UserDefaultsFactory.make()
    let store = AnnotateCanvasPresetStore(defaults: defaults)
    let preset = AnnotateCanvasPreset(name: "Проверка", payload: .init(
      backgroundStyle: CodableBackgroundStyle(from: .solidColor(.red))!,
      padding: 12, shadowIntensity: 0, cornerRadius: 0))
    store.savePresets([preset])
    store.saveDefaultPresetId(preset.id)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("preset-bypass-\(UUID()).png")
    defer { try? FileManager.default.removeItem(at: url) }
    let image = try XCTUnwrap(TestImageFactory.solidColor(width: 10, height: 10))
    let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    try data.write(to: url)

    let applier = ScreenshotPresetAutoApplier(presetStore: store)
    XCTAssertNil(applier.applyDefaultPresetIfNeeded(to: url, bypassDefaultPreset: true))
    XCTAssertEqual(try Data(contentsOf: url), data)
    XCTAssertEqual(store.loadDefaultPresetId(validating: store.loadPresets()), preset.id)
    XCTAssertNotNil(applier.applyDefaultPresetIfNeeded(to: url, bypassDefaultPreset: false))
    XCTAssertNotEqual(try Data(contentsOf: url), data)
  }

  func testФоновыйПресетСохраняетСкриншотИзменённыйПослеЧтения() throws {
    let files = FileManager.default
    let directory = files.temporaryDirectory.appendingPathComponent("preset-race-\(UUID())", isDirectory: true)
    try files.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? files.removeItem(at: directory) }
    let store = AnnotateCanvasPresetStore(defaults: UserDefaultsFactory.make())
    let preset = AnnotateCanvasPreset(name: "Проверка", payload: .init(
      backgroundStyle: CodableBackgroundStyle(from: .solidColor(.red))!,
      padding: 12, shadowIntensity: 0, cornerRadius: 0))
    store.savePresets([preset])
    store.saveDefaultPresetId(preset.id)
    let image = try XCTUnwrap(TestImageFactory.solidColor(width: 10, height: 10))
    let original = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    let changedImage = try XCTUnwrap(TestImageFactory.solidColor(width: 20, height: 15))
    let changed = try XCTUnwrap(NSBitmapImageRep(cgImage: changedImage).representation(using: .png, properties: [:]))
    let fileAccess = FileAccess(directory: directory)
    let applier = ScreenshotPresetAutoApplier(presetStore: store, fileAccess: fileAccess)

    for replacesFile in [false, true] {
      let source = directory.appendingPathComponent("source-\(replacesFile).png")
      try original.write(to: source)
      let identity = try XCTUnwrap(CaptureFilePublication.SourceIdentity.regularFile(at: source))
      var changedOnWrite = false
      fileAccess.beforeDirectoryAccess = {
        do {
          try changed.write(to: source, options: replacesFile ? [.atomic] : [])
          changedOnWrite = true
          XCTAssertEqual(CaptureFilePublication.SourceIdentity.regularFile(at: source) == identity, !replacesFile)
        } catch {
          XCTFail("Не удалось изменить скриншот: \(error)")
        }
      }

      XCTAssertNil(applier.applyDefaultPresetIfNeeded(to: source))
      XCTAssertTrue(changedOnWrite)
      XCTAssertEqual(try Data(contentsOf: source), changed)
    }

    XCTAssertEqual(store.loadDefaultPresetId(validating: store.loadPresets()), preset.id)
  }
}
