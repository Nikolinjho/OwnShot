//
//  TempCaptureManager.swift
//  Snapzy
//
//  Manages temporary capture files for the "Auto-save" toggle.
//  When auto-save is OFF, captures are stored in a temp directory.
//  Users can manually save via Quick Access Card or dismiss to delete.
//

import Darwin
import Foundation
import os.log

private let logger = Logger(subsystem: "Snapzy", category: "TempCaptureManager")

struct RecordingSavePlan {
  let finalDirectory: URL
  let processingSession: RecordingProcessingSession
  let autoSaveEnabled: Bool
}

struct RecordingProcessingSession {
  let directory: URL
  var processingRoot: URL { directory.deletingLastPathComponent() }

  private let identity: CaptureFilePublication.SourceIdentity
  private let rootIdentity: CaptureFilePublication.SourceIdentity

  fileprivate init?(directory: URL) {
    guard let identity = CaptureFilePublication.SourceIdentity.at(directory, type: mode_t(S_IFDIR)),
          let rootIdentity = CaptureFilePublication.SourceIdentity.at(
            directory.deletingLastPathComponent(), type: mode_t(S_IFDIR)
          ) else { return nil }
    self.directory = directory
    self.identity = identity
    self.rootIdentity = rootIdentity
  }

  var isProcessingRootCurrent: Bool {
    CaptureFilePublication.SourceIdentity.at(processingRoot, type: mode_t(S_IFDIR)) == rootIdentity
  }

  var isCurrent: Bool {
    isProcessingRootCurrent
      && CaptureFilePublication.SourceIdentity.at(directory, type: mode_t(S_IFDIR)) == identity
  }

  nonisolated static func discardMarker(for directory: URL) -> URL {
    directory.deletingLastPathComponent()
      .appendingPathComponent(".\(directory.lastPathComponent).discarded", isDirectory: true)
  }
}

/// Manages lifecycle of temporary capture files when auto-save is disabled
@MainActor
final class TempCaptureManager {
  static let shared = TempCaptureManager()

  private let preferences: PreferencesProviding
  private let fileAccess: SandboxFileAccessing
  private let defaults: UserDefaults

  /// Temp directory for unsaved captures. App Support keeps them alive during drag-and-drop.
  let tempCaptureDirectory: URL

  /// Per-session writer processing space for recordings and their transient sidecars.
  private let recordingProcessingDirectory: URL

  init(
    preferences: PreferencesProviding? = nil,
    fileAccess: SandboxFileAccessing? = nil,
    defaults: UserDefaults = .standard,
    captureRoot: URL? = nil
  ) {
    self.preferences = preferences ?? PreferencesManager.shared
    self.fileAccess = fileAccess ?? SandboxFileAccessManager.shared
    self.defaults = defaults
    let root = captureRoot ?? Self.tempCaptureRootDirectory()
    tempCaptureDirectory = root
    recordingProcessingDirectory = root.appendingPathComponent("RecordingProcessing", isDirectory: true)
    try? FileManager.default.createDirectory(at: recordingProcessingDirectory, withIntermediateDirectories: true)
  }

  // MARK: - Public API

  /// Resolve save directory based on auto-save toggle state.
  /// Returns temp directory if auto-save is OFF, export directory if ON.
  func resolveSaveDirectory(
    for captureType: CaptureType,
    exportDirectory: URL
  ) -> URL {
    let autoSaveEnabled = preferences.isActionEnabled(.save, for: captureType)
    let typeLabel = captureType == .screenshot ? "screenshot" : "recording"

    if autoSaveEnabled {
      logger.info("Auto-save ON for \(typeLabel), using export directory")
      DiagnosticLogger.shared.log(
        .info,
        .capture,
        "Temp capture resolved to export directory",
        context: ["captureType": typeLabel, "autoSave": "true"]
      )
      return exportDirectory
    }

    // Auto-save OFF: use temp directory
    logger.info("Auto-save OFF for \(typeLabel), using temp directory")
    DiagnosticLogger.shared.log(
      .info,
      .capture,
      "Temp capture resolved to temp directory",
      context: ["captureType": typeLabel, "autoSave": "false"]
    )
    return tempCaptureDirectory
  }

  /// Resolve final and processing directories for recording output.
  /// The final video is moved into `finalDirectory` after the writer completes,
  /// while AVAssetWriter and any transient sidecars stay in `processingDirectory`.
  func makeRecordingSavePlan(exportDirectory: URL) throws -> RecordingSavePlan {
    let autoSaveEnabled = preferences.isActionEnabled(.save, for: .recording)
    let finalDirectory = autoSaveEnabled ? exportDirectory : tempCaptureDirectory
    let processingSession = try createRecordingProcessingSession()

    DiagnosticLogger.shared.log(
      .info,
      .recording,
      "Recording save plan resolved",
      context: [
        "autoSave": autoSaveEnabled ? "true" : "false",
        "finalDirectory": finalDirectory.lastPathComponent,
        "processingDirectory": processingSession.directory.lastPathComponent,
      ]
    )

    return RecordingSavePlan(
      finalDirectory: finalDirectory,
      processingSession: processingSession,
      autoSaveEnabled: autoSaveEnabled
    )
  }

  /// Корень каталогов сеансов записи: восстановление после аварийного выхода ищет здесь.
  var recordingProcessingRootDirectory: URL { recordingProcessingDirectory }

  /// Build a stable fallback URL in the temp capture root if final export move fails.
  func makeRecoveredRecordingURL(for sourceURL: URL) -> URL {
    let proposed = proposedRecoveredRecordingURL(for: sourceURL)
    return CaptureOutputNaming.makeUniqueFileURL(
      in: proposed.deletingLastPathComponent(),
      baseName: proposed.deletingPathExtension().lastPathComponent,
      fileExtension: proposed.pathExtension
    )
  }

  func proposedRecoveredRecordingURL(for sourceURL: URL) -> URL {
    let fileExtension = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension
    return tempCaptureDirectory.appendingPathComponent(
      sourceURL.deletingPathExtension().lastPathComponent + "." + fileExtension
    )
  }

  func deleteRecordingProcessingDirectory(_ session: RecordingProcessingSession) {
    guard session.isCurrent else { return }
    deleteRecordingProcessingDirectory(session.directory)
  }

  func discardRecordingProcessingDirectory(_ session: RecordingProcessingSession) {
    let directory = session.directory
    guard session.processingRoot.standardizedFileURL.path == recordingProcessingDirectory.standardizedFileURL.path else {
      return
    }
    let removed = session.isCurrent && directory.withUnsafeFileSystemRepresentation { path in
      guard let path else { return false }
      return rmdir(path) == 0
    }
    guard !removed, session.isProcessingRootCurrent else { return }

    // Отметка рядом с каталогом сохраняется, даже если сам каталог подменили.
    let marker = RecordingProcessingSession.discardMarker(for: directory)
    do {
      try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: false)
    } catch let error as CocoaError where error.code == .fileWriteFileExists {
      return
    } catch {
      DiagnosticLogger.shared.logError(.recording, error, "Failed to mark recording session as discarded", context: [
        "directory": directory.lastPathComponent
      ])
    }
  }

  /// Удаляет каталог записи, проверенный при восстановлении после сбоя.
  func deleteRecordingProcessingDirectory(_ directory: URL) {
    guard isRecordingProcessingSessionDirectory(directory) else {
      DiagnosticLogger.shared.log(
        .warning,
        .recording,
        "Recording processing directory cleanup skipped; path outside processing root",
        context: ["directory": directory.lastPathComponent]
      )
      return
    }

    var isDirectory = ObjCBool(false)
    guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
          isDirectory.boolValue else { return }

    do {
      try FileManager.default.removeItem(at: directory)
      DiagnosticLogger.shared.log(
        .debug,
        .recording,
        "Recording processing directory cleaned",
        context: ["directory": directory.lastPathComponent]
      )
    } catch {
      DiagnosticLogger.shared.logError(
        .recording,
        error,
        "Recording processing directory cleanup failed",
        context: ["directory": directory.lastPathComponent]
      )
    }
  }

  /// Move a temp file to the permanent export location.
  /// Returns the new URL on success, nil on failure.
  func saveToExportLocation(tempURL: URL) -> URL? {
    guard let source = temporaryEntryURL(for: tempURL),
          let sourceInfo = fileInfo(at: source, followingSymbolicLink: true),
          sourceInfo.st_mode & S_IFMT == S_IFREG else {
      logger.warning("saveToExportLocation called on invalid source: \(tempURL.lastPathComponent)")
      DiagnosticLogger.shared.log(
        .warning,
        .fileAccess,
        "Temp capture save skipped; source is unavailable or not a managed file",
        context: ["fileName": tempURL.lastPathComponent]
      )
      return nil
    }

    let exportDir = fileAccess.resolvedExportDirectoryURL()
    let exportAccess = fileAccess.beginAccessingURL(exportDir)
    defer { exportAccess.stop() }

    guard let relativePath = relativeTempPath(for: tempURL) else {
      DiagnosticLogger.shared.log(
        .warning,
        .fileAccess,
        "Temp capture save skipped; source has no relative temp path",
        context: ["fileName": tempURL.lastPathComponent]
      )
      return nil
    }

    let preferredURL = exportAccess.url.appendingPathComponent(relativePath)
    let destinationDirectory = preferredURL.deletingLastPathComponent()
    guard canCreateExportDirectory(destinationDirectory, in: exportAccess.url) else {
      DiagnosticLogger.shared.log(
        .warning,
        .fileAccess,
        "Temp capture save skipped; destination is outside the export directory",
        context: ["fileName": tempURL.lastPathComponent]
      )
      return nil
    }
    guard sourceLinkKeepsTarget(source, targetInfo: sourceInfo, in: destinationDirectory) else { return nil }
    if source.path == SandboxFileAccessManager.directoryEntryPath(for: preferredURL) {
      return FileManager.default.fileExists(atPath: source.path) ? tempURL : nil
    }

    do {
      // Create export directory if needed
      try FileManager.default.createDirectory(
        at: destinationDirectory,
        withIntermediateDirectories: true
      )
      guard canCreateExportDirectory(destinationDirectory, in: exportAccess.url),
            sourceLinkKeepsTarget(source, targetInfo: sourceInfo, in: destinationDirectory) else { return nil }

      // Resolve the old metadata key before the source path disappears.
      let metadataSourceURL = source.resolvingSymlinksInPath()
      let sourceExtension = tempURL.pathExtension.lowercased()
      let isRecording = VideoFormat(rawValue: sourceExtension) != nil
      let metadataDestination = isRecording
        ? RecordingMetadataStore.publicationDestination(forCurrentFile: tempURL)
        : .existing
      var publication: RecordingMetadataStore.PublicationEvidence?
      let destinationURL = try CaptureFilePublication.moveChoosingFreeName(at: source, to: preferredURL) { candidate in
        if isRecording {
          publication = RecordingMetadataStore.publicationEvidence(forCandidate: candidate)
        }
      }

      if !["png", "jpg", "jpeg", "webp"].contains(sourceExtension) {
        moveRecordingMetadataIfNeeded(
          from: metadataSourceURL, to: destinationURL,
          destination: metadataDestination, publication: publication
        )
      }
      pruneEmptyTempDirectories(startingAt: tempURL.deletingLastPathComponent())

      logger.info("Saved temp file to export: \(destinationURL.lastPathComponent)")
      DiagnosticLogger.shared.log(
        .info,
        .fileAccess,
        "Temp capture saved to export",
        context: ["fileName": destinationURL.lastPathComponent]
      )
      return destinationURL
    } catch {
      logger.error("Failed to save temp file: \(error.localizedDescription)")
      DiagnosticLogger.shared.logError(
        .fileAccess,
        error,
        "Temp capture save to export failed",
        context: ["fileName": tempURL.lastPathComponent]
      )
      return nil
    }
  }

  private func canCreateExportDirectory(_ directory: URL, in exportRoot: URL) -> Bool {
    let files = FileManager.default
    let root = exportRoot.standardizedFileURL
    var ancestor = directory.standardizedFileURL

    while ancestor.path.hasPrefix(root.path + "/") {
      var isDirectory: ObjCBool = false
      if files.fileExists(atPath: ancestor.path, isDirectory: &isDirectory) {
        guard isDirectory.boolValue else { return false }
        var relationship: FileManager.URLRelationship = .other
        do {
          try files.getRelationship(
            &relationship,
            ofDirectoryAt: root.resolvingSymlinksInPath(),
            toItemAt: ancestor.resolvingSymlinksInPath()
          )
          return relationship == .contains || relationship == .same
        } catch {
          return false
        }
      }
      if (try? files.destinationOfSymbolicLink(atPath: ancestor.path)) != nil { return false }
      ancestor.deleteLastPathComponent()
    }

    return ancestor.path == root.path
  }

  private func sourceLinkKeepsTarget(_ source: URL, targetInfo: stat, in directory: URL) -> Bool {
    guard let link = try? FileManager.default.destinationOfSymbolicLink(atPath: source.path),
          !link.hasPrefix("/") else { return true }
    let targetAfterMove = directory.appendingPathComponent(link)
    guard let info = fileInfo(at: targetAfterMove, followingSymbolicLink: true) else { return false }
    return info.st_dev == targetInfo.st_dev && info.st_ino == targetInfo.st_ino
  }

  /// Delete a temp file
  func deleteTempFile(at url: URL) {
    guard let entry = temporaryEntryURL(for: url),
          let info = fileInfo(at: entry) else { return }
    let type = info.st_mode & S_IFMT
    guard type == S_IFREG || type == S_IFLNK else { return }
    let identity = CaptureFilePublication.SourceIdentity(device: info.st_dev, inode: info.st_ino)

    do {
      try identity.removeOriginal(at: entry, entryType: type)
      // Also clean up recording metadata if exists
      try? RecordingMetadataStore.delete(for: url)
      pruneEmptyTempDirectories(startingAt: url.deletingLastPathComponent())
      logger.debug("Deleted temp file: \(url.lastPathComponent)")
      DiagnosticLogger.shared.log(
        .info,
        .fileAccess,
        "Temp capture deleted",
        context: ["fileName": url.lastPathComponent]
      )
    } catch {
      logger.error("Failed to delete temp file: \(error.localizedDescription)")
      DiagnosticLogger.shared.logError(
        .fileAccess,
        error,
        "Temp capture delete failed",
        context: ["fileName": url.lastPathComponent]
      )
    }
  }

  /// Check if a URL is in the temp capture directory
  func isTempFile(_ url: URL) -> Bool {
    let tempPath = tempCaptureDirectory.standardizedFileURL.path
    let filePath = url.standardizedFileURL.path
    return filePath == tempPath || filePath.hasPrefix(tempPath + "/")
  }

  func temporaryEntryURL(for url: URL) -> URL? {
    guard isTempFile(url) else { return nil }
    let rootPath = tempCaptureDirectory.resolvingSymlinksInPath().path
    let entryPath = SandboxFileAccessManager.directoryEntryPath(for: url)
    guard entryPath.hasPrefix(rootPath + "/") else { return nil }
    return URL(fileURLWithPath: entryPath)
  }

  private func fileInfo(at entry: URL, followingSymbolicLink: Bool = false) -> stat? {
    entry.withUnsafeFileSystemRepresentation { path in
      var info = stat()
      guard let path else { return nil }
      let result = followingSymbolicLink ? stat(path, &info) : lstat(path, &info)
      guard result == 0 else { return nil }
      return info
    }
  }

  /// Cleanup all orphaned temp files (call on app launch).
  /// Skips files that have an active history record — the retention service
  /// will delete them when the history record ages out.
  func cleanupOrphanedFiles() {
    let fm = FileManager.default

    guard let enumerator = fm.enumerator(
      at: tempCaptureDirectory,
      includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .creationDateKey],
      options: [.skipsHiddenFiles]
    ) else {
      DiagnosticLogger.shared.log(.warning, .fileAccess, "Temp capture startup cleanup failed to list directory")
      return
    }

    let historyEnabled = defaults.snapzyHistoryEnabled
    let retainedPaths = CaptureHistoryStore.shared.fetchRecords().map { records in
      Set(records.map { $0.fileURL.resolvingSymlinksInPath().path })
    }
    var count = 0
    var skipped = 0
    var preservedForRetention = 0
    var directoriesToPrune: [URL] = []
    let recordingProcessingPath = recordingProcessingDirectory.standardizedFileURL.path

    for case let fileURL as URL in enumerator {
      // Незавершённые записи и их служебные файлы обрабатывает восстановление.
      if fileURL.standardizedFileURL.path == recordingProcessingPath {
        enumerator.skipDescendants()
        continue
      }
      guard let revision = CaptureFilePublication.FileRevision(at: fileURL) else { continue }

      // Skip files referenced by active history records
      if retainedPaths?.contains(fileURL.resolvingSymlinksInPath().path) == true {
        skipped += 1
        continue
      }

      if historyEnabled, retainedPaths == nil {
        preservedForRetention += 1
        continue
      }

      // Keep recent temp captures alive while history is enabled, even if the
      // startup lookup cannot reconcile them yet. Retention and explicit cache
      // clearing remain the mechanisms that actually delete these files.
      if shouldPreserveForHistoryRetention(fileURL, historyEnabled: historyEnabled) {
        preservedForRetention += 1
        continue
      }

      do {
        try revision.removeOriginal(at: fileURL)
        try? RecordingMetadataStore.delete(for: fileURL)
        directoriesToPrune.append(fileURL.deletingLastPathComponent())
        count += 1
      } catch {
        logger.error("Failed to cleanup orphan: \(fileURL.lastPathComponent)")
        DiagnosticLogger.shared.logError(
          .fileAccess,
          error,
          "Temp capture startup cleanup failed to delete orphan",
          context: ["fileName": fileURL.lastPathComponent]
        )
      }
    }

    for directory in directoriesToPrune {
      pruneEmptyTempDirectories(startingAt: directory)
    }

    if count > 0 {
      logger.info("Cleaned up \(count) orphaned temp capture file(s)")
      DiagnosticLogger.shared.log(
        .info,
        .lifecycle,
        "Temp capture startup cleanup removed orphaned files",
        context: ["fileCount": "\(count)"]
      )
    }
    if skipped > 0 {
      logger.info("Preserved \(skipped) temp file(s) with active history records")
      DiagnosticLogger.shared.log(
        .info,
        .lifecycle,
        "Temp capture startup cleanup preserved files with history records",
        context: ["fileCount": "\(skipped)"]
      )
    }
    if preservedForRetention > 0 {
      logger.info("Preserved \(preservedForRetention) recent temp file(s) within history retention window")
      DiagnosticLogger.shared.log(
        .info,
        .lifecycle,
        "Temp capture startup cleanup preserved recent files within history retention window",
        context: ["fileCount": "\(preservedForRetention)"]
      )
    }
  }

  // MARK: - Private

  static func tempCaptureRootDirectory() -> URL {
    guard let appSupport = OwnShotStoragePaths.applicationSupportDirectory else {
      return FileManager.default.temporaryDirectory
        .appendingPathComponent("OwnShot_Captures", isDirectory: true)
    }

    return appSupport
      .appendingPathComponent("OwnShot", isDirectory: true)
      .appendingPathComponent("Captures", isDirectory: true)
  }

  private func relativeTempPath(for url: URL) -> String? {
    let tempPath = tempCaptureDirectory.standardizedFileURL.path
    let filePath = url.standardizedFileURL.path

    guard filePath.hasPrefix(tempPath + "/") else { return nil }

    let relativePath = String(filePath.dropFirst(tempPath.count + 1))
    return relativePath.isEmpty ? nil : relativePath
  }

  private func pruneEmptyTempDirectories(startingAt directory: URL) {
    let rootPath = tempCaptureDirectory.standardizedFileURL.path
    var current = directory.standardizedFileURL

    while current.path.hasPrefix(rootPath + "/") {
      guard current.withUnsafeFileSystemRepresentation({ path in
        guard let path else { return false }
        return rmdir(path) == 0
      }) else { break }
      current.deleteLastPathComponent()
    }
  }

  private func createRecordingProcessingSession() throws -> RecordingProcessingSession {
    try FileManager.default.createDirectory(at: recordingProcessingDirectory, withIntermediateDirectories: true)
    let directory = recordingProcessingDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    guard let session = RecordingProcessingSession(directory: directory) else {
      throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: directory.path])
    }
    return session
  }

  private func isRecordingProcessingSessionDirectory(_ directory: URL) -> Bool {
    let rootPath = recordingProcessingDirectory.standardizedFileURL.resolvingSymlinksInPath().path
    let directoryPath = directory.standardizedFileURL.resolvingSymlinksInPath().path
    return directoryPath.hasPrefix(rootPath + "/")
  }

  /// Move associated recording metadata sidecar when saving a video
  private func moveRecordingMetadataIfNeeded(
    from sourceURL: URL, to destinationURL: URL,
    destination: RecordingMetadataStore.MoveDestination,
    publication: RecordingMetadataStore.PublicationEvidence?
  ) {
    do {
      try RecordingMetadataStore.moveAssociation(
        from: sourceURL, to: destinationURL, destination: destination, publication: publication
      )
    } catch {
      DiagnosticLogger.shared.logError(
        .recording,
        error,
        "Recording metadata move failed for temp capture",
        context: ["fileName": destinationURL.lastPathComponent]
      )
    }
  }

  private func shouldPreserveForHistoryRetention(_ fileURL: URL, historyEnabled: Bool) -> Bool {
    guard historyEnabled else { return false }
    guard
      let values = try? fileURL.resourceValues(
        forKeys: [.isRegularFileKey, .contentModificationDateKey, .creationDateKey]
      ),
      values.isRegularFile == true
    else {
      return false
    }

    let retentionDays = defaults.integer(forKey: PreferencesKeys.historyRetentionDays)
    if retentionDays == 0 {
      return true
    }

    let referenceDate = values.contentModificationDate ?? values.creationDate ?? .distantPast
    let cutoff = Date().addingTimeInterval(-TimeInterval(retentionDays * 24 * 60 * 60))
    return referenceDate >= cutoff
  }
}

/// Publishes capture files and staged session packages.
nonisolated enum CaptureFilePublication {
  enum Result {
    case moved
    case copied(FileRevision)
    case failed(Int32)
  }

  struct FileRevision: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
    let fileSize: off_t
    private let modifiedSeconds: Int
    private let modifiedNanoseconds: Int
    private let changedSeconds: Int
    private let changedNanoseconds: Int

    var modificationDate: Date {
      Date(timeIntervalSinceReferenceDate: Double(modifiedSeconds) - Date.timeIntervalBetween1970AndReferenceDate +
        Double(modifiedNanoseconds) / 1_000_000_000)
    }

    init?(at url: URL) {
      var info = stat()
      let isRegularFile = url.withUnsafeFileSystemRepresentation { path in
        guard let path, lstat(path, &info) == 0 else { return false }
        return info.st_mode & S_IFMT == S_IFREG
      }
      guard isRegularFile else { return nil }
      self.init(info)
    }

    fileprivate init(_ info: stat) {
      device = info.st_dev
      inode = info.st_ino
      fileSize = info.st_size
      modifiedSeconds = info.st_mtimespec.tv_sec
      modifiedNanoseconds = info.st_mtimespec.tv_nsec
      changedSeconds = info.st_ctimespec.tv_sec
      changedNanoseconds = info.st_ctimespec.tv_nsec
    }

    fileprivate func matchesWrittenFile(_ other: Self) -> Bool {
      device == other.device && inode == other.inode && fileSize == other.fileSize &&
        modifiedSeconds == other.modifiedSeconds && modifiedNanoseconds == other.modifiedNanoseconds
    }

    func removeOriginal(at url: URL) throws {
      try CaptureFilePublication.removeOriginal(at: url) { Self($0) == self }
    }
  }

  struct SourceIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t

    static func regularFile(at url: URL) -> Self? {
      at(url, type: mode_t(S_IFREG))
    }

    static func at(_ url: URL, type: mode_t? = nil) -> Self? {
      url.withUnsafeFileSystemRepresentation { path in
        var info = stat()
        guard let path, lstat(path, &info) == 0 else { return nil }
        if let type, info.st_mode & mode_t(S_IFMT) != type { return nil }
        return Self(device: info.st_dev, inode: info.st_ino)
      }
    }

    func removeOriginal(at url: URL, entryType: mode_t = mode_t(S_IFREG)) throws {
      try CaptureFilePublication.removeOriginal(at: url, entryType: entryType) {
        $0.st_dev == device && $0.st_ino == inode
      }
    }
  }

  private static func removeOriginal(
    at url: URL, entryType: mode_t = mode_t(S_IFREG), matching matches: (stat) -> Bool
  ) throws {
    let status = url.withUnsafeFileSystemRepresentation { path -> Int32 in
      guard let path else { return EINVAL }
      var current = stat()
      guard lstat(path, &current) == 0 else { return errno }
      guard current.st_mode & mode_t(S_IFMT) == entryType, matches(current) else { return ESTALE }
      return unlink(path) == 0 ? 0 : errno
    }
    guard status == 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(status), userInfo: [NSFilePathErrorKey: url.path])
    }
  }

  static func stagePackagePayload(from source: URL, to stage: URL, using fileManager: FileManager = .default) throws {
    // The new manifest needs a writable parent even when the source package is read-only.
    try fileManager.createDirectory(at: stage, withIntermediateDirectories: false)
    let flags = copyfile_flags_t(COPYFILE_CLONE | COPYFILE_RECURSIVE)
    for entry in try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
    where entry.lastPathComponent != "manifest.json" {
      let target = stage.appendingPathComponent(entry.lastPathComponent)
      try entry.withUnsafeFileSystemRepresentation { sourcePath in
        try target.withUnsafeFileSystemRepresentation { targetPath in
          guard let sourcePath, let targetPath else { throw POSIXError(.EINVAL) }
          guard copyfile(sourcePath, targetPath, nil, flags) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
          }
        }
      }
    }
  }

  enum DestinationRevision: Equatable, Sendable {
    case missing
    case file(FileRevision)
    case link(SourceIdentity)

    init(at url: URL) throws {
      var info = stat()
      let error = url.withUnsafeFileSystemRepresentation { path -> Int32 in
        guard let path else { return EINVAL }
        return lstat(path, &info) == 0 ? 0 : errno
      }
      if error == ENOENT {
        self = .missing
        return
      }
      guard error == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(error), userInfo: [NSFilePathErrorKey: url.path])
      }
      guard let revision = Self(snapshot: info) else { throw POSIXError(.EINVAL) }
      self = revision
    }

    static func existing(at url: URL) throws -> Self {
      let revision = try Self(at: url)
      guard revision != .missing else {
        throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
      }
      return revision
    }

    fileprivate init?(snapshot info: stat) {
      switch info.st_mode & mode_t(S_IFMT) {
      case mode_t(S_IFREG):
        self = .file(FileRevision(info))
      case mode_t(S_IFLNK):
        self = .link(SourceIdentity(device: info.st_dev, inode: info.st_ino))
      default:
        return nil
      }
    }
  }

  static func replaceFile(
    from staged: URL, to destination: URL, expecting revision: DestinationRevision
  ) throws {
    let error: Int32
    if revision == .missing {
      switch publish(staged, to: destination, copyFlags: copyfile_flags_t(COPYFILE_ALL)) {
      case .moved, .copied: return
      case .failed(let failure): error = failure
      }
    } else {
      error = staged.withUnsafeFileSystemRepresentation { stagedPath in
        destination.withUnsafeFileSystemRepresentation { destinationPath -> Int32 in
          guard let stagedPath, let destinationPath else { return EINVAL }
          var info = stat()
          guard lstat(destinationPath, &info) == 0 else { return errno }
          guard DestinationRevision(snapshot: info) == revision else { return ESTALE }
          return Darwin.rename(stagedPath, destinationPath) == 0 ? 0 : errno
        }
      }
    }
    guard error == 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(error), userInfo: [NSFilePathErrorKey: destination.path])
    }
  }

  static func destinationSnapshot(named name: String, in directory: Int32)
    throws -> (revision: DestinationRevision, permissions: mode_t?) {
    var info = stat()
    if fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
      let error = errno
      if error == ENOENT { return (.missing, nil) }
      throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
    }
    guard let revision = DestinationRevision(snapshot: info) else { throw POSIXError(.EINVAL) }
    let permissions: mode_t? = (info.st_mode & S_IFMT) == S_IFREG ? info.st_mode & 0o7777 : nil
    return (revision, permissions)
  }

  static func isDirectory(_ url: URL, representedBy descriptor: Int32) -> Bool {
    var info = stat()
    guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return false }
    let identity = SourceIdentity(device: info.st_dev, inode: info.st_ino)
    return SourceIdentity.at(url.resolvingSymlinksInPath(), type: mode_t(S_IFDIR)) == identity
  }

  /// Записывает данные во временный файл на том же томе, что и назначение.
  /// Очистка и публикация работают через открытый каталог, даже если его переименовали.
  static func replaceFile(
    with data: Data, to destination: URL, in directory: Int32,
    expecting revision: DestinationRevision, permissions: mode_t?
  ) throws -> FileRevision {
    let temporaryName = ".ownshot-annotate-\(UUID().uuidString)"
    let initialMode: mode_t = permissions == nil ? 0o666 : 0o600
    let descriptor = temporaryName.withCString {
      openat(directory, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, initialMode)
    }
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    func removeTemporaryEntry() {
      var staged = stat()
      var entry = stat()
      if fstat(descriptor, &staged) == 0,
         fstatat(directory, temporaryName, &entry, AT_SYMLINK_NOFOLLOW) == 0,
         staged.st_dev == entry.st_dev, staged.st_ino == entry.st_ino {
        _ = unlinkat(directory, temporaryName, 0)
      }
    }
    defer {
      removeTemporaryEntry()
      Darwin.close(descriptor)
    }

    try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).write(contentsOf: data)
    if let permissions, fchmod(descriptor, permissions) != 0 {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    var written = stat()
    var entry = stat()
    guard fstat(descriptor, &written) == 0,
          fstatat(directory, temporaryName, &entry, AT_SYMLINK_NOFOLLOW) == 0,
          FileRevision(written) == FileRevision(entry) else { throw POSIXError(.ESTALE) }

    guard isDirectory(destination.deletingLastPathComponent(), representedBy: directory) else {
      throw POSIXError(.ESTALE)
    }
    let name = destination.lastPathComponent
    var result: Int32
    if revision == .missing {
      result = renameatx_np(directory, temporaryName, directory, name, UInt32(RENAME_EXCL))
      if result != 0, errno == ENOTSUP {
        result = linkat(directory, temporaryName, directory, name, 0)
      }
    } else {
      guard try destinationSnapshot(named: name, in: directory).revision == revision else {
        throw POSIXError(.ESTALE)
      }
      result = renameat(directory, temporaryName, directory, name)
    }
    guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    // После linkat удаление временного имени меняет ctime опубликованного файла.
    removeTemporaryEntry()
    var published = stat()
    guard fstat(descriptor, &published) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    let publishedRevision = FileRevision(published)
    guard publishedRevision.matchesWrittenFile(FileRevision(written)) else { throw POSIXError(.ESTALE) }
    return publishedRevision
  }

  static func publishPackage(from staged: URL, to destination: URL) throws {
    try destination.withUnsafeFileSystemRepresentation { destinationPath in
      guard let destinationPath else { throw POSIXError(.EINVAL) }
      var info = stat()
      let flags: UInt32
      if lstat(destinationPath, &info) == 0 {
        guard info.st_mode & S_IFMT == S_IFDIR else { throw POSIXError(.ENOTDIR) }
        // Keep the previous package published until the complete replacement takes its place.
        flags = UInt32(RENAME_SWAP)
      } else {
        guard errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        flags = UInt32(RENAME_EXCL)
      }
      try staged.withUnsafeFileSystemRepresentation { stagedPath in
        guard let stagedPath else { throw POSIXError(.EINVAL) }
        guard renamex_np(stagedPath, destinationPath, flags) == 0 else {
          throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
      }
    }
  }

  static func moveChoosingFreeName(
    at sourceURL: URL, to preferredURL: URL,
    beforePublication: (URL) throws -> Void
  ) throws -> URL {
    let directory = preferredURL.deletingLastPathComponent()
    let baseName = preferredURL.deletingPathExtension().lastPathComponent
    let fileExtension = preferredURL.pathExtension
    var destination = preferredURL
    var suffix = 2

    while true {
      try beforePublication(destination)
      switch publish(sourceURL, to: destination, copyFlags: copyfile_flags_t(COPYFILE_ALL)) {
      case .moved:
        return destination
      case .copied(let sourceRevision):
        // If removal fails, retain the complete copy and original, and report the failure.
        try sourceRevision.removeOriginal(at: sourceURL)
        return destination
      case .failed(EEXIST):
        let name = "\(baseName)_\(suffix)" + (fileExtension.isEmpty ? "" : ".\(fileExtension)")
        destination = directory.appendingPathComponent(name)
        suffix += 1
      case .failed(let error):
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(error), userInfo: [NSFilePathErrorKey: destination.path])
      }
    }
  }

  static func publish(
    _ source: URL,
    to destination: URL,
    copyFlags: copyfile_flags_t
  ) -> Result {
    source.withUnsafeFileSystemRepresentation { sourcePath in
      destination.withUnsafeFileSystemRepresentation { destinationPath in
        guard let sourcePath, let destinationPath else { return .failed(EINVAL) }
        if renamex_np(sourcePath, destinationPath, UInt32(RENAME_EXCL)) == 0 { return .moved }
        let renameError = errno
        guard renameError == EXDEV || renameError == ENOTSUP || renameError == EOPNOTSUPP else {
          return .failed(renameError)
        }

        return copyExclusively(from: sourcePath, to: destinationPath, flags: copyFlags)
      }
    }
  }

  private static func copyExclusively(
    from source: UnsafePointer<CChar>,
    to destination: UnsafePointer<CChar>,
    flags: copyfile_flags_t
  ) -> Result {
    let sourceFD = open(source, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard sourceFD >= 0 else { return .failed(errno) }
    defer { close(sourceFD) }

    var identity = stat()
    guard fstat(sourceFD, &identity) == 0 else { return .failed(errno) }
    guard (identity.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { return .failed(EINVAL) }
    let revision = FileRevision(identity)
    let outputFD = open(destination, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o666))
    guard outputFD >= 0 else { return .failed(errno) }

    var result = fcopyfile(sourceFD, outputFD, nil, flags) == 0 ? 0 : errno
    if result == 0 {
      var current = stat()
      if fstat(sourceFD, &current) != 0 {
        result = errno
      } else if FileRevision(current) != revision {
        result = ESTALE
      }
    }
    var owned = stat()
    let didIdentifyOutput = fstat(outputFD, &owned) == 0
    let closeError = close(outputFD) == 0 ? 0 : errno
    if result == 0 { result = closeError }
    if result != 0, didIdentifyOutput {
      var current = stat()
      if lstat(destination, &current) == 0, current.st_dev == owned.st_dev, current.st_ino == owned.st_ino {
        unlink(destination)
      }
    }
    return result == 0 ? .copied(revision) : .failed(result)
  }
}
