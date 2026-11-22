//
//  QuickAccessClipboardPreservationTests.swift
//  SnapzyTests
//
//  Verify that dismissing a Quick Access card does NOT delete a temp capture
//  while the general pasteboard still references it (#234), and that deletion
//  proceeds normally once the pasteboard has moved on.
//

import AppKit
@testable import Snapzy
import XCTest

@MainActor
final class QuickAccessClipboardPreservationTests: XCTestCase {
  private var originalHistoryEnabled: Bool?
  private var testFiles: [URL] = []

  override func setUp() {
    super.setUp()
    originalHistoryEnabled = UserDefaults.standard.object(forKey: PreferencesKeys.historyEnabled) as? Bool
    // Isolate the pasteboard-reference path from the history-preservation path.
    UserDefaults.standard.set(false, forKey: PreferencesKeys.historyEnabled)
    ClipboardHelper.resetPasteboardReferenceTracking()
  }

  override func tearDown() async throws {
    QuickAccessManager.shared.dismissAll()

    for url in testFiles {
      CaptureHistoryStore.shared.removeByFilePath(url.path)
      try? FileManager.default.removeItem(at: url)
    }
    testFiles.removeAll()

    if let originalHistoryEnabled {
      UserDefaults.standard.set(originalHistoryEnabled, forKey: PreferencesKeys.historyEnabled)
    } else {
      UserDefaults.standard.removeObject(forKey: PreferencesKeys.historyEnabled)
    }
    ClipboardHelper.resetPasteboardReferenceTracking()
    try await super.tearDown()
  }

  // MARK: - Helpers

  private func createTempCapture() throws -> URL {
    let directory = TempCaptureManager.shared.tempCaptureDirectory
    let fileURL = directory.appendingPathComponent("test_\(UUID().uuidString).png")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    guard let cgImage = TestImageFactory.solidColor(width: 10, height: 10) else {
      throw XCTSkip("Failed to create test image")
    }
    let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: 10, height: 10))
    guard let data = AnnotateExporter.imageData(from: nsImage, for: "png") else {
      throw XCTSkip("Failed to encode test image")
    }
    try data.write(to: fileURL)
    testFiles.append(fileURL)
    return fileURL
  }

  private func addAndRemoveItem(for fileURL: URL) async throws {
    await QuickAccessManager.shared.addScreenshot(url: fileURL)
    let item = try XCTUnwrap(
      QuickAccessManager.shared.items.first { $0.url == fileURL },
      "Quick Access item should have been added"
    )
    QuickAccessManager.shared.removeItem(id: item.id)
  }

  private func settleCleanup() async {
    // scheduleDismissCleanup runs in a Task after `Task.yield()`; give it a
    // few run-loop turns to execute before asserting.
    try? await Task.sleep(nanoseconds: 300_000_000)
  }

  private func waitUntil(
    timeout: TimeInterval = 1.0,
    condition: @escaping @MainActor () -> Bool
  ) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() {
        return true
      }
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
  }

  // MARK: - Tests

  func testCopyKeepsMissingImageAndRecordingCardsForRetry() async throws {
    guard ClipboardHelper.pasteboardName != .general else {
      XCTFail("Requires the isolated Test Host pasteboard")
      return
    }
    let root = try XCTUnwrap(OwnShotStoragePaths.testRoot)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let defaults = UserDefaults.standard
    let keys = [PreferencesKeys.playSounds, PreferencesKeys.floatingAutoDismissEnabled]
    let oldValues = keys.map { defaults.object(forKey: $0) }
    let manager = QuickAccessManager(presentsPanel: false)
    let pasteboard = ClipboardHelper.pasteboard
    defer {
      manager.dismissAll()
      for (key, value) in zip(keys, oldValues) { defaults.set(value, forKey: key) }
      pasteboard.clearContents()
      ClipboardHelper.resetPasteboardReferenceTracking()
      try? FileManager.default.removeItem(at: root)
    }
    defaults.set(false, forKey: PreferencesKeys.playSounds)
    manager.autoDismissEnabled = false

    let image = try XCTUnwrap(TestImageFactory.solidColor(width: 10, height: 10))
    let imageData = try XCTUnwrap(AnnotateExporter.imageData(
      from: NSImage(cgImage: image, size: NSSize(width: 10, height: 10)), for: "png"
    ))
    for (name, data) in [("capture.png", imageData), ("recording.mov", Data("recording fixture".utf8))] {
      let file = root.appendingPathComponent(name)
      let moved = root.appendingPathComponent("moved-" + name)
      try data.write(to: file)
      let added: QuickAccessItem?
      if file.pathExtension == "mov" {
        added = await manager.addVideo(url: file)
      } else {
        added = await manager.addScreenshot(url: file)
      }
      let item = try XCTUnwrap(added)
      try FileManager.default.moveItem(at: file, to: moved)
      pasteboard.clearContents()
      XCTAssertTrue(pasteboard.setString("previous clipboard fixture", forType: .string))
      let changeCount = pasteboard.changeCount

      manager.copyToClipboard(id: item.id, optionHeld: false)

      XCTAssertTrue(manager.items.contains { $0.id == item.id }, name)
      XCTAssertEqual(pasteboard.changeCount, changeCount, name)
      XCTAssertEqual(pasteboard.string(forType: .string), "previous clipboard fixture", name)

      try FileManager.default.moveItem(at: moved, to: file)
      manager.copyToClipboard(id: item.id, optionHeld: false)

      XCTAssertFalse(manager.items.contains { $0.id == item.id }, name)
      XCTAssertNotEqual(pasteboard.changeCount, changeCount, name)
      XCTAssertEqual(try Data(contentsOf: file), data, name)
    }
  }

  func testSavingRecordingRepointsExplicitCopyWhenAutoCopyIsOff() async throws {
    try await withCopiedRecording { manager, item, destination, pasteboard in
      manager.saveItem(id: item.id, useSavePanel: false, revealInFinder: false)
      let didFinish = await waitUntil { !manager.items.contains { $0.id == item.id } }
      XCTAssertTrue(didFinish)

      let copiedURLs = pasteboard.readObjects(
        forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
      ) as? [URL]
      XCTAssertEqual(
        copiedURLs?.map { $0.standardizedFileURL.resolvingSymlinksInPath().path },
        [destination.standardizedFileURL.resolvingSymlinksInPath().path]
      )
      XCTAssertTrue(ClipboardHelper.isReferencedByGeneralPasteboard(destination))
      XCTAssertFalse(FileManager.default.fileExists(atPath: item.url.path))
      XCTAssertEqual(try Data(contentsOf: destination), Data("recording fixture".utf8))
    }
  }

  func testSavingRecordingKeepsNewerClipboardValueWhenAutoCopyIsOff() async throws {
    try await withCopiedRecording { manager, item, destination, pasteboard in
      pasteboard.clearContents()
      XCTAssertTrue(pasteboard.setString("newer clipboard fixture", forType: .string))
      let changeCount = pasteboard.changeCount
      manager.saveItem(id: item.id, useSavePanel: false, revealInFinder: false)
      let didFinish = await waitUntil { !manager.items.contains { $0.id == item.id } }
      XCTAssertTrue(didFinish)

      XCTAssertEqual(pasteboard.changeCount, changeCount)
      XCTAssertEqual(pasteboard.string(forType: .string), "newer clipboard fixture")
      XCTAssertFalse(FileManager.default.fileExists(atPath: item.url.path))
      XCTAssertEqual(try Data(contentsOf: destination), Data("recording fixture".utf8))
    }
  }

  func testSavingRecordingKeepsExistingAutomaticRecopy() async throws {
    try await withCopiedRecording { manager, item, destination, pasteboard in
      PreferencesManager.shared.afterCaptureActions[.copyFile, default: [:]][.recording] = true
      pasteboard.clearContents()
      XCTAssertTrue(pasteboard.setString("previous clipboard fixture", forType: .string))
      manager.saveItem(id: item.id, useSavePanel: false, revealInFinder: false)
      let didFinish = await waitUntil { !manager.items.contains { $0.id == item.id } }
      XCTAssertTrue(didFinish)

      XCTAssertTrue(ClipboardHelper.isReferencedByGeneralPasteboard(destination))
      XCTAssertFalse(FileManager.default.fileExists(atPath: item.url.path))
      XCTAssertEqual(try Data(contentsOf: destination), Data("recording fixture".utf8))
    }
  }

  func testSavingRecordingKeepsMultiFileClipboardWhenAutoCopyIsOff() async throws {
    try await withCopiedRecording { manager, item, destination, pasteboard in
      ClipboardHelper.copyFileURLs([item.url, destination.deletingLastPathComponent()])
      let changeCount = pasteboard.changeCount
      manager.saveItem(id: item.id, useSavePanel: false, revealInFinder: false)
      let didFinish = await waitUntil { !manager.items.contains { $0.id == item.id } }
      XCTAssertTrue(didFinish)

      XCTAssertEqual(pasteboard.changeCount, changeCount)
      XCTAssertEqual(try Data(contentsOf: destination), Data("recording fixture".utf8))
    }
  }

  func testSavingImportedRecordingKeepsClipboardPointingAtOriginal() async throws {
    try await withCopiedRecording(sourceIsTemporary: false) { manager, item, destination, pasteboard in
      let changeCount = pasteboard.changeCount
      manager.saveItem(id: item.id, useSavePanel: false, revealInFinder: false)
      let didFinish = await waitUntil { !manager.items.contains { $0.id == item.id } }
      XCTAssertTrue(didFinish)

      XCTAssertEqual(pasteboard.changeCount, changeCount)
      XCTAssertTrue(ClipboardHelper.isReferencedByGeneralPasteboard(item.url))
      XCTAssertEqual(try Data(contentsOf: item.url), Data("recording fixture".utf8))
      XCTAssertEqual(try Data(contentsOf: destination), Data("recording fixture".utf8))
    }
  }

  func testSavingRecordingToSamePathDoesNotRewriteClipboard() async throws {
    try await withCopiedRecording { manager, item, _, pasteboard in
      UserDefaults.standard.set(item.url.deletingLastPathComponent().path, forKey: PreferencesKeys.exportLocation)
      let changeCount = pasteboard.changeCount
      manager.saveItem(id: item.id, useSavePanel: false, revealInFinder: false)
      let didFinish = await waitUntil { !manager.items.contains { $0.id == item.id } }
      XCTAssertTrue(didFinish)

      XCTAssertEqual(pasteboard.changeCount, changeCount)
      XCTAssertTrue(ClipboardHelper.isReferencedByGeneralPasteboard(item.url))
      XCTAssertEqual(try Data(contentsOf: item.url), Data("recording fixture".utf8))
    }
  }

  private func withCopiedRecording(
    sourceIsTemporary: Bool = true,
    _ body: (QuickAccessManager, QuickAccessItem, URL, NSPasteboard) async throws -> Void
  ) async throws {
    guard ClipboardHelper.pasteboardName != .general else {
      XCTFail("Requires the isolated Test Host pasteboard")
      return
    }
    let root = try XCTUnwrap(OwnShotStoragePaths.testRoot)
    let defaults = UserDefaults.standard
    let preferences = PreferencesManager.shared
    let originalActions = preferences.afterCaptureActions
    let exportDirectory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
    let keys = [
      PreferencesKeys.exportLocation, PreferencesKeys.exportLocationBookmark,
      PreferencesKeys.playSounds, PreferencesKeys.floatingAutoDismissEnabled,
    ]
    let oldValues = keys.map { defaults.object(forKey: $0) }
    let manager = QuickAccessManager(presentsPanel: false)
    let sourceDirectory = sourceIsTemporary
      ? TempCaptureManager.shared.tempCaptureDirectory
      : exportDirectory.appendingPathComponent("Imported", isDirectory: true)
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    let source = sourceDirectory.appendingPathComponent("\(UUID().uuidString).mov")
    let destination = exportDirectory.appendingPathComponent(source.lastPathComponent)
    let pasteboard = ClipboardHelper.pasteboard
    defer {
      manager.dismissAll()
      for (key, value) in zip(keys, oldValues) { defaults.set(value, forKey: key) }
      preferences.afterCaptureActions = originalActions
      pasteboard.clearContents()
      ClipboardHelper.resetPasteboardReferenceTracking()
      try? FileManager.default.removeItem(at: source)
      try? FileManager.default.removeItem(at: exportDirectory)
    }
    defaults.set(exportDirectory.path, forKey: PreferencesKeys.exportLocation)
    defaults.removeObject(forKey: PreferencesKeys.exportLocationBookmark)
    defaults.set(false, forKey: PreferencesKeys.playSounds)
    manager.autoDismissEnabled = false
    preferences.afterCaptureActions[.copyFile, default: [:]][.recording] = false
    try Data("recording fixture".utf8).write(to: source)
    let addedItem = await manager.addVideo(url: source)
    let item = try XCTUnwrap(addedItem)
    manager.copyToClipboard(id: item.id, optionHeld: true)
    XCTAssertTrue(manager.items.contains { $0.id == item.id })
    XCTAssertTrue(ClipboardHelper.isReferencedByGeneralPasteboard(source))

    try await body(manager, item, destination, pasteboard)
  }

  func testDismissedTempFile_isPreservedWhileReferencedByPasteboard() async throws {
    let fileURL = try createTempCapture()
    // Simulate the post-capture auto copy-to-clipboard.
    ClipboardHelper.copyImage(from: fileURL)
    XCTAssertTrue(ClipboardHelper.isReferencedByGeneralPasteboard(fileURL))

    try await addAndRemoveItem(for: fileURL)
    await settleCleanup()

    XCTAssertTrue(
      FileManager.default.fileExists(atPath: fileURL.path),
      "Temp file must survive dismiss cleanup while the pasteboard references it (#234)"
    )
  }

  func testDismissedTempFile_isDeletedWhenNotOnPasteboard() async throws {
    let fileURL = try createTempCapture()
    // No clipboard copy — cleanup must behave as before.

    try await addAndRemoveItem(for: fileURL)

    let didDelete = await waitUntil {
      !FileManager.default.fileExists(atPath: fileURL.path)
    }
    XCTAssertTrue(didDelete, "Unreferenced temp file should still be auto-deleted on dismiss")
  }

  func testDismissedTempFile_isDeletedAfterPasteboardMovesOn() async throws {
    let fileURL = try createTempCapture()
    ClipboardHelper.copyImage(from: fileURL)
    XCTAssertTrue(ClipboardHelper.isReferencedByGeneralPasteboard(fileURL))

    // The user copies something else before dismissing the card.
    let pasteboard = ClipboardHelper.pasteboard
    pasteboard.clearContents()
    pasteboard.setString("unrelated content", forType: .string)

    try await addAndRemoveItem(for: fileURL)

    let didDelete = await waitUntil {
      !FileManager.default.fileExists(atPath: fileURL.path)
    }
    XCTAssertTrue(
      didDelete,
      "Once newer clipboard content exists, the temp file must not be kept alive"
    )
  }
}
