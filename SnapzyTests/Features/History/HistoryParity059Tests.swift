import Foundation
import GRDB
import XCTest
@testable import Snapzy

/// Паритет History с CleanShot X, волна 059
@MainActor
final class HistoryParity059Tests: XCTestCase {
  func testМенюKeepHistoryОтмечаетТекущийСрок() {
    XCTAssertEqual(HistoryRetentionChoice.current(historyEnabled: false, retentionDays: 3), .never)
    XCTAssertEqual(HistoryRetentionChoice.current(historyEnabled: true, retentionDays: 3), .threeDays)
    XCTAssertEqual(HistoryRetentionChoice.current(historyEnabled: true, retentionDays: 30), .oneMonth)
    XCTAssertNil(HistoryRetentionChoice.current(historyEnabled: true, retentionDays: 0))
    XCTAssertEqual(
      HistoryRetentionChoice.allCases.map(\.title),
      ["Never", "1 day", "3 days", "1 week", "1 month"]
    )
  }

  func testВыборСрокаМеняетНастройки() {
    var enabled = true
    var days = 30
    HistoryRetentionChoice.never.apply(historyEnabled: &enabled, retentionDays: &days)
    XCTAssertFalse(enabled)
    XCTAssertEqual(days, 30)
    HistoryRetentionChoice.oneWeek.apply(historyEnabled: &enabled, retentionDays: &days)
    XCTAssertTrue(enabled)
    XCTAssertEqual(days, 7)
  }

  func testТекстПустойИстории() {
    XCTAssertEqual(HistoryChrome.emptyTitle(historyEnabled: true), "No files to restore...")
    XCTAssertEqual(HistoryChrome.emptyTitle(historyEnabled: false), "Capture History is disabled.")
    XCTAssertEqual(L10n.PreferencesHistory.filterVideoProjects, "Video Projects")
    XCTAssertEqual(
      L10n.PreferencesHistory.clearHistoryDeleteAllTitle,
      "Are you sure you want to delete all files from history?"
    )
  }

  func testDeleteОставляетСохранённыеФайлы() {
    let temp = URL(fileURLWithPath: "/tmp/OwnShotCaptures", isDirectory: true)
    XCTAssertTrue(HistoryDeleteFilePolicy.shouldRecycleFile(at: temp.appendingPathComponent("a.png"), tempDirectory: temp))
    XCTAssertFalse(HistoryDeleteFilePolicy.shouldRecycleFile(at: URL(fileURLWithPath: "/Users/me/Desktop/a.png"), tempDirectory: temp))
    XCTAssertFalse(HistoryDeleteFilePolicy.shouldRecycleFile(at: URL(fileURLWithPath: "/tmp/OwnShotCaptures2/a.png"), tempDirectory: temp))
  }

  func testDeleteKeepsFailedCaptureAndCommitsOtherRecords() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let captures = root.appendingPathComponent("captures", isDirectory: true)
    try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let database = try DatabaseManager.openDatabase(at: root.appendingPathComponent("history.sqlite"))
    defer { XCTAssertNoThrow(try database.dbPool.close()) }
    let store = CaptureHistoryStore(databasePool: database.dbPool)
    let defaults = try XCTUnwrap(UserDefaults(suiteName: root.lastPathComponent))
    defer { defaults.removePersistentDomain(forName: root.lastPathComponent) }
    defaults.set(true, forKey: PreferencesKeys.historyEnabled)
    store.userDefaults = defaults
    let sessions = AnnotationSessionStore(rootDirectory: root.appendingPathComponent("sessions", isDirectory: true))

    func addRecord(at url: URL, present: Bool = true) throws -> CaptureHistoryRecord {
      try Data(url.lastPathComponent.utf8).write(to: url)
      let thumbnail = root.appendingPathComponent(UUID().uuidString)
      try Data([1]).write(to: thumbnail)
      let record = CaptureHistoryRecord(
        id: UUID(), filePath: url.path, fileName: url.lastPathComponent, captureType: .screenshot,
        fileSize: 1, capturedAt: Date(), thumbnailPath: thumbnail.path, isDeleted: false
      )
      store.add(record)
      XCTAssertTrue(sessions.persist(AnnotationSessionData(
        originalImageData: Data([2]), annotations: [],
        canvasEffects: AnnotationCanvasEffects()
      ), for: url))
      if !present { try FileManager.default.removeItem(at: url) }
      return record
    }

    let failed = try addRecord(at: captures.appendingPathComponent("failed.png"))
    let moved = try addRecord(at: captures.appendingPathComponent("moved.png"))
    let saved = try addRecord(at: root.appendingPathComponent("saved.png"))
    let missing = try addRecord(at: captures.appendingPathComponent("missing.png"), present: false)
    let recycled = root.appendingPathComponent("recycled.png")
    var attemptedNames = Set<String>()

    let outcome = await HistoryWindowController.shared.removeHistoryRecords(
      [failed, moved, saved, missing],
      store: store, sessionStore: sessions, tempDirectory: captures,
      deleteThumbnail: { _ in }
    ) { urls in
      for url in urls {
        attemptedNames.insert(url.lastPathComponent)
        XCTAssertTrue(store.hasRecord(forFilePath: url.path))
        XCTAssertNotNil(sessions.load(for: url))
      }
      let source = urls.first { $0.lastPathComponent == moved.fileName }
      if let source {
        do {
          try FileManager.default.moveItem(at: source, to: recycled)
        } catch {
          XCTFail("Scratch move failed: \(error)")
          return .init(moved: [], errorMessage: error.localizedDescription)
        }
      }
      return .init(moved: Set([source].compactMap { $0 }), errorMessage: "Trash failed")
    }

    XCTAssertEqual(attemptedNames, [failed.fileName, moved.fileName])
    XCTAssertEqual(outcome.removed, 3)
    XCTAssertEqual(outcome.errorMessage, "Trash failed")
    XCTAssertEqual(try XCTUnwrap(store.fetchRecords()).map(\.id), [failed.id])
    XCTAssertEqual(try Data(contentsOf: failed.fileURL), Data(failed.fileName.utf8))
    XCTAssertEqual(try Data(contentsOf: saved.fileURL), Data(saved.fileName.utf8))
    XCTAssertEqual(try Data(contentsOf: recycled), Data(moved.fileName.utf8))
    XCTAssertNotNil(sessions.load(for: failed.fileURL))
    XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(failed.thumbnailPath)))

    let failedAgain = await HistoryWindowController.shared.removeHistoryRecords(
      [failed], store: store, sessionStore: sessions, tempDirectory: captures,
      deleteThumbnail: { _ in XCTFail("Failed recycle must not delete a thumbnail") }
    ) { urls in
      XCTAssertEqual(urls.map(\.path), [failed.filePath])
      return .init(moved: [], errorMessage: CocoaError(.fileNoSuchFile).localizedDescription)
    }
    XCTAssertEqual(failedAgain.removed, 0)
    XCTAssertNotNil(failedAgain.errorMessage)
    XCTAssertEqual(try XCTUnwrap(store.fetchRecords()).map(\.id), [failed.id])
    XCTAssertNotNil(sessions.load(for: failed.fileURL))
    let changed = try addRecord(at: captures.appendingPathComponent("changed.png"))
    let recreated = try addRecord(at: captures.appendingPathComponent("recreated.png"))
    let absent = try addRecord(at: captures.appendingPathComponent("newly-created.png"), present: false)
    let replacement = root.appendingPathComponent("replacement.png")
    let staleOutcome = await HistoryWindowController.shared.removeHistoryRecords(
      [changed, recreated, absent], store: store, sessionStore: sessions, tempDirectory: captures,
      deleteThumbnail: { _ in XCTFail("A newer source must keep its record and thumbnail") }
    ) { urls in
      XCTAssertEqual(Set(urls.map(\.path)), [changed.filePath, recreated.filePath])
      do {
        try FileManager.default.moveItem(at: changed.fileURL, to: replacement)
        store.updateFilePath(id: changed.id, newPath: replacement.path)
        try FileManager.default.removeItem(at: recreated.fileURL)
        try Data("new capture".utf8).write(to: recreated.fileURL, options: .atomic)
        try Data("newly created capture".utf8).write(to: absent.fileURL, options: .atomic)
      } catch {
        XCTFail("Scratch replacement failed: \(error)")
      }
      await Task.yield()
      return .init(moved: Set(urls), errorMessage: nil)
    }
    XCTAssertEqual(staleOutcome.removed, 0)
    XCTAssertTrue(store.hasRecord(forFilePath: replacement.path))
    XCTAssertTrue(store.hasRecord(forFilePath: recreated.filePath))
    XCTAssertEqual(try Data(contentsOf: recreated.fileURL), Data("new capture".utf8))
    XCTAssertTrue(store.hasRecord(forFilePath: absent.filePath))
    XCTAssertEqual(try Data(contentsOf: absent.fileURL), Data("newly created capture".utf8))

    for record in [moved, saved, missing] {
      let sessionPath = AnnotationSessionStore.pathHash(
        for: AnnotationSessionStore.normalizedPath(for: record.fileURL)
      )
      XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("sessions")
        .appendingPathComponent(sessionPath).path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(record.thumbnailPath)))
    }
  }

  func testВнешнийФайлПолучаетТипПоРасширению() {
    XCTAssertEqual(HistoryExternalFileRecorder.captureType(for: URL(fileURLWithPath: "/tmp/a.GIF")), .gif)
    XCTAssertEqual(HistoryExternalFileRecorder.captureType(for: URL(fileURLWithPath: "/tmp/a.png")), .screenshot)
  }
}
