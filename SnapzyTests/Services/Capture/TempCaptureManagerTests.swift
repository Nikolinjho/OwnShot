//
//  TempCaptureManagerTests.swift
//  SnapzyTests
//
//  Unit tests for TempCaptureManager file lifecycle management.
//

import Darwin
import XCTest
@testable import Snapzy

@MainActor
final class TempCaptureManagerTests: XCTestCase {

  func testПубликацияОчищаетВременныйФайлВПереименованномКаталоге() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("selected", isDirectory: true)
    let moved = root.appendingPathComponent("moved", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let descriptor = directory.withUnsafeFileSystemRepresentation { path in
      path.map { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) } ?? -1
    }
    XCTAssertGreaterThanOrEqual(descriptor, 0)
    guard descriptor >= 0 else { return }
    defer { Darwin.close(descriptor) }
    try FileManager.default.moveItem(at: directory, to: moved)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let contents = Data("Другой файл".utf8)
    let name = "result.heic"
    try contents.write(to: moved.appendingPathComponent(name))

    XCTAssertThrowsError(try CaptureFilePublication.replaceFile(
      with: Data([1, 2, 3]), to: directory.appendingPathComponent(name),
      in: descriptor, expecting: .missing, permissions: nil)) {
      XCTAssertEqual(($0 as NSError).code, Int(ESTALE))
    }

    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: moved.path), [name])
    XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent(name)), contents)
  }

  private final class FakeSandboxFileAccess: SandboxFileAccessing {
    let exportDirectory: URL

    init(exportDirectory: URL) {
      self.exportDirectory = exportDirectory
    }

    func resolvedExportDirectoryURL() -> URL {
      exportDirectory
    }

    func beginAccessingURL(_ targetURL: URL) -> SandboxFileAccessManager.ScopedAccess {
      SandboxFileAccessManager.ScopedAccess(
        url: targetURL,
        accessURL: targetURL,
        didStartAccessing: false
      )
    }
  }

  private var fakePreferences: FakePreferencesProvider!
  private var fakeFileAccess: FakeSandboxFileAccess!
  private var defaults: UserDefaults!
  private var manager: TempCaptureManager!
  private var testFiles: [URL] = []

  override func setUp() {
    super.setUp()
    fakePreferences = FakePreferencesProvider()
    let exportDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("SnapzyTests_Export_\(UUID().uuidString)", isDirectory: true)
    let captureRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("SnapzyTests_Captures_\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
    fakeFileAccess = FakeSandboxFileAccess(exportDirectory: exportDirectory)
    defaults = UserDefaultsFactory.make()
    manager = TempCaptureManager(
      preferences: fakePreferences,
      fileAccess: fakeFileAccess,
      defaults: defaults,
      captureRoot: captureRoot
    )
    testFiles.append(exportDirectory)
    testFiles.append(captureRoot)
  }

  override func tearDown() async throws {
    // Clean up any test files created in temp directory
    for url in testFiles {
      try? FileManager.default.removeItem(at: url)
    }
    testFiles.removeAll()
    try await super.tearDown()
  }

  /// Create a test file in the temp capture directory.
  private func createTempTestFile(
    name: String = "test_\(UUID().uuidString).png"
  ) throws -> URL {
    let url = manager.tempCaptureDirectory.appendingPathComponent(name)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("test".utf8).write(to: url)
    testFiles.append(url)
    return url
  }

  /// Create a test file in an arbitrary directory.
  private func createExternalTestFile() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("SnapzyTests_External_\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("external_file.png")
    try Data("test".utf8).write(to: url)
    testFiles.append(dir) // Clean up dir
    return url
  }

  // MARK: - isTempFile

  func testIsTempFile_fileInTempDir_returnsTrue() throws {
    let url = try createTempTestFile()
    XCTAssertTrue(manager.isTempFile(url))
  }

  func testIsTempFile_fileOutsideTempDir_returnsFalse() throws {
    let url = try createExternalTestFile()
    XCTAssertFalse(manager.isTempFile(url))
  }

  func testIsTempFile_nonexistentFileInTempDir_stillReturnsTrue() {
    let url = manager.tempCaptureDirectory.appendingPathComponent("nonexistent.png")
    // isTempFile checks path prefix, not file existence
    XCTAssertTrue(manager.isTempFile(url))
  }

  func testIsTempFile_siblingPathWithSamePrefix_returnsFalse() throws {
    let siblingDir = URL(fileURLWithPath: manager.tempCaptureDirectory.path + "_Sibling", isDirectory: true)
    try FileManager.default.createDirectory(at: siblingDir, withIntermediateDirectories: true)
    let url = siblingDir.appendingPathComponent("not_temp.png")
    try Data("test".utf8).write(to: url)
    testFiles.append(siblingDir)

    XCTAssertFalse(manager.isTempFile(url))
  }

  // MARK: - saveToExportLocation

  func testSaveToExportLocation_nestedTempFile_preservesRelativeSubfolder() throws {
    let tempURL = try createTempTestFile(name: "Shots/May/nested.png")
    testFiles.append(manager.tempCaptureDirectory.appendingPathComponent("Shots", isDirectory: true))

    let savedURL = manager.saveToExportLocation(tempURL: tempURL)

    let expectedURL = fakeFileAccess.exportDirectory
      .appendingPathComponent("Shots/May/nested.png")
    XCTAssertEqual(savedURL?.path, expectedURL.path)
    XCTAssertTrue(FileManager.default.fileExists(atPath: expectedURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: manager.tempCaptureDirectory.appendingPathComponent("Shots").path
      )
    )
  }

  func testSaveToExportLocation_choosesNextNameWithoutReplacingNestedCaptures() throws {
    let input = try createTempTestFile(name: "Shots/May/demo.png")
    let export = fakeFileAccess.exportDirectory.appendingPathComponent("Shots/May", isDirectory: true)
    try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true)
    let first = export.appendingPathComponent("demo.png")
    let second = export.appendingPathComponent("demo_2.png")
    try Data("first".utf8).write(to: first)
    try Data("second".utf8).write(to: second)

    let saved = manager.saveToExportLocation(tempURL: input)

    XCTAssertEqual(saved?.path, export.appendingPathComponent("demo_3.png").path)
    XCTAssertEqual(try Data(contentsOf: first), Data("first".utf8))
    XCTAssertEqual(try Data(contentsOf: second), Data("second".utf8))
    if let saved { XCTAssertEqual(try Data(contentsOf: saved), Data("test".utf8)) }
    XCTAssertFalse(FileManager.default.fileExists(atPath: input.path))
  }

  func testSaveToExportLocation_skipsDanglingSymlinkWithoutReplacingIt() throws {
    let input = try createTempTestFile(name: "demo.png")
    let export = fakeFileAccess.exportDirectory
    let symlink = export.appendingPathComponent("demo.png")
    let missingTarget = export.appendingPathComponent("missing.png")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: missingTarget)

    let saved = manager.saveToExportLocation(tempURL: input)

    XCTAssertEqual(saved?.path, export.appendingPathComponent("demo_2.png").path)
    XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: symlink.path), missingTarget.path)
    XCTAssertFalse(FileManager.default.fileExists(atPath: missingTarget.path))
    if let saved { XCTAssertEqual(try Data(contentsOf: saved), Data("test".utf8)) }
    XCTAssertFalse(FileManager.default.fileExists(atPath: input.path))
  }

  func testSaveToExportLocationKeepsADirectoryAtTheCapturePath() throws {
    let fm = FileManager.default
    let directory = manager.tempCaptureDirectory.appendingPathComponent("replaced.png", isDirectory: true)
    let retained = directory.appendingPathComponent("keep.txt")
    let data = Data("temporary fixture".utf8)
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    try data.write(to: retained)

    XCTAssertNil(manager.saveToExportLocation(tempURL: directory))
    XCTAssertEqual(try Data(contentsOf: retained), data)
    XCTAssertFalse(fm.fileExists(
      atPath: fakeFileAccess.exportDirectory.appendingPathComponent(directory.lastPathComponent).path
    ))
  }

  func testSaveToExportLocationDoesNotMoveOutsideFilesThroughALinkedFolder() throws {
    let fm = FileManager.default
    let outside = fakeFileAccess.exportDirectory.appendingPathComponent("outside.png")
    let link = manager.tempCaptureDirectory.appendingPathComponent("linked")
    let data = Data("temporary fixture".utf8)
    try data.write(to: outside)
    try fm.createSymbolicLink(at: link, withDestinationURL: outside.deletingLastPathComponent())
    let candidate = link.appendingPathComponent(outside.lastPathComponent)
    XCTAssertTrue(manager.isTempFile(candidate))

    XCTAssertNil(manager.saveToExportLocation(tempURL: candidate))
    XCTAssertEqual(try Data(contentsOf: outside), data)
  }

  func testSaveToExportLocationKeepsASnapshotWhenTheExportSubfolderPointsOutside() throws {
    let fm = FileManager.default
    let outside = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: outside) }
    let input = try createTempTestFile(name: "Album/May/capture.png")
    let exportLink = fakeFileAccess.exportDirectory.appendingPathComponent("Album")
    try fm.createSymbolicLink(at: exportLink, withDestinationURL: outside)

    XCTAssertNil(manager.saveToExportLocation(tempURL: input))

    XCTAssertEqual(try Data(contentsOf: input), Data("test".utf8))
    XCTAssertFalse(fm.fileExists(atPath: outside.appendingPathComponent("May", isDirectory: true).path))
  }

  func testSaveToExportLocationAllowsALinkedSubfolderInsideExport() throws {
    let fm = FileManager.default
    let export = fakeFileAccess.exportDirectory
    let inside = export.appendingPathComponent("actual", isDirectory: true)
    try fm.createDirectory(at: inside, withIntermediateDirectories: true)
    let input = try createTempTestFile(name: "Album/May/capture.png")
    let exportLink = export.appendingPathComponent("Album")
    try fm.createSymbolicLink(at: exportLink, withDestinationURL: inside)

    let saved = try XCTUnwrap(manager.saveToExportLocation(tempURL: input))

    XCTAssertEqual(saved.path, exportLink.appendingPathComponent("May/capture.png").path)
    XCTAssertEqual(try Data(contentsOf: inside.appendingPathComponent("May/capture.png")), Data("test".utf8))
    XCTAssertFalse(fm.fileExists(atPath: input.path))
  }

  func testSaveToExportLocationKeepsASourceLinkWhenItsTargetIsMissing() throws {
    let files = FileManager.default
    let source = manager.tempCaptureDirectory.appendingPathComponent("missing.png")
    let missingTarget = manager.tempCaptureDirectory.appendingPathComponent("offline.png")
    try files.createSymbolicLink(at: source, withDestinationURL: missingTarget)

    XCTAssertNil(manager.saveToExportLocation(tempURL: source))

    XCTAssertEqual(try files.destinationOfSymbolicLink(atPath: source.path), missingTarget.path)
    let destination = fakeFileAccess.exportDirectory.appendingPathComponent(source.lastPathComponent)
    XCTAssertThrowsError(try files.destinationOfSymbolicLink(atPath: destination.path))
  }

  func testSaveToExportLocationKeepsARelativeLinkThatWouldPointToADifferentCapture() throws {
    let files = FileManager.default
    let original = try createTempTestFile(name: "original.png")
    let alias = manager.tempCaptureDirectory.appendingPathComponent("alias.png")
    let export = fakeFileAccess.exportDirectory
    let unrelated = export.appendingPathComponent(original.lastPathComponent)
    let unrelatedBytes = Data("unrelated capture".utf8)
    try unrelatedBytes.write(to: unrelated)
    try files.createSymbolicLink(atPath: alias.path, withDestinationPath: original.lastPathComponent)

    XCTAssertNil(manager.saveToExportLocation(tempURL: alias))

    XCTAssertEqual(try Data(contentsOf: alias), Data("test".utf8))
    XCTAssertEqual(try Data(contentsOf: unrelated), unrelatedBytes)
    let exportedAlias = export.appendingPathComponent(alias.lastPathComponent)
    XCTAssertThrowsError(try files.destinationOfSymbolicLink(atPath: exportedAlias.path))
  }

  func testSaveToExportLocationAllowsARelativeLinkThatKeepsItsCapture() throws {
    let files = FileManager.default
    let original = try createTempTestFile(name: "original.png")
    let alias = manager.tempCaptureDirectory.appendingPathComponent("alias.png")
    let export = fakeFileAccess.exportDirectory
    let targetInExport = export.appendingPathComponent(original.lastPathComponent)
    try files.createSymbolicLink(at: targetInExport, withDestinationURL: original)
    try files.createSymbolicLink(atPath: alias.path, withDestinationPath: original.lastPathComponent)

    let saved = try XCTUnwrap(manager.saveToExportLocation(tempURL: alias))

    XCTAssertEqual(saved.path, export.appendingPathComponent(alias.lastPathComponent).path)
    XCTAssertEqual(try Data(contentsOf: saved), Data("test".utf8))
    XCTAssertEqual(try Data(contentsOf: original), Data("test".utf8))
  }

  func testSaveToExportLocation_sameFileDoesNotRenameCapture() throws {
    let input = try createTempTestFile(name: "demo.png")
    let sameRoot = FakeSandboxFileAccess(exportDirectory: manager.tempCaptureDirectory)
    let sameLocationManager = TempCaptureManager(
      preferences: fakePreferences,
      fileAccess: sameRoot,
      defaults: defaults,
      captureRoot: manager.tempCaptureDirectory
    )

    let saved = sameLocationManager.saveToExportLocation(tempURL: input)

    XCTAssertEqual(saved?.path, input.path)
    XCTAssertEqual(try Data(contentsOf: input), Data("test".utf8))
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: input.deletingLastPathComponent().appendingPathComponent("demo_2.png").path
    ))
  }

  func testCapturePublication_concurrentMovesDoNotOverwriteOrConsumeLosers() async throws {
    let export = fakeFileAccess.exportDirectory
    let destination = export.appendingPathComponent("winner.png")
    let inputs = try (0..<8).map { index in
      let url = export.appendingPathComponent("input_\(index).png")
      try Data("input-\(index)".utf8).write(to: url)
      return url
    }
    let results = await withTaskGroup(of: Int32.self) { group in
      for source in inputs {
        group.addTask {
          switch CaptureFilePublication.publish(source, to: destination, copyFlags: copyfile_flags_t(COPYFILE_ALL)) {
          case .moved: return 0
          case .copied: return -1
          case .failed(let error): return error
          }
        }
      }
      var results: [Int32] = []
      for await result in group { results.append(result) }
      return results
    }

    XCTAssertEqual(results.filter { $0 == 0 }.count, 1)
    XCTAssertEqual(results.filter { $0 == EEXIST }.count, inputs.count - 1)
    let missing = inputs.indices.filter { !FileManager.default.fileExists(atPath: inputs[$0].path) }
    XCTAssertEqual(missing.count, 1)
    let winner = try XCTUnwrap(missing.first)
    XCTAssertEqual(try Data(contentsOf: destination), Data("input-\(winner)".utf8))
  }

  // MARK: - deleteTempFile

  func testDeleteTempFile_removesFileFromDisk() throws {
    let url = try createTempTestFile()
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

    manager.deleteTempFile(at: url)

    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    testFiles.removeAll { $0 == url } // Already deleted
  }

  func testDeleteTempFile_nonTempFile_noOp() throws {
    let url = try createExternalTestFile()
    let existedBefore = FileManager.default.fileExists(atPath: url.path)

    manager.deleteTempFile(at: url)

    // File should still exist — not in temp dir
    XCTAssertTrue(existedBefore)
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
  }

  func testDeleteTempFile_nestedTempFile_prunesEmptySubfolders() throws {
    let url = try createTempTestFile(name: "DeleteMe/May/nested.png")
    let rootSubfolder = manager.tempCaptureDirectory.appendingPathComponent("DeleteMe", isDirectory: true)
    testFiles.append(rootSubfolder)

    manager.deleteTempFile(at: url)

    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: rootSubfolder.path))
  }

  func testDeleteTempFileKeepsADirectoryAtTheCapturePath() throws {
    let fm = FileManager.default
    let directory = manager.tempCaptureDirectory.appendingPathComponent("replaced.png", isDirectory: true)
    let retained = directory.appendingPathComponent("keep.txt")
    let data = Data("temporary fixture".utf8)
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    try data.write(to: retained)

    manager.deleteTempFile(at: directory)

    XCTAssertEqual(try Data(contentsOf: retained), data)
  }

  func testDeleteTempFileDoesNotDeleteOutsideTheRootThroughALinkedFolder() throws {
    let fm = FileManager.default
    let outside = fakeFileAccess.exportDirectory.appendingPathComponent("outside.png")
    let link = manager.tempCaptureDirectory.appendingPathComponent("linked")
    let data = Data("temporary fixture".utf8)
    try data.write(to: outside)
    try fm.createSymbolicLink(at: link, withDestinationURL: outside.deletingLastPathComponent())
    let candidate = link.appendingPathComponent(outside.lastPathComponent)
    XCTAssertTrue(manager.isTempFile(candidate))

    manager.deleteTempFile(at: candidate)

    XCTAssertEqual(try Data(contentsOf: outside), data)
  }

  func testDeleteTempFileRemovesALeafLinkWithoutRemovingItsTarget() throws {
    let fm = FileManager.default
    let target = fakeFileAccess.exportDirectory.appendingPathComponent("outside.png")
    let alias = manager.tempCaptureDirectory.appendingPathComponent("alias.png")
    let data = Data("temporary fixture".utf8)
    try data.write(to: target)
    try fm.createSymbolicLink(at: alias, withDestinationURL: target)

    manager.deleteTempFile(at: alias)

    XCTAssertFalse(fm.fileExists(atPath: alias.path))
    XCTAssertEqual(try Data(contentsOf: target), data)
  }

  func testDeleteTempFile_nonexistentFile_doesNotCrash() {
    let url = manager.tempCaptureDirectory.appendingPathComponent("ghost_\(UUID().uuidString).png")
    // Should complete without crash
    manager.deleteTempFile(at: url)
  }

  // MARK: - makeRecoveredRecordingURL

  func testMakeRecoveredRecordingURL_returnsURLInTempDir() {
    let sourceURL = URL(fileURLWithPath: "/tmp/recording.mov")
    let recoveredURL = manager.makeRecoveredRecordingURL(for: sourceURL)

    XCTAssertTrue(
      manager.isTempFile(recoveredURL),
      "Recovered URL should be in temp capture directory"
    )
    XCTAssertEqual(recoveredURL.pathExtension, "mov")
  }

  func testMakeRecoveredRecordingURL_preservesExtension() {
    let sourceURL = URL(fileURLWithPath: "/tmp/clip.mp4")
    let recoveredURL = manager.makeRecoveredRecordingURL(for: sourceURL)

    XCTAssertEqual(recoveredURL.pathExtension, "mp4")
  }

  func testMakeRecoveredRecordingURL_noExtension_defaultsToMov() {
    let sourceURL = URL(fileURLWithPath: "/tmp/recording")
    let recoveredURL = manager.makeRecoveredRecordingURL(for: sourceURL)

    XCTAssertEqual(recoveredURL.pathExtension, "mov")
  }

  func testMakeRecoveredRecordingURL_uniqueNames() {
    let sourceURL = URL(fileURLWithPath: "/tmp/recording.mov")
    let url1 = manager.makeRecoveredRecordingURL(for: sourceURL)

    // Create the first file so the next call must find a unique name
    try? Data("test".utf8).write(to: url1)
    testFiles.append(url1)

    let url2 = manager.makeRecoveredRecordingURL(for: sourceURL)
    XCTAssertNotEqual(url1.lastPathComponent, url2.lastPathComponent)
    testFiles.append(url2)
  }

  // MARK: - resolveSaveDirectory

  func testResolveSaveDirectory_autoSaveOn_returnsExportDir() {
    // Ensure auto-save is enabled for screenshots
    fakePreferences.setAction(.save, for: .screenshot, enabled: true)

    let exportDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("SnapzyTests_Export_\(UUID().uuidString)")

    let result = manager.resolveSaveDirectory(
      for: .screenshot,
      exportDirectory: exportDir
    )

    XCTAssertEqual(result, exportDir)
  }

  func testResolveSaveDirectory_autoSaveOff_returnsTempDir() {
    // Disable auto-save for screenshots
    fakePreferences.setAction(.save, for: .screenshot, enabled: false)

    let exportDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("SnapzyTests_Export_\(UUID().uuidString)")

    let result = manager.resolveSaveDirectory(
      for: .screenshot,
      exportDirectory: exportDir
    )

    XCTAssertEqual(result, manager.tempCaptureDirectory)
  }

  // MARK: - tempCaptureDirectory

  func testTempCaptureDirectory_exists() {
    XCTAssertTrue(FileManager.default.fileExists(atPath: manager.tempCaptureDirectory.path))
  }

  func testTempCaptureDirectory_isInAppSupport() {
    let path = TempCaptureManager.tempCaptureRootDirectory().path
    XCTAssertTrue(
      path.contains("Application Support/OwnShot/Captures")
        || path.contains("OwnShot_Captures"),
      "Temp directory should be in App Support or fallback: \(path)"
    )
  }

  func testУдалениеПослеКопированияСохраняетФайлСНовойРевизией() throws {
    let files = FileManager.default
    let source = manager.tempCaptureDirectory.appendingPathComponent("moving.mov")
    let initial = Data("старая запись".utf8)
    let appended = Data("новые данные".utf8)
    try initial.write(to: source)
    let copiedRevision = try XCTUnwrap(CaptureFilePublication.FileRevision(at: source))

    let handle = try FileHandle(forWritingTo: source)
    _ = try handle.seekToEnd()
    try handle.write(contentsOf: appended)
    try handle.close()

    XCTAssertThrowsError(try copiedRevision.removeOriginal(at: source)) { error in
      XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain)
      XCTAssertEqual((error as NSError).code, Int(ESTALE))
    }
    XCTAssertEqual(try Data(contentsOf: source), initial + appended)

    let currentRevision = try XCTUnwrap(CaptureFilePublication.FileRevision(at: source))
    try currentRevision.removeOriginal(at: source)
    XCTAssertFalse(files.fileExists(atPath: source.path))
  }

  // MARK: - RecordingSavePlan

  func testRecordingSavePlan_structure() throws {
    let exportDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("SnapzyTests_Export_\(UUID().uuidString)")

    let plan = try manager.makeRecordingSavePlan(exportDirectory: exportDir)

    // Processing directory should exist
    XCTAssertTrue(FileManager.default.fileExists(atPath: plan.processingSession.directory.path))

    // Clean up
    try? FileManager.default.removeItem(at: plan.processingSession.directory)
  }

  func testRecordingSavePlan_autoSaveOn_finalDirIsExport() throws {
    fakePreferences.setAction(.save, for: .recording, enabled: true)

    let exportDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("SnapzyTests_Export_\(UUID().uuidString)")

    let plan = try manager.makeRecordingSavePlan(exportDirectory: exportDir)
    XCTAssertEqual(plan.finalDirectory, exportDir)
    XCTAssertTrue(plan.autoSaveEnabled)

    try? FileManager.default.removeItem(at: plan.processingSession.directory)
  }

  func testRecordingSavePlan_autoSaveOff_finalDirIsTemp() throws {
    fakePreferences.setAction(.save, for: .recording, enabled: false)

    let exportDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("SnapzyTests_Export_\(UUID().uuidString)")

    let plan = try manager.makeRecordingSavePlan(exportDirectory: exportDir)
    XCTAssertEqual(plan.finalDirectory, manager.tempCaptureDirectory)
    XCTAssertFalse(plan.autoSaveEnabled)

    try? FileManager.default.removeItem(at: plan.processingSession.directory)
  }

  // MARK: - deleteRecordingProcessingDirectory

  func testDeleteRecordingProcessingDirectory_validDir_removesIt() throws {
    let exportDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("SnapzyTests_Export_\(UUID().uuidString)")

    let plan = try manager.makeRecordingSavePlan(exportDirectory: exportDir)
    XCTAssertTrue(FileManager.default.fileExists(atPath: plan.processingSession.directory.path))

    manager.deleteRecordingProcessingDirectory(plan.processingSession)
    XCTAssertFalse(FileManager.default.fileExists(atPath: plan.processingSession.directory.path))
  }

  func testОчисткаНеУдаляетФайлНаМестеКаталогаЗаписи() throws {
    let files = FileManager.default
    let plan = try manager.makeRecordingSavePlan(exportDirectory: fakeFileAccess.exportDirectory)
    let file = URL(fileURLWithPath: plan.processingSession.directory.path, isDirectory: false)
    let contents = Data("replacement fixture".utf8)
    try files.removeItem(at: plan.processingSession.directory)
    try contents.write(to: file)

    manager.deleteRecordingProcessingDirectory(plan.processingSession)

    XCTAssertEqual(try Data(contentsOf: file), contents)
  }

  func testОчисткаСохраняетКаталогПодменившийКаталогЗаписи() throws {
    let files = FileManager.default
    let plan = try manager.makeRecordingSavePlan(exportDirectory: fakeFileAccess.exportDirectory)
    let moved = plan.processingSession.directory.deletingLastPathComponent()
      .appendingPathComponent("moved-session", isDirectory: true)
    try files.moveItem(at: plan.processingSession.directory, to: moved)
    try files.createDirectory(at: plan.processingSession.directory, withIntermediateDirectories: false)
    let unrelatedFile = plan.processingSession.directory.appendingPathComponent("unrelated.txt")
    let contents = Data("чужой файл".utf8)
    try contents.write(to: unrelatedFile)

    manager.deleteRecordingProcessingDirectory(plan.processingSession)

    XCTAssertEqual(try? Data(contentsOf: unrelatedFile), contents)
    XCTAssertTrue(files.fileExists(atPath: moved.path))
  }

  func testDeleteRecordingProcessingDirectory_outsideRoot_noOp() {
    let outsideDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("NotRecordingProcessing_\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)

    manager.deleteRecordingProcessingDirectory(outsideDir)

    // Should still exist — not inside the recording processing root
    XCTAssertTrue(FileManager.default.fileExists(atPath: outsideDir.path))
    try? FileManager.default.removeItem(at: outsideDir)
  }
}

@MainActor
final class TempCaptureOrphanCleanupTests: XCTestCase {
  func testStartupCleanupKeepsAFileReferencedByAHistoryAlias() throws {
    let files = FileManager.default
    let testRoot = try XCTUnwrap(OwnShotStoragePaths.testRoot)
    let root = testRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let defaults = UserDefaultsFactory.make()
    defaults.set(true, forKey: PreferencesKeys.historyEnabled)
    defaults.set(7, forKey: PreferencesKeys.historyRetentionDays)
    let manager = TempCaptureManager(
      preferences: FakePreferencesProvider(), defaults: defaults, captureRoot: root
    )

    let history = CaptureHistoryStore.shared
    let originalDefaults = history.userDefaults
    history.userDefaults = defaults
    let source = root.appendingPathComponent("source.png")
    let control = root.appendingPathComponent("unowned.png")
    let alias = root.appendingPathComponent("alias.png")
    defer {
      history.removeByFilePath(alias.path)
      history.userDefaults = originalDefaults
      try? files.removeItem(at: root)
    }

    let data = Data("temporary fixture".utf8)
    for url in [source, control] {
      try data.write(to: url)
      try files.setAttributes([.modificationDate: Date().addingTimeInterval(-86400 * 10)], ofItemAtPath: url.path)
    }
    try files.createSymbolicLink(at: alias, withDestinationURL: source)
    history.add(CaptureHistoryRecord(
      id: UUID(), filePath: alias.path, fileName: alias.lastPathComponent, captureType: .screenshot,
      fileSize: Int64(data.count), capturedAt: Date(), width: 4, height: 4,
      duration: nil, thumbnailPath: nil, isDeleted: false
    ))
    XCTAssertTrue(history.hasRecord(forFilePath: alias.path))

    manager.cleanupOrphanedFiles()

    XCTAssertEqual(try Data(contentsOf: alias), data)
    XCTAssertFalse(files.fileExists(atPath: control.path))
  }

  func testОчисткаПриСтартеСохраняетКаталогНаМестеСтарогоСнимка() throws {
    let files = FileManager.default
    let testRoot = try XCTUnwrap(OwnShotStoragePaths.testRoot)
    let fixture = testRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let root = fixture.appendingPathComponent("captures", isDirectory: true)
    let source = root.appendingPathComponent("old.png")
    let held = fixture.appendingPathComponent("original.png")
    let foreign = source.appendingPathComponent("note.txt")
    let original = Data("старый снимок".utf8)
    let contents = Data("сохранить".utf8)
    let suiteName = "ownshot-retention-test-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(ObservedRetentionDefaults(suiteName: suiteName) {
      guard !files.fileExists(atPath: held.path) else { return }
      do {
        try files.moveItem(at: source, to: held)
        try files.createDirectory(at: source, withIntermediateDirectories: false)
        try contents.write(to: foreign)
      } catch {
        XCTFail("Не удалось подменить снимок каталогом: \(error)")
      }
    })
    defer {
      defaults.removePersistentDomain(forName: suiteName)
      try? files.removeItem(at: fixture)
    }
    defaults.set(true, forKey: PreferencesKeys.historyEnabled)
    defaults.set(7, forKey: PreferencesKeys.historyRetentionDays)
    let manager = TempCaptureManager(
      preferences: FakePreferencesProvider(), defaults: defaults, captureRoot: root
    )
    try original.write(to: source)
    try files.setAttributes([.modificationDate: Date().addingTimeInterval(-86400 * 10)], ofItemAtPath: source.path)

    manager.cleanupOrphanedFiles()

    XCTAssertEqual(try? Data(contentsOf: held), original)
    XCTAssertEqual(try? Data(contentsOf: foreign), contents)
  }

  func testОчисткаПриСтартеСохраняетНезавершённуюЗаписьПриВыключеннойИстории() throws {
    let files = FileManager.default
    let root = files.temporaryDirectory
      .appendingPathComponent("ownshot-orphan-cleanup-\(UUID().uuidString)", isDirectory: true)
    defer { try? files.removeItem(at: root) }

    let defaults = UserDefaultsFactory.make()
    defaults.set(false, forKey: PreferencesKeys.historyEnabled)
    let manager = TempCaptureManager(
      preferences: FakePreferencesProvider(), defaults: defaults, captureRoot: root
    )
    let plan = try manager.makeRecordingSavePlan(exportDirectory: root)
    let writer = plan.processingSession.directory.appendingPathComponent("unfinished.mov")
    let sidecar = plan.processingSession.directory.appendingPathComponent("audio.m4a")
    let orphan = root.appendingPathComponent("orphan.png")
    let videoBytes = Data("unfinished writer output".utf8)
    let sidecarBytes = Data("writer sidecar".utf8)
    try videoBytes.write(to: writer)
    try sidecarBytes.write(to: sidecar)
    try Data("ordinary orphan".utf8).write(to: orphan)

    manager.cleanupOrphanedFiles()

    XCTAssertEqual(try? Data(contentsOf: writer), videoBytes)
    XCTAssertEqual(try? Data(contentsOf: sidecar), sidecarBytes)
    XCTAssertFalse(files.fileExists(atPath: orphan.path))
  }
}

private final class ObservedRetentionDefaults: UserDefaults, @unchecked Sendable {
  private let onRetentionRead: @Sendable () -> Void

  init?(suiteName: String, onRetentionRead: @escaping @Sendable () -> Void) {
    self.onRetentionRead = onRetentionRead
    super.init(suiteName: suiteName)
  }

  override func integer(forKey defaultName: String) -> Int {
    if defaultName == PreferencesKeys.historyRetentionDays { onRetentionRead() }
    return super.integer(forKey: defaultName)
  }
}
