import AppKit
import XCTest
@testable import Snapzy

@MainActor
final class OwnShotFeatureGateTests: XCTestCase {
  func testКампанииИсходногоПроектаНеПоказываются() {
    XCTAssertNil(FeatureIntroManager.shared.getPendingCampaign())
  }

  func testСхемаПринимаетТолькоСсылкиOwnShot() {
    XCTAssertEqual(SnapzyDeepLinkAction(url: URL(string: "ownshot://record/screen")!), .recordScreen)
    XCTAssertNil(SnapzyDeepLinkAction(url: URL(string: "snapzy://record/screen")!))
  }

  func testОткрытиеПустогоВидеоредактораПовторноИспользуетОкно() throws {
    try XCTSkipIf(NSScreen.screens.isEmpty)
    let manager = VideoEditorManager.shared
    defer { manager.closeAll() }
    let existingWindows = visibleVideoEditorCount

    manager.openEmptyEditor()
    manager.openEmptyEditor()

    XCTAssertTrue(manager.hasOpenWindows)
    XCTAssertEqual(visibleVideoEditorCount, existingWindows + 1)
    XCTAssertFalse(OwnShotFeaturePolicy.isAvailable(.studio))
  }

  func testВидеоредакторНеОткрываетНесуществующийФайлИлиПапку() throws {
    let manager = VideoEditorManager.shared
    defer { manager.closeAll() }
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(UUID().uuidString).mp4", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let missingFile = directory.appendingPathComponent("missing.gif")
    for url in [directory, missingFile, URL(string: "https://example.invalid/video.mp4")!] {
      manager.openEditor(for: url)
      manager.openEditor(for: QuickAccessItem(url: url, thumbnail: NSImage(), duration: 1))
    }

    XCTAssertFalse(manager.hasOpenWindows)
  }

  func testКарточкаGifПовторноИспользуетВидеоредакторОткрытыйПоФайлу() throws {
    try XCTSkipIf(NSScreen.screens.isEmpty)
    let manager = VideoEditorManager.shared
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).gif")
    try TestImageFactory.writeAnimatedGIF(to: url)
    defer {
      manager.closeAll()
      try? FileManager.default.removeItem(at: url)
    }
    let item = QuickAccessItem(url: url, thumbnail: NSImage(), duration: 1)
    let existingWindows = visibleVideoEditorCount

    manager.openEditor(for: url)
    XCTAssertTrue(manager.isEditingFile(at: url))
    manager.openEditor(for: item)

    XCTAssertEqual(visibleVideoEditorCount, existingWindows + 1)
  }

  private var visibleVideoEditorCount: Int {
    NSApp.windows.filter { $0 is VideoEditorWindow && $0.isVisible }.count
  }

  func testОблачныйПровайдерНедоступен() {
    XCTAssertNil(CloudManager.shared.createProvider())
    XCTAssertFalse(OwnShotFeaturePolicy.isAvailable(.cloud))
  }

  func testЛокальныеДанныеИзолированы() throws {
    let root = try XCTUnwrap(OwnShotStoragePaths.testRoot)
    XCTAssertEqual(SnapzyConfigurationPaths.suggestedConfigDirectoryURL.lastPathComponent, "ownshot")
    XCTAssertEqual(
      DatabaseManager.defaultDatabaseURL.standardizedFileURL.path,
      root.appendingPathComponent("Library/Application Support/OwnShot/snapzy.db").standardizedFileURL.path
    )
    XCTAssertTrue(CaptureStorageManager.shared.capturesDirectoryURL!.path.contains("/OwnShot/"))
    XCTAssertTrue(CloudKeychainItem.accessKey.account.hasPrefix("dev.nikoko.ownshot."))
    XCTAssertTrue(CloudKeychainItem.accessKey.legacyAccounts.isEmpty)
  }

  func testОблачнаяЗагрузкаОтклоняетсяДоЧтенияФайла() async {
    do {
      _ = try await CloudManager.shared.upload(fileURL: URL(fileURLWithPath: "/nonexistent-ownshot-test.mp4"))
      XCTFail("Облачная загрузка должна быть отложена")
    } catch {
      XCTAssertEqual(error.localizedDescription, "Cloud is coming later. Files stay on this Mac.")
    }
  }
}
