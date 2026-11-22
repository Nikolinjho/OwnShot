//
//  RecordingMetadata.swift
//  Snapzy
//
//  Internal metadata for recordings that need editor-only context.
//

import CoreGraphics
import Darwin
import Foundation
import os.log

private let recordingMetadataLogger = Logger(subsystem: "Snapzy", category: "RecordingMetadata")

nonisolated struct RecordedMouseSample: Codable, Equatable {
  var time: TimeInterval
  var normalizedX: CGFloat
  var normalizedY: CGFloat
  var isInsideCapture: Bool

  var normalizedPoint: CGPoint {
    CGPoint(x: normalizedX, y: normalizedY)
  }
}

nonisolated enum RecordingCoordinateSpace: String, Codable {
  case bottomLeftNormalized
  case topLeftNormalized
}

nonisolated enum RecordingAudioSourceTrackRole: String, Codable, Equatable {
  case systemAudio
  case microphone

  static func roles(capturesSystemAudio: Bool, capturesMicrophone: Bool) -> [RecordingAudioSourceTrackRole] {
    var roles: [RecordingAudioSourceTrackRole] = []
    if capturesSystemAudio {
      roles.append(.systemAudio)
    }
    if capturesMicrophone {
      roles.append(.microphone)
    }
    return roles
  }
}

nonisolated struct RecordingAudioSourceTrack: Codable, Equatable {
  var trackID: Int
  var role: RecordingAudioSourceTrackRole
}

nonisolated struct RecordingMetadata: Codable, Equatable {
  static let currentVersion = 5

  var version: Int
  var coordinateSpace: RecordingCoordinateSpace
  var captureSize: CGSize
  var samplesPerSecond: Int
  var mouseSamples: [RecordedMouseSample]
  var audioSourceURL: URL?
  var audioSourceTrackRoles: [RecordingAudioSourceTrackRole]
  var audioSourceTracks: [RecordingAudioSourceTrack]

  init(
    version: Int = RecordingMetadata.currentVersion,
    coordinateSpace: RecordingCoordinateSpace = .topLeftNormalized,
    captureSize: CGSize,
    samplesPerSecond: Int,
    mouseSamples: [RecordedMouseSample],
    audioSourceURL: URL? = nil,
    audioSourceTrackRoles: [RecordingAudioSourceTrackRole] = [],
    audioSourceTracks: [RecordingAudioSourceTrack] = []
  ) {
    self.version = version
    self.coordinateSpace = coordinateSpace
    self.captureSize = captureSize
    self.samplesPerSecond = samplesPerSecond
    self.mouseSamples = mouseSamples
    self.audioSourceURL = audioSourceURL
    self.audioSourceTrackRoles = audioSourceTrackRoles
    self.audioSourceTracks = audioSourceTracks
  }

  private enum CodingKeys: String, CodingKey {
    case version
    case coordinateSpace
    case captureSize
    case samplesPerSecond
    case mouseSamples
    case audioSourceURL
    case audioSourceTrackRoles
    case audioSourceTracks
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let decodedVersion = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
    let decodedCoordinateSpace = try container.decodeIfPresent(
      RecordingCoordinateSpace.self,
      forKey: .coordinateSpace
    )

    version = decodedVersion
    coordinateSpace = decodedCoordinateSpace ?? (
      decodedVersion >= 2
        ? .topLeftNormalized
        : .bottomLeftNormalized
    )
    captureSize = try container.decode(CGSize.self, forKey: .captureSize)
    samplesPerSecond = try container.decode(Int.self, forKey: .samplesPerSecond)
    mouseSamples = try container.decode([RecordedMouseSample].self, forKey: .mouseSamples)
    audioSourceURL = try container.decodeIfPresent(URL.self, forKey: .audioSourceURL)
    audioSourceTrackRoles = try container.decodeIfPresent(
      [RecordingAudioSourceTrackRole].self,
      forKey: .audioSourceTrackRoles
    ) ?? []
    audioSourceTracks = try container.decodeIfPresent(
      [RecordingAudioSourceTrack].self,
      forKey: .audioSourceTracks
    ) ?? []
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(version, forKey: .version)
    try container.encode(coordinateSpace, forKey: .coordinateSpace)
    try container.encode(captureSize, forKey: .captureSize)
    try container.encode(samplesPerSecond, forKey: .samplesPerSecond)
    try container.encode(mouseSamples, forKey: .mouseSamples)
    try container.encodeIfPresent(audioSourceURL, forKey: .audioSourceURL)
    if !audioSourceTrackRoles.isEmpty {
      try container.encode(audioSourceTrackRoles, forKey: .audioSourceTrackRoles)
    }
    if !audioSourceTracks.isEmpty {
      try container.encode(audioSourceTracks, forKey: .audioSourceTracks)
    }
  }
}

@MainActor
enum RecordingMetadataStore {
  private struct StoreLocation {
    let entriesURL: URL
    let indexURL: URL
    let audioSourcesURL: URL
  }

  private struct MetadataIndex: Codable {
    var entries: [MetadataIndexEntry] = []
  }

  private struct MetadataIndexEntry: Codable, Equatable {
    var id: UUID
    var lastKnownPath: String
    var bookmarkData: Data
    var staleSince: Date?
    var excludedPath: String? = nil
  }

  private enum CleanupDisposition {
    case keep(MetadataIndexEntry)
    case delete
  }

  private static let appSupportFolderName = "OwnShot"
  private static let capturesFolderName = "Captures"
  private static let storeFolderName = "RecordingMetadata"
  private static let entriesFolderName = "Entries"
  private static let audioSourcesFolderName = "AudioSources"
  private static let indexFileName = "index.json"
  private static let metadataFileExtension = "json"
  private static let legacySidecarExtension = "ownshot-recording.json"
  private static let orphanGracePeriod: TimeInterval = 24 * 60 * 60

  private enum StoreLayout {
    case unified
    case legacy

    var pathComponents: [String] {
      switch self {
      case .unified:
        return [RecordingMetadataStore.capturesFolderName, RecordingMetadataStore.storeFolderName]
      case .legacy:
        return [RecordingMetadataStore.storeFolderName]
      }
    }
  }

  static func load(for videoURL: URL, applicationSupportDirectory: URL? = nil) -> RecordingMetadata? {
    do {
      let unifiedLocation = try requiredStoreLocation(applicationSupportDirectory: applicationSupportDirectory)
      var unifiedIndex = loadIndex(from: unifiedLocation)

      if let metadata = try loadStoredMetadata(
        for: videoURL,
        location: unifiedLocation,
        index: &unifiedIndex
      ) {
        return metadata.canonicalizedForCurrentVersion()
      }

      if let metadata = try migrateLegacySidecarIfNeeded(
        for: videoURL,
        location: unifiedLocation,
        index: &unifiedIndex
      ) {
        return metadata.canonicalizedForCurrentVersion()
      }

      for (layout, location) in try allStoreLocationsForRead(applicationSupportDirectory: applicationSupportDirectory) where layout == .legacy {
        var index = loadIndex(from: location)
        guard let metadata = try loadStoredMetadata(for: videoURL, location: location, index: &index)
        else {
          continue
        }

        let canonicalMetadata = metadata.canonicalizedForCurrentVersion()
        try save(canonicalMetadata, for: videoURL, applicationSupportDirectory: applicationSupportDirectory)
        try? deleteStoredMetadata(for: videoURL, location: location, index: &index, applicationSupportDirectory: applicationSupportDirectory)
        return canonicalMetadata
      }
    } catch {
      recordingMetadataLogger.error("Failed to load recording metadata for \(videoURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
    }

    return nil
  }

  static func save(_ metadata: RecordingMetadata, for videoURL: URL, applicationSupportDirectory: URL? = nil) throws {
    let location = try requiredStoreLocation(applicationSupportDirectory: applicationSupportDirectory)
    var index = loadIndex(from: location)

    let existingEntry = resolveEntry(for: videoURL, index: index)?.entry
    let entry = try makeEntry(id: existingEntry?.id ?? UUID(), for: videoURL)
    let metadataURL = self.metadataURL(for: entry.id, location: location)
    let normalizedMetadata = metadata.canonicalizedForCurrentVersion()

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(normalizedMetadata)
    try data.write(to: metadataURL, options: .atomic)

    upsert(entry: entry, into: &index)
    try saveIndex(index, to: location)
    if let legacyLocation = try storeLocation(layout: .legacy, createIfNeeded: false, applicationSupportDirectory: applicationSupportDirectory),
       legacyLocation.entriesURL != location.entriesURL {
      var legacyIndex = loadIndex(from: legacyLocation)
      try? deleteStoredMetadata(for: videoURL, location: legacyLocation, index: &legacyIndex, applicationSupportDirectory: applicationSupportDirectory)
    }
    try deleteLegacySidecarIfPresent(for: videoURL)
  }

  static func storeAudioSource(from sourceURL: URL, applicationSupportDirectory: URL? = nil) throws -> URL {
    let location = try requiredStoreLocation(applicationSupportDirectory: applicationSupportDirectory)
    let fileExtension = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension
    let destinationURL = location.audioSourcesURL
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension(fileExtension)

    try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    return destinationURL
  }

  enum MoveDestination: Equatable {
    case existing
    case newlyPublishedWithoutSourceMetadata
    case newlyPublishedWithUnifiedSourceID(UUID)
  }

  struct PublicationEvidence {
    fileprivate let path: String
    fileprivate let previousLocations: [UUID: URL]
  }

  /// Resolve prior bookmarks while the candidate is absent. Once a replacement
  /// exists, bookmark resolution can fall back to that path instead of the old file.
  static func publicationEvidence(
    forCandidate url: URL, applicationSupportDirectory: URL? = nil
  ) -> PublicationEvidence {
    let path = SandboxFileAccessManager.directoryEntryPath(for: url)
    let wasAbsent = url.withUnsafeFileSystemRepresentation { filePath in
      var info = stat()
      guard let filePath else { return false }
      return lstat(filePath, &info) != 0 && errno == ENOENT
    }
    guard wasAbsent,
          let location = try? storeLocation(
            layout: .unified, createIfNeeded: false,
            applicationSupportDirectory: applicationSupportDirectory, requireExisting: false
          ),
          let index = cleanupIndex(at: location, using: JSONDecoder()) else {
      return PublicationEvidence(path: path, previousLocations: [:])
    }

    var previousLocations: [UUID: URL] = [:]
    for entry in index.entries where entry.lastKnownPath == path {
      previousLocations[entry.id] = resolveBookmarkedURL(for: entry)
    }
    return PublicationEvidence(path: path, previousLocations: previousLocations)
  }

  /// Read the source before publication, while a bookmark can still find it.
  static func publicationDestination(
    forCurrentFile videoURL: URL, applicationSupportDirectory: URL? = nil
  ) -> MoveDestination {
    guard regularFileIdentity(at: videoURL) != nil else { return .existing }
    let decoder = JSONDecoder()
    let sourcePath = normalizedPath(for: videoURL)
    for layout in [StoreLayout.unified, .legacy] {
      guard let location = try? storeLocation(
        layout: layout, createIfNeeded: false,
        applicationSupportDirectory: applicationSupportDirectory, requireExisting: false
      ),
        let index = cleanupIndex(at: location, using: decoder) else { return .existing }
      if let match = resolveEntry(for: videoURL, index: index) {
        // An exact current path survives the move lookup. A bookmark from an
        // earlier name will follow the new file and needs its stable index ID.
        if layout == .unified, index.entries[match.index].lastKnownPath != sourcePath {
          return .newlyPublishedWithUnifiedSourceID(match.entry.id)
        }
        return .existing
      }
    }

    return confirmsLegacySidecarMissing(for: videoURL) ? .newlyPublishedWithoutSourceMetadata : .existing
  }

  private static func confirmsLegacySidecarMissing(for videoURL: URL) -> Bool {
    let sidecar = legacySidecarURL(for: videoURL)
    do {
      try SandboxFileAccessManager.shared.withScopedAccess(to: sidecar.deletingLastPathComponent()) {
        _ = try FileManager.default.attributesOfItem(atPath: sidecar.path)
      }
      return false
    } catch let error as CocoaError where [.fileNoSuchFile, .fileReadNoSuchFile].contains(error.code) {
      return true
    } catch {
      return false
    }
  }

  static func moveAssociation(
    from oldURL: URL, to newURL: URL,
    destination: MoveDestination = .existing,
    publication: PublicationEvidence? = nil,
    applicationSupportDirectory: URL? = nil
  ) throws {
    let unifiedLocation = try requiredStoreLocation(applicationSupportDirectory: applicationSupportDirectory)
    var unifiedIndex = loadIndex(from: unifiedLocation)

    let sourceIndex: Int?
    if case .newlyPublishedWithUnifiedSourceID(let sourceID) = destination {
      guard let anchored = unifiedIndex.entries.firstIndex(where: { $0.id == sourceID }) else { return }
      sourceIndex = anchored
    } else {
      sourceIndex = resolveEntry(for: oldURL, index: unifiedIndex)?.index
    }
    if let sourceIndex {
      let entry = try makeEntry(id: unifiedIndex.entries[sourceIndex].id, for: newURL)
      unifiedIndex.entries[sourceIndex] = entry
      let displaced = reconcileDestination(
        in: &unifiedIndex, path: entry.lastKnownPath, retaining: entry.id,
        publication: publication, allowsLegacyLookup: destination == .existing
      )
      try saveIndex(unifiedIndex, to: unifiedLocation)

      if !displaced.isEmpty {
        deleteUnreferencedMetadataFiles(
          displaced.map { metadataURL(for: $0, location: unifiedLocation) },
          applicationSupportDirectory: applicationSupportDirectory,
          mayDeleteAudio: (destination == .existing && publication == nil) || confirmsLegacySidecarMissing(for: newURL)
        )
      }
      if case .newlyPublishedWithUnifiedSourceID = destination { return }
      if let legacyLocation = try storeLocation(layout: .legacy, createIfNeeded: false, applicationSupportDirectory: applicationSupportDirectory),
         legacyLocation.entriesURL != unifiedLocation.entriesURL {
        var legacyIndex = loadIndex(from: legacyLocation)
        try? deleteStoredMetadata(for: oldURL, location: legacyLocation, index: &legacyIndex, applicationSupportDirectory: applicationSupportDirectory)
      }
      try deleteLegacySidecarIfPresent(for: oldURL)
      try deleteLegacySidecarIfPresent(for: newURL)
      return
    }

    if let legacyLocation = try storeLocation(layout: .legacy, createIfNeeded: false, applicationSupportDirectory: applicationSupportDirectory),
       legacyLocation.entriesURL != unifiedLocation.entriesURL {
      var legacyIndex = loadIndex(from: legacyLocation)
      if let metadata = try loadStoredMetadata(for: oldURL, location: legacyLocation, index: &legacyIndex) {
        try save(metadata, for: newURL, applicationSupportDirectory: applicationSupportDirectory)
        try? deleteStoredMetadata(for: oldURL, location: legacyLocation, index: &legacyIndex, applicationSupportDirectory: applicationSupportDirectory)
        try deleteLegacySidecarIfPresent(for: oldURL)
        try deleteLegacySidecarIfPresent(for: newURL)
        return
      }
    }

    if let metadata = try loadLegacySidecarMetadata(for: oldURL) {
      try save(metadata, for: newURL, applicationSupportDirectory: applicationSupportDirectory)
      try deleteLegacySidecarIfPresent(for: oldURL)
      return
    }

    guard destination == .newlyPublishedWithoutSourceMetadata,
          var currentIndex = cleanupIndex(at: unifiedLocation, using: JSONDecoder()) else { return }
    let path = normalizedPath(for: newURL)
    guard currentIndex.entries.contains(where: { $0.lastKnownPath == path }) else { return }
    let displaced = reconcileDestination(in: &currentIndex, path: path, publication: publication)
    try saveIndex(currentIndex, to: unifiedLocation)
    if !displaced.isEmpty {
      deleteUnreferencedMetadataFiles(
        displaced.map { metadataURL(for: $0, location: unifiedLocation) },
        applicationSupportDirectory: applicationSupportDirectory,
        mayDeleteAudio: confirmsLegacySidecarMissing(for: newURL)
      )
    }
  }

  /// An exact path can be stale while its bookmark still tracks an earlier movie.
  private static func reconcileDestination(
    in index: inout MetadataIndex, path: String, retaining sourceID: UUID? = nil,
    publication: PublicationEvidence?, allowsLegacyLookup: Bool = false
  ) -> [UUID] {
    var displaced: [UUID] = []
    index.entries = index.entries.compactMap { entry in
      guard entry.id != sourceID, entry.lastKnownPath == path else { return entry }
      let bookmarkedURL: URL?
      if let publication {
        bookmarkedURL = publication.path == path ? publication.previousLocations[entry.id] : nil
      } else {
        bookmarkedURL = allowsLegacyLookup ? resolveBookmarkedURL(for: entry) : nil
      }
      if let bookmarkedURL {
        if normalizedPath(for: bookmarkedURL) == path {
          displaced.append(entry.id)
          return nil
        }
        if regularFileIdentity(at: bookmarkedURL) != nil {
          return refreshedEntry(entry, with: bookmarkedURL)
        }
      }
      // Keep the bookmark and audio reference, but release the path now used by
      // the new recording. A later lookup can recover the original by bookmark.
      var detached = entry
      detached.lastKnownPath = ""
      detached.excludedPath = path
      return detached
    }
    return displaced
  }

  static func delete(for videoURL: URL, applicationSupportDirectory: URL? = nil) throws {
    for location in try allStoreLocationsForMaintenance(applicationSupportDirectory: applicationSupportDirectory) {
      var index = loadIndex(from: location)
      try deleteStoredMetadata(for: videoURL, location: location, index: &index, applicationSupportDirectory: applicationSupportDirectory)
    }

    try deleteLegacySidecarIfPresent(for: videoURL)
  }

  static func performOrphanCleanup(
    now: Date = Date(), applicationSupportDirectory: URL? = nil
  ) throws {
    for location in try allStoreLocationsForMaintenance(applicationSupportDirectory: applicationSupportDirectory) {
      var index = loadIndex(from: location)
      var keptEntries: [MetadataIndexEntry] = []
      var metadataURLsToDelete: [URL] = []

      for entry in index.entries {
        let metadataURL = self.metadataURL(for: entry.id, location: location)

        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
          metadataURLsToDelete.append(metadataURL)
          continue
        }

        switch cleanupDisposition(for: entry, now: now) {
        case .keep(let updatedEntry):
          keptEntries.append(updatedEntry)
        case .delete:
          metadataURLsToDelete.append(metadataURL)
        }
      }

      guard keptEntries != index.entries || !metadataURLsToDelete.isEmpty else {
        continue
      }

      index.entries = keptEntries
      try saveIndex(index, to: location)

      deleteUnreferencedMetadataFiles(metadataURLsToDelete, applicationSupportDirectory: applicationSupportDirectory)
    }
  }

  private static func storeLocation(
    layout: StoreLayout,
    createIfNeeded: Bool,
    applicationSupportDirectory: URL?,
    requireExisting: Bool = true
  ) throws -> StoreLocation? {
    guard let appSupportURL = applicationSupportDirectory
      ?? OwnShotStoragePaths.applicationSupportDirectory
    else {
      return nil
    }

    let baseURL = appSupportURL
      .appendingPathComponent(appSupportFolderName, isDirectory: true)

    let rootURL = layout.pathComponents.reduce(baseURL) { partial, component in
      partial.appendingPathComponent(component, isDirectory: true)
    }
    let entriesURL = rootURL.appendingPathComponent(entriesFolderName, isDirectory: true)
    let audioSourcesURL = rootURL.appendingPathComponent(audioSourcesFolderName, isDirectory: true)
    let indexURL = rootURL.appendingPathComponent(indexFileName)

    if createIfNeeded {
      try FileManager.default.createDirectory(
        at: entriesURL,
        withIntermediateDirectories: true,
        attributes: nil
      )
      try FileManager.default.createDirectory(
        at: audioSourcesURL,
        withIntermediateDirectories: true,
        attributes: nil
      )
    } else if requireExisting && !FileManager.default.fileExists(atPath: rootURL.path) {
      return nil
    }

    return StoreLocation(
      entriesURL: entriesURL,
      indexURL: indexURL,
      audioSourcesURL: audioSourcesURL
    )
  }

  private static func requiredStoreLocation(applicationSupportDirectory: URL? = nil) throws -> StoreLocation {
    if let location = try storeLocation(layout: .unified, createIfNeeded: true, applicationSupportDirectory: applicationSupportDirectory) {
      return location
    }

    throw CocoaError(.fileNoSuchFile)
  }

  private static func allStoreLocationsForRead(applicationSupportDirectory: URL? = nil) throws -> [(layout: StoreLayout, location: StoreLocation)] {
    var result: [(layout: StoreLayout, location: StoreLocation)] = []

    if let unified = try storeLocation(layout: .unified, createIfNeeded: false, applicationSupportDirectory: applicationSupportDirectory) {
      result.append((.unified, unified))
    }

    if let legacy = try storeLocation(layout: .legacy, createIfNeeded: false, applicationSupportDirectory: applicationSupportDirectory) {
      let alreadyIncluded = result.contains { $0.location.entriesURL == legacy.entriesURL }
      if !alreadyIncluded {
        result.append((.legacy, legacy))
      }
    }

    return result
  }

  private static func allStoreLocationsForMaintenance(applicationSupportDirectory: URL? = nil) throws -> [StoreLocation] {
    var locations: [StoreLocation] = []

    if let unified = try storeLocation(layout: .unified, createIfNeeded: false, applicationSupportDirectory: applicationSupportDirectory) {
      locations.append(unified)
    }

    if let legacy = try storeLocation(layout: .legacy, createIfNeeded: false, applicationSupportDirectory: applicationSupportDirectory),
       !locations.contains(where: { $0.entriesURL == legacy.entriesURL }) {
      locations.append(legacy)
    }

    return locations
  }

  private static func loadIndex(from location: StoreLocation) -> MetadataIndex {
    guard FileManager.default.fileExists(atPath: location.indexURL.path),
          let data = try? Data(contentsOf: location.indexURL)
    else {
      return MetadataIndex()
    }

    do {
      return try JSONDecoder().decode(MetadataIndex.self, from: data)
    } catch {
      recordingMetadataLogger.error("Failed to decode metadata index at \(location.indexURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
      return MetadataIndex()
    }
  }

  private static func saveIndex(_ index: MetadataIndex, to location: StoreLocation) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(index)
    try data.write(to: location.indexURL, options: .atomic)
  }

  private static func loadStoredMetadata(
    for videoURL: URL,
    location: StoreLocation,
    index: inout MetadataIndex
  ) throws -> RecordingMetadata? {
    guard let resolved = resolveEntry(for: videoURL, index: index) else {
      return nil
    }

    let metadataURL = self.metadataURL(for: resolved.entry.id, location: location)
    guard FileManager.default.fileExists(atPath: metadataURL.path) else {
      index.entries.remove(at: resolved.index)
      try saveIndex(index, to: location)
      return nil
    }

    let data = try Data(contentsOf: metadataURL)
    let metadata = try JSONDecoder().decode(RecordingMetadata.self, from: data)

    if index.entries[resolved.index] != resolved.entry {
      index.entries[resolved.index] = resolved.entry
      try saveIndex(index, to: location)
    }

    return metadata
  }

  private static func deleteStoredMetadata(
    for videoURL: URL,
    location: StoreLocation,
    index: inout MetadataIndex,
    applicationSupportDirectory: URL?
  ) throws {
    guard let resolved = resolveEntry(for: videoURL, index: index) else {
      return
    }

    let metadataURL = self.metadataURL(for: resolved.entry.id, location: location)
    index.entries.remove(at: resolved.index)
    try saveIndex(index, to: location)

    deleteUnreferencedMetadataFiles([metadataURL], applicationSupportDirectory: applicationSupportDirectory)
  }

  private static func resolveEntry(
    for videoURL: URL,
    index: MetadataIndex
  ) -> (index: Int, entry: MetadataIndexEntry)? {
    let targetPath = normalizedPath(for: videoURL)

    if let exactIndex = index.entries.firstIndex(where: {
      $0.lastKnownPath == targetPath && $0.excludedPath != targetPath
    }) {
      return (exactIndex, refreshedEntry(index.entries[exactIndex], with: videoURL))
    }

    for (indexPosition, entry) in index.entries.enumerated() {
      guard let bookmarkedURL = resolveBookmarkedURL(for: entry) else { continue }
      guard entry.excludedPath != targetPath, normalizedPath(for: bookmarkedURL) == targetPath else { continue }
      return (indexPosition, refreshedEntry(entry, with: videoURL))
    }

    return nil
  }

  private static func upsert(entry: MetadataIndexEntry, into index: inout MetadataIndex) {
    if let existingIndex = index.entries.firstIndex(where: { $0.id == entry.id }) {
      index.entries[existingIndex] = entry
    } else {
      index.entries.append(entry)
    }
  }

  private static func makeEntry(id: UUID, for videoURL: URL) throws -> MetadataIndexEntry {
    MetadataIndexEntry(
      id: id,
      lastKnownPath: normalizedPath(for: videoURL),
      bookmarkData: try videoBookmarkData(for: videoURL),
      staleSince: nil
    )
  }

  private static func refreshedEntry(_ entry: MetadataIndexEntry, with videoURL: URL) -> MetadataIndexEntry {
    var refreshed = entry
    refreshed.lastKnownPath = normalizedPath(for: videoURL)
    refreshed.staleSince = nil
    refreshed.excludedPath = nil

    if let bookmarkData = try? videoBookmarkData(for: videoURL) {
      refreshed.bookmarkData = bookmarkData
    }

    return refreshed
  }

  private static func videoBookmarkData(for videoURL: URL) throws -> Data {
    try SandboxFileAccessManager.shared.withScopedAccess(to: videoURL) {
      try videoURL.standardizedFileURL.bookmarkData(
        options: [.minimalBookmark],
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
    }
  }

  private static func resolveBookmarkedURL(for entry: MetadataIndexEntry) -> URL? {
    var isStale = false

    do {
      return try URL(
        resolvingBookmarkData: entry.bookmarkData,
        options: [.withoutUI, .withoutMounting],
        relativeTo: nil,
        bookmarkDataIsStale: &isStale
      )
      .standardizedFileURL
      .resolvingSymlinksInPath()
    } catch {
      return nil
    }
  }

  private static func cleanupDisposition(
    for entry: MetadataIndexEntry,
    now: Date
  ) -> CleanupDisposition {
    if let bookmarkedURL = resolveBookmarkedURL(for: entry),
       normalizedPath(for: bookmarkedURL) != entry.excludedPath,
       FileManager.default.fileExists(atPath: bookmarkedURL.path)
    {
      return .keep(refreshedCleanupEntry(entry, resolvedURL: bookmarkedURL))
    }

    let lastKnownURL = URL(fileURLWithPath: entry.lastKnownPath)
    if !entry.lastKnownPath.isEmpty,
       entry.lastKnownPath != entry.excludedPath,
       FileManager.default.fileExists(atPath: lastKnownURL.path) {
      return .keep(refreshedCleanupEntry(entry, resolvedURL: lastKnownURL))
    }

    guard let staleSince = entry.staleSince else {
      var staleEntry = entry
      staleEntry.staleSince = now
      return .keep(staleEntry)
    }

    if now.timeIntervalSince(staleSince) >= orphanGracePeriod {
      return .delete
    }

    return .keep(entry)
  }

  private static func refreshedCleanupEntry(
    _ entry: MetadataIndexEntry,
    resolvedURL: URL
  ) -> MetadataIndexEntry {
    var refreshed = entry
    refreshed.lastKnownPath = normalizedPath(for: resolvedURL)
    refreshed.staleSince = nil
    refreshed.excludedPath = nil

    if let bookmarkData = try? videoBookmarkData(for: resolvedURL) {
      refreshed.bookmarkData = bookmarkData
    }

    return refreshed
  }

  private static func normalizedPath(for videoURL: URL) -> String {
    videoURL.standardizedFileURL.resolvingSymlinksInPath().path
  }

  private static func metadataURL(for id: UUID, location: StoreLocation) -> URL {
    location.entriesURL
      .appendingPathComponent(id.uuidString)
      .appendingPathExtension(metadataFileExtension)
  }

  private struct AudioReference: Decodable {
    let audioSourceURL: URL?

    private enum CodingKeys: String, CodingKey {
      case captureSize
      case samplesPerSecond
      case mouseSamples
      case audioSourceURL
    }

    init(from decoder: Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      for key in [CodingKeys.captureSize, .samplesPerSecond, .mouseSamples] where !values.contains(key) {
        throw DecodingError.keyNotFound(key, .init(
          codingPath: values.codingPath, debugDescription: "Incomplete recording metadata"
        ))
      }
      audioSourceURL = try values.decodeIfPresent(URL.self, forKey: .audioSourceURL)
    }
  }

  /// Removes retired metadata after its index commit. A copied recording may
  /// share its editor audio with another entry, including one in the other layout.
  private static func deleteUnreferencedMetadataFiles(
    _ metadataURLs: [URL],
    applicationSupportDirectory: URL?,
    mayDeleteAudio: Bool = true
  ) {
    let decoder = JSONDecoder()
    var audioURLs: [URL] = []
    for metadataURL in metadataURLs {
      if mayDeleteAudio,
         let audioURL = readAudioReference(at: metadataURL, using: decoder)?.audioSourceURL {
        audioURLs.append(audioURL)
      }
      try? FileManager.default.removeItem(at: metadataURL)
    }
    guard !audioURLs.isEmpty else { return }

    guard let locations = try? [StoreLayout.unified, .legacy].compactMap({ layout in
      try storeLocation(
        layout: layout,
        createIfNeeded: false,
        applicationSupportDirectory: applicationSupportDirectory,
        requireExisting: false
      )
    }) else { return }
    let ownedRoots = Set(locations.map { normalizedPath(for: $0.audioSourcesURL) })
    var candidates: [String: (url: URL, device: dev_t, inode: ino_t)] = [:]
    for audioURL in audioURLs where audioURL.isFileURL {
      let parent = audioURL.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
      guard ownedRoots.contains(parent.path) else { continue }
      // Resolve the parent for ownership, but never follow a leaf symlink.
      let leaf = parent.appendingPathComponent(audioURL.lastPathComponent)
      guard let identity = regularFileIdentity(at: leaf) else { continue }
      candidates[normalizedPath(for: leaf)] = (leaf, identity.device, identity.inode)
    }
    guard !candidates.isEmpty else { return }

    for location in locations {
      guard let index = cleanupIndex(at: location, using: decoder) else { return }
      for entry in index.entries {
        let url = metadataURL(for: entry.id, location: location)
        guard let reference = readAudioReference(at: url, using: decoder) else { return }
        if let audioURL = reference.audioSourceURL {
          candidates.removeValue(forKey: normalizedPath(for: audioURL))
          if candidates.isEmpty { return }
        }
      }
    }

    for candidate in candidates.values {
      guard let current = regularFileIdentity(at: candidate.url),
            current.device == candidate.device,
            current.inode == candidate.inode else { continue }
      // unlink is deliberately nonrecursive and acts on the original leaf.
      candidate.url.withUnsafeFileSystemRepresentation { path in
        if let path { _ = unlink(path) }
      }
    }
  }

  private static func cleanupIndex(at location: StoreLocation, using decoder: JSONDecoder) -> MetadataIndex? {
    let missingFileErrors: [CocoaError.Code] = [.fileNoSuchFile, .fileReadNoSuchFile]
    do {
      let data = try Data(contentsOf: location.indexURL)
      return try decoder.decode(MetadataIndex.self, from: data)
    } catch let error as CocoaError where missingFileErrors.contains(error.code) {
      do {
        let entries = try FileManager.default.contentsOfDirectory(atPath: location.entriesURL.path)
        return entries.isEmpty ? MetadataIndex() : nil
      } catch let error as CocoaError where missingFileErrors.contains(error.code) {
        return MetadataIndex()
      } catch {
        return nil
      }
    } catch {
      return nil
    }
  }

  private static func readAudioReference(at url: URL, using decoder: JSONDecoder) -> AudioReference? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? decoder.decode(AudioReference.self, from: data)
  }

  private static func regularFileIdentity(at url: URL) -> (device: dev_t, inode: ino_t)? {
    url.withUnsafeFileSystemRepresentation { path in
      var info = stat()
      guard let path, lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
      return (info.st_dev, info.st_ino)
    }
  }

  private static func migrateLegacySidecarIfNeeded(
    for videoURL: URL,
    location: StoreLocation,
    index: inout MetadataIndex
  ) throws -> RecordingMetadata? {
    guard let metadata = try loadLegacySidecarMetadata(for: videoURL) else {
      return nil
    }

    let entry = try makeEntry(id: UUID(), for: videoURL)
    let metadataURL = self.metadataURL(for: entry.id, location: location)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(metadata)

    try data.write(to: metadataURL, options: .atomic)
    upsert(entry: entry, into: &index)
    try saveIndex(index, to: location)
    try deleteLegacySidecarIfPresent(for: videoURL)

    return metadata
  }

  private static func loadLegacySidecarMetadata(for videoURL: URL) throws -> RecordingMetadata? {
    let sidecarURL = legacySidecarURL(for: videoURL)

    return try SandboxFileAccessManager.shared.withScopedAccess(to: sidecarURL.deletingLastPathComponent()) {
      guard FileManager.default.fileExists(atPath: sidecarURL.path) else {
        return nil
      }

      let data = try Data(contentsOf: sidecarURL)
      return try JSONDecoder().decode(RecordingMetadata.self, from: data)
    }
  }

  private static func deleteLegacySidecarIfPresent(for videoURL: URL) throws {
    let sidecarURL = legacySidecarURL(for: videoURL)

    try SandboxFileAccessManager.shared.withScopedAccess(to: sidecarURL.deletingLastPathComponent()) {
      guard FileManager.default.fileExists(atPath: sidecarURL.path) else { return }
      try FileManager.default.removeItem(at: sidecarURL)
    }
  }

  private static func legacySidecarURL(for videoURL: URL) -> URL {
    videoURL
      .deletingPathExtension()
      .appendingPathExtension(legacySidecarExtension)
  }
}

private extension RecordingMetadata {
  func canonicalizedForCurrentVersion() -> RecordingMetadata {
    let normalizedSamples: [RecordedMouseSample]
    switch coordinateSpace {
    case .topLeftNormalized:
      normalizedSamples = mouseSamples
    case .bottomLeftNormalized:
      normalizedSamples = mouseSamples.map { sample in
        var normalized = sample
        normalized.normalizedY = (1 - sample.normalizedY).clamped(to: 0...1)
        return normalized
      }
    }

    return RecordingMetadata(
      version: RecordingMetadata.currentVersion,
      coordinateSpace: .topLeftNormalized,
      captureSize: captureSize,
      samplesPerSecond: samplesPerSecond,
      mouseSamples: normalizedSamples,
      audioSourceURL: audioSourceURL,
      audioSourceTrackRoles: audioSourceTrackRoles,
      audioSourceTracks: audioSourceTracks
    )
  }
}

private extension CGFloat {
  func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
    Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
  }
}
