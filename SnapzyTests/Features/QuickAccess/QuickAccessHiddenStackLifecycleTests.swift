import AppKit
import XCTest
@testable import Snapzy

@MainActor
final class QuickAccessHiddenStackLifecycleTests: XCTestCase {
  func testПолоскаСкрытогоСтекаИсчезаетПослеПоследнейКарточки() async throws {
    try XCTSkipUnless(
      Bundle.main.bundleIdentifier == "dev.nikoko.ownshot.test-host" && !NSScreen.screens.isEmpty,
      "Нужен изолированный оконный OwnShot Test Host"
    )

    let defaults = UserDefaults.standard
    let autoDismissKey = "floatingScreenshot.autoDismissEnabled"
    let previousRawAutoDismiss = defaults.object(forKey: autoDismissKey)
    let manager = QuickAccessManager.shared
    let previousAutoDismiss = manager.autoDismissEnabled
    manager.dismissAll()
    manager.autoDismissEnabled = false
    defer {
      manager.dismissAll()
      manager.autoDismissEnabled = previousAutoDismiss
      if let previousRawAutoDismiss {
        defaults.set(previousRawAutoDismiss, forKey: autoDismissKey)
      } else {
        defaults.removeObject(forKey: autoDismissKey)
      }
    }

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let image = try XCTUnwrap(TestImageFactory.solidColor(width: 16, height: 16))
    let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    let keyWindow = NSApp.keyWindow

    var itemIDs: [UUID] = []
    for index in 1...2 {
      let url = directory.appendingPathComponent("capture-\(index).png")
      try data.write(to: url)
      let record = CaptureHistoryRecord(
        id: UUID(), filePath: url.path, fileName: url.lastPathComponent,
        captureType: .screenshot, fileSize: Int64(data.count), capturedAt: Date(),
        width: 16, height: 16, duration: nil, thumbnailPath: nil, isDeleted: false
      )
      let restored = await manager.restoreHistoryItem(record)
      itemIDs.append(try XCTUnwrap(restored).id)
    }

    XCTAssertEqual(manager.items.count, 2)
    XCTAssertTrue(NSApp.keyWindow === keyWindow)
    manager.temporarilyHide()
    XCTAssertTrue(QuickAccessHiddenStackStrip.shared.isVisible)
    XCTAssertTrue(NSApp.keyWindow === keyWindow)

    manager.removeScreenshot(id: itemIDs[0])
    XCTAssertEqual(manager.items.map(\.id), [itemIDs[1]])
    XCTAssertTrue(QuickAccessHiddenStackStrip.shared.isVisible, "Полоска нужна для оставшейся карточки")

    manager.removeScreenshot(id: itemIDs[1])
    XCTAssertTrue(manager.items.isEmpty)
    XCTAssertFalse(QuickAccessHiddenStackStrip.shared.isVisible, "Без карточек возвращать нечего")
    XCTAssertTrue(NSApp.keyWindow === keyWindow)
  }
}
