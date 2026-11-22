//
//  AnnotationSessionStore.swift
//  Snapzy
//
//  Sidecar persistence for committed editable annotation sessions.
//

import CryptoKit
import Darwin
import Foundation

@MainActor
final class AnnotationSessionStore {
  static let shared = AnnotationSessionStore()

  private let fileManager: FileManager
  private nonisolated let rootDirectory: URL
  private nonisolated let packagePublicationLock = NSLock()

  init(
    rootDirectory: URL = AnnotationSessionStore.defaultRootDirectory(),
    fileManager: FileManager = .default
  ) {
    self.rootDirectory = rootDirectory
    self.fileManager = fileManager
  }

  func load(for sourceURL: URL) -> AnnotationSessionData? {
    let normalizedPath = Self.normalizedPath(for: sourceURL)
    let pathHash = Self.pathHash(for: normalizedPath)
    let directory = sessionDirectory(pathHash: pathHash)
    let manifestURL = directory.appendingPathComponent("manifest.json")

    guard fileManager.fileExists(atPath: manifestURL.path) else { return nil }
    guard let manifest = readManifest(at: manifestURL),
          manifest.schemaVersion == PersistedAnnotationSession.currentSchemaVersion,
          manifest.sourceFilePathHash == pathHash,
          manifest.sourceFilePath == normalizedPath,
          let currentSignature = fileSignature(for: sourceURL),
          currentSignature == manifest.sourceSignature else {
      return nil
    }

    do {
      let originalData = try Data(contentsOf: directory.appendingPathComponent(manifest.originalFileName))
      let cutoutData = try manifest.cutoutFileName.map {
        try Data(contentsOf: directory.appendingPathComponent($0))
      }
      let assetsDirectory = directory.appendingPathComponent("assets", isDirectory: true)
      var embeddedAssets: [UUID: Data] = [:]
      for (assetIdString, fileName) in manifest.embeddedAssetFileNames {
        guard let assetId = UUID(uuidString: assetIdString) else { continue }
        let data = try Data(contentsOf: assetsDirectory.appendingPathComponent(fileName))
        embeddedAssets[assetId] = data
      }
      return manifest.sessionData(
        originalImageData: originalData,
        cutoutImageData: cutoutData,
        embeddedImageAssetsData: embeddedAssets
      )
    } catch {
      DiagnosticLogger.shared.logError(.annotate, error, "Annotation sidecar load failed")
      return nil
    }
  }

  @discardableResult
  func persist(_ sessionData: AnnotationSessionData, for sourceURL: URL) -> Bool {
    let scopedAccess = SandboxFileAccessManager.shared.beginAccessingURL(sourceURL)
    defer { scopedAccess.stop() }
    guard let signature = readFileSignature(for: sourceURL) else { return false }
    let manifest = buildManifest(sessionData, for: sourceURL, signature: signature)
    return persistWrite(manifest: manifest, sessionData: sessionData, for: sourceURL)
  }

  /// Off-main persist for the save-and-close background path: the multi-MB package
  /// write runs on the calling queue instead of the main thread.
  nonisolated func persistOffMain(
    _ sessionData: AnnotationSessionData,
    for sourceURL: URL,
    expecting expectedSourceRevision: CaptureFilePublication.FileRevision? = nil
  ) async -> Bool {
    let scopedAccess = await MainActor.run { SandboxFileAccessManager.shared.beginAccessingURL(sourceURL) }
    defer { scopedAccess.stop() }
    guard let signature = readFileSignature(for: sourceURL, expecting: expectedSourceRevision) else { return false }
    let manifest = await buildManifest(sessionData, for: sourceURL, signature: signature)
    return persistWrite(manifest: manifest, sessionData: sessionData,
      for: sourceURL, expecting: expectedSourceRevision)
  }

  /// Manifest construction is cheap and kept on main (the conversion init is @MainActor).
  @MainActor
  private func buildManifest(
    _ sessionData: AnnotationSessionData,
    for sourceURL: URL,
    signature: PersistedFileSignature
  ) -> PersistedAnnotationSession {
    let normalizedPath = Self.normalizedPath(for: sourceURL)
    let pathHash = Self.pathHash(for: normalizedPath)
    let directory = sessionDirectory(pathHash: pathHash)
    let previousCreatedAt = readManifest(
      at: directory.appendingPathComponent("manifest.json")
    )?.createdAt ?? Date()
    return PersistedAnnotationSession(
      sessionData: sessionData,
      sourceFilePath: normalizedPath,
      sourceFilePathHash: pathHash,
      sourceSignature: signature,
      createdAt: previousCreatedAt
    )
  }

  /// The heavy multi-MB package write. Runs on the caller's queue (main for the
  /// interactive path, a background queue for the save-and-close path).
  private nonisolated func persistWrite(
    manifest: PersistedAnnotationSession,
    sessionData: AnnotationSessionData,
    for sourceURL: URL,
    expecting expectedSourceRevision: CaptureFilePublication.FileRevision? = nil
  ) -> Bool {
    let pathHash = Self.pathHash(for: Self.normalizedPath(for: sourceURL))
    let directory = sessionDirectory(pathHash: pathHash)
    do {
      try writePackage(
        manifest: manifest,
        sessionData: sessionData,
        to: directory,
        source: expectedSourceRevision.map { (url: sourceURL, revision: $0) }
      )
      DiagnosticLogger.shared.log(
        .debug,
        .annotate,
        "Annotation sidecar persisted",
        context: ["fileName": sourceURL.lastPathComponent, "annotations": "\(sessionData.annotations.count)"]
      )
      return true
    } catch {
      DiagnosticLogger.shared.logError(.annotate, error, "Annotation sidecar persist failed")
      return false
    }
  }

  @discardableResult
  func moveSession(from oldURL: URL, to newURL: URL) -> Bool {
    let oldPath = Self.normalizedPath(for: oldURL)
    let oldHash = Self.pathHash(for: oldPath)
    let oldDirectory = sessionDirectory(pathHash: oldHash)
    guard let original = directoryInfo(at: oldDirectory) else { return false }

    let newPath = Self.normalizedPath(for: newURL)
    let newHash = Self.pathHash(for: newPath)
    let newDirectory = sessionDirectory(pathHash: newHash)
    guard oldDirectory.standardizedFileURL != newDirectory.standardizedFileURL else { return true }
    guard let signature = fileSignature(for: newURL),
          var manifest = readManifest(at: oldDirectory.appendingPathComponent("manifest.json")),
          manifest.schemaVersion == PersistedAnnotationSession.currentSchemaVersion,
          manifest.sourceFilePath == oldPath,
          manifest.sourceFilePathHash == oldHash else { return false }

    let stage = rootDirectory.appendingPathComponent(".\(newHash).\(UUID().uuidString)", isDirectory: true)
    let retired = rootDirectory.appendingPathComponent(".\(oldHash).\(UUID().uuidString)", isDirectory: true)
    var didRetire = false
    defer {
      try? fileManager.removeItem(at: stage)
      if didRetire { removeRetiredPackage(at: retired, original: original) }
    }
    do {
      try CaptureFilePublication.stagePackagePayload(from: oldDirectory, to: stage, using: fileManager)
      manifest.sourceFilePath = newPath
      manifest.sourceFilePathHash = newHash
      manifest.sourceSignature = signature
      manifest.updatedAt = Date()
      try writeManifest(manifest, to: stage.appendingPathComponent("manifest.json"))

      try packagePublicationLock.withLock {
        guard let current = directoryInfo(at: oldDirectory),
              current.st_dev == original.st_dev, current.st_ino == original.st_ino else {
          throw POSIXError(.ESTALE)
        }
        try CaptureFilePublication.publishPackage(from: stage, to: newDirectory)
        // A persist that swaps in a new package cannot interleave with this retirement.
        didRetire = (try? fileManager.moveItem(at: oldDirectory, to: retired)) != nil
      }
      return true
    } catch {
      DiagnosticLogger.shared.logError(.annotate, error, "Annotation sidecar move failed")
      return false
    }
  }

  private func removeRetiredPackage(at url: URL, original: stat) {
    guard let retired = directoryInfo(at: url),
          retired.st_dev == original.st_dev, retired.st_ino == original.st_ino else { return }
    if retired.st_mode & S_IWUSR == 0 {
      // Only the retired copy needs write permission for removal of its children.
      let permissions = (retired.st_mode & 0o777) | S_IWUSR
      try? fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }
    try? fileManager.removeItem(at: url)
  }

  private func directoryInfo(at directory: URL) -> stat? {
    directory.withUnsafeFileSystemRepresentation { path in
      var info = stat()
      guard let path, lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
      return info
    }
  }

  func deleteSession(for sourceURL: URL) {
    let pathHash = Self.pathHash(for: Self.normalizedPath(for: sourceURL))
    let directory = sessionDirectory(pathHash: pathHash)
    guard directoryInfo(at: directory) != nil else { return }
    do {
      try fileManager.removeItem(at: directory)
    } catch {
      DiagnosticLogger.shared.logError(.annotate, error, "Annotation sidecar delete failed")
    }
  }

  func cleanup(keepingScreenshotFilePaths paths: Set<String>) {
    // Writers publish from hidden directories only after the manifest is ready.
    guard let contents = try? fileManager.contentsOfDirectory(
      at: rootDirectory,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    ) else { return }

    let activePaths = Set(paths.map(Self.normalizedPath(forPath:)))
    for directory in contents {
      guard directoryInfo(at: directory) != nil else { continue }
      let manifestURL = directory.appendingPathComponent("manifest.json")
      guard let manifest = readManifest(at: manifestURL) else {
        try? fileManager.removeItem(at: directory)
        continue
      }

      let sourceURL = URL(fileURLWithPath: manifest.sourceFilePath)
      // A retained History entry can become readable again after a move or an unmounted volume.
      let shouldKeep = activePaths.contains(manifest.sourceFilePath)
        && (fileSignature(for: sourceURL).map { $0 == manifest.sourceSignature } ?? true)
      if !shouldKeep {
        try? fileManager.removeItem(at: directory)
      }
    }
  }

  func deleteAllSessions() {
    guard fileManager.fileExists(atPath: rootDirectory.path) else { return }
    do {
      try fileManager.removeItem(at: rootDirectory)
    } catch {
      DiagnosticLogger.shared.logError(.annotate, error, "Annotation sidecar clear failed")
    }
  }

  func shouldPersist(for sourceURL: URL) -> Bool {
    let historyEnabled = CaptureHistoryStore.shared.userDefaults.snapzyHistoryEnabled
    return historyEnabled || CaptureHistoryStore.shared.hasRecord(forFilePath: sourceURL.path)
  }

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

  private nonisolated static func defaultRootDirectory() -> URL {
    let appSupport = OwnShotStoragePaths.applicationSupportDirectory!
    return appSupport
      .appendingPathComponent("OwnShot", isDirectory: true)
      .appendingPathComponent("AnnotationSessions", isDirectory: true)
  }

  private nonisolated func sessionDirectory(pathHash: String) -> URL {
    rootDirectory.appendingPathComponent(pathHash, isDirectory: true)
  }

  private nonisolated func ensureRootDirectory() throws {
    try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
  }

  private func fileSignature(for sourceURL: URL) -> PersistedFileSignature? {
    let scopedAccess = SandboxFileAccessManager.shared.beginAccessingURL(sourceURL)
    defer { scopedAccess.stop() }
    return readFileSignature(for: sourceURL)
  }

  private nonisolated func readFileSignature(
    for sourceURL: URL,
    expecting expectedRevision: CaptureFilePublication.FileRevision? = nil
  ) -> PersistedFileSignature? {
    let fileSize: Int64
    let modifiedAt: TimeInterval
    if let expectedRevision {
      guard CaptureFilePublication.FileRevision(at: sourceURL) == expectedRevision else { return nil }
      fileSize = expectedRevision.fileSize
      modifiedAt = expectedRevision.modificationDate.timeIntervalSince1970
    } else {
      guard let attributes = try? FileManager.default.attributesOfItem(atPath: sourceURL.path) else { return nil }
      fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
      modifiedAt = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    }
    return PersistedFileSignature(
      fileSize: fileSize,
      modifiedAtMilliseconds: Int64((modifiedAt * 1000).rounded()),
      pathExtension: sourceURL.pathExtension.lowercased()
    )
  }

  private nonisolated func readManifest(at url: URL) -> PersistedAnnotationSession? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(PersistedAnnotationSession.self, from: data)
  }

  private nonisolated func writePackage(
    manifest: PersistedAnnotationSession,
    sessionData: AnnotationSessionData,
    to directory: URL,
    source: (url: URL, revision: CaptureFilePublication.FileRevision)?
  ) throws {
    try ensureRootDirectory()
    let tempDirectory = rootDirectory.appendingPathComponent(
      ".\(directory.lastPathComponent).\(UUID().uuidString)",
      isDirectory: true
    )
    let assetsDirectory = tempDirectory.appendingPathComponent("assets", isDirectory: true)
    try FileManager.default.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)
    do {
      try sessionData.originalImageData.write(
        to: tempDirectory.appendingPathComponent(manifest.originalFileName),
        options: .atomic
      )
      if let cutoutFileName = manifest.cutoutFileName, let cutoutImageData = sessionData.cutoutImageData {
        try cutoutImageData.write(to: tempDirectory.appendingPathComponent(cutoutFileName), options: .atomic)
      }
      for (assetIdString, fileName) in manifest.embeddedAssetFileNames {
        guard let assetId = UUID(uuidString: assetIdString),
              let data = sessionData.embeddedImageAssetsData[assetId] else { continue }
        try data.write(to: assetsDirectory.appendingPathComponent(fileName), options: .atomic)
      }
      try writeManifest(manifest, to: tempDirectory.appendingPathComponent("manifest.json"))
      try packagePublicationLock.withLock {
        if let source, CaptureFilePublication.FileRevision(at: source.url) != source.revision {
          throw POSIXError(.ESTALE)
        }
        try CaptureFilePublication.publishPackage(from: tempDirectory, to: directory)
      }
      try? FileManager.default.removeItem(at: tempDirectory)
    } catch {
      try? FileManager.default.removeItem(at: tempDirectory)
      throw error
    }
  }

  private nonisolated func writeManifest(_ manifest: PersistedAnnotationSession, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(manifest).write(to: url, options: .atomic)
  }
}
