//
//  VideoEditorSessionStore.swift
//  Snapzy
//
//  Durable sidecar storage for non-destructive Video Editor sessions.
//

import CryptoKit
import Darwin
import Foundation

@MainActor
final class VideoEditorSessionStore {
  static let shared = VideoEditorSessionStore()

  struct PreparedSourceSnapshot: Sendable {
    let directoryURL: URL
    let sourceURL: URL
  }

  enum StoreError: LocalizedError {
    case sourceUnavailable(URL)
    case packageUnavailable

    var errorDescription: String? {
      switch self {
      case .sourceUnavailable(let url):
        "The original video source could not be preserved for continued editing: \(url.lastPathComponent)"
      case .packageUnavailable:
        "The editable video session could not be stored."
      }
    }
  }

  private nonisolated let rootDirectory: URL
  private nonisolated let packagePublicationLock = NSLock()

  init(
    rootDirectory: URL = VideoEditorSessionStore.defaultRootDirectory()
  ) {
    self.rootDirectory = rootDirectory
  }

  // MARK: - Load

  /// Load a session only when the current media still matches the commit that
  /// created it. A nil result intentionally means “open this file as legacy media”.
  func load(for sourceURL: URL) -> VideoEditorSessionData? {
    let normalizedPath = Self.normalizedPath(for: sourceURL)
    let pathHash = Self.pathHash(for: normalizedPath)
    let directory = sessionDirectory(pathHash: pathHash)
    let manifestURL = directory.appendingPathComponent("manifest.json")

    guard let manifest = Self.readManifest(at: manifestURL),
          manifest.schemaVersion == PersistedVideoEditorSession.currentSchemaVersion,
          manifest.sourceFilePath == normalizedPath,
          manifest.sourceFilePathHash == pathHash,
          let currentSignature = fileSignature(for: sourceURL),
          currentSignature == manifest.sourceSignature
    else {
      return nil
    }

    let sourceSnapshotURL = directory.appendingPathComponent(
      manifest.sourceSnapshotFileName,
      isDirectory: false
    )
    guard FileManager.default.fileExists(atPath: sourceSnapshotURL.path) else {
      return nil
    }

    return manifest.sessionData(sourceSnapshotURL: sourceSnapshotURL)
  }

  // MARK: - Source Snapshot

  /// Copy the current unrendered editor source into a pending package before the
  /// destination is replaced. The copy is deliberately off the main actor because
  /// recordings can be hundreds of megabytes.
  nonisolated func prepareSourceSnapshot(
    from sourceURL: URL,
    for targetURL: URL
  ) async throws -> PreparedSourceSnapshot {
    let sourceAccess = await MainActor.run {
      SandboxFileAccessManager.shared.beginAccessingURL(sourceURL)
    }
    defer { sourceAccess.stop() }

    let scopedSourceURL = sourceAccess.url
    guard FileManager.default.fileExists(atPath: scopedSourceURL.path) else {
      throw StoreError.sourceUnavailable(sourceURL)
    }

    let normalizedTargetPath = Self.normalizedPath(for: targetURL)
    let pathHash = Self.pathHash(for: normalizedTargetPath)
    let pendingDirectory = rootDirectory.appendingPathComponent(
      ".\(pathHash).\(UUID().uuidString)",
      isDirectory: true
    )
    let sourceFileName = Self.sourceSnapshotFileName(for: scopedSourceURL)
    let pendingSourceURL = pendingDirectory.appendingPathComponent(sourceFileName)

    do {
      try FileManager.default.createDirectory(
        at: pendingDirectory,
        withIntermediateDirectories: true
      )
      try Self.copySourceSnapshot(from: scopedSourceURL, to: pendingSourceURL)
      return PreparedSourceSnapshot(
        directoryURL: pendingDirectory,
        sourceURL: pendingSourceURL
      )
    } catch {
      try? FileManager.default.removeItem(at: pendingDirectory)
      throw error
    }
  }

  nonisolated func discardPreparedSourceSnapshot(_ prepared: PreparedSourceSnapshot) {
    guard prepared.directoryURL.deletingLastPathComponent().standardizedFileURL
      == rootDirectory.standardizedFileURL,
      prepared.directoryURL.lastPathComponent.hasPrefix(".")
    else {
      return
    }
    try? FileManager.default.removeItem(at: prepared.directoryURL)
  }

  /// Resolve the stable source URL for a committed session package. Callers may
  /// use this when a save started with a pending source snapshot: the pending
  /// directory is moved into this package after the manifest is written.
  nonisolated func committedSourceSnapshotURL(
    for sourceURL: URL,
    fileName: String
  ) -> URL {
    let pathHash = Self.pathHash(for: Self.normalizedPath(for: sourceURL))
    return sessionDirectory(pathHash: pathHash).appendingPathComponent(fileName)
  }

  // MARK: - Persist

  @discardableResult
  func persist(
    _ sessionData: VideoEditorSessionData,
    for sourceURL: URL,
    preparedSourceDirectory: URL? = nil
  ) -> Bool {
    let scopedAccess = SandboxFileAccessManager.shared.beginAccessingURL(sourceURL)
    defer { scopedAccess.stop() }
    guard let signature = Self.readFileSignature(for: scopedAccess.url) else { return false }

    let manifest = makeManifest(
      sessionData,
      for: sourceURL,
      signature: signature
    )
    return persistWrite(
      manifest: manifest,
      sessionData: sessionData,
      for: sourceURL,
      preparedSourceDirectory: preparedSourceDirectory
    )
  }

  /// Off-main variant used after export. With a prepared source package this only
  /// writes a small JSON manifest; the fallback path copies the source snapshot.
  nonisolated func persistOffMain(
    _ sessionData: VideoEditorSessionData,
    for sourceURL: URL,
    preparedSourceDirectory: URL? = nil
  ) async -> Bool {
    let scopedAccess = await MainActor.run {
      SandboxFileAccessManager.shared.beginAccessingURL(sourceURL)
    }
    defer { scopedAccess.stop() }
    guard let signature = Self.readFileSignature(for: scopedAccess.url) else { return false }

    let manifest = makeManifest(
      sessionData,
      for: sourceURL,
      signature: signature
    )
    return persistWrite(
      manifest: manifest,
      sessionData: sessionData,
      for: sourceURL,
      preparedSourceDirectory: preparedSourceDirectory
    )
  }

  // MARK: - Ownership Changes

  @discardableResult
  func moveSession(from oldURL: URL, to newURL: URL) -> Bool {
    let oldPath = Self.normalizedPath(for: oldURL)
    let oldHash = Self.pathHash(for: oldPath)
    let oldDirectory = sessionDirectory(pathHash: oldHash)
    let newPath = Self.normalizedPath(for: newURL)
    let newHash = Self.pathHash(for: newPath)
    let newDirectory = sessionDirectory(pathHash: newHash)
    let originalManifestURL = oldDirectory.appendingPathComponent("manifest.json")
    guard let original = CaptureFilePublication.SourceIdentity.at(oldDirectory, type: mode_t(S_IFDIR)),
          let originalRevision = CaptureFilePublication.FileRevision(at: originalManifestURL),
          let signature = fileSignature(for: newURL),
          var manifest = Self.readManifest(at: originalManifestURL),
          manifest.schemaVersion == PersistedVideoEditorSession.currentSchemaVersion,
          manifest.sourceFilePath == oldPath,
          manifest.sourceFilePathHash == oldHash else { return false }

    manifest.sourceFilePath = newPath
    manifest.sourceFilePathHash = newHash
    manifest.sourceSignature = signature
    manifest.updatedAt = Date()

    let files = FileManager.default
    let stage = rootDirectory.appendingPathComponent(".\(newHash).\(UUID().uuidString)", isDirectory: true)
    let retired = rootDirectory.appendingPathComponent(".\(oldHash).\(UUID().uuidString)", isDirectory: true)
    defer {
      Self.removeRetiredPackage(at: stage)
      Self.removeRetiredPackage(at: retired, expectedIdentity: original)
    }
    do {
      let changesPackagePath = oldDirectory.standardizedFileURL != newDirectory.standardizedFileURL
      if changesPackagePath {
        try CaptureFilePublication.stagePackagePayload(from: oldDirectory, to: stage)
        try Self.writeManifest(manifest, to: stage.appendingPathComponent("manifest.json"))
      }
      try packagePublicationLock.withLock {
        guard CaptureFilePublication.SourceIdentity.at(oldDirectory, type: mode_t(S_IFDIR)) == original,
              CaptureFilePublication.FileRevision(at: originalManifestURL) == originalRevision else {
          throw POSIXError(.ESTALE)
        }
        if changesPackagePath {
          try CaptureFilePublication.publishPackage(from: stage, to: newDirectory)
          try? files.moveItem(at: oldDirectory, to: retired)
        } else {
          try Self.writeManifest(manifest, to: originalManifestURL)
        }
      }
      return true
    } catch {
      DiagnosticLogger.shared.logError(.editor, error, "Video Editor session move failed")
      return false
    }
  }

  func deleteSession(for sourceURL: URL) {
    let pathHash = Self.pathHash(for: Self.normalizedPath(for: sourceURL))
    let directory = sessionDirectory(pathHash: pathHash)
    guard Self.isRealDirectory(directory) else { return }
    do {
      try FileManager.default.removeItem(at: directory)
    } catch {
      DiagnosticLogger.shared.logError(.editor, error, "Video Editor session delete failed")
    }
  }

  func cleanup(keepingMediaFilePaths paths: Set<String>) {
    guard let contents = try? FileManager.default.contentsOfDirectory(
      at: rootDirectory,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    ) else {
      return
    }

    let activePaths = Set(paths.map(Self.normalizedPath(forPath:)))
    for directory in contents {
      guard Self.isRealDirectory(directory) else { continue }
      let manifestURL = directory.appendingPathComponent("manifest.json")
      guard let manifest = Self.readManifest(at: manifestURL) else {
        try? FileManager.default.removeItem(at: directory)
        continue
      }

      let sourceURL = URL(fileURLWithPath: manifest.sourceFilePath)
      let sourceSnapshotURL = directory.appendingPathComponent(manifest.sourceSnapshotFileName)
      let shouldKeep = activePaths.contains(manifest.sourceFilePath)
        && (fileSignature(for: sourceURL).map { $0 == manifest.sourceSignature } ?? true)
        && FileManager.default.fileExists(atPath: sourceSnapshotURL.path)
      if !shouldKeep {
        try? FileManager.default.removeItem(at: directory)
      }
    }
  }

  func deleteAllSessions() {
    guard FileManager.default.fileExists(atPath: rootDirectory.path) else { return }
    do {
      try FileManager.default.removeItem(at: rootDirectory)
    } catch {
      DiagnosticLogger.shared.logError(.editor, error, "Video Editor session clear failed")
    }
  }

  // MARK: - Paths and Signatures

  nonisolated static func normalizedPath(for sourceURL: URL) -> String {
    normalizedPath(forPath: sourceURL.standardizedFileURL.path)
  }

  nonisolated static func normalizedPath(forPath path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.path
  }

  nonisolated static func pathHash(for normalizedPath: String) -> String {
    let digest = SHA256.hash(data: Data(normalizedPath.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  // MARK: - Private Persistence

  private nonisolated func sessionDirectory(pathHash: String) -> URL {
    rootDirectory.appendingPathComponent(pathHash, isDirectory: true)
  }

  private nonisolated func makeManifest(
    _ sessionData: VideoEditorSessionData,
    for sourceURL: URL,
    signature: PersistedFileSignature
  ) -> PersistedVideoEditorSession {
    let normalizedPath = Self.normalizedPath(for: sourceURL)
    let pathHash = Self.pathHash(for: normalizedPath)
    let directory = sessionDirectory(pathHash: pathHash)
    let previousCreatedAt = Self.readManifest(
      at: directory.appendingPathComponent("manifest.json")
    )?.createdAt ?? Date()

    return PersistedVideoEditorSession(
      sessionData: sessionData,
      sourceFilePath: normalizedPath,
      sourceFilePathHash: pathHash,
      sourceSignature: signature,
      sourceSnapshotFileName: Self.sourceSnapshotFileName(for: sessionData.sourceSnapshotURL),
      createdAt: previousCreatedAt
    )
  }

  private nonisolated func persistWrite(
    manifest: PersistedVideoEditorSession,
    sessionData: VideoEditorSessionData,
    for sourceURL: URL,
    preparedSourceDirectory: URL?
  ) -> Bool {
    let directory = sessionDirectory(pathHash: manifest.sourceFilePathHash)

    do {
      try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)

      if let preparedSourceDirectory {
        guard preparedSourceDirectory.deletingLastPathComponent().standardizedFileURL
          == rootDirectory.standardizedFileURL,
          preparedSourceDirectory.standardizedFileURL != directory.standardizedFileURL,
          FileManager.default.fileExists(
            atPath: preparedSourceDirectory.appendingPathComponent(
              manifest.sourceSnapshotFileName
            ).path
          )
        else {
          throw StoreError.packageUnavailable
        }

        try Self.writeManifest(
          manifest,
          to: preparedSourceDirectory.appendingPathComponent("manifest.json")
        )
        try publishPreparedPackage(from: preparedSourceDirectory, to: directory)
      } else if Self.isSnapshotInside(
        sessionData.sourceSnapshotURL,
        directory: directory
      ), CaptureFilePublication.SourceIdentity.regularFile(at: sessionData.sourceSnapshotURL) != nil {
        // Reopening and saving an existing session only needs an atomic manifest
        // update; the master source must remain byte-for-byte unchanged.
        try packagePublicationLock.withLock {
          try Self.writeManifest(manifest, to: directory.appendingPathComponent("manifest.json"))
        }
      } else {
        let temporaryDirectory = rootDirectory.appendingPathComponent(
          ".\(directory.lastPathComponent).\(UUID().uuidString)",
          isDirectory: true
        )
        let sourceFileURL = temporaryDirectory.appendingPathComponent(
          manifest.sourceSnapshotFileName
        )
        try FileManager.default.createDirectory(
          at: temporaryDirectory,
          withIntermediateDirectories: true
        )
        do {
          try Self.copySourceSnapshot(from: sessionData.sourceSnapshotURL, to: sourceFileURL)
          try Self.writeManifest(
            manifest,
            to: temporaryDirectory.appendingPathComponent("manifest.json")
          )
          try publishPreparedPackage(from: temporaryDirectory, to: directory)
        } catch {
          try? FileManager.default.removeItem(at: temporaryDirectory)
          throw error
        }
      }

      DiagnosticLogger.shared.log(
        .debug,
        .editor,
        "Video Editor session persisted",
        context: [
          "fileName": sourceURL.lastPathComponent,
          "clips": "\(sessionData.clips.count)",
          "zooms": "\(sessionData.zoomSegments.count)",
          "speeds": "\(sessionData.speedSegments.count)",
        ]
      )
      return true
    } catch {
      DiagnosticLogger.shared.logError(.editor, error, "Video Editor session persist failed")
      return false
    }
  }

  private nonisolated static func copySourceSnapshot(from sourceURL: URL, to destination: URL) throws {
    let sourceFile = sourceURL.resolvingSymlinksInPath()
    guard CaptureFilePublication.SourceIdentity.regularFile(at: sourceFile) != nil else {
      throw StoreError.sourceUnavailable(sourceURL)
    }
    try FileManager.default.copyItem(at: sourceFile, to: destination)
  }

  private nonisolated func publishPreparedPackage(from stage: URL, to destination: URL) throws {
    try packagePublicationLock.withLock {
      try CaptureFilePublication.publishPackage(from: stage, to: destination)
    }
    Self.removeRetiredPackage(at: stage)
  }

  private nonisolated static func removeRetiredPackage(
    at directory: URL, expectedIdentity: CaptureFilePublication.SourceIdentity? = nil
  ) {
    guard let identity = CaptureFilePublication.SourceIdentity.at(directory, type: mode_t(S_IFDIR)),
          expectedIdentity == nil || identity == expectedIdentity else { return }
    let files = FileManager.default
    if let permissions = (try? files.attributesOfItem(atPath: directory.path)[.posixPermissions]) as? NSNumber,
       permissions.intValue & 0o200 == 0 {
      try? files.setAttributes([.posixPermissions: permissions.intValue | 0o200], ofItemAtPath: directory.path)
    }
    try? files.removeItem(at: directory)
  }

  private nonisolated static func isRealDirectory(_ url: URL) -> Bool {
    CaptureFilePublication.SourceIdentity.at(url, type: mode_t(S_IFDIR)) != nil
  }

  private nonisolated static func isSnapshotInside(_ sourceURL: URL, directory: URL) -> Bool {
    sourceURL.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL
  }

  private nonisolated static func sourceSnapshotFileName(for sourceURL: URL) -> String {
    let fileExtension = sourceURL.pathExtension
    return fileExtension.isEmpty ? "source" : "source.\(fileExtension)"
  }

  private nonisolated static func defaultRootDirectory() -> URL {
    let appSupport = OwnShotStoragePaths.applicationSupportDirectory!
    return appSupport
      .appendingPathComponent("OwnShot", isDirectory: true)
      .appendingPathComponent("VideoEditorSessions", isDirectory: true)
  }

  private func fileSignature(for sourceURL: URL) -> PersistedFileSignature? {
    let scopedAccess = SandboxFileAccessManager.shared.beginAccessingURL(sourceURL)
    defer { scopedAccess.stop() }
    return Self.readFileSignature(for: scopedAccess.url)
  }

  private nonisolated static func readFileSignature(for sourceURL: URL) -> PersistedFileSignature? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: sourceURL.path) else {
      return nil
    }
    let modifiedAt = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    return PersistedFileSignature(
      fileSize: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
      modifiedAtMilliseconds: Int64((modifiedAt * 1000).rounded()),
      pathExtension: sourceURL.pathExtension.lowercased()
    )
  }

  private nonisolated static func writeManifest(
    _ manifest: PersistedVideoEditorSession,
    to url: URL
  ) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(manifest).write(to: url, options: .atomic)
  }

  private nonisolated static func readManifest(
    at url: URL
  ) -> PersistedVideoEditorSession? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(PersistedVideoEditorSession.self, from: data)
  }
}
