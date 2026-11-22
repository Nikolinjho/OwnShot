//
//  QuickAccessBulkActionsTests.swift
//  SnapzyTests
//
//  Save All и Close All для карточек Quick Access.
//

import AppKit
import XCTest
@testable import Snapzy

@MainActor
final class QuickAccessBulkActionsTests: XCTestCase {
  private var testFiles: [URL] = []
  private var suiteName = ""
  private var defaults: UserDefaults!

  override func setUp() {
    super.setUp()
    QuickAccessManager.shared.dismissAll()
    suiteName = "ownshot.quickAccess.bulk.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
  }

  override func tearDown() async throws {
    QuickAccessManager.shared.dismissAll()
    for url in testFiles {
      CaptureHistoryStore.shared.removeByFilePath(url.path)
      try? FileManager.default.removeItem(at: url)
    }
    testFiles.removeAll()
    defaults.removePersistentDomain(forName: suiteName)
    try await super.tearDown()
  }

  // MARK: - Helpers

  private func createFile(in directory: URL) throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("bulk_\(UUID().uuidString).png")
    try Data("test".utf8).write(to: url)
    testFiles.append(url)
    return url
  }

  private func addCard(in directory: URL) async throws -> QuickAccessItem {
    let url = try createFile(in: directory)
    _ = await QuickAccessManager.shared.addScreenshot(url: url)
    return try XCTUnwrap(QuickAccessManager.shared.items.first { $0.url == url })
  }

  private func addTempCards(_ count: Int) async throws -> [QuickAccessItem] {
    var cards: [QuickAccessItem] = []
    for _ in 0..<count {
      cards.append(try await addCard(in: TempCaptureManager.shared.tempCaptureDirectory))
    }
    return cards
  }

  // MARK: - Доступность

  func testSaveAllИCloseAllДоступныТолькоПриНесколькихКарточках() async throws {
    XCTAssertFalse(QuickAccessBulkActions.isAvailable(itemCount: 0))
    XCTAssertFalse(QuickAccessBulkActions.isAvailable(itemCount: 1))
    XCTAssertTrue(QuickAccessBulkActions.isAvailable(itemCount: 2))

    _ = try await addTempCards(1)
    XCTAssertFalse(QuickAccessManager.shared.isBulkActionAvailable)
    _ = try await addTempCards(1)
    XCTAssertTrue(QuickAccessManager.shared.isBulkActionAvailable)
  }

  // MARK: - Save All

  func testSaveAllСохраняетВсеНесохранённыеИПропускаетУжеСохранённые() async throws {
    let unsaved = try await addTempCards(2)
    let importedDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ownshot-bulk-\(UUID().uuidString)")
    let imported = try await addCard(in: importedDirectory)
    defer { try? FileManager.default.removeItem(at: importedDirectory) }

    var savedIDs: [UUID] = []
    QuickAccessManager.shared.saveAll { savedIDs.append($0) }

    XCTAssertEqual(Set(savedIDs), Set(unsaved.map(\.id)))
    XCTAssertEqual(savedIDs.count, 2)
    XCTAssertFalse(savedIDs.contains(imported.id))
  }

  func testSaveAllНеТрогаетОбрабатываемыеИСохраняемыеСейчасКарточки() {
    let directory = TempCaptureManager.shared.tempCaptureDirectory
    let idle = QuickAccessItem(url: directory.appendingPathComponent("a.png"), thumbnail: NSImage())
    var processing = QuickAccessItem(url: directory.appendingPathComponent("b.png"), thumbnail: NSImage())
    processing.processingState = .processing(progress: nil)
    let busy = QuickAccessItem(url: directory.appendingPathComponent("c.png"), thumbnail: NSImage())

    let ids = QuickAccessBulkActions.unsavedItemIDs(
      in: [idle, processing, busy],
      isTemporary: { TempCaptureManager.shared.isTempFile($0) },
      excluding: [busy.id]
    )

    XCTAssertEqual(ids, [idle.id])
  }

  // MARK: - Close All

  func testCloseAllСЗапомненнымDontAskЗакрываетВсёБезДиалога() async throws {
    defaults.set(true, forKey: QuickAccessCloseAllConfirmation.skipConfirmationKey)
    _ = try await addTempCards(3)

    QuickAccessManager.shared.requestCloseAll(
      confirmation: QuickAccessCloseAllConfirmation(defaults: defaults)
    ) {
      XCTFail("Диалог не должен показываться после Don't ask for confirmation")
      return .cancel
    }

    XCTAssertTrue(QuickAccessManager.shared.items.isEmpty)
  }

  func testCloseAllСФлажкомЗапоминаетВыборИБольшеНеСпрашивает() async throws {
    let confirmation = QuickAccessCloseAllConfirmation(defaults: defaults)
    _ = try await addTempCards(2)

    var prompts = 0
    QuickAccessManager.shared.requestCloseAll(confirmation: confirmation) {
      prompts += 1
      return .close(suppressFutureConfirmation: true)
    }
    XCTAssertTrue(QuickAccessManager.shared.items.isEmpty)
    XCTAssertFalse(confirmation.requiresPrompt)

    _ = try await addTempCards(2)
    QuickAccessManager.shared.requestCloseAll(confirmation: confirmation) {
      prompts += 1
      return .cancel
    }
    XCTAssertTrue(QuickAccessManager.shared.items.isEmpty)
    XCTAssertEqual(prompts, 1)
  }

  func testCloseAllБезФлажкаСпрашиваетСноваВСледующийРаз() async throws {
    let confirmation = QuickAccessCloseAllConfirmation(defaults: defaults)
    _ = try await addTempCards(2)

    QuickAccessManager.shared.requestCloseAll(confirmation: confirmation) {
      .close(suppressFutureConfirmation: false)
    }

    XCTAssertTrue(QuickAccessManager.shared.items.isEmpty)
    XCTAssertTrue(confirmation.requiresPrompt)
  }

  func testCancelВДиалогеCloseAllОставляетВсеКарточки() async throws {
    let confirmation = QuickAccessCloseAllConfirmation(defaults: defaults)
    let cards = try await addTempCards(3)

    QuickAccessManager.shared.requestCloseAll(confirmation: confirmation) { .cancel }

    XCTAssertEqual(Set(QuickAccessManager.shared.items.map(\.id)), Set(cards.map(\.id)))
    XCTAssertTrue(confirmation.requiresPrompt)
  }
}

@MainActor
final class QuickAccessSaveOwnershipTests: XCTestCase {
  func testSaveAllSkipsActiveEditorButKeepsIdleAndPinnedCapturesEligible() {
    let fixture = makeFixture()
    fixture.manager.pauseCountdownForEditingItem(fixture.edited.id)
    var firstBatch: [UUID] = []
    fixture.manager.saveAll { firstBatch.append($0) }

    XCTAssertEqual(Set(firstBatch), [fixture.idle.id, fixture.pinned.id])
    XCTAssertEqual(firstBatch.count, 2)

    fixture.manager.resumeCountdownForEditingItem(fixture.edited.id)
    var retryBatch: [UUID] = []
    fixture.manager.saveAll { retryBatch.append($0) }
    XCTAssertEqual(Set(retryBatch), [fixture.edited.id, fixture.idle.id, fixture.pinned.id])
    XCTAssertEqual(retryBatch.count, 3)
  }

  func testActualDirectSavePreservesSourceUntilEditingEnds() async throws {
    try await withTemporaryCapture { manager, item, destination, bytes in
      manager.pauseCountdownForEditingItem(item.id)
      // The editor retains its ordinary in-place save reservation.
      XCTAssertTrue(manager.beginSavingItem(id: item.id))
      manager.finishSavingItem(id: item.id)
      manager.saveItem(id: item.id, useSavePanel: false, revealInFinder: false)
      let firstSaveFinished = await waitForSaveRelease(manager, id: item.id)
      XCTAssertTrue(firstSaveFinished)

      XCTAssertEqual(try? Data(contentsOf: item.url), bytes)
      XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
      XCTAssertEqual(manager.item(id: item.id)?.url, item.url)
      guard manager.item(id: item.id) != nil else { return }

      manager.resumeCountdownForEditingItem(item.id)
      manager.saveItem(id: item.id, useSavePanel: false, revealInFinder: false)
      let retryFinished = await waitForSaveRelease(manager, id: item.id)
      XCTAssertTrue(retryFinished)
      XCTAssertEqual(try Data(contentsOf: destination), bytes)
      XCTAssertFalse(FileManager.default.fileExists(atPath: item.url.path))
      XCTAssertNil(manager.item(id: item.id))
    }
  }

  func testActualDirectSaveRechecksEditorOwnershipBeforeMovingSource() async throws {
    try await withTemporaryCapture { manager, item, destination, bytes in
      manager.saveItem(id: item.id, useSavePanel: false, revealInFinder: false)
      // The Save task has reserved this card and cannot run before this main-actor turn ends.
      manager.pauseCountdownForEditingItem(item.id)
      let finished = await waitForSaveRelease(manager, id: item.id)

      XCTAssertTrue(finished, "A rejected pending move must release its Save reservation")
      XCTAssertEqual(try? Data(contentsOf: item.url), bytes)
      XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
      XCTAssertEqual(manager.item(id: item.id)?.url, item.url)
    }
  }

  func testPendingDirectSaveKeepsAReplacementAtTheCapturePath() async throws {
    try await withTemporaryCapture { manager, item, destination, bytes in
      let fileManager = FileManager.default
      let heldSource = item.url.appendingPathExtension("original")
      defer { try? fileManager.removeItem(at: heldSource) }
      let replacement = Data("another capture".utf8)

      manager.saveItem(id: item.id, useSavePanel: false, revealInFinder: false)
      try fileManager.moveItem(at: item.url, to: heldSource)
      try replacement.write(to: item.url)
      let finished = await waitForSaveRelease(manager, id: item.id)

      XCTAssertTrue(finished)
      XCTAssertEqual(try Data(contentsOf: heldSource), bytes)
      XCTAssertEqual(try Data(contentsOf: item.url), replacement)
      XCTAssertFalse(fileManager.fileExists(atPath: destination.path))
      XCTAssertEqual(manager.item(id: item.id)?.url, item.url)
    }
  }

  private func waitForSaveRelease(_ manager: QuickAccessManager, id: UUID) async -> Bool {
    for _ in 0..<100 {
      if manager.beginSavingItem(id: id) {
        manager.finishSavingItem(id: id)
        return true
      }
      await Task.yield()
    }
    return false
  }

  private func withTemporaryCapture(
    _ body: (QuickAccessManager, QuickAccessItem, URL, Data) async throws -> Void
  ) async throws {
    let root = try XCTUnwrap(OwnShotStoragePaths.testRoot)
    let fileManager = FileManager.default
    let export = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try fileManager.createDirectory(at: export, withIntermediateDirectories: true)
    let source = TempCaptureManager.shared.tempCaptureDirectory
      .appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
    let destination = export.appendingPathComponent(source.lastPathComponent)

    let defaults = UserDefaults.standard
    let oldExport = defaults.object(forKey: PreferencesKeys.exportLocation)
    let oldBookmark = defaults.object(forKey: PreferencesKeys.exportLocationBookmark)
    let preferences = PreferencesManager.shared
    let oldActions = preferences.afterCaptureActions
    defer {
      defaults.set(oldExport, forKey: PreferencesKeys.exportLocation)
      defaults.set(oldBookmark, forKey: PreferencesKeys.exportLocationBookmark)
      preferences.afterCaptureActions = oldActions
      try? fileManager.removeItem(at: source)
      try? fileManager.removeItem(at: export)
    }
    defaults.set(export.path, forKey: PreferencesKeys.exportLocation)
    defaults.removeObject(forKey: PreferencesKeys.exportLocationBookmark)
    preferences.afterCaptureActions[.copyFile, default: [:]][.screenshot] = false

    let image = try XCTUnwrap(TestImageFactory.solidColor(width: 16, height: 16))
    let bytes = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    try bytes.write(to: source)
    let item = QuickAccessItem(url: source, thumbnail: NSImage(cgImage: image, size: NSSize(width: 16, height: 16)))
    let manager = QuickAccessManager(presentsPanel: false, initialItems: [item])
    try await body(manager, item, destination, bytes)
  }

  private func makeFixture() -> (manager: QuickAccessManager, edited: QuickAccessItem, idle: QuickAccessItem, pinned: QuickAccessItem) {
    let directory = TempCaptureManager.shared.tempCaptureDirectory.appendingPathComponent(UUID().uuidString)
    let edited = QuickAccessItem(url: directory.appendingPathComponent("edited.png"), thumbnail: NSImage())
    let idle = QuickAccessItem(url: directory.appendingPathComponent("idle.png"), thumbnail: NSImage())
    var pinned = QuickAccessItem(url: directory.appendingPathComponent("pinned.png"), thumbnail: NSImage())
    pinned.isPinned = true
    let manager = QuickAccessManager(presentsPanel: false, initialItems: [edited, idle, pinned])
    return (manager, edited, idle, pinned)
  }
}
