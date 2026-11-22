//
//  QuickAccessHistoryCleanupTests.swift
//  SnapzyTests
//
//  Verify that user-initiated deletion from Quick Access also removes the
//  matching Capture History record, while auto-dismiss paths preserve it.
//

import AppKit
import Combine
import SwiftUI
import XCTest
@testable import Snapzy

@MainActor
final class QuickAccessHistoryCleanupTests: XCTestCase {

  private var originalHistoryEnabled: Bool!
  private var testFiles: [URL] = []

  override func setUp() {
    super.setUp()
    originalHistoryEnabled = UserDefaults.standard.bool(forKey: PreferencesKeys.historyEnabled)
    UserDefaults.standard.set(true, forKey: PreferencesKeys.historyEnabled)
  }

  override func tearDown() async throws {
    QuickAccessManager.shared.dismissAll()

    for url in testFiles {
      CaptureHistoryStore.shared.removeByFilePath(url.path)
      try? FileManager.default.removeItem(at: url)
    }
    testFiles.removeAll()

    UserDefaults.standard.set(originalHistoryEnabled, forKey: PreferencesKeys.historyEnabled)
    try await super.tearDown()
  }

  // MARK: - Helpers

  private func createTestFile(in directory: URL, name: String? = nil) throws -> URL {
    let fileName = name ?? "test_\(UUID().uuidString).png"
    let fileURL = directory.appendingPathComponent(fileName)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("test".utf8).write(to: fileURL)
    testFiles.append(fileURL)
    return fileURL
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

  func testOverflowRestoresOldestUnsavedCaptureWithHistoryDisabled() async throws {
    try await withOverflowFixtures { manager, files, data in
      let captures = try files(manager.maxVisibleItems + 1)
      for url in captures { _ = await manager.addScreenshot(url: url) }

      let oldest = captures[0]
      XCTAssertEqual(manager.items.map(\.url), Array(captures.dropFirst().reversed()))
      XCTAssertEqual(try Data(contentsOf: oldest), data)
      XCTAssertFalse(CaptureHistoryStore.shared.hasRecord(forFilePath: oldest.path))

      await manager.restoreRecentlyClosed()

      XCTAssertEqual(manager.items.first?.url, oldest)
      XCTAssertEqual(manager.items.count, manager.maxVisibleItems)
      XCTAssertEqual(try Data(contentsOf: oldest), data)
    }
  }

  func testRepeatedOverflowRestoreVisitsPendingCapturesBeforeDisplacedCards() async throws {
    try await withOverflowFixtures { manager, files, data in
      let captures = try files(manager.maxVisibleItems + 2)
      for url in captures { _ = await manager.addScreenshot(url: url) }

      // A manual close remains the most recent entry and fills the free slot first.
      let newest = try XCTUnwrap(manager.items.first)
      manager.dismissCard(id: newest.id)
      for expected in [newest.url, captures[1], captures[0], captures[2]] {
        await manager.restoreRecentlyClosed()
        XCTAssertEqual(manager.items.first?.url, expected)
        XCTAssertEqual(manager.items.count, manager.maxVisibleItems)
        XCTAssertEqual(try Data(contentsOf: expected), data)
      }
    }
  }

  func testRestoreRecentlyClosedReusesAnAlreadyReopenedCaptureWithoutHistory() async throws {
    try await withOverflowFixtures { manager, files, _ in
      let captures = try files(manager.maxVisibleItems)
      for url in captures { _ = await manager.addScreenshot(url: url) }
      let closedCard = try XCTUnwrap(manager.items.first)
      manager.dismissCard(id: closedCard.id)
      let reopenedCard = await manager.addScreenshot(url: closedCard.url)
      XCTAssertNotNil(reopenedCard)
      XCTAssertFalse(CaptureHistoryStore.shared.hasRecord(forFilePath: closedCard.url.path))
      let cardsBeforeRestore = manager.items.map(\.id)

      await manager.restoreRecentlyClosed()

      XCTAssertEqual(manager.items.map(\.id), cardsBeforeRestore)
      XCTAssertEqual(manager.items.filter { $0.url == closedCard.url }.count, 1)
    }
  }

  func testOverflowExpiryDoesNotDeleteOldestUnsavedCapture() async throws {
    try await withOverflowFixtures { manager, files, data in
      let captures = try files(manager.maxVisibleItems + 21)
      for url in captures { _ = await manager.addScreenshot(url: url) }
      await manager.restoreRecentlyClosed()

      XCTAssertEqual(manager.items.first?.url, captures[20])
      XCTAssertEqual(manager.items.count, manager.maxVisibleItems)
      XCTAssertEqual(try Data(contentsOf: captures[0]), data)
    }
  }

  func testRestoreRecentlyClosedSkipsADirectoryWithoutHistory() async throws {
    try await withOverflowFixtures { manager, files, _ in
      let captures = try files(3)
      for url in captures { _ = await manager.addScreenshot(url: url) }
      let older = try XCTUnwrap(manager.items.first { $0.url == captures[1] })
      let newer = try XCTUnwrap(manager.items.first { $0.url == captures[2] })
      manager.dismissCard(id: older.id)
      manager.dismissCard(id: newer.id)
      try FileManager.default.removeItem(at: newer.url)
      try FileManager.default.createDirectory(at: newer.url, withIntermediateDirectories: false)

      await manager.restoreRecentlyClosed()

      XCTAssertEqual(manager.items.map(\.url), [older.url, captures[0]])
    }
  }

  func testRestoreRecentlyClosedSkipsAReplacementAtTheSamePath() async throws {
    try await withOverflowFixtures { manager, files, data in
      let captures = try files(3)
      for url in captures { _ = await manager.addScreenshot(url: url) }
      let older = try XCTUnwrap(manager.items.first { $0.url == captures[1] })
      let newer = try XCTUnwrap(manager.items.first { $0.url == captures[2] })
      manager.dismissCard(id: older.id)
      manager.dismissCard(id: newer.id)
      let original = newer.url.deletingLastPathComponent().appendingPathComponent("original.png")
      try FileManager.default.moveItem(at: newer.url, to: original)
      let replacement = try XCTUnwrap(TestImageFactory.solidColor(width: 16, height: 12, red: 255))
      let replacementPNG = try XCTUnwrap(NSBitmapImageRep(cgImage: replacement).representation(using: .png, properties: [:]))
      try replacementPNG.write(to: newer.url)

      await manager.restoreRecentlyClosed()

      XCTAssertEqual(manager.items.map(\.url), [older.url, captures[0]])
      XCTAssertEqual(try Data(contentsOf: original), data)
      XCTAssertEqual(try Data(contentsOf: newer.url), replacementPNG)
    }
  }

  func testRestoreRecentlyClosedSkipsTheSameReplacementWhenFallingBackToHistory() async throws {
    try await withOverflowFixtures { manager, files, png in
      let captures = try files(3)
      let older = captures[1]
      let newer = captures[2]
      UserDefaults.standard.set(true, forKey: PreferencesKeys.historyEnabled)
      let store = CaptureHistoryStore.shared
      defer {
        store.removeByFilePath(older.path)
        store.removeByFilePath(newer.path)
      }
      let now = Date()
      for (url, date) in [(older, now), (newer, now.addingTimeInterval(1))] {
        store.add(CaptureHistoryRecord(
          id: UUID(), filePath: url.path, fileName: url.lastPathComponent,
          captureType: .screenshot, fileSize: Int64(png.count), capturedAt: date,
          width: 4, height: 4, duration: nil, thumbnailPath: nil, isDeleted: false
        ))
      }
      let observed = await waitUntil {
        let paths = Set(store.records.map(\.filePath))
        return paths.contains(older.path) && paths.contains(newer.path)
      }
      XCTAssertTrue(observed)
      _ = await manager.addScreenshot(url: captures[0])
      let newestCard = await manager.addScreenshot(url: newer)
      manager.dismissCard(id: try XCTUnwrap(newestCard).id)
      let original = newer.deletingLastPathComponent().appendingPathComponent("original.png")
      try FileManager.default.moveItem(at: newer, to: original)
      try png.write(to: newer)

      await manager.restoreRecentlyClosed()

      XCTAssertEqual(manager.items.map(\.url), [older, captures[0]])
      XCTAssertTrue(FileManager.default.fileExists(atPath: newer.path))
    }
  }

  func testOverflowDoesNotRestoreProcessingOrEditorOwnedCards() async throws {
    try await withOverflowFixtures { manager, files, data in
      let captures = try files(manager.maxVisibleItems + 2)
      let processing = await manager.addScreenshot(url: captures[0])
      let processingCard = try XCTUnwrap(processing)
      manager.updateProcessingState(id: processingCard.id, state: .processing(progress: nil))
      let editing = await manager.addScreenshot(url: captures[1])
      let editingCard = try XCTUnwrap(editing)
      manager.setWindowOpen(id: editingCard.id, isOpen: true)
      for url in captures.dropFirst(2) { _ = await manager.addScreenshot(url: url) }

      let visible = manager.items.map(\.url)
      await manager.restoreRecentlyClosed()

      XCTAssertEqual(manager.items.map(\.url), visible)
      XCTAssertEqual(try Data(contentsOf: captures[0]), data)
      XCTAssertEqual(try Data(contentsOf: captures[1]), data)
    }
  }

  private func withOverflowFixtures(
    _ body: (QuickAccessManager, (Int) throws -> [URL], Data) async throws -> Void
  ) async throws {
    let root = try XCTUnwrap(OwnShotStoragePaths.testRoot)
    let capturesRoot = TempCaptureManager.shared.tempCaptureDirectory
    guard capturesRoot.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else {
      XCTFail("Expected isolated Test Host capture storage")
      return
    }
    let directory = capturesRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let defaults = UserDefaults.standard
    let keys = [PreferencesKeys.historyEnabled, PreferencesKeys.floatingAutoDismissEnabled, PreferencesKeys.playSounds]
    let values = keys.map { defaults.object(forKey: $0) }
    defaults.set(false, forKey: PreferencesKeys.historyEnabled)
    defaults.set(false, forKey: PreferencesKeys.floatingAutoDismissEnabled)
    defaults.set(false, forKey: PreferencesKeys.playSounds)
    let manager = QuickAccessManager(presentsPanel: false)
    defer {
      manager.dismissAll()
      for (key, value) in zip(keys, values) { defaults.set(value, forKey: key) }
      try? FileManager.default.removeItem(at: directory)
    }
    let image = try XCTUnwrap(TestImageFactory.solidColor(width: 4, height: 4))
    let data = try XCTUnwrap(AnnotateExporter.imageData(
      from: NSImage(cgImage: image, size: NSSize(width: 4, height: 4)), for: "png"
    ))
    try await body(manager, { count in
      try (0..<count).map { index in
        let capture = directory.appendingPathComponent("capture-\(index).png")
        try data.write(to: capture)
        return capture
      }
    }, data)
  }

  func testДваПерекрывающихсяRestoreВозвращаютОднуКарточкуБезВытеснения() async throws {
    let defaults = UserDefaults.standard
    let autoDismissKey = "floatingScreenshot.autoDismissEnabled"
    let previousAutoDismiss = defaults.object(forKey: autoDismissKey)
    defaults.set(false, forKey: autoDismissKey)
    defer {
      if let previousAutoDismiss {
        defaults.set(previousAutoDismiss, forKey: autoDismissKey)
      } else {
        defaults.removeObject(forKey: autoDismissKey)
      }
    }

    let manager = QuickAccessManager(presentsPanel: false)
    defer { manager.dismissAll() }
    let directory = FileManager.default.temporaryDirectory
    let thumbnail = ThumbnailResult(thumbnail: NSImage(size: CGSize(width: 2, height: 2)), duration: nil)

    func makeRecord() throws -> CaptureHistoryRecord {
      let file = try createTestFile(in: directory)
      return CaptureHistoryRecord(
        id: UUID(), filePath: file.path, fileName: file.lastPathComponent,
        captureType: .screenshot, fileSize: 4, capturedAt: Date(),
        width: 2, height: 2, duration: nil, thumbnailPath: nil, isDeleted: false
      )
    }

    for _ in 0..<(manager.maxVisibleItems - 1) {
      let record = try makeRecord()
      _ = await manager.restoreHistoryItem(record, thumbnailForURL: { _ in thumbnail })
    }
    let existingIDs = Set(manager.items.map(\.id))
    XCTAssertEqual(existingIDs.count, manager.maxVisibleItems - 1)
    let record = try makeRecord()

    let entered = expectation(description: "Оба восстановления дошли до генерации превью")
    entered.expectedFulfillmentCount = 2
    var waiting: [CheckedContinuation<ThumbnailResult, Never>] = []
    var readyToReturn = false
    func suspendedThumbnail(_ url: URL) async -> ThumbnailResult {
      XCTAssertEqual(url.standardizedFileURL, record.fileURL.standardizedFileURL)
      if readyToReturn { return thumbnail }
      return await withCheckedContinuation { continuation in
        waiting.append(continuation)
        entered.fulfill()
      }
    }

    let first = Task { await manager.restoreHistoryItem(record, thumbnailForURL: suspendedThumbnail) }
    let second = Task { await manager.restoreHistoryItem(record, thumbnailForURL: suspendedThumbnail) }
    await fulfillment(of: [entered], timeout: 2)
    readyToReturn = true
    for continuation in waiting {
      continuation.resume(returning: thumbnail)
    }
    waiting.removeAll()

    let firstItem = await first.value
    let secondItem = await second.value
    let restored = try XCTUnwrap(firstItem)
    XCTAssertEqual(restored.id, try XCTUnwrap(secondItem).id)
    XCTAssertEqual(manager.items.count, manager.maxVisibleItems)
    XCTAssertEqual(manager.items.filter {
      $0.url.standardizedFileURL == record.fileURL.standardizedFileURL
    }.count, 1)
    XCTAssertEqual(Set(manager.items.map(\.id)), existingIDs.union([restored.id]))
  }

  func testRestoreLastSkipsAHistoryCaptureReplacedWithADirectory() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let older = try createTestFile(in: directory, name: "older.png")
    let newer = try createTestFile(in: directory, name: "newer.png")
    let visible = try createTestFile(in: directory, name: "visible.png")
    defer { try? FileManager.default.removeItem(at: directory) }

    let bitmap = try XCTUnwrap(TestImageFactory.solidColor(width: 4, height: 4))
    let png = try XCTUnwrap(NSBitmapImageRep(cgImage: bitmap).representation(using: .png, properties: [:]))
    try png.write(to: older)
    try png.write(to: visible)

    let now = Date()
    let store = CaptureHistoryStore.shared
    for (url, date) in [(older, now), (newer, now.addingTimeInterval(1))] {
      store.add(CaptureHistoryRecord(
        id: UUID(), filePath: url.path, fileName: url.lastPathComponent,
        captureType: .screenshot, fileSize: Int64(png.count), capturedAt: date,
        width: 4, height: 4, duration: nil, thumbnailPath: nil, isDeleted: false
      ))
    }
    let isObserved = await waitUntil {
      let files = Set(store.records.map(\.filePath))
      return files.contains(older.path) && files.contains(newer.path)
    }
    XCTAssertTrue(isObserved)

    try FileManager.default.removeItem(at: newer)
    try FileManager.default.createDirectory(at: newer, withIntermediateDirectories: false)

    let manager = QuickAccessManager(presentsPanel: false)
    defer { manager.dismissAll() }
    let visibleCard = await manager.addScreenshot(url: visible)
    XCTAssertNotNil(visibleCard)

    await manager.restoreLastFromHistoryOrWarn()

    XCTAssertEqual(manager.items.map(\.url), [older, visible])
  }

  func testDeleteItem_removesHistoryRecordForTempFile() async throws {
    let fileURL = try createTestFile(in: TempCaptureManager.shared.tempCaptureDirectory)
    CaptureHistoryStore.shared.addCapture(url: fileURL, captureType: .screenshot)
    XCTAssertTrue(
      CaptureHistoryStore.shared.hasRecord(forFilePath: fileURL.path),
      "History record should exist before delete"
    )

    await QuickAccessManager.shared.addScreenshot(url: fileURL)
    let item = try XCTUnwrap(
      QuickAccessManager.shared.items.first { $0.url == fileURL },
      "Quick Access item should have been added"
    )

    XCTAssertTrue(QuickAccessManager.shared.deleteItem(id: item.id, expectedURL: fileURL))

    XCTAssertFalse(
      CaptureHistoryStore.shared.hasRecord(forFilePath: fileURL.path),
      "History record should be removed after explicit delete"
    )
  }

  func testЗапланированноеУдалениеНеУбираетДругойФайлПоТомуЖеПути() async throws {
    let fileURL = try createTestFile(in: TempCaptureManager.shared.tempCaptureDirectory)
    let files = FileManager.default
    let heldSource = fileURL.appendingPathExtension("original")
    let original = Data("original capture".utf8)
    let replacement = Data("unrelated file".utf8)
    try original.write(to: fileURL)
    defer { try? files.removeItem(at: heldSource) }

    CaptureHistoryStore.shared.addCapture(url: fileURL, captureType: .screenshot)
    let item = QuickAccessItem(url: fileURL, thumbnail: NSImage(size: CGSize(width: 16, height: 16)))
    let manager = QuickAccessManager(presentsPanel: false, initialItems: [item])
    defer { manager.dismissAll() }
    let hosting = NSHostingView(rootView: QuickAccessCardView(item: item, manager: manager))
    hosting.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
    hosting.layoutSubtreeIfNeeded()
    defer { withExtendedLifetime(hosting) {} }

    let trigger = QuickAccessCardShortcutTrigger(itemID: item.id, action: .delete)
    manager.cardShortcutTrigger.send(trigger)
    try files.moveItem(at: fileURL, to: heldSource)
    try replacement.write(to: fileURL)

    let deleted = await waitUntil(timeout: 0.25) { manager.item(id: item.id) == nil }
    XCTAssertFalse(deleted)
    XCTAssertEqual(try Data(contentsOf: fileURL), replacement)
    XCTAssertEqual(try Data(contentsOf: heldSource), original)
    XCTAssertTrue(CaptureHistoryStore.shared.hasRecord(forFilePath: fileURL.path))
    guard manager.item(id: item.id) != nil else { return }

    try files.removeItem(at: fileURL)
    try files.moveItem(at: heldSource, to: fileURL)
    manager.cardShortcutTrigger.send(trigger)
    let retryDeleted = await waitUntil { manager.item(id: item.id) == nil }
    XCTAssertTrue(retryDeleted, "После отказа исходный снимок можно удалить повторной командой")
    XCTAssertFalse(CaptureHistoryStore.shared.hasRecord(forFilePath: fileURL.path))
  }

  func testRemoveItem_preservesHistoryRecordForTempFile() async throws {
    let fileURL = try createTestFile(in: TempCaptureManager.shared.tempCaptureDirectory)
    CaptureHistoryStore.shared.addCapture(url: fileURL, captureType: .screenshot)
    XCTAssertTrue(
      CaptureHistoryStore.shared.hasRecord(forFilePath: fileURL.path),
      "History record should exist before dismiss"
    )

    await QuickAccessManager.shared.addScreenshot(url: fileURL)
    let item = try XCTUnwrap(
      QuickAccessManager.shared.items.first { $0.url == fileURL },
      "Quick Access item should have been added"
    )

    QuickAccessManager.shared.removeItem(id: item.id)

    XCTAssertTrue(
      CaptureHistoryStore.shared.hasRecord(forFilePath: fileURL.path),
      "History record should be preserved after auto-dismiss path"
    )
  }

  func testRemoveItem_removesCardBeforeDeferredTempCleanup() async throws {
    let fileURL = try createTestFile(in: TempCaptureManager.shared.tempCaptureDirectory)

    await QuickAccessManager.shared.addScreenshot(url: fileURL)
    let item = try XCTUnwrap(
      QuickAccessManager.shared.items.first { $0.url == fileURL },
      "Quick Access item should have been added"
    )

    QuickAccessManager.shared.removeItem(id: item.id)

    XCTAssertFalse(
      QuickAccessManager.shared.items.contains { $0.id == item.id },
      "Quick Access card should be removed synchronously before cleanup runs"
    )
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: fileURL.path),
      "Temp file should still exist until deferred cleanup gets a chance to run"
    )
    let didDeleteTempFile = await waitUntil {
      !FileManager.default.fileExists(atPath: fileURL.path)
    }
    XCTAssertTrue(didDeleteTempFile, "Deferred cleanup should delete unpreserved temp files")
  }

  func testDeferredDismissCleanupPreservesAReplacementAtTheSamePath() async throws {
    try await withOverflowFixtures { manager, files, png in
      let captures = try files(2)
      let removed = await manager.addScreenshot(url: captures[0])
      let control = await manager.addScreenshot(url: captures[1])
      let item = try XCTUnwrap(removed)
      let controlItem = try XCTUnwrap(control)
      let original = item.url.deletingLastPathComponent().appendingPathComponent("original.png")

      manager.removeItem(id: item.id)
      try FileManager.default.moveItem(at: item.url, to: original)
      try png.write(to: item.url)
      manager.removeItem(id: controlItem.id)

      let cleanupRan = await waitUntil {
        !FileManager.default.fileExists(atPath: controlItem.url.path)
      }
      XCTAssertTrue(cleanupRan)
      XCTAssertEqual(try Data(contentsOf: item.url), png)
      XCTAssertEqual(try Data(contentsOf: original), png)
    }
  }

  func testExpiredRecentlyClosedEntryPreservesAReplacementAtTheSamePath() async throws {
    try await withOverflowFixtures { manager, files, png in
      let captures = try files(22)
      let first = await manager.addScreenshot(url: captures[0])
      let item = try XCTUnwrap(first)
      manager.dismissCard(id: item.id)

      let original = item.url.deletingLastPathComponent().appendingPathComponent("original.png")
      try FileManager.default.moveItem(at: item.url, to: original)
      try png.write(to: item.url)

      for url in captures.dropFirst() {
        let added = await manager.addScreenshot(url: url)
        manager.dismissCard(id: try XCTUnwrap(added).id)
      }

      let cleanupRan = await waitUntil {
        !FileManager.default.fileExists(atPath: captures[1].path)
      }
      XCTAssertTrue(cleanupRan)
      XCTAssertEqual(try Data(contentsOf: item.url), png)
      XCTAssertEqual(try Data(contentsOf: original), png)
    }
  }

  func testDeferredDismissCleanupPreservesTheSourceOfAnotherVisibleCard() async throws {
    try await withOverflowFixtures { manager, files, png in
      let captures = try files(2)
      let alias = captures[0].deletingLastPathComponent().appendingPathComponent("alias.png")
      try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: captures[0])
      let first = await manager.addScreenshot(url: captures[0])
      let second = await manager.addScreenshot(url: alias)
      let control = await manager.addScreenshot(url: captures[1])
      let dismissed = try XCTUnwrap(first)
      let retained = try XCTUnwrap(second)
      let controlItem = try XCTUnwrap(control)

      manager.removeItem(id: dismissed.id)
      manager.removeItem(id: controlItem.id)

      let cleanupRan = await waitUntil {
        !FileManager.default.fileExists(atPath: controlItem.url.path)
      }
      XCTAssertTrue(cleanupRan)
      XCTAssertEqual(manager.items.map(\.id), [retained.id])
      XCTAssertEqual(try Data(contentsOf: retained.url), png)
    }
  }

  func testImmediateRestoreKeepsARecentlyClosedTempFileUntilTheCardReturns() async throws {
    try await withOverflowFixtures { manager, files, png in
      let captures = try files(3)
      let remaining = await manager.addScreenshot(url: captures[0])
      let closing = await manager.addScreenshot(url: captures[1])
      let control = await manager.addScreenshot(url: captures[2])
      let remainingItem = try XCTUnwrap(remaining)
      let closingItem = try XCTUnwrap(closing)
      let controlItem = try XCTUnwrap(control)

      manager.removeScreenshot(id: closingItem.id)
      manager.removeItem(id: controlItem.id)
      await manager.restoreRecentlyClosed { url in
        XCTAssertEqual(url, closingItem.url)
        let cleanupRan = await waitUntil {
          !FileManager.default.fileExists(atPath: controlItem.url.path)
        }
        XCTAssertTrue(cleanupRan)
        return await ThumbnailGenerator.generate(from: url)
      }

      XCTAssertEqual(manager.items.map(\.url), [closingItem.url, remainingItem.url])
      XCTAssertEqual(try Data(contentsOf: closingItem.url), png)
    }
  }

  func testDeferredDismissCleanupPreservesTheSourceOfARecentlyClosedAlias() async throws {
    try await withOverflowFixtures { manager, files, png in
      let captures = try files(3)
      let alias = captures[0].deletingLastPathComponent().appendingPathComponent("alias.png")
      try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: captures[0])
      let direct = await manager.addScreenshot(url: captures[0])
      let linked = await manager.addScreenshot(url: alias)
      let control = await manager.addScreenshot(url: captures[1])
      let remaining = await manager.addScreenshot(url: captures[2])
      let directItem = try XCTUnwrap(direct)
      let linkedItem = try XCTUnwrap(linked)
      let controlItem = try XCTUnwrap(control)
      let remainingItem = try XCTUnwrap(remaining)

      manager.dismissCard(id: linkedItem.id)
      manager.removeItem(id: directItem.id)
      manager.removeItem(id: controlItem.id)
      let cleanupRan = await waitUntil {
        !FileManager.default.fileExists(atPath: controlItem.url.path)
      }
      XCTAssertTrue(cleanupRan)
      await manager.restoreRecentlyClosed()

      XCTAssertEqual(manager.items.map(\.url), [alias, remainingItem.url])
      XCTAssertEqual(try Data(contentsOf: alias), png)
    }
  }

  func testThumbnailRetryDoesNotOverwriteAnUpdatedCardThumbnail() async throws {
    try await withOverflowFixtures { manager, files, png in
      let url = try XCTUnwrap(files(1).first)
      let record = CaptureHistoryRecord(
        id: UUID(), filePath: url.path, fileName: url.lastPathComponent,
        captureType: .screenshot, fileSize: Int64(png.count), capturedAt: Date(),
        width: 4, height: 4, duration: nil, thumbnailPath: nil, isDeleted: false
      )
      let restored = await manager.restoreHistoryItem(record) { _ in
        ThumbnailResult(thumbnail: nil, duration: nil)
      }
      let item = try XCTUnwrap(restored)
      let editedThumbnail = NSImage(size: CGSize(width: 13, height: 17))
      manager.updateItemThumbnail(id: item.id, thumbnail: editedThumbnail, fullResImage: nil)

      let staleThumbnail = expectation(description: "Фоновая загрузка не заменяет превью редактора")
      staleThumbnail.isInverted = true
      let observation = manager.$items.dropFirst().sink { cards in
        if let card = cards.first(where: { $0.id == item.id }), card.thumbnail !== editedThumbnail {
          staleThumbnail.fulfill()
        }
      }
      defer { observation.cancel() }

      await fulfillment(of: [staleThumbnail], timeout: 1.5)
      XCTAssertTrue(manager.items.first?.thumbnail === editedThumbnail)
    }
  }

  func testThumbnailRetryPreservesAnUpdatedCardCropWhenTheThumbnailInstanceIsReused() async throws {
    try await withOverflowFixtures { manager, files, png in
      let url = try XCTUnwrap(files(1).first)
      let record = CaptureHistoryRecord(
        id: UUID(), filePath: url.path, fileName: url.lastPathComponent,
        captureType: .screenshot, fileSize: Int64(png.count), capturedAt: Date(),
        width: 4, height: 4, duration: nil, thumbnailPath: nil, isDeleted: false
      )
      let restored = await manager.restoreHistoryItem(record) { _ in
        ThumbnailResult(thumbnail: nil, duration: nil)
      }
      let item = try XCTUnwrap(restored)
      let editedImage = try XCTUnwrap(NSImage(data: png))
      manager.updateItemThumbnail(id: item.id, thumbnail: item.thumbnail, fullResImage: editedImage)
      let edited = try XCTUnwrap(manager.items.first)
      XCTAssertTrue(edited.thumbnail === item.thumbnail)
      XCTAssertNotNil(edited.cardThumbnail)

      let staleCrop = expectation(description: "Повторная загрузка сохраняет новый фрагмент карточки")
      staleCrop.isInverted = true
      let observation = manager.$items.dropFirst().sink { cards in
        if let card = cards.first(where: { $0.id == item.id }), card.thumbnailVersion != edited.thumbnailVersion {
          staleCrop.fulfill()
        }
      }
      defer { observation.cancel() }

      await fulfillment(of: [staleCrop], timeout: 1.5)
      XCTAssertEqual(manager.items.first?.thumbnailVersion, edited.thumbnailVersion)
    }
  }

  func testThumbnailRefreshKeepsAnEditorUpdateMadeDuringLoading() async throws {
    try await withOverflowFixtures { manager, files, _ in
      let url = try XCTUnwrap(files(1).first)
      let created = await manager.addScreenshot(url: url)
      let item = try XCTUnwrap(created)
      let editedThumbnail = NSImage(size: CGSize(width: 13, height: 17))
      let staleThumbnail = NSImage(size: CGSize(width: 4, height: 4))

      await manager.refreshItemThumbnail(id: item.id) { sourceURL in
        XCTAssertEqual(sourceURL, url)
        manager.updateItemThumbnail(id: item.id, thumbnail: editedThumbnail, fullResImage: nil)
        return ThumbnailResult(thumbnail: staleThumbnail, duration: nil)
      }

      XCTAssertTrue(manager.items.first?.thumbnail === editedThumbnail)
    }
  }

  func testThumbnailRefreshPublishesOnlyTheNewestRequest() async throws {
    try await withOverflowFixtures { manager, files, _ in
      let url = try XCTUnwrap(files(1).first)
      let created = await manager.addScreenshot(url: url)
      let item = try XCTUnwrap(created)
      let olderThumbnail = NSImage(size: CGSize(width: 7, height: 11))
      let newerThumbnail = NSImage(size: CGSize(width: 13, height: 17))
      let olderStarted = expectation(description: "Запущено старое обновление")
      let newerStarted = expectation(description: "Запущено новое обновление")
      var olderResult: CheckedContinuation<ThumbnailResult, Never>?
      var newerResult: CheckedContinuation<ThumbnailResult, Never>?

      let older = Task {
        await manager.refreshItemThumbnail(id: item.id) { _ in
          guard !Task.isCancelled else { return ThumbnailResult(thumbnail: nil, duration: nil) }
          return await withCheckedContinuation { continuation in
            olderResult = continuation
            olderStarted.fulfill()
          }
        }
      }
      await fulfillment(of: [olderStarted], timeout: 2)
      let newer = Task {
        await manager.refreshItemThumbnail(id: item.id) { _ in
          guard !Task.isCancelled else { return ThumbnailResult(thumbnail: nil, duration: nil) }
          return await withCheckedContinuation { continuation in
            newerResult = continuation
            newerStarted.fulfill()
          }
        }
      }
      await fulfillment(of: [newerStarted], timeout: 2)

      guard let olderResult, let newerResult else {
        older.cancel()
        newer.cancel()
        olderResult?.resume(returning: ThumbnailResult(thumbnail: nil, duration: nil))
        newerResult?.resume(returning: ThumbnailResult(thumbnail: nil, duration: nil))
        return XCTFail("Оба чтения должны дойти до управляемой точки")
      }

      olderResult.resume(returning: ThumbnailResult(thumbnail: olderThumbnail, duration: nil))
      await older.value
      XCTAssertTrue(manager.items.first?.thumbnail === item.thumbnail)

      newerResult.resume(returning: ThumbnailResult(thumbnail: newerThumbnail, duration: nil))
      await newer.value
      XCTAssertTrue(manager.items.first?.thumbnail === newerThumbnail)
    }
  }

  func testSynchronousThumbnailUpdatesInvalidateAnOlderSaveResult() async throws {
    try await withOverflowFixtures { manager, files, png in
      let paths = try files(2)
      let first = await manager.addScreenshot(url: paths[0])
      let second = await manager.addScreenshot(url: paths[1])
      let firstItem = try XCTUnwrap(first)
      let secondItem = try XCTUnwrap(second)
      let firstGeneration = manager.nextThumbnailGeneration(for: firstItem.id)
      let secondGeneration = manager.nextThumbnailGeneration(for: secondItem.id)
      let current = try XCTUnwrap(NSImage(data: png))
      let older = NSImage(size: CGSize(width: 13, height: 17))

      manager.updateItemThumbnail(id: firstItem.id, image: current)
      manager.updateItemThumbnail(id: secondItem.id, thumbnail: current, fullResImage: nil)
      let firstVersion = try XCTUnwrap(manager.item(id: firstItem.id)).thumbnailVersion
      let secondVersion = try XCTUnwrap(manager.item(id: secondItem.id)).thumbnailVersion

      manager.updateItemThumbnail(
        id: firstItem.id, thumbnail: older, fullResImage: nil, generation: firstGeneration
      )
      manager.updateItemThumbnail(
        id: secondItem.id, thumbnail: older, fullResImage: nil, generation: secondGeneration
      )

      XCTAssertEqual(manager.item(id: firstItem.id)?.thumbnailVersion, firstVersion)
      XCTAssertEqual(manager.item(id: secondItem.id)?.thumbnailVersion, secondVersion)
    }
  }

  func testОшибкаКорзиныСохраняетФайлКарточкуИсториюИАннотации() async throws {
    let (manager, record, item, contents) = try await makeSavedItem()
    defer { manager.dismissAll() }
    defer { AnnotationSessionStore.shared.deleteSession(for: item.url) }

    let expectedIDs = try XCTUnwrap(AnnotateManager.shared.getSessionData(for: item.id)).annotations.map(\.id)
    let succeeded = manager.deleteItem(id: item.id, expectedURL: item.url, trashFile: { source in
      XCTAssertEqual(source, item.url)
      throw CocoaError(.fileWriteNoPermission)
    })

    XCTAssertFalse(succeeded)
    XCTAssertEqual(try Data(contentsOf: item.url), contents)
    XCTAssertTrue(manager.items.contains { $0.id == item.id })
    XCTAssertTrue(CaptureHistoryStore.shared.hasRecord(forFilePath: record.filePath))
    XCTAssertEqual(AnnotationSessionStore.shared.load(for: item.url)?.annotations.map(\.id), expectedIDs)
    XCTAssertEqual(AnnotateManager.shared.getSessionData(for: item.id)?.annotations.map(\.id), expectedIDs)
  }

  func testУспешныйПереносСначалаПеремещаетФайлПотомОчищаетСостояние() async throws {
    let (manager, record, item, contents) = try await makeSavedItem()
    defer { manager.dismissAll() }
    defer { AnnotationSessionStore.shared.deleteSession(for: item.url) }
    let simulatedTrash = item.url.deletingLastPathComponent()
      .appendingPathComponent("test-trash-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: simulatedTrash) }

    let succeeded = manager.deleteItem(id: item.id, expectedURL: item.url, trashFile: { source in
      XCTAssertTrue(manager.items.contains { $0.id == item.id })
      XCTAssertTrue(CaptureHistoryStore.shared.hasRecord(forFilePath: record.filePath))
      XCTAssertEqual(AnnotationSessionStore.shared.load(for: source)?.annotations.count, 1)
      try FileManager.default.moveItem(at: source, to: simulatedTrash)
    })

    XCTAssertTrue(succeeded)
    XCTAssertEqual(try Data(contentsOf: simulatedTrash), contents)
    XCTAssertFalse(FileManager.default.fileExists(atPath: record.filePath))
    XCTAssertFalse(manager.items.contains { $0.id == item.id })
    XCTAssertFalse(CaptureHistoryStore.shared.hasRecord(forFilePath: record.filePath))
    XCTAssertNil(AnnotateManager.shared.getSessionData(for: item.id))
    try FileManager.default.moveItem(at: simulatedTrash, to: item.url)
    XCTAssertNil(AnnotationSessionStore.shared.load(for: item.url))
  }

  func testУдалениеСохранённогоСнимкаСохраняетКаталогНаЕгоМесте() async throws {
    let (manager, record, item, contents) = try await makeSavedItem()
    let fileManager = FileManager.default
    let heldSource = item.url.appendingPathExtension("original")
    let child = item.url.appendingPathComponent("inside.png")
    let simulatedTrash = item.url.appendingPathExtension("test-trash")
    defer { manager.dismissAll() }
    defer {
      AnnotationSessionStore.shared.deleteSession(for: item.url)
      try? fileManager.removeItem(at: item.url)
      try? fileManager.removeItem(at: heldSource)
      try? fileManager.removeItem(at: simulatedTrash)
    }
    try fileManager.moveItem(at: item.url, to: heldSource)
    try fileManager.createDirectory(at: item.url, withIntermediateDirectories: false)
    try contents.write(to: child)

    let removed = manager.deleteItem(id: item.id, expectedURL: item.url, trashFile: { source in
      try fileManager.moveItem(at: source, to: simulatedTrash)
    })

    XCTAssertFalse(removed)
    XCTAssertEqual(try Data(contentsOf: child), contents)
    XCTAssertEqual(try Data(contentsOf: heldSource), contents)
    XCTAssertFalse(fileManager.fileExists(atPath: simulatedTrash.path))
    XCTAssertEqual(manager.item(id: item.id)?.url, item.url)
    XCTAssertTrue(CaptureHistoryStore.shared.hasRecord(forFilePath: record.filePath))
  }

  func testУдалениеСсылкиСохраняетЕёЦелевойФайл() async throws {
    let files = FileManager.default
    let target = files.temporaryDirectory.appendingPathComponent("target-\(UUID().uuidString).png")
    let simulatedTrash = files.temporaryDirectory.appendingPathComponent("test-trash-\(UUID().uuidString).png")
    defer {
      try? files.removeItem(at: simulatedTrash)
      try? files.removeItem(at: target)
    }
    let (manager, record, item, contents) = try await makeSavedItem(beforeRestore: { source in
      try files.moveItem(at: source, to: target)
      try files.createSymbolicLink(at: source, withDestinationURL: target)
    })
    defer { manager.dismissAll() }
    defer { AnnotationSessionStore.shared.deleteSession(for: item.url) }

    let removed = manager.deleteItem(id: item.id, expectedURL: item.url, trashFile: { source in
      try files.moveItem(at: source, to: simulatedTrash)
    })

    XCTAssertTrue(removed)
    XCTAssertEqual(try files.destinationOfSymbolicLink(atPath: simulatedTrash.path), target.path)
    XCTAssertEqual(try Data(contentsOf: target), contents)
    XCTAssertNil(manager.item(id: item.id))
    XCTAssertFalse(CaptureHistoryStore.shared.hasRecord(forFilePath: record.filePath))
  }

  func testУдалениеПерепроверяетURLИАктивныйРедакторПередПереносом() async throws {
    let (manager, record, item, contents) = try await makeSavedItem()
    defer { manager.dismissAll() }
    defer { AnnotationSessionStore.shared.deleteSession(for: item.url) }

    let staleURL = item.url.deletingLastPathComponent().appendingPathComponent("stale-source.png")
    let staleDelete = manager.deleteItem(id: item.id, expectedURL: staleURL, trashFile: { _ in
      XCTFail("Изменившийся URL нельзя перемещать в Корзину")
      throw CocoaError(.fileWriteNoPermission)
    })
    XCTAssertFalse(staleDelete)

    manager.pauseCountdownForEditingItem(item.id)
    let editingDelete = manager.deleteItem(id: item.id, expectedURL: item.url, trashFile: { _ in
      XCTFail("Нельзя перемещать файл открытого редактора")
      throw CocoaError(.fileWriteNoPermission)
    })
    XCTAssertFalse(editingDelete)
    XCTAssertEqual(try Data(contentsOf: item.url), contents)
    XCTAssertTrue(manager.items.contains { $0.id == item.id })
    XCTAssertTrue(CaptureHistoryStore.shared.hasRecord(forFilePath: record.filePath))
    XCTAssertEqual(AnnotationSessionStore.shared.load(for: item.url)?.annotations.count, 1)
  }

  func testОткрытыйПоURLРедакторЗащищаетОбеКарточкиФайлаСАлиасомКаталога() async throws {
    try XCTSkipUnless(
      Bundle.main.bundleIdentifier == "dev.nikoko.ownshot.test-host" && !NSScreen.screens.isEmpty,
      "Нужен изолированный оконный OwnShot Test Host"
    )
    let keyWindow = NSApp.keyWindow
    var editor: AnnotateWindowController?
    var linkedDirectory: URL?
    defer {
      editor?.window?.close()
      if let linkedDirectory { try? FileManager.default.removeItem(at: linkedDirectory) }
    }
    let (manager, record, originalItem, contents) = try await makeSavedItem(beforeRestore: { source in
      let link = FileManager.default.temporaryDirectory.appendingPathComponent("parent-link-\(UUID().uuidString)")
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source.deletingLastPathComponent())
      linkedDirectory = link
      // Register the real URL controller through the normal ownership path without showing or activating it.
      let controller = AnnotateWindowController(url: link.appendingPathComponent(source.lastPathComponent))
      AnnotateManager.shared.trackStandaloneFileWindow(controller)
      editor = controller
    })
    defer { manager.dismissAll() }
    defer { AnnotationSessionStore.shared.deleteSession(for: originalItem.url) }

    let link = try XCTUnwrap(linkedDirectory)
    let alias = link.appendingPathComponent(originalItem.url.lastPathComponent)
    XCTAssertNotEqual(alias.standardizedFileURL.path, originalItem.url.standardizedFileURL.path)
    XCTAssertTrue(AnnotateManager.shared.isEditingFile(at: originalItem.url))
    XCTAssertTrue(NSApp.keyWindow === keyWindow)

    let leafLink = link.appendingPathComponent("leaf-link-\(UUID().uuidString).png")
    try FileManager.default.createSymbolicLink(at: leafLink, withDestinationURL: originalItem.url)
    defer { try? FileManager.default.removeItem(at: leafLink) }
    XCTAssertNotEqual(
      SandboxFileAccessManager.directoryEntryPath(for: originalItem.url),
      SandboxFileAccessManager.directoryEntryPath(for: leafLink)
    )

    let aliasRecord = CaptureHistoryRecord(
      id: UUID(), filePath: alias.path, fileName: alias.lastPathComponent,
      captureType: .screenshot, fileSize: Int64(contents.count), capturedAt: Date(),
      width: 16, height: 16, duration: nil, thumbnailPath: nil, isDeleted: false
    )
    CaptureHistoryStore.shared.add(aliasRecord)
    defer { CaptureHistoryStore.shared.removeByFilePath(alias.path) }
    let aliasRestored = await manager.restoreHistoryItem(aliasRecord, thumbnailForURL: { _ in
      ThumbnailResult(thumbnail: originalItem.thumbnail, duration: nil)
    })
    let aliasItem = try XCTUnwrap(aliasRestored)
    XCTAssertNotEqual(aliasItem.id, originalItem.id)
    let session = try XCTUnwrap(AnnotateManager.shared.getSessionData(for: originalItem.id))
    XCTAssertTrue(AnnotationSessionStore.shared.persist(session, for: alias))
    defer { AnnotationSessionStore.shared.deleteSession(for: alias) }

    let attemptedWhileEditing = manager.deleteItem(id: originalItem.id, expectedURL: originalItem.url, trashFile: { _ in
      XCTFail("Открытый отдельно редактор должен защищать файл")
      throw CocoaError(.fileWriteNoPermission)
    })
    XCTAssertFalse(attemptedWhileEditing)
    XCTAssertEqual(manager.items.count, 2)
    XCTAssertEqual(try Data(contentsOf: originalItem.url), contents)
    XCTAssertTrue(CaptureHistoryStore.shared.hasRecord(forFilePath: record.filePath))
    XCTAssertTrue(CaptureHistoryStore.shared.hasRecord(forFilePath: alias.path))

    editor?.window?.close()
    editor = nil
    XCTAssertFalse(AnnotateManager.shared.isEditingFile(at: originalItem.url))
    let simulatedTrash = originalItem.url.deletingLastPathComponent()
      .appendingPathComponent("test-trash-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: simulatedTrash) }
    let moved = manager.deleteItem(id: aliasItem.id, expectedURL: alias, trashFile: { source in
      XCTAssertEqual(source.path, alias.path)
      try FileManager.default.moveItem(at: source, to: simulatedTrash)
    })
    XCTAssertTrue(moved)
    XCTAssertEqual(try Data(contentsOf: simulatedTrash), contents)
    XCTAssertTrue(manager.items.isEmpty)
    XCTAssertFalse(CaptureHistoryStore.shared.hasRecord(forFilePath: originalItem.url.path))
    XCTAssertFalse(CaptureHistoryStore.shared.hasRecord(forFilePath: alias.path))
    try FileManager.default.moveItem(at: simulatedTrash, to: originalItem.url)
    XCTAssertNil(AnnotationSessionStore.shared.load(for: originalItem.url))
    XCTAssertNil(AnnotationSessionStore.shared.load(for: alias))
    XCTAssertTrue(NSApp.keyWindow === keyWindow)
  }

  private func makeSavedItem(
    beforeRestore: (URL) throws -> Void = { _ in }
  ) async throws -> (QuickAccessManager, CaptureHistoryRecord, QuickAccessItem, Data) {
    let url = try createTestFile(in: FileManager.default.temporaryDirectory)
    XCTAssertFalse(TempCaptureManager.shared.isTempFile(url))
    let image = try XCTUnwrap(TestImageFactory.solidColor(width: 16, height: 16))
    let contents = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    try contents.write(to: url)
    let record = CaptureHistoryRecord(
      id: UUID(), filePath: url.path, fileName: url.lastPathComponent,
      captureType: .screenshot, fileSize: Int64(contents.count), capturedAt: Date(),
      width: 16, height: 16, duration: nil, thumbnailPath: nil, isDeleted: false
    )
    CaptureHistoryStore.shared.add(record)
    XCTAssertTrue(CaptureHistoryStore.shared.hasRecord(forFilePath: url.path))

    let manager = QuickAccessManager(presentsPanel: false)
    let thumbnail = ThumbnailResult(thumbnail: NSImage(cgImage: image, size: CGSize(width: 16, height: 16)), duration: nil)
    try beforeRestore(url)
    let restored = await manager.restoreHistoryItem(record, thumbnailForURL: { _ in thumbnail })
    let item = try XCTUnwrap(restored)
    manager.pauseCountdownForActivity(item.id)
    let session = AnnotationSessionData(
      originalImageData: contents,
      annotations: [
        AnnotationItem(
          id: UUID(), type: .text("Сохранённые правки"), bounds: CGRect(x: 0, y: 0, width: 16, height: 16),
          properties: AnnotationProperties()
        )
      ],
      canvasEffects: AnnotationCanvasEffects(),
      cropRect: nil
    )
    XCTAssertTrue(AnnotationSessionStore.shared.persist(session, for: url))
    AnnotateManager.shared.saveSessionData(session, for: item.id)
    return (manager, record, item, contents)
  }
}

@MainActor
final class QuickAccessHistoryRestoreSourceTests: XCTestCase {
  func testRestoreDoesNotReuseCardAfterLinkedParentChanges() async throws {
    try await exerciseReplacement(linkedParent: true, restoresReplacement: true)
  }

  func testRestoreDoesNotPublishThumbnailAfterSamePathReplacement() async throws {
    try await exerciseReplacement(linkedParent: false, restoresReplacement: false)
  }

  func testDistinctHistoryAliasPathsKeepSeparateCards() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let real = root.appendingPathComponent("real", isDirectory: true)
    let alias = root.appendingPathComponent("alias", isDirectory: true)
    try fileManager.createDirectory(at: real, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: root) }
    try fileManager.createSymbolicLink(at: alias, withDestinationURL: real)
    let source = real.appendingPathComponent("capture.png")
    try Data("same file".utf8).write(to: source)
    let linkedSource = alias.appendingPathComponent(source.lastPathComponent)
    let manager = makeManager()
    let thumbnail = ThumbnailResult(thumbnail: NSImage(size: CGSize(width: 2, height: 2)), duration: nil)

    let directCard = await manager.restoreHistoryItem(makeRecord(at: source), thumbnailForURL: { _ in thumbnail })
    let linkedCard = await manager.restoreHistoryItem(makeRecord(at: linkedSource), thumbnailForURL: { _ in thumbnail })

    XCTAssertEqual(try XCTUnwrap(directCard).url, source)
    XCTAssertEqual(try XCTUnwrap(linkedCard).url, linkedSource)
    XCTAssertNotEqual(directCard?.id, linkedCard?.id)
    XCTAssertEqual(manager.items.count, 2)
  }

  private func makeManager() -> QuickAccessManager {
    let manager = QuickAccessManager(presentsPanel: false)
    let defaults = UserDefaults.standard
    let key = PreferencesKeys.floatingAutoDismissEnabled
    let old = defaults.object(forKey: key)
    manager.autoDismissEnabled = false
    defaults.set(old, forKey: key)
    return manager
  }

  private func makeRecord(at url: URL, fileSize: Int = 0) -> CaptureHistoryRecord {
    CaptureHistoryRecord(
      id: UUID(), filePath: url.path, fileName: url.lastPathComponent,
      captureType: .screenshot, fileSize: Int64(fileSize), capturedAt: Date(),
      width: 2, height: 2, duration: nil, thumbnailPath: nil, isDeleted: false
    )
  }

  private func exerciseReplacement(linkedParent: Bool, restoresReplacement: Bool) async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let firstDirectory = root.appendingPathComponent("first", isDirectory: true)
    let secondDirectory = root.appendingPathComponent("second", isDirectory: true)
    try fileManager.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: root) }
    try fileManager.createDirectory(at: secondDirectory, withIntermediateDirectories: false)
    let first = firstDirectory.appendingPathComponent("capture.png")
    let second = secondDirectory.appendingPathComponent("capture.png")
    let link = root.appendingPathComponent("alias", isDirectory: true)
    let archive = root.appendingPathComponent("preserved.png")
    let firstBytes = Data("first fixture".utf8)
    let secondBytes = Data("second fixture".utf8)
    try firstBytes.write(to: first)
    try secondBytes.write(to: second)
    if linkedParent { try fileManager.createSymbolicLink(at: link, withDestinationURL: firstDirectory) }
    let url = linkedParent ? link.appendingPathComponent("capture.png") : first
    let record = makeRecord(at: url, fileSize: firstBytes.count)
    let manager = makeManager()
    let firstThumbnail = ThumbnailResult(thumbnail: NSImage(size: CGSize(width: 2, height: 2)), duration: nil)
    let secondThumbnail = ThumbnailResult(thumbnail: NSImage(size: CGSize(width: 4, height: 4)), duration: nil)
    let entered = expectation(description: "History is generating the first source thumbnail")
    var suspended: CheckedContinuation<ThumbnailResult, Never>?
    let pending = Task {
      await manager.restoreHistoryItem(record, thumbnailForURL: { source in
        XCTAssertEqual(try? Data(contentsOf: source), firstBytes)
        return await withCheckedContinuation {
          suspended = $0
          entered.fulfill()
        }
      })
    }
    await fulfillment(of: [entered], timeout: 2)
    let gate = try XCTUnwrap(suspended)
    defer { suspended?.resume(returning: firstThumbnail) }

    if linkedParent {
      try fileManager.removeItem(at: link)
      try fileManager.createSymbolicLink(at: link, withDestinationURL: secondDirectory)
    } else {
      try fileManager.moveItem(at: first, to: archive)
      try fileManager.moveItem(at: second, to: first)
    }
    XCTAssertEqual(try Data(contentsOf: linkedParent ? first : archive), firstBytes)
    XCTAssertEqual(try Data(contentsOf: url), secondBytes)

    var replacement: QuickAccessItem?
    if restoresReplacement {
      replacement = await manager.restoreHistoryItem(record, thumbnailForURL: { source in
        XCTAssertEqual(try? Data(contentsOf: source), secondBytes)
        return secondThumbnail
      })
      XCTAssertNotNil(replacement)
    }

    suspended = nil
    gate.resume(returning: firstThumbnail)
    let restored = await pending.value
    XCTAssertNil(restored, "An in-flight restore may only return its original source")
    if let replacement {
      XCTAssertNotEqual(restored?.id, replacement.id)
      XCTAssertEqual(manager.items.map(\.id), [replacement.id])
    } else {
      XCTAssertTrue(manager.items.isEmpty)
    }
  }
}
