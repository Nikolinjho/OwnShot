//
//  AnnotationSessionStoreTests.swift
//  SnapzyTests
//
//  Unit tests for persisted editable annotation session sidecars.
//

import AppKit
import SwiftUI
import XCTest
@testable import Snapzy

@MainActor
final class AnnotationSessionStoreTests: XCTestCase {

  private var tempDirectory: URL!
  private var sessionsDirectory: URL!
  private var sourceDirectory: URL!
  private var store: AnnotationSessionStore!

  override func setUp() {
    super.setUp()
    tempDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("SnapzyTests_AnnotationSessionStore_\(UUID().uuidString)", isDirectory: true)
    sessionsDirectory = tempDirectory.appendingPathComponent("AnnotationSessions", isDirectory: true)
    sourceDirectory = tempDirectory.appendingPathComponent("Sources", isDirectory: true)
    try? FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    store = AnnotationSessionStore(rootDirectory: sessionsDirectory)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: tempDirectory)
    store = nil
    tempDirectory = nil
    sessionsDirectory = nil
    sourceDirectory = nil
    super.tearDown()
  }

  func testPersistAndLoad_roundTripsEditableSession() throws {
    let sourceURL = try writeSourceImage(named: "capture.png")
    let assetId = UUID()
    let sessionData = try makeSessionData(assetId: assetId)

    XCTAssertTrue(store.persist(sessionData, for: sourceURL))

    let loaded = try XCTUnwrap(store.load(for: sourceURL))
    XCTAssertEqual(loaded.originalImageData, sessionData.originalImageData)
    XCTAssertEqual(loaded.annotations.count, 4)
    XCTAssertEqual(loaded.annotations.map(\.id), sessionData.annotations.map(\.id))
    XCTAssertEqual(loaded.canvasEffects.padding, 18)
    XCTAssertEqual(loaded.canvasEffects.shadowIntensity, 0.7)
    XCTAssertEqual(loaded.canvasEffects.aspectRatio, .ratio16x9)
    XCTAssertEqual(loaded.selectedCanvasPresetId, sessionData.selectedCanvasPresetId)
    XCTAssertEqual(loaded.cropRect, sessionData.cropRect)
    XCTAssertEqual(loaded.cutoutImageData, sessionData.cutoutImageData)
    XCTAssertEqual(loaded.embeddedImageAssetsData[assetId], Data("embedded-asset".utf8))
    XCTAssertEqual(loaded.sourceLogicalSize, sessionData.sourceLogicalSize)
    XCTAssertEqual(loaded.originalCropSourceSize, sessionData.originalCropSourceSize)

    guard case .text("Editable text") = loaded.annotations[0].type else {
      return XCTFail("Expected text annotation")
    }
    guard case .arrow(let geometry) = loaded.annotations[1].type else {
      return XCTFail("Expected arrow annotation")
    }
    XCTAssertEqual(geometry.style, .curvedRight)
    XCTAssertEqual(geometry.bendDirection, .alternate)
    XCTAssertEqual(loaded.annotations[1].properties.lineStyle, .dashed)
    guard case .blur(.gaussian) = loaded.annotations[2].type else {
      return XCTFail("Expected gaussian blur annotation")
    }
    guard case .embeddedImage(let loadedAssetId) = loaded.annotations[3].type else {
      return XCTFail("Expected embedded image annotation")
    }
    XCTAssertEqual(loadedAssetId, assetId)
  }

  func testLoad_decodesLegacyManifestWithoutSourceLogicalSize() throws {
    let sourceURL = try writeSourceImage(named: "capture.png")
    let sessionData = try makeSessionData()

    XCTAssertTrue(store.persist(sessionData, for: sourceURL))

    // Simulate a sidecar written before sourceLogicalSize existed (schemaVersion 1
    // stays unchanged; the optional key is simply absent).
    let manifestURL = sidecarDirectory(for: sourceURL).appendingPathComponent("manifest.json")
    let manifestData = try Data(contentsOf: manifestURL)
    var manifestObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
    )
    manifestObject.removeValue(forKey: "sourceLogicalSize")
    manifestObject.removeValue(forKey: "originalCropSourceSize")
    let legacyData = try JSONSerialization.data(withJSONObject: manifestObject, options: [.sortedKeys])
    try legacyData.write(to: manifestURL, options: .atomic)

    let loaded = try XCTUnwrap(store.load(for: sourceURL))
    XCTAssertNil(loaded.sourceLogicalSize)
    XCTAssertNil(loaded.originalCropSourceSize)
    XCTAssertEqual(loaded.annotations.count, sessionData.annotations.count)
  }

  func testPersistOffMainНеПривязываетПрежниеПравкиКЗаменённомуФайлу() async throws {
    let sourceURL = try writeSourceImage(named: "capture.png")
    let formerSession = try makeSessionData()
    let publishedRevision = try XCTUnwrap(CaptureFilePublication.FileRevision(at: sourceURL))

    try makeImageData(width: 40, height: 30).write(to: sourceURL, options: .atomic)
    let currentAssetId = UUID()
    let currentSession = try makeSessionData(assetId: currentAssetId)
    XCTAssertTrue(store.persist(currentSession, for: sourceURL))

    let saved = await store.persistOffMain(formerSession, for: sourceURL, expecting: publishedRevision)

    XCTAssertFalse(saved)
    let loaded = try XCTUnwrap(store.load(for: sourceURL))
    XCTAssertEqual(Set(loaded.embeddedImageAssetsData.keys), [currentAssetId])
  }

  func testPersistOffMainПривязываетПравкиКПодтверждённомуФайлу() async throws {
    let sourceURL = try writeSourceImage(named: "capture.png")
    let session = try makeSessionData()
    let revision = try XCTUnwrap(CaptureFilePublication.FileRevision(at: sourceURL))

    let saved = await store.persistOffMain(session, for: sourceURL, expecting: revision)

    XCTAssertTrue(saved)
    XCTAssertEqual(store.load(for: sourceURL)?.annotations.map(\.id), session.annotations.map(\.id))
  }

  func testLoad_returnsNilWhenSourceSignatureChanges() throws {
    let sourceURL = try writeSourceImage(named: "capture.png")
    let sessionData = try makeSessionData()

    XCTAssertTrue(store.persist(sessionData, for: sourceURL))
    XCTAssertNotNil(store.load(for: sourceURL))

    try Data("changed flattened image bytes".utf8).write(to: sourceURL, options: .atomic)
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(60)],
      ofItemAtPath: sourceURL.path
    )

    XCTAssertNil(store.load(for: sourceURL))
  }

  func testMoveSession_rekeysSidecarToNewSourcePath() throws {
    let sourceURL = try writeSourceImage(named: "capture.png")
    let destinationURL = sourceDirectory.appendingPathComponent("exported.png")
    let sessionData = try makeSessionData()

    XCTAssertTrue(store.persist(sessionData, for: sourceURL))
    try FileManager.default.moveItem(at: sourceURL, to: destinationURL)

    XCTAssertTrue(store.moveSession(from: sourceURL, to: destinationURL))
    XCTAssertNil(store.load(for: sourceURL))
    XCTAssertEqual(store.load(for: destinationURL)?.annotations.count, sessionData.annotations.count)
    XCTAssertFalse(FileManager.default.fileExists(atPath: sidecarDirectory(for: sourceURL).path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarDirectory(for: destinationURL).path))
  }

  func testMoveSessionRekeysReadOnlySourcePackageWithoutRelocatingItsOldManifest() throws {
    let source = try writeSourceImage(named: "read-only-source.png")
    let destination = try writeSourceImage(named: "existing-destination.png")
    let sourceData = try makeSessionData()
    let destinationData = try makeSessionData()
    XCTAssertTrue(store.persist(sourceData, for: source))
    XCTAssertTrue(store.persist(destinationData, for: destination))

    let sourcePackage = sidecarDirectory(for: source)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: sourcePackage.path)
    defer {
      let packages = (try? FileManager.default.contentsOfDirectory(
        at: sessionsDirectory, includingPropertiesForKeys: nil
      )) ?? []
      for package in packages {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: package.path)
      }
    }
    try FileManager.default.removeItem(at: destination)
    try FileManager.default.moveItem(at: source, to: destination)

    XCTAssertTrue(store.moveSession(from: source, to: destination))
    XCTAssertEqual(store.load(for: destination)?.embeddedImageAssetsData, sourceData.embeddedImageAssetsData)
    XCTAssertEqual(store.load(for: destination)?.cutoutImageData, sourceData.cutoutImageData)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: sessionsDirectory.path),
      [sidecarDirectory(for: destination).lastPathComponent]
    )
  }

  func testMoveSessionPreservesSourceAndUnexpectedDestinationEntry() throws {
    let source = try writeSourceImage(named: "source.png")
    let destination = sourceDirectory.appendingPathComponent("destination.png")
    let session = try makeSessionData()
    XCTAssertTrue(store.persist(session, for: source))
    let sourcePackage = sidecarDirectory(for: source)
    let destinationPackage = sidecarDirectory(for: destination)
    let manifestURL = sourcePackage.appendingPathComponent("manifest.json")
    let previousManifest = try Data(contentsOf: manifestURL)
    let sentinel = Data("Unexpected file at the package path".utf8)
    try sentinel.write(to: destinationPackage)
    try FileManager.default.moveItem(at: source, to: destination)

    XCTAssertFalse(store.moveSession(from: source, to: destination))
    XCTAssertEqual(try? Data(contentsOf: manifestURL), previousManifest)
    XCTAssertEqual(try? Data(contentsOf: destinationPackage), sentinel)
    XCTAssertEqual(
      Set(try FileManager.default.contentsOfDirectory(atPath: sessionsDirectory.path)),
      Set([sourcePackage.lastPathComponent, destinationPackage.lastPathComponent])
    )
  }


  func testMoveSessionPreservesBothPublishedPackagesWhenStagingFails() throws {
    let source = try writeSourceImage(named: "source.png")
    let destination = try writeSourceImage(named: "destination.png")
    XCTAssertTrue(store.persist(try makeSessionData(), for: source))
    XCTAssertTrue(store.persist(try makeSessionData(), for: destination))

    let sourcePackage = sidecarDirectory(for: source)
    let destinationPackage = sidecarDirectory(for: destination)
    let manifests = [sourcePackage, destinationPackage].map { $0.appendingPathComponent("manifest.json") }
    let before = try manifests.map { try Data(contentsOf: $0) }
    try FileManager.default.removeItem(at: destination)
    try FileManager.default.moveItem(at: source, to: destination)

    let failingStore = AnnotationSessionStore(rootDirectory: sessionsDirectory, fileManager: FailingStagingFileManager())
    XCTAssertFalse(failingStore.moveSession(from: source, to: destination))
    XCTAssertEqual(manifests.map { try? Data(contentsOf: $0) }, before.map(Optional.some))
    XCTAssertEqual(
      Set(try FileManager.default.contentsOfDirectory(atPath: sessionsDirectory.path)),
      Set([sourcePackage.lastPathComponent, destinationPackage.lastPathComponent])
    )
  }

  private final class FailingStagingFileManager: FileManager, @unchecked Sendable {
    override func createDirectory(
      at url: URL, withIntermediateDirectories createIntermediates: Bool,
      attributes: [FileAttributeKey: Any]? = nil
    ) throws {
      if url.lastPathComponent.hasPrefix(".") { throw POSIXError(.EIO) }
      try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }
  }

  func testCleanup_removesMissingAndInactiveSidecarsButKeepsActiveMatches() throws {
    let activeURL = try writeSourceImage(named: "active.png")
    let missingURL = try writeSourceImage(named: "missing.png")
    let inactiveURL = try writeSourceImage(named: "inactive.png")
    let sessionData = try makeSessionData()

    XCTAssertTrue(store.persist(sessionData, for: activeURL))
    XCTAssertTrue(store.persist(sessionData, for: missingURL))
    XCTAssertTrue(store.persist(sessionData, for: inactiveURL))
    try FileManager.default.removeItem(at: missingURL)

    store.cleanup(keepingScreenshotFilePaths: [activeURL.path])

    XCTAssertNotNil(store.load(for: activeURL))
    XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarDirectory(for: activeURL).path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: sidecarDirectory(for: missingURL).path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: sidecarDirectory(for: inactiveURL).path))
  }

  func testCleanupKeepsStagingPackageAndRemovesMalformedPublishedPackage() throws {
    let sourceURL = try writeSourceImage(named: "pending.png")
    let destination = sidecarDirectory(for: sourceURL)
    let stagingDirectory = sessionsDirectory.appendingPathComponent(
      ".\(destination.lastPathComponent).\(UUID().uuidString)",
      isDirectory: true
    )
    let stagedImage = stagingDirectory.appendingPathComponent("original.png")
    let bytes = Data("Original image bytes".utf8)
    try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
    try bytes.write(to: stagedImage)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    let invalidManifest = destination.appendingPathComponent("manifest.json")
    try Data("Invalid manifest".utf8).write(to: invalidManifest)

    store.cleanup(keepingScreenshotFilePaths: [sourceURL.path])

    XCTAssertEqual(try? Data(contentsOf: stagedImage), bytes)
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
  }

  func testОчисткаСессийСохраняетФайлИСсылкуПоПутиПакета() throws {
    let files = FileManager.default
    try files.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
    let referent = sourceDirectory.appendingPathComponent("external", isDirectory: true)
    try files.createDirectory(at: referent, withIntermediateDirectories: true)
    let referentFile = referent.appendingPathComponent("notes")
    let data = Data("Keep existing entry".utf8)
    try data.write(to: referentFile)

    for cleansHistory in [true, false] {
      let fileSource = try writeSourceImage(named: "file-\(cleansHistory).png")
      let linkSource = try writeSourceImage(named: "link-\(cleansHistory).png")
      let filePackage = sidecarDirectory(for: fileSource)
      let linkPackage = sidecarDirectory(for: linkSource)
      try data.write(to: filePackage)
      try files.createSymbolicLink(at: linkPackage, withDestinationURL: referent)

      if cleansHistory {
        store.cleanup(keepingScreenshotFilePaths: [])
      } else {
        store.deleteSession(for: fileSource)
        store.deleteSession(for: linkSource)
      }

      XCTAssertEqual(try? Data(contentsOf: filePackage), data)
      XCTAssertEqual(try? files.destinationOfSymbolicLink(atPath: linkPackage.path), referent.path)
      XCTAssertEqual(try Data(contentsOf: referentFile), data)
    }
  }

  func testPersistPreservesUnexpectedFileAndSymlinkAtPackagePath() throws {
    try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
    let sessionData = try makeSessionData()
    let original = Data("Keep existing entry".utf8)
    for isSymlink in [false, true] {
      let source = try writeSourceImage(named: isSymlink ? "link.png" : "file.png")
      let package = sidecarDirectory(for: source)
      if isSymlink {
        let referent = sourceDirectory.appendingPathComponent("referent")
        try original.write(to: referent)
        try FileManager.default.createSymbolicLink(at: package, withDestinationURL: referent)
        XCTAssertFalse(store.persist(sessionData, for: source))
        XCTAssertEqual(try? FileManager.default.destinationOfSymbolicLink(atPath: package.path), referent.path)
        XCTAssertEqual(try Data(contentsOf: referent), original)
      } else {
        try original.write(to: package)
        XCTAssertFalse(store.persist(sessionData, for: source))
        XCTAssertEqual(try? Data(contentsOf: package), original)
      }
    }
  }

  func testPersistReplacesAnExistingPackageAndCleansStaging() throws {
    let source = try writeSourceImage(named: "replacement.png")
    let assetId = UUID()
    let old = try makeSessionData(assetId: assetId)
    var updated = old
    updated.embeddedImageAssetsData[assetId] = Data("Updated image asset".utf8)

    XCTAssertTrue(store.persist(old, for: source))
    XCTAssertEqual(store.load(for: source)?.embeddedImageAssetsData, old.embeddedImageAssetsData)
    XCTAssertTrue(store.persist(updated, for: source))
    XCTAssertEqual(store.load(for: source)?.embeddedImageAssetsData, updated.embeddedImageAssetsData)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: sessionsDirectory.path),
      [sidecarDirectory(for: source).lastPathComponent]
    )
  }

  // MARK: - Helpers

  private func writeSourceImage(named fileName: String) throws -> URL {
    let url = sourceDirectory.appendingPathComponent(fileName)
    try makeImageData(width: 24, height: 16).write(to: url, options: .atomic)
    return url
  }

  private func makeSessionData(assetId: UUID = UUID()) throws -> AnnotationSessionData {
    let originalData = try makeImageData(width: 24, height: 16)
    let cutoutData = try makeImageData(width: 8, height: 8)
    let presetId = UUID()
    let arrowGeometry = ArrowGeometry(
      start: CGPoint(x: 4, y: 5),
      end: CGPoint(x: 50, y: 60),
      style: .curvedRight,
      bendDirection: .alternate
    )
    return AnnotationSessionData(
      originalImageData: originalData,
      annotations: [
        AnnotationItem(
          id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
          type: .text("Editable text"),
          bounds: CGRect(x: 1, y: 2, width: 30, height: 16),
          properties: AnnotationProperties(
            strokeColor: .yellow,
            fillColor: .blue,
            strokeWidth: 4,
            cornerRadius: 3,
            fontSize: 18,
            fontName: "SF Pro",
            opacity: 0.8,
            rotationDegrees: 12,
            watermarkStyle: .diagonal
          )
        ),
        AnnotationItem(
          id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
          type: .arrow(arrowGeometry),
          bounds: arrowGeometry.bounds(),
          properties: AnnotationProperties(strokeColor: .red, strokeWidth: 5, lineStyle: .dashed)
        ),
        AnnotationItem(
          id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
          type: .blur(.gaussian),
          bounds: CGRect(x: 10, y: 12, width: 44, height: 22),
          properties: AnnotationProperties()
        ),
        AnnotationItem(
          id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
          type: .embeddedImage(assetId),
          bounds: CGRect(x: 2, y: 3, width: 12, height: 9),
          properties: AnnotationProperties()
        )
      ],
      canvasEffects: AnnotationCanvasEffects(
        backgroundStyle: .gradient(.blueGreen),
        isBlurredBackgroundEnabled: true,
        blurredBackgroundEffect: .vivid,
        padding: 18,
        inset: 6,
        autoBalance: false,
        shadowIntensity: 0.7,
        cornerRadius: 11,
        imageAlignment: .bottomRight,
        aspectRatio: .ratio16x9,
        aspectRatioOrientation: .vertical
      ),
      selectedCanvasPresetId: presetId,
      isSelectedCanvasPresetDirty: true,
      cropRect: CGRect(x: 1, y: 1, width: 20, height: 12),
      isCutoutApplied: true,
      cutoutImageData: cutoutData,
      didCutoutAutoApplyCrop: true,
      cutoutAutoAppliedCropRect: CGRect(x: 2, y: 2, width: 10, height: 6),
      embeddedImageAssetsData: [assetId: Data("embedded-asset".utf8)],
      sourceLogicalSize: CGSize(width: 280, height: 202),
      originalCropSourceSize: OriginalCropSourceSize(
        logicalSize: CGSize(width: 202.5, height: 280), backingSize: CGSize(width: 405, height: 560))
    )
  }

  private func makeImageData(width: Int, height: Int) throws -> Data {
    let cgImage = try XCTUnwrap(TestImageFactory.solidColor(width: width, height: height))
    let image = NSImage(cgImage: cgImage, size: CGSize(width: width, height: height))
    return try XCTUnwrap(AnnotateExporter.imageData(from: image, for: "png"))
  }

  private func sidecarDirectory(for sourceURL: URL) -> URL {
    let normalizedPath = AnnotationSessionStore.normalizedPath(for: sourceURL)
    return sessionsDirectory.appendingPathComponent(
      AnnotationSessionStore.pathHash(for: normalizedPath),
      isDirectory: true
    )
  }
}
