//
//  RecordingMetadataStoreTests.swift
//  SnapzyTests
//
//  Tests for recording Smart Camera metadata persistence and migration.
//

import AVFoundation
import CoreGraphics
import XCTest
@testable import Snapzy

@MainActor
final class RecordingMetadataStoreTests: XCTestCase {

  private struct LegacyMetadataV1: Codable {
    var version: Int
    var captureSize: CGSize
    var samplesPerSecond: Int
    var mouseSamples: [RecordedMouseSample]
  }

  private struct LegacyMetadataV3: Codable {
    var version: Int
    var coordinateSpace: RecordingCoordinateSpace
    var captureSize: CGSize
    var samplesPerSecond: Int
    var mouseSamples: [RecordedMouseSample]
    var audioSourceURL: URL?
  }

  private var tempDirectory: URL!
  private var videoURLs: [URL] = []

  override func setUp() async throws {
    try await super.setUp()
    tempDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("SnapzyTests_RecordingMetadata_\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
  }

  override func tearDown() async throws {
    for url in videoURLs {
      try? RecordingMetadataStore.delete(for: url)
    }
    videoURLs.removeAll()
    if let tempDirectory {
      try? FileManager.default.removeItem(at: tempDirectory)
    }
    try await super.tearDown()
  }

  func testRecordingMetadata_currentVersionRoundTripsThroughCodable() throws {
    let metadata = makeCurrentMetadata()
    let data = try JSONEncoder().encode(metadata)
    let decoded = try JSONDecoder().decode(RecordingMetadata.self, from: data)

    XCTAssertEqual(decoded, metadata)
    XCTAssertEqual(decoded.version, RecordingMetadata.currentVersion)
    XCTAssertEqual(decoded.coordinateSpace, .topLeftNormalized)
  }

  func testRecordingMetadata_v1WithoutCoordinateSpaceDecodesAsBottomLeft() throws {
    let legacy = LegacyMetadataV1(
      version: 1,
      captureSize: CGSize(width: 320, height: 200),
      samplesPerSecond: 60,
      mouseSamples: [
        RecordedMouseSample(time: 0.1, normalizedX: 0.2, normalizedY: 0.25, isInsideCapture: true)
      ]
    )
    let data = try JSONEncoder().encode(legacy)
    let decoded = try JSONDecoder().decode(RecordingMetadata.self, from: data)

    XCTAssertEqual(decoded.version, 1)
    XCTAssertEqual(decoded.coordinateSpace, .bottomLeftNormalized)
    XCTAssertEqual(decoded.mouseSamples.first?.normalizedY, 0.25)
  }

  func testRecordingMetadata_v3WithoutAudioTrackRolesDecodesEmptyRoles() throws {
    let sourceURL = tempDirectory.appendingPathComponent("legacy-audio-source.mov")
    let legacy = LegacyMetadataV3(
      version: 3,
      coordinateSpace: .topLeftNormalized,
      captureSize: CGSize(width: 640, height: 360),
      samplesPerSecond: 60,
      mouseSamples: [],
      audioSourceURL: sourceURL
    )
    let data = try JSONEncoder().encode(legacy)
    let decoded = try JSONDecoder().decode(RecordingMetadata.self, from: data)

    XCTAssertEqual(decoded.version, 3)
    XCTAssertEqual(decoded.audioSourceURL, sourceURL)
    XCTAssertTrue(decoded.audioSourceTrackRoles.isEmpty)
    XCTAssertTrue(decoded.audioSourceTracks.isEmpty)
  }

  func testRecordingAudioSourceTrackRolesFollowWriterOrder() {
    XCTAssertEqual(
      RecordingAudioSourceTrackRole.roles(capturesSystemAudio: true, capturesMicrophone: true),
      [.systemAudio, .microphone]
    )
    XCTAssertEqual(
      RecordingAudioSourceTrackRole.roles(capturesSystemAudio: true, capturesMicrophone: false),
      [.systemAudio]
    )
    XCTAssertEqual(
      RecordingAudioSourceTrackRole.roles(capturesSystemAudio: false, capturesMicrophone: true),
      [.microphone]
    )
  }

  func testRecordingMetadataStore_saveLoadRoundTripsCurrentMetadata() throws {
    let videoURL = try makeVideoFile(named: "roundtrip.mov")
    let metadata = makeCurrentMetadata()

    try RecordingMetadataStore.save(metadata, for: videoURL)
    let loaded = try XCTUnwrap(RecordingMetadataStore.load(for: videoURL))

    XCTAssertEqual(loaded, metadata)
  }

  func testRecordingMetadataStore_loadsLegacySidecarAndMigratesToTopLeft() throws {
    let videoURL = try makeVideoFile(named: "legacy.mov")
    let sidecarURL = legacySidecarURL(for: videoURL)
    let legacy = LegacyMetadataV1(
      version: 1,
      captureSize: CGSize(width: 640, height: 360),
      samplesPerSecond: 30,
      mouseSamples: [
        RecordedMouseSample(time: 0.0, normalizedX: 0.3, normalizedY: 0.25, isInsideCapture: true),
        RecordedMouseSample(time: 0.5, normalizedX: 0.6, normalizedY: 1.2, isInsideCapture: false),
      ]
    )
    try JSONEncoder().encode(legacy).write(to: sidecarURL, options: .atomic)

    let loaded = try XCTUnwrap(RecordingMetadataStore.load(for: videoURL))

    XCTAssertEqual(loaded.version, RecordingMetadata.currentVersion)
    XCTAssertEqual(loaded.coordinateSpace, .topLeftNormalized)
    XCTAssertEqual(loaded.captureSize, legacy.captureSize)
    XCTAssertEqual(loaded.samplesPerSecond, legacy.samplesPerSecond)
    XCTAssertEqual(loaded.mouseSamples[0].normalizedY, 0.75, accuracy: 0.0001)
    XCTAssertEqual(loaded.mouseSamples[1].normalizedY, 0.0, accuracy: 0.0001)
    XCTAssertFalse(FileManager.default.fileExists(atPath: sidecarURL.path))

    let loadedAfterMigration = try XCTUnwrap(RecordingMetadataStore.load(for: videoURL))
    XCTAssertEqual(loadedAfterMigration, loaded)
  }

  func testRecordingMetadataStore_moveAssociationPreservesMetadataForRenamedVideo() throws {
    let oldURL = try makeVideoFile(named: "before.mov")
    let newURL = try makeVideoFile(named: "after.mov")
    let metadata = makeCurrentMetadata()

    try RecordingMetadataStore.save(metadata, for: oldURL)
    try RecordingMetadataStore.moveAssociation(from: oldURL, to: newURL)

    XCTAssertNil(RecordingMetadataStore.load(for: oldURL))
    XCTAssertEqual(RecordingMetadataStore.load(for: newURL), metadata)
  }

  func testMoveAssociationReplacesStaleDestinationAfterRename() throws {
    try assertMoveAssociationReplacesStaleDestination(copyThenUnlink: false, viaParentAlias: false, sharedAudio: false)
  }

  func testMoveAssociationReplacesStaleDestinationThroughLinkedParent() throws {
    try assertMoveAssociationReplacesStaleDestination(copyThenUnlink: false, viaParentAlias: true, sharedAudio: true)
  }

  func testMoveAssociationReplacesStaleDestinationAfterCopyThenUnlink() throws {
    try assertMoveAssociationReplacesStaleDestination(copyThenUnlink: true, viaParentAlias: false, sharedAudio: true)
  }

  private func assertMoveAssociationReplacesStaleDestination(
    copyThenUnlink: Bool, viaParentAlias: Bool, sharedAudio: Bool
  ) throws {
    let fileManager = FileManager.default
    let store = tempDirectory.appendingPathComponent("IsolatedStore", isDirectory: true)
    let directory = tempDirectory.appendingPathComponent("Exports", isDirectory: true)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
    let selectedDirectory: URL
    if viaParentAlias {
      selectedDirectory = tempDirectory.appendingPathComponent("Alias", isDirectory: true)
      try fileManager.createSymbolicLink(at: selectedDirectory, withDestinationURL: directory)
    } else {
      selectedDirectory = directory
    }
    let canonicalDestination = directory.appendingPathComponent("capture_2.mov")
    let destination = selectedDirectory.appendingPathComponent("capture_2.mov")
    let source = tempDirectory.appendingPathComponent("temp.mov")
    let masterAudio = tempDirectory.appendingPathComponent("audio.mov")
    let mediaBytes = Data("Current video".utf8)
    let audioBytes = Data("Current editor audio".utf8)
    try audioBytes.write(to: masterAudio)
    let audio = try RecordingMetadataStore.storeAudioSource(from: masterAudio, applicationSupportDirectory: store)
    let staleAudio = sharedAudio ? audio : try RecordingMetadataStore.storeAudioSource(
      from: masterAudio, applicationSupportDirectory: store
    )
    var stale = makeCurrentMetadata()
    stale.captureSize = CGSize(width: 320, height: 180)
    stale.audioSourceURL = staleAudio
    var current = makeCurrentMetadata()
    current.captureSize = CGSize(width: 1440, height: 900)
    current.audioSourceURL = audio

    try Data("Former video".utf8).write(to: canonicalDestination)
    try RecordingMetadataStore.save(stale, for: canonicalDestination, applicationSupportDirectory: store)
    try fileManager.removeItem(at: canonicalDestination)
    try mediaBytes.write(to: source)
    try RecordingMetadataStore.save(current, for: source, applicationSupportDirectory: store)
    if copyThenUnlink {
      try fileManager.copyItem(at: source, to: destination)
      try fileManager.removeItem(at: source)
    } else {
      try fileManager.moveItem(at: source, to: destination)
    }

    try RecordingMetadataStore.moveAssociation(from: source, to: destination, applicationSupportDirectory: store)

    XCTAssertEqual(RecordingMetadataStore.load(for: canonicalDestination, applicationSupportDirectory: store), current)
    XCTAssertNil(RecordingMetadataStore.load(for: source, applicationSupportDirectory: store))
    XCTAssertEqual(try Data(contentsOf: canonicalDestination), mediaBytes)
    XCTAssertEqual(try Data(contentsOf: audio), audioBytes)
    if !sharedAudio {
      XCTAssertFalse(fileManager.fileExists(atPath: staleAudio.path))
    }
    try RecordingMetadataStore.delete(for: destination, applicationSupportDirectory: store)
    XCTAssertNil(RecordingMetadataStore.load(for: canonicalDestination, applicationSupportDirectory: store))
    XCTAssertFalse(fileManager.fileExists(atPath: audio.path))
  }

  func testDeletingRecordingKeepsAudioStillReferencedByItsSavedCopy() throws {
    try assertSavedCopyKeepsSharedAudio(useOrphanCleanup: false)
  }

  func testOrphanCleanupKeepsAudioStillReferencedBySavedRecording() throws {
    try assertSavedCopyKeepsSharedAudio(useOrphanCleanup: true)
  }

  private func assertSavedCopyKeepsSharedAudio(useOrphanCleanup: Bool) throws {
    let fileManager = FileManager.default
    let store = tempDirectory.appendingPathComponent("IsolatedStore", isDirectory: true)
    let source = tempDirectory.appendingPathComponent("source.mov")
    let destination = tempDirectory.appendingPathComponent("saved-copy.mov")
    let audioMaster = tempDirectory.appendingPathComponent("master.mov")
    let audioBytes = Data("Editor audio".utf8)
    try Data("Recording".utf8).write(to: source)
    try audioBytes.write(to: audioMaster)
    let audio = try RecordingMetadataStore.storeAudioSource(from: audioMaster, applicationSupportDirectory: store)
    var metadata = makeCurrentMetadata()
    metadata.audioSourceURL = audio
    try RecordingMetadataStore.save(metadata, for: source, applicationSupportDirectory: store)
    try fileManager.copyItem(at: source, to: destination)
    let copiedMetadata = try XCTUnwrap(RecordingMetadataStore.load(for: source, applicationSupportDirectory: store))
    try RecordingMetadataStore.save(copiedMetadata, for: destination, applicationSupportDirectory: store)
    try fileManager.removeItem(at: source)

    if useOrphanCleanup {
      let now = Date(timeIntervalSinceReferenceDate: 100_000)
      try RecordingMetadataStore.performOrphanCleanup(now: now, applicationSupportDirectory: store)
      XCTAssertEqual(try? Data(contentsOf: audio), audioBytes)
      try RecordingMetadataStore.performOrphanCleanup(now: now.addingTimeInterval(25 * 3600), applicationSupportDirectory: store)
    } else {
      try RecordingMetadataStore.delete(for: source, applicationSupportDirectory: store)
    }

    XCTAssertNil(RecordingMetadataStore.load(for: source, applicationSupportDirectory: store))
    XCTAssertEqual(RecordingMetadataStore.load(for: destination, applicationSupportDirectory: store), metadata)
    XCTAssertEqual(try? Data(contentsOf: audio), audioBytes)

    try RecordingMetadataStore.delete(for: destination, applicationSupportDirectory: store)
    XCTAssertNil(RecordingMetadataStore.load(for: destination, applicationSupportDirectory: store))
    XCTAssertFalse(fileManager.fileExists(atPath: audio.path))
  }

  func testDeleteKeepsAudioWhenAnotherIndexIsMissingButEntriesRemain() throws {
    let store = tempDirectory.appendingPathComponent("IsolatedStore", isDirectory: true)
    let legacyEntries = store.appendingPathComponent("OwnShot/RecordingMetadata/Entries", isDirectory: true)
    let video = tempDirectory.appendingPathComponent("source.mov")
    let master = tempDirectory.appendingPathComponent("master.mov")
    let audioBytes = Data("Editor audio".utf8)
    try Data("Recording".utf8).write(to: video)
    try audioBytes.write(to: master)
    let audio = try RecordingMetadataStore.storeAudioSource(from: master, applicationSupportDirectory: store)
    var metadata = makeCurrentMetadata()
    metadata.audioSourceURL = audio
    try RecordingMetadataStore.save(metadata, for: video, applicationSupportDirectory: store)
    try FileManager.default.createDirectory(at: legacyEntries, withIntermediateDirectories: true)
    try JSONEncoder().encode(metadata).write(to: legacyEntries.appendingPathComponent("survivor.metadata"))

    try RecordingMetadataStore.delete(for: video, applicationSupportDirectory: store)

    XCTAssertNil(RecordingMetadataStore.load(for: video, applicationSupportDirectory: store))
    XCTAssertEqual(try? Data(contentsOf: audio), audioBytes)
  }

  func testDeleteDoesNotFollowAudioSymlink() throws {
    let store = tempDirectory.appendingPathComponent("IsolatedStore", isDirectory: true)
    let video = tempDirectory.appendingPathComponent("source.mov")
    let master = tempDirectory.appendingPathComponent("master.mov")
    let audioBytes = Data("Editor audio".utf8)
    try Data("Recording".utf8).write(to: video)
    try audioBytes.write(to: master)
    let audio = try RecordingMetadataStore.storeAudioSource(from: master, applicationSupportDirectory: store)
    let alias = audio.deletingLastPathComponent().appendingPathComponent("linked.mov")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: audio)
    var metadata = makeCurrentMetadata()
    metadata.audioSourceURL = alias
    try RecordingMetadataStore.save(metadata, for: video, applicationSupportDirectory: store)

    try RecordingMetadataStore.delete(for: video, applicationSupportDirectory: store)

    XCTAssertNil(RecordingMetadataStore.load(for: video, applicationSupportDirectory: store))
    XCTAssertEqual(try? Data(contentsOf: audio), audioBytes)
    XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: alias.path), audio.path)
  }

  func testDeleteDoesNotRemoveAudioDirectory() throws {
    let store = tempDirectory.appendingPathComponent("IsolatedStore", isDirectory: true)
    let directory = store.appendingPathComponent("OwnShot/Captures/RecordingMetadata/AudioSources/Unexpected", isDirectory: true)
    let sentinel = directory.appendingPathComponent("keep.mov")
    let video = tempDirectory.appendingPathComponent("source.mov")
    let bytes = Data("Keep directory contents".utf8)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try bytes.write(to: sentinel)
    try Data("Recording".utf8).write(to: video)
    var metadata = makeCurrentMetadata()
    metadata.audioSourceURL = directory
    try RecordingMetadataStore.save(metadata, for: video, applicationSupportDirectory: store)

    try RecordingMetadataStore.delete(for: video, applicationSupportDirectory: store)

    XCTAssertNil(RecordingMetadataStore.load(for: video, applicationSupportDirectory: store))
    XCTAssertEqual(try? Data(contentsOf: sentinel), bytes)
  }

  func testNewPublicationWithoutMetadataDoesNotInheritStaleAudio() throws {
    let fixture = try makeStalePublicationFixture()
    let metadataDestination = RecordingMetadataStore.publicationDestination(
      forCurrentFile: fixture.source, applicationSupportDirectory: fixture.store
    )
    XCTAssertEqual(metadataDestination, .newlyPublishedWithoutSourceMetadata)
    let publication = RecordingMetadataStore.publicationEvidence(forCandidate: fixture.target, applicationSupportDirectory: fixture.store)
    try FileManager.default.moveItem(at: fixture.source, to: fixture.target)

    try RecordingMetadataStore.moveAssociation(
      from: fixture.source, to: fixture.target,
      destination: metadataDestination, publication: publication,
      applicationSupportDirectory: fixture.store
    )

    XCTAssertNil(RecordingMetadataStore.load(for: fixture.target, applicationSupportDirectory: fixture.store))
    XCTAssertEqual(try Data(contentsOf: fixture.target), Data("New video".utf8))
  }

  func testMoveAssociationReplayDoesNotClearDestinationMetadata() throws {
    let fixture = try makeStalePublicationFixture()
    let metadata = makeCurrentMetadata()
    try RecordingMetadataStore.save(metadata, for: fixture.source, applicationSupportDirectory: fixture.store)
    XCTAssertEqual(RecordingMetadataStore.publicationDestination(
      forCurrentFile: fixture.source, applicationSupportDirectory: fixture.store
    ), .existing)
    try FileManager.default.moveItem(at: fixture.source, to: fixture.target)

    for _ in 0..<2 {
      try RecordingMetadataStore.moveAssociation(
        from: fixture.source, to: fixture.target, applicationSupportDirectory: fixture.store
      )
    }

    XCTAssertEqual(RecordingMetadataStore.load(for: fixture.target, applicationSupportDirectory: fixture.store), metadata)
  }

  func testNewPublicationRequiresReadableIndexesBeforeProvingSourceAbsence() throws {
    for missingIndex in [true, false] {
      let fixture = try makeStalePublicationFixture()
      let legacy = fixture.store.appendingPathComponent("OwnShot/RecordingMetadata", isDirectory: true)
      let entries = legacy.appendingPathComponent("Entries", isDirectory: true)
      try FileManager.default.createDirectory(at: entries, withIntermediateDirectories: true)
      try JSONEncoder().encode(makeCurrentMetadata()).write(to: entries.appendingPathComponent("prior.json"))
      if !missingIndex {
        try Data("Unreadable index".utf8).write(to: legacy.appendingPathComponent("index.json"))
      }
      let metadataDestination = RecordingMetadataStore.publicationDestination(
        forCurrentFile: fixture.source, applicationSupportDirectory: fixture.store
      )
      XCTAssertEqual(metadataDestination, .existing)
      let publication = RecordingMetadataStore.publicationEvidence(forCandidate: fixture.target, applicationSupportDirectory: fixture.store)
      try FileManager.default.moveItem(at: fixture.source, to: fixture.target)

      try RecordingMetadataStore.moveAssociation(
        from: fixture.source, to: fixture.target,
        destination: metadataDestination, publication: publication,
        applicationSupportDirectory: fixture.store
      )

      XCTAssertNotNil(RecordingMetadataStore.load(for: fixture.target, applicationSupportDirectory: fixture.store))
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.audio.path))
    }
  }

  func testNewPublicationDoesNotRemoveUnownedLegacySidecar() throws {
    let fixture = try makeStalePublicationFixture()
    let sidecar = fixture.target.deletingPathExtension().appendingPathExtension("ownshot-recording.json")
    var legacy = makeCurrentMetadata()
    legacy.audioSourceURL = fixture.audio
    let sidecarBytes = try JSONEncoder().encode(legacy)
    try sidecarBytes.write(to: sidecar)
    let metadataDestination = RecordingMetadataStore.publicationDestination(
      forCurrentFile: fixture.source, applicationSupportDirectory: fixture.store
    )
    XCTAssertEqual(metadataDestination, .newlyPublishedWithoutSourceMetadata)
    let publication = RecordingMetadataStore.publicationEvidence(forCandidate: fixture.target, applicationSupportDirectory: fixture.store)
    try FileManager.default.moveItem(at: fixture.source, to: fixture.target)

    try RecordingMetadataStore.moveAssociation(
      from: fixture.source, to: fixture.target,
      destination: metadataDestination, publication: publication,
      applicationSupportDirectory: fixture.store
    )

    XCTAssertEqual(try Data(contentsOf: sidecar), sidecarBytes)
    XCTAssertEqual(try Data(contentsOf: fixture.audio), Data("Former audio".utf8))
  }

  func testNewPublicationRekeysSourceIdentifiedByEarlierBookmark() throws {
    let fixture = try makeStalePublicationFixture()
    var metadata = makeCurrentMetadata()
    metadata.captureSize = CGSize(width: 600, height: 400)
    try RecordingMetadataStore.save(metadata, for: fixture.source, applicationSupportDirectory: fixture.store)
    let renamed = fixture.source.deletingLastPathComponent().appendingPathComponent("renamed-before-saving.mov")
    try FileManager.default.moveItem(at: fixture.source, to: renamed)

    let metadataDestination = RecordingMetadataStore.publicationDestination(
      forCurrentFile: renamed, applicationSupportDirectory: fixture.store
    )
    guard case .newlyPublishedWithUnifiedSourceID = metadataDestination else {
      XCTFail("Expected the earlier bookmark to resolve to the live source")
      return
    }
    let publication = RecordingMetadataStore.publicationEvidence(forCandidate: fixture.target, applicationSupportDirectory: fixture.store)
    try FileManager.default.moveItem(at: renamed, to: fixture.target)
    try RecordingMetadataStore.moveAssociation(
      from: renamed, to: fixture.target, destination: metadataDestination, publication: publication,
      applicationSupportDirectory: fixture.store
    )

    XCTAssertEqual(RecordingMetadataStore.load(for: fixture.target, applicationSupportDirectory: fixture.store), metadata)
  }

  func testNewPublicationKeepsArchivedRecordingMetadataAndAudio() throws {
    try assertPublicationKeepsArchivedRecording(throughLinkedParent: false)
  }

  func testNewPublicationKeepsArchivedRecordingThroughLinkedParent() throws {
    try assertPublicationKeepsArchivedRecording(throughLinkedParent: true)
  }

  private func assertPublicationKeepsArchivedRecording(throughLinkedParent: Bool) throws {
    for hasSourceMetadata in [false, true] {
      let fixture = try makeStalePublicationFixture(archivePrevious: true)
      let exportDirectory = fixture.target.deletingLastPathComponent()
      let archive = exportDirectory.appendingPathComponent("archive.mov")
      var target = fixture.target
      if throughLinkedParent {
        let alias = tempDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: exportDirectory)
        target = alias.appendingPathComponent(target.lastPathComponent)
      }
      var expectedSource: RecordingMetadata?
      var source = fixture.source
      if hasSourceMetadata {
        var metadata = makeCurrentMetadata()
        metadata.captureSize = CGSize(width: 600, height: 400)
        try RecordingMetadataStore.save(metadata, for: source, applicationSupportDirectory: fixture.store)
        source = source.deletingLastPathComponent().appendingPathComponent("renamed-before-saving.mov")
        try FileManager.default.moveItem(at: fixture.source, to: source)
        expectedSource = metadata
      }
      let metadataDestination = RecordingMetadataStore.publicationDestination(
        forCurrentFile: source, applicationSupportDirectory: fixture.store
      )
      let publication = RecordingMetadataStore.publicationEvidence(forCandidate: target, applicationSupportDirectory: fixture.store)
      try FileManager.default.moveItem(at: source, to: target)
      try RecordingMetadataStore.moveAssociation(
        from: source, to: target, destination: metadataDestination, publication: publication,
        applicationSupportDirectory: fixture.store
      )

      XCTAssertEqual(RecordingMetadataStore.load(for: target, applicationSupportDirectory: fixture.store), expectedSource)
      XCTAssertEqual(RecordingMetadataStore.load(for: archive, applicationSupportDirectory: fixture.store)?.audioSourceURL, fixture.audio)
      XCTAssertEqual(try Data(contentsOf: fixture.audio), Data("Former audio".utf8))
      XCTAssertEqual(try Data(contentsOf: archive), Data("Former video".utf8))
    }
  }

  func testNewPublicationDetachesUnresolvedBookmarkButKeepsItsAudio() throws {
    let fixture = try makeStalePublicationFixture()
    let indexURL = fixture.store.appendingPathComponent("OwnShot/Captures/RecordingMetadata/index.json")
    let rawIndex = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as? [String: Any])
    var entries = try XCTUnwrap(rawIndex["entries"] as? [[String: Any]])
    XCTAssertEqual(entries.count, 1)
    entries[0]["bookmarkData"] = Data([0xFF]).base64EncodedString()
    try JSONSerialization.data(withJSONObject: ["entries": entries]).write(to: indexURL, options: .atomic)

    let destination = RecordingMetadataStore.publicationDestination(
      forCurrentFile: fixture.source, applicationSupportDirectory: fixture.store
    )
    let publication = RecordingMetadataStore.publicationEvidence(forCandidate: fixture.target, applicationSupportDirectory: fixture.store)
    try FileManager.default.moveItem(at: fixture.source, to: fixture.target)
    try RecordingMetadataStore.moveAssociation(
      from: fixture.source, to: fixture.target, destination: destination, publication: publication,
      applicationSupportDirectory: fixture.store
    )
    try RecordingMetadataStore.performOrphanCleanup(
      now: Date(timeIntervalSinceReferenceDate: 100_000), applicationSupportDirectory: fixture.store
    )

    XCTAssertNil(RecordingMetadataStore.load(for: fixture.target, applicationSupportDirectory: fixture.store))
    XCTAssertEqual(try Data(contentsOf: fixture.audio), Data("Former audio".utf8))
    let remaining = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as? [String: Any])
    let detached = try XCTUnwrap((remaining["entries"] as? [[String: Any]])?.first)
    XCTAssertEqual(detached["lastKnownPath"] as? String, "")
    let normalized = fixture.target.standardizedFileURL.resolvingSymlinksInPath().path
    XCTAssertEqual(detached["excludedPath"] as? String, normalized)
  }

  private func makeStalePublicationFixture(archivePrevious: Bool = false) throws -> (store: URL, source: URL, target: URL, audio: URL) {
    let directory = tempDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let store = directory.appendingPathComponent("IsolatedStore", isDirectory: true)
    let source = directory.appendingPathComponent("source.mov")
    let target = directory.appendingPathComponent("capture_2.mov")
    let master = directory.appendingPathComponent("original-audio.mov")
    try Data("Former video".utf8).write(to: target)
    try Data("Former audio".utf8).write(to: master)
    let audio = try RecordingMetadataStore.storeAudioSource(from: master, applicationSupportDirectory: store)
    var stale = makeCurrentMetadata()
    stale.audioSourceURL = audio
    try RecordingMetadataStore.save(stale, for: target, applicationSupportDirectory: store)
    if archivePrevious {
      try FileManager.default.moveItem(at: target, to: directory.appendingPathComponent("archive.mov"))
    } else {
      try FileManager.default.removeItem(at: target)
    }
    try Data("New video".utf8).write(to: source)
    return (store, source, target, audio)
  }

  func testRecordingMetadataStore_deleteRemovesMetadata() throws {
    let videoURL = try makeVideoFile(named: "delete.mov")
    let metadata = makeCurrentMetadata()

    try RecordingMetadataStore.save(metadata, for: videoURL)
    XCTAssertNotNil(RecordingMetadataStore.load(for: videoURL))

    try RecordingMetadataStore.delete(for: videoURL)
    XCTAssertNil(RecordingMetadataStore.load(for: videoURL))
  }

  func testRecordingMetadataStore_storeAudioSourceAndDeleteRemovesSidecar() throws {
    let videoURL = try makeVideoFile(named: "audio-source.mov")
    let sourceURL = tempDirectory.appendingPathComponent("multitrack-source.mov")
    try Data("multitrack".utf8).write(to: sourceURL)

    let storedSourceURL = try RecordingMetadataStore.storeAudioSource(from: sourceURL)
    var metadata = makeCurrentMetadata()
    metadata.audioSourceURL = storedSourceURL
    metadata.audioSourceTrackRoles = [.systemAudio, .microphone]
    metadata.audioSourceTracks = [
      RecordingAudioSourceTrack(trackID: 2, role: .systemAudio),
      RecordingAudioSourceTrack(trackID: 3, role: .microphone),
    ]

    try RecordingMetadataStore.save(metadata, for: videoURL)
    let loaded = try XCTUnwrap(RecordingMetadataStore.load(for: videoURL))
    XCTAssertEqual(loaded.audioSourceURL, storedSourceURL)
    XCTAssertEqual(loaded.audioSourceTrackRoles, [.systemAudio, .microphone])
    XCTAssertEqual(loaded.audioSourceTracks, metadata.audioSourceTracks)
    XCTAssertTrue(FileManager.default.fileExists(atPath: storedSourceURL.path))

    try RecordingMetadataStore.delete(for: videoURL)
    XCTAssertNil(RecordingMetadataStore.load(for: videoURL))
    XCTAssertFalse(FileManager.default.fileExists(atPath: storedSourceURL.path))
  }

  func testVideoEditorStateResolvesStoredAudioSourceAssetWhenAvailable() throws {
    let videoURL = try makeVideoFile(named: "editor-compatible-output.mov")
    let sourceURL = tempDirectory.appendingPathComponent("editor-multitrack-source.mov")
    try Data("multitrack".utf8).write(to: sourceURL)
    let storedSourceURL = try RecordingMetadataStore.storeAudioSource(from: sourceURL)

    var metadata = makeCurrentMetadata()
    metadata.audioSourceURL = storedSourceURL
    metadata.audioSourceTrackRoles = [.systemAudio, .microphone]
    try RecordingMetadataStore.save(metadata, for: videoURL)

    let loaded = try XCTUnwrap(RecordingMetadataStore.load(for: videoURL))
    XCTAssertEqual(VideoEditorState.editorAssetURL(for: videoURL, metadata: loaded), storedSourceURL)
    XCTAssertEqual(
      VideoEditorState.audioTrackRoles(forAudioTrackCount: 2, metadata: loaded),
      [.systemAudio, .microphone]
    )
    XCTAssertEqual(
      VideoEditorState.audioTrackRoles(forAudioTrackCount: 1, metadata: loaded),
      [.mixed]
    )
  }

  func testVideoEditorStateAudioTrackRolesPreferTrackIDMetadata() throws {
    let composition = AVMutableComposition()
    let microphoneTrack = try XCTUnwrap(composition.addMutableTrack(
      withMediaType: .audio,
      preferredTrackID: 42
    ))
    let systemTrack = try XCTUnwrap(composition.addMutableTrack(
      withMediaType: .audio,
      preferredTrackID: 7
    ))

    let metadata = RecordingMetadata(
      captureSize: CGSize(width: 640, height: 360),
      samplesPerSecond: 60,
      mouseSamples: [],
      audioSourceURL: tempDirectory.appendingPathComponent("source.mov"),
      audioSourceTrackRoles: [.systemAudio, .microphone],
      audioSourceTracks: [
        RecordingAudioSourceTrack(trackID: Int(systemTrack.trackID), role: .systemAudio),
        RecordingAudioSourceTrack(trackID: Int(microphoneTrack.trackID), role: .microphone),
      ]
    )

    XCTAssertEqual(
      VideoEditorState.audioTrackRoles(for: [microphoneTrack, systemTrack], metadata: metadata),
      [.microphone, .systemAudio]
    )
  }

  private func makeCurrentMetadata() -> RecordingMetadata {
    RecordingMetadata(
      coordinateSpace: .topLeftNormalized,
      captureSize: CGSize(width: 1_280, height: 720),
      samplesPerSecond: 60,
      mouseSamples: [
        RecordedMouseSample(time: 0.0, normalizedX: 0.1, normalizedY: 0.2, isInsideCapture: true),
        RecordedMouseSample(time: 0.5, normalizedX: 0.7, normalizedY: 0.8, isInsideCapture: true),
      ]
    )
  }

  private func makeVideoFile(named name: String) throws -> URL {
    let url = tempDirectory.appendingPathComponent(name)
    try Data("video".utf8).write(to: url)
    videoURLs.append(url)
    return url
  }

  private func legacySidecarURL(for videoURL: URL) -> URL {
    videoURL
      .deletingPathExtension()
      .appendingPathExtension("ownshot-recording.json")
  }
}
