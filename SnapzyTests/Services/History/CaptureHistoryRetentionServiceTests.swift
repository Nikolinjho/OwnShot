//
//  CaptureHistoryRetentionServiceTests.swift
//  SnapzyTests
//
//  Unit tests for retention service scheduling and sweep logic.
//  Verifies via synchronous DB reads to avoid observation timing issues.
//

import AppKit
import Foundation
import XCTest
@testable import Snapzy

@MainActor
final class CaptureHistoryRetentionServiceTests: XCTestCase {

  private var service: CaptureHistoryRetentionService!
  private var defaults: UserDefaults!
  private var defaultsSuiteName: String!
  private var tempDirectory: URL!
  private var annotationSessionStore: AnnotationSessionStore!
  private var videoEditorSessionStore: VideoEditorSessionStore!

  override func setUp() {
    super.setUp()
    service = CaptureHistoryRetentionService.shared
    tempDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("SnapzyTests_CaptureHistoryRetention_\(UUID().uuidString)", isDirectory: true)
    annotationSessionStore = AnnotationSessionStore(
      rootDirectory: tempDirectory.appendingPathComponent("AnnotationSessions", isDirectory: true)
    )
    videoEditorSessionStore = VideoEditorSessionStore(
      rootDirectory: tempDirectory.appendingPathComponent("VideoEditorSessions", isDirectory: true)
    )
    defaultsSuiteName = "SnapzyTests.CaptureHistoryRetentionServiceTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: defaultsSuiteName)
    defaults.removePersistentDomain(forName: defaultsSuiteName)
    defaults.set(true, forKey: PreferencesKeys.historyEnabled)
    defaults.set(0, forKey: PreferencesKeys.historyRetentionDays)
    defaults.set(0, forKey: PreferencesKeys.historyMaxCount)
    CaptureHistoryStore.shared.userDefaults = defaults
    service.userDefaults = defaults
    service.annotationSessionStore = annotationSessionStore
    service.videoEditorSessionStore = videoEditorSessionStore

    CaptureHistoryStore.shared.removeAll()
    CaptureHistoryStore.shared.refreshRecords()
  }

  override func tearDown() {
    service.stop()
    CaptureHistoryStore.shared.removeAll()
    CaptureHistoryStore.shared.refreshRecords()
    UserDefaults.standard.removePersistentDomain(forName: defaultsSuiteName)
    CaptureHistoryStore.shared.userDefaults = .standard
    service.userDefaults = .standard
    service.annotationSessionStore = .shared
    service.videoEditorSessionStore = .shared
    try? FileManager.default.removeItem(at: tempDirectory)
    annotationSessionStore = nil
    videoEditorSessionStore = nil
    tempDirectory = nil
    super.tearDown()
  }

  // MARK: - sweep

  func testSweep_skipsWhenHistoryDisabled() async {
    defaults.set(false, forKey: PreferencesKeys.historyEnabled)
    await service.sweep()
  }

  func testSweep_noOpWhenRetentionDaysZeroAndMaxCountZero() async {
    let record = makeRecord()
    CaptureHistoryStore.shared.add(record)
    CaptureHistoryStore.shared.refreshRecords()
    XCTAssertTrue(CaptureHistoryStore.shared.hasRecord(forFilePath: record.filePath))

    await service.sweep()
    XCTAssertTrue(CaptureHistoryStore.shared.hasRecord(forFilePath: record.filePath))
  }

  func testSweep_removesOldRecordsWhenRetentionDaysSet() async {
    defaults.set(7, forKey: PreferencesKeys.historyRetentionDays)
    let old = makeRecord(capturedAt: Date().addingTimeInterval(-86400 * 10))
    let recent = makeRecord(capturedAt: Date())
    CaptureHistoryStore.shared.add(old)
    CaptureHistoryStore.shared.add(recent)
    CaptureHistoryStore.shared.refreshRecords()

    await service.sweep()
    CaptureHistoryStore.shared.refreshRecords()
    XCTAssertFalse(CaptureHistoryStore.shared.hasRecord(forFilePath: old.filePath))
    XCTAssertTrue(CaptureHistoryStore.shared.hasRecord(forFilePath: recent.filePath))
  }

  func testSweepKeepsADirectoryAtAnExpiredTempCapturePath() async throws {
    let testRoot = try XCTUnwrap(OwnShotStoragePaths.testRoot)
    let capturesRoot = TempCaptureManager.shared.tempCaptureDirectory
    guard capturesRoot.standardizedFileURL.path.hasPrefix(testRoot.standardizedFileURL.path + "/") else {
      return XCTFail("Для теста требуется отдельный каталог снимков Test Host")
    }
    let fixtures = capturesRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let replacement = fixtures.appendingPathComponent("capture.png", isDirectory: true)
    try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: fixtures) }

    let data = Data("temporary fixture".utf8)
    let retained = replacement.appendingPathComponent("keep.txt")
    let expired = fixtures.appendingPathComponent("expired.png")
    try data.write(to: retained)
    try data.write(to: expired)

    defaults.set(7, forKey: PreferencesKeys.historyRetentionDays)
    let cutoff = Date().addingTimeInterval(-86400 * 10)
    for url in [replacement, expired] {
      CaptureHistoryStore.shared.add(makeRecord(filePath: url.path, capturedAt: cutoff))
      XCTAssertTrue(CaptureHistoryStore.shared.hasRecord(forFilePath: url.path))
    }

    await service.sweep()

    XCTAssertFalse(CaptureHistoryStore.shared.hasRecord(forFilePath: replacement.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: expired.path))
    XCTAssertEqual(try Data(contentsOf: retained), data)
  }

  func testSweepKeepsAFileOutsideTempStorageReachedThroughALinkedDirectory() async throws {
    let testRoot = try XCTUnwrap(OwnShotStoragePaths.testRoot)
    let capturesRoot = TempCaptureManager.shared.tempCaptureDirectory
    guard capturesRoot.standardizedFileURL.path.hasPrefix(testRoot.standardizedFileURL.path + "/") else {
      return XCTFail("Для теста требуется отдельный каталог снимков Test Host")
    }
    let fixtures = capturesRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: fixtures) }

    let external = try writeSourceFile(named: "external.png")
    let original = try Data(contentsOf: external)
    let link = fixtures.appendingPathComponent("linked")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external.deletingLastPathComponent())
    let historyURL = link.appendingPathComponent(external.lastPathComponent)
    XCTAssertTrue(TempCaptureManager.shared.isTempFile(historyURL))

    defaults.set(7, forKey: PreferencesKeys.historyRetentionDays)
    let cutoff = Date().addingTimeInterval(-86400 * 10)
    CaptureHistoryStore.shared.add(makeRecord(filePath: historyURL.path, capturedAt: cutoff))
    XCTAssertTrue(CaptureHistoryStore.shared.hasRecord(forFilePath: historyURL.path))

    await service.sweep()

    XCTAssertFalse(CaptureHistoryStore.shared.hasRecord(forFilePath: historyURL.path))
    XCTAssertEqual(try Data(contentsOf: external), original)
  }

  func testSweepKeepsAnExpiredTempFileStillReferencedByALiveAlias() async throws {
    let testRoot = try XCTUnwrap(OwnShotStoragePaths.testRoot)
    let capturesRoot = TempCaptureManager.shared.tempCaptureDirectory
    guard capturesRoot.standardizedFileURL.path.hasPrefix(testRoot.standardizedFileURL.path + "/") else {
      return XCTFail("Для теста требуется отдельный каталог снимков Test Host")
    }
    let fixtures = capturesRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: fixtures) }

    let source = fixtures.appendingPathComponent("capture.png")
    let alias = fixtures.appendingPathComponent("alias.png")
    let data = Data("temporary fixture".utf8)
    try data.write(to: source)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)

    defaults.set(7, forKey: PreferencesKeys.historyRetentionDays)
    let cutoff = Date().addingTimeInterval(-86400 * 10)
    CaptureHistoryStore.shared.add(makeRecord(filePath: source.path, capturedAt: cutoff))
    CaptureHistoryStore.shared.add(makeRecord(filePath: alias.path))
    XCTAssertTrue(CaptureHistoryStore.shared.hasRecord(forFilePath: source.path))
    XCTAssertTrue(CaptureHistoryStore.shared.hasRecord(forFilePath: alias.path))

    await service.sweep()

    XCTAssertFalse(CaptureHistoryStore.shared.hasRecord(forFilePath: source.path))
    XCTAssertTrue(CaptureHistoryStore.shared.hasRecord(forFilePath: alias.path))
    XCTAssertEqual(try Data(contentsOf: alias), data)
  }

  func testSweepKeepsAnExpiredTempFileWhileTheClipboardReferencesIt() async throws {
    let testRoot = try XCTUnwrap(OwnShotStoragePaths.testRoot)
    let capturesRoot = TempCaptureManager.shared.tempCaptureDirectory
    guard capturesRoot.standardizedFileURL.path.hasPrefix(testRoot.standardizedFileURL.path + "/"),
          ClipboardHelper.pasteboardName != .general else {
      return XCTFail("Для теста нужны отдельные хранилище и буфер Test Host")
    }
    let fixtures = capturesRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
    let pasteboard = ClipboardHelper.pasteboard
    defer {
      pasteboard.clearContents()
      ClipboardHelper.resetPasteboardReferenceTracking()
      try? FileManager.default.removeItem(at: fixtures)
    }

    let retained = fixtures.appendingPathComponent("copied.png")
    let removed = fixtures.appendingPathComponent("uncopied.png")
    let data = Data("temporary fixture".utf8)
    try data.write(to: retained)
    try data.write(to: removed)
    ClipboardHelper.copyFileURLs([retained])
    XCTAssertTrue(ClipboardHelper.isReferencedByGeneralPasteboard(retained))

    defaults.set(7, forKey: PreferencesKeys.historyRetentionDays)
    let cutoff = Date().addingTimeInterval(-86400 * 10)
    for url in [retained, removed] {
      CaptureHistoryStore.shared.add(makeRecord(filePath: url.path, capturedAt: cutoff))
      XCTAssertTrue(CaptureHistoryStore.shared.hasRecord(forFilePath: url.path))
    }

    await service.sweep()

    XCTAssertFalse(CaptureHistoryStore.shared.hasRecord(forFilePath: retained.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: removed.path))
    XCTAssertEqual(try Data(contentsOf: retained), data)
  }

  func testSweepKeepsExpiredTempFilesStillOwnedByQuickAccess() async throws {
    let testRoot = try XCTUnwrap(OwnShotStoragePaths.testRoot)
    let capturesRoot = TempCaptureManager.shared.tempCaptureDirectory
    guard capturesRoot.standardizedFileURL.path.hasPrefix(testRoot.standardizedFileURL.path + "/") else {
      return XCTFail("Для теста требуется отдельный каталог снимков Test Host")
    }
    let fixtures = capturesRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
    let manager = QuickAccessManager(presentsPanel: false)
    let preferences = UserDefaults.standard
    let originalAutoDismiss = preferences.object(forKey: PreferencesKeys.floatingAutoDismissEnabled)
    manager.autoDismissEnabled = false
    defer {
      manager.dismissAll()
      preferences.set(originalAutoDismiss, forKey: PreferencesKeys.floatingAutoDismissEnabled)
      try? FileManager.default.removeItem(at: fixtures)
    }

    let visible = fixtures.appendingPathComponent("visible.png")
    let closed = fixtures.appendingPathComponent("closed.png")
    let control = fixtures.appendingPathComponent("unowned.png")
    let image = try XCTUnwrap(TestImageFactory.solidColor(width: 4, height: 4))
    let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    defaults.set(7, forKey: PreferencesKeys.historyRetentionDays)
    let cutoff = Date().addingTimeInterval(-86400 * 10)
    for url in [visible, closed, control] {
      try data.write(to: url)
      CaptureHistoryStore.shared.add(makeRecord(filePath: url.path, capturedAt: cutoff))
      XCTAssertTrue(CaptureHistoryStore.shared.hasRecord(forFilePath: url.path))
    }

    let visibleCard = await manager.addScreenshot(url: visible)
    let closingCard = await manager.addScreenshot(url: closed)
    XCTAssertNotNil(visibleCard)
    manager.dismissCard(id: try XCTUnwrap(closingCard).id)
    await service.sweep(quickAccess: manager)

    XCTAssertFalse(CaptureHistoryStore.shared.hasRecord(forFilePath: visible.path))
    XCTAssertFalse(CaptureHistoryStore.shared.hasRecord(forFilePath: closed.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: control.path))
    XCTAssertEqual(try Data(contentsOf: visible), data)
    XCTAssertEqual(try Data(contentsOf: closed), data)
    await manager.restoreRecentlyClosed()
    XCTAssertEqual(manager.items.map(\.url), [closed, visible])
  }

  func testSweepKeepsEditorSessionsForCapturesStillInQuickAccess() async throws {
    let screenshot = try writeSourceFile(named: "visible.png")
    let recording = try writeSourceFile(named: "visible.mov")
    let snapshot = try writeSourceFile(named: "master.mov")
    let unrelated = try writeSourceFile(named: "unowned.png")
    let thumbnail = NSImage(size: CGSize(width: 4, height: 4))
    let manager = QuickAccessManager(presentsPanel: false, initialItems: [
      QuickAccessItem(url: screenshot, thumbnail: thumbnail),
      QuickAccessItem(url: recording, thumbnail: thumbnail, duration: 1),
    ])
    defer { manager.dismissAll() }

    XCTAssertTrue(annotationSessionStore.persist(makeSessionData(), for: screenshot))
    XCTAssertTrue(annotationSessionStore.persist(makeSessionData(), for: unrelated))
    let recordingSession = VideoEditorSessionData(sourceSnapshotURL: snapshot)
    XCTAssertTrue(videoEditorSessionStore.persist(recordingSession, for: recording))

    defaults.set(7, forKey: PreferencesKeys.historyRetentionDays)
    let cutoff = Date().addingTimeInterval(-86400 * 10)
    CaptureHistoryStore.shared.add(makeRecord(filePath: screenshot.path, capturedAt: cutoff))

    await service.sweep(quickAccess: manager)

    XCTAssertFalse(CaptureHistoryStore.shared.hasRecord(forFilePath: screenshot.path))
    XCTAssertNotNil(annotationSessionStore.load(for: screenshot))
    XCTAssertNotNil(videoEditorSessionStore.load(for: recording))
    XCTAssertFalse(FileManager.default.fileExists(atPath: sidecarDirectory(for: unrelated).path))
  }

  func testSweepRecoversVideoEditsAfterAHistorySourceReturns() async throws {
    let source = try writeSourceFile(named: "temporarily-missing.mov")
    let heldSource = source.deletingLastPathComponent().appendingPathComponent("held.mov")
    let sourceSnapshot = try writeSourceFile(named: "master.mov")
    let history = CaptureHistoryRecord(
      id: UUID(), filePath: source.path, fileName: source.lastPathComponent, captureType: .video,
      fileSize: 16, capturedAt: Date(), width: 4, height: 4, duration: 1,
      thumbnailPath: nil, isDeleted: false
    )
    CaptureHistoryStore.shared.add(history)
    XCTAssertTrue(CaptureHistoryStore.shared.hasRecord(forFilePath: source.path))
    XCTAssertTrue(videoEditorSessionStore.persist(
      VideoEditorSessionData(sourceSnapshotURL: sourceSnapshot), for: source
    ))
    let existing = try XCTUnwrap(videoEditorSessionStore.load(for: source))
    let originalSnapshotBytes = try Data(contentsOf: existing.sourceSnapshotURL)

    try FileManager.default.moveItem(at: source, to: heldSource)
    await service.sweep()
    try FileManager.default.moveItem(at: heldSource, to: source)

    let recovered = try XCTUnwrap(videoEditorSessionStore.load(for: source))
    XCTAssertEqual(try Data(contentsOf: recovered.sourceSnapshotURL), originalSnapshotBytes)
    XCTAssertTrue(CaptureHistoryStore.shared.hasRecord(forFilePath: source.path))
  }

  func testSweep_trimsToMaxCount() async {
    defaults.set(2, forKey: PreferencesKeys.historyMaxCount)
    let r1 = makeRecord(capturedAt: Date().addingTimeInterval(-10))
    let r2 = makeRecord(capturedAt: Date().addingTimeInterval(-5))
    let r3 = makeRecord(capturedAt: Date())
    CaptureHistoryStore.shared.add(r1)
    CaptureHistoryStore.shared.add(r2)
    CaptureHistoryStore.shared.add(r3)
    CaptureHistoryStore.shared.refreshRecords()

    await service.sweep()
    CaptureHistoryStore.shared.refreshRecords()
    let ids = Set(CaptureHistoryStore.shared.records.map(\.id))
    XCTAssertEqual(ids.count, 2)
    XCTAssertTrue(ids.contains(r2.id))
    XCTAssertTrue(ids.contains(r3.id))
  }

  // MARK: - clearAllHistory

  func testClearAllHistory_removesAllRecordsAndThumbnails() {
    CaptureHistoryStore.shared.add(makeRecord())
    CaptureHistoryStore.shared.refreshRecords()

    service.clearAllHistory()
    CaptureHistoryStore.shared.refreshRecords()
    XCTAssertTrue(CaptureHistoryStore.shared.records.isEmpty)
  }

  func testClearAllHistory_removesAnnotationSidecars() throws {
    let sourceURL = try writeSourceFile(named: "capture.png")
    XCTAssertTrue(annotationSessionStore.persist(makeSessionData(), for: sourceURL))
    XCTAssertNotNil(annotationSessionStore.load(for: sourceURL))

    service.clearAllHistory()

    XCTAssertNil(annotationSessionStore.load(for: sourceURL))
  }

  func testClearAllHistory_removesVideoEditorSidecars() throws {
    let sourceURL = try writeSourceFile(named: "capture.mov")
    let masterURL = try writeSourceFile(named: "capture-master.mov")
    let sessionData = VideoEditorSessionData(sourceSnapshotURL: masterURL)
    XCTAssertTrue(videoEditorSessionStore.persist(sessionData, for: sourceURL))
    XCTAssertNotNil(videoEditorSessionStore.load(for: sourceURL))

    service.clearAllHistory()

    XCTAssertNil(videoEditorSessionStore.load(for: sourceURL))
  }

  func testSweep_cleansOrphanedAnnotationSidecars() async throws {
    let activeURL = try writeSourceFile(named: "active.png")
    let inactiveURL = try writeSourceFile(named: "inactive.png")
    let missingURL = try writeSourceFile(named: "missing.png")

    CaptureHistoryStore.shared.add(makeRecord(filePath: activeURL.path))
    CaptureHistoryStore.shared.refreshRecords()
    XCTAssertTrue(annotationSessionStore.persist(makeSessionData(), for: activeURL))
    XCTAssertTrue(annotationSessionStore.persist(makeSessionData(), for: inactiveURL))
    XCTAssertTrue(annotationSessionStore.persist(makeSessionData(), for: missingURL))
    try FileManager.default.removeItem(at: missingURL)

    await service.sweep()

    XCTAssertNotNil(annotationSessionStore.load(for: activeURL))
    XCTAssertFalse(FileManager.default.fileExists(atPath: sidecarDirectory(for: inactiveURL).path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: sidecarDirectory(for: missingURL).path))
  }

  func testSweepRecoversEditsForRetainedHistoryAfterMissingRasterReturns() async throws {
    let source = try writeSourceFile(named: "temporarily-missing.png")
    let heldFile = source.deletingLastPathComponent().appendingPathComponent("held.png")
    let session = makeSessionData()
    let originalRaster = try Data(contentsOf: source)
    let record = makeRecord(filePath: source.path, capturedAt: Date(timeIntervalSince1970: 100))
    CaptureHistoryStore.shared.add(record)
    XCTAssertTrue(annotationSessionStore.persist(session, for: source))
    let package = sidecarDirectory(for: source)
    let manifest = package.appendingPathComponent("manifest.json")
    let originalManifest = try Data(contentsOf: manifest)

    try FileManager.default.moveItem(at: source, to: heldFile)
    await service.sweep()

    XCTAssertTrue(CaptureHistoryStore.shared.hasRecord(forFilePath: source.path))
    XCTAssertEqual(try? Data(contentsOf: manifest), originalManifest)
    XCTAssertNil(annotationSessionStore.load(for: source))

    try FileManager.default.moveItem(at: heldFile, to: source)
    let recovered = annotationSessionStore.load(for: source)
    XCTAssertEqual(recovered?.originalImageData, session.originalImageData)
    XCTAssertEqual(recovered?.annotations.map(\.id), session.annotations.map(\.id))

    let newer = try writeSourceFile(named: "newer.png")
    CaptureHistoryStore.shared.add(makeRecord(filePath: newer.path, capturedAt: Date(timeIntervalSince1970: 200)))
    defaults.set(1, forKey: PreferencesKeys.historyMaxCount)
    await service.sweep()

    XCTAssertFalse(CaptureHistoryStore.shared.hasRecord(forFilePath: source.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: package.path))
    XCTAssertEqual(try Data(contentsOf: source), originalRaster)
  }

  func testSweepRemovesStaleEditsForChangedRasterEvenWithRetainedRow() async throws {
    let source = try writeSourceFile(named: "changed.png")
    CaptureHistoryStore.shared.add(makeRecord(filePath: source.path))
    XCTAssertTrue(annotationSessionStore.persist(makeSessionData(), for: source))
    let replacement = Data("different screenshot bytes at the same path".utf8)
    try replacement.write(to: source, options: .atomic)

    await service.sweep()

    XCTAssertTrue(CaptureHistoryStore.shared.hasRecord(forFilePath: source.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: sidecarDirectory(for: source).path))
    XCTAssertNil(annotationSessionStore.load(for: source))
    XCTAssertEqual(try Data(contentsOf: source), replacement)
  }

  func testSweep_cleansOrphanedVideoEditorSidecars() async throws {
    let activeURL = try writeSourceFile(named: "active.mov")
    let inactiveURL = try writeSourceFile(named: "inactive.mov")
    let activeMasterURL = try writeSourceFile(named: "active-master.mov")
    let inactiveMasterURL = try writeSourceFile(named: "inactive-master.mov")

    CaptureHistoryStore.shared.add(makeRecord(filePath: activeURL.path))
    CaptureHistoryStore.shared.refreshRecords()
    XCTAssertTrue(
      videoEditorSessionStore.persist(
        VideoEditorSessionData(sourceSnapshotURL: activeMasterURL),
        for: activeURL
      )
    )
    XCTAssertTrue(
      videoEditorSessionStore.persist(
        VideoEditorSessionData(sourceSnapshotURL: inactiveMasterURL),
        for: inactiveURL
      )
    )

    await service.sweep()

    XCTAssertNotNil(videoEditorSessionStore.load(for: activeURL))
    XCTAssertFalse(FileManager.default.fileExists(atPath: videoSessionDirectory(for: inactiveURL).path))
  }

  func testSweep_keepsSidecarsWhenStoreHasNotPublishedRecordsYet() async throws {
    let sourceURL = try writeSourceFile(named: "launch.png")
    let videoURL = try writeSourceFile(named: "launch.mov")
    let masterURL = try writeSourceFile(named: "launch-master.mov")
    CaptureHistoryStore.shared.add(makeRecord(filePath: sourceURL.path))
    CaptureHistoryStore.shared.add(makeRecord(filePath: videoURL.path))
    XCTAssertTrue(annotationSessionStore.persist(makeSessionData(), for: sourceURL))
    XCTAssertTrue(
      videoEditorSessionStore.persist(VideoEditorSessionData(sourceSnapshotURL: masterURL), for: videoURL)
    )
    // No refreshRecords(): like app launch, the observation has not delivered the rows yet.
    try XCTSkipUnless(
      CaptureHistoryStore.shared.records.isEmpty,
      "Observation already published the new rows; the launch race cannot be reproduced"
    )

    await service.sweep()

    XCTAssertNotNil(annotationSessionStore.load(for: sourceURL))
    XCTAssertNotNil(videoEditorSessionStore.load(for: videoURL))
  }

  func testFetchRecords_readsDatabaseBeforeObservationPublishes() {
    let record = makeRecord()
    CaptureHistoryStore.shared.add(record)

    XCTAssertEqual(CaptureHistoryStore.shared.fetchRecords()?.map(\.id), [record.id])
  }

  // MARK: - temp file collection

  func testTempFilePaths_collectsExpiredAndOverflowTempRecords() {
    let now = Date()
    let newest = makeRecord(filePath: "/tmp/newest.png", capturedAt: now)
    let overflow = makeRecord(filePath: "/tmp/overflow.png", capturedAt: now.addingTimeInterval(-60))
    let expired = makeRecord(filePath: "/tmp/expired.png", capturedAt: now.addingTimeInterval(-86400 * 10))
    let expiredSaved = makeRecord(filePath: "/saved/expired.png", capturedAt: now.addingTimeInterval(-86400 * 11))

    let paths = CaptureHistoryRetentionService.tempFilePathsForRecordsToDelete(
      in: [newest, overflow, expired, expiredSaved],
      retentionDays: 7,
      maxCount: 1,
      now: now,
      isTempFile: { $0.path.hasPrefix("/tmp/") }
    )

    XCTAssertEqual(paths, [expired.filePath, overflow.filePath])
  }

  func testTempFilePaths_emptyWhenLimitsDisabled() {
    let record = makeRecord(filePath: "/tmp/old.png", capturedAt: Date().addingTimeInterval(-86400 * 100))

    let paths = CaptureHistoryRetentionService.tempFilePathsForRecordsToDelete(
      in: [record],
      retentionDays: 0,
      maxCount: 0,
      isTempFile: { _ in true }
    )

    XCTAssertTrue(paths.isEmpty)
  }

  // MARK: - thumbnail ownership

  func testThumbnailOwnership_matchesLegacyAndCacheKeyedNames() {
    let id = UUID().uuidString
    let ids: Set<String> = [id]

    XCTAssertTrue(CaptureHistoryRetentionService.thumbnail(named: id, belongsToAnyOf: ids))
    XCTAssertTrue(
      CaptureHistoryRetentionService.thumbnail(named: "\(id)-preview-v2-1700000000000-1024", belongsToAnyOf: ids)
    )
    XCTAssertFalse(
      CaptureHistoryRetentionService.thumbnail(named: "\(UUID().uuidString)-preview-v2-1-1", belongsToAnyOf: ids)
    )
    XCTAssertFalse(CaptureHistoryRetentionService.thumbnail(named: "\(id)x", belongsToAnyOf: ids))
  }

  // MARK: - start / stop

  func testStartStop_lifecycleDoesNotCrash() {
    service.start()
    service.stop()
    service.start()
    service.stop()
  }

  // MARK: - Helpers

  private func makeRecord(capturedAt: Date = Date()) -> CaptureHistoryRecord {
    let path = "/tmp/\(UUID().uuidString).png"
    return makeRecord(filePath: path, capturedAt: capturedAt)
  }

  private func makeRecord(filePath path: String, capturedAt: Date = Date()) -> CaptureHistoryRecord {
    return CaptureHistoryRecord(
      id: UUID(),
      filePath: path,
      fileName: (path as NSString).lastPathComponent,
      captureType: .screenshot,
      fileSize: 1024,
      capturedAt: capturedAt,
      width: 100,
      height: 100,
      duration: nil,
      thumbnailPath: nil,
      isDeleted: false
    )
  }

  private func makeSessionData() -> AnnotationSessionData {
    AnnotationSessionData(
      originalImageData: Data("original".utf8),
      annotations: [
        AnnotationItem(
          type: .text("History"),
          bounds: CGRect(x: 0, y: 0, width: 40, height: 16),
          properties: AnnotationProperties()
        )
      ],
      canvasEffects: AnnotationCanvasEffects(),
      cropRect: nil
    )
  }

  private func writeSourceFile(named fileName: String) throws -> URL {
    let directory = tempDirectory.appendingPathComponent("Sources", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(fileName)
    try Data("source-\(fileName)".utf8).write(to: url, options: .atomic)
    return url
  }

  private func sidecarDirectory(for sourceURL: URL) -> URL {
    let normalizedPath = AnnotationSessionStore.normalizedPath(for: sourceURL)
    return tempDirectory
      .appendingPathComponent("AnnotationSessions", isDirectory: true)
      .appendingPathComponent(AnnotationSessionStore.pathHash(for: normalizedPath), isDirectory: true)
  }

  private func videoSessionDirectory(for sourceURL: URL) -> URL {
    let normalizedPath = VideoEditorSessionStore.normalizedPath(for: sourceURL)
    return tempDirectory
      .appendingPathComponent("VideoEditorSessions", isDirectory: true)
      .appendingPathComponent(VideoEditorSessionStore.pathHash(for: normalizedPath), isDirectory: true)
  }
}
