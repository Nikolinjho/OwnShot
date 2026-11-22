//
//  AnnotateExportSaveTests.swift
//  SnapzyTests
//
//  Characterization tests for AnnotateExporter render + save paths.
//  ALWAYS-RUN: renderFinalImage non-nil + dims (NO pixel equality — retina
//  pixel fidelity is already covered in AnnotateCoreTests), saveToOriginal /
//  saveToFile writing to a temp dir. CI-SKIP: saveAs (NSSavePanel),
//  copyToClipboard (NSPasteboard).
//

import AppKit
import CoreGraphics
import XCTest
@testable import Snapzy

@MainActor
final class AnnotateExportSaveTests: XCTestCase {
  private static var retainedAnnotateStates: [AnnotateState] = []

  private var tempDir: URL!

  override func setUp() {
    super.setUp()
    tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("SnapzyTests_ExportSave_\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: tempDir)
    tempDir = nil
    super.tearDown()
  }

  private func makeAnnotateState() -> AnnotateState {
    let state = AnnotateState()
    Self.retainedAnnotateStates.append(state)
    return state
  }

  private func makeImage(width: Int, height: Int) throws -> NSImage {
    let cgImage = try XCTUnwrap(TestImageFactory.solidColor(width: width, height: height))
    return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
  }

  func testDeleteKeepsDirtyEditorAndReferencesWhenTrashFails() throws {
    let source = tempDir.appendingPathComponent("capture.png")
    let original = Data("Capture".utf8)
    try original.write(to: source)
    let confirmation = try AnnotateBottomBarView.DeleteConfirmation(at: source)
    let state = makeAnnotateState()
    state.sourceURL = source
    state.hasUnsavedChanges = true
    var removeCalls = 0
    var closeCalls = 0

    XCTAssertThrowsError(try AnnotateBottomBarView.deleteConfirmedScreenshot(
      confirmation, state: state,
      trash: { url in
        XCTAssertEqual(url, source)
        throw CocoaError(.fileWriteNoPermission)
      },
      removeReferences: { removeCalls += 1 },
      close: { closeCalls += 1 }
    ))

    XCTAssertEqual(removeCalls, 0)
    XCTAssertEqual(closeCalls, 0)
    XCTAssertTrue(state.hasUnsavedChanges)
    XCTAssertEqual(state.sourceURL, source)
    XCTAssertEqual(try Data(contentsOf: source), original)
  }

  func testDeleteCommitsReferencesAndClosesAfterTrashSucceeds() throws {
    let source = tempDir.appendingPathComponent("capture.png")
    let moved = tempDir.appendingPathComponent("moved.png")
    let original = Data("Capture".utf8)
    try original.write(to: source)
    let confirmation = try AnnotateBottomBarView.DeleteConfirmation(at: source)
    let state = makeAnnotateState()
    state.sourceURL = source
    state.hasUnsavedChanges = true
    var actions: [String] = []

    try AnnotateBottomBarView.deleteConfirmedScreenshot(
      confirmation, state: state,
      trash: { url in
        XCTAssertTrue(state.hasUnsavedChanges)
        try FileManager.default.moveItem(at: url, to: moved)
        actions.append("trash")
      },
      removeReferences: { actions.append("references") },
      close: {
        XCTAssertFalse(state.hasUnsavedChanges)
        actions.append("close")
      }
    )

    XCTAssertEqual(actions, ["trash", "references", "close"])
    XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    XCTAssertEqual(try Data(contentsOf: moved), original)
  }

  func testDeleteIgnoresConfirmationForPreviousSource() throws {
    let oldSource = tempDir.appendingPathComponent("previous.png")
    let currentSource = tempDir.appendingPathComponent("current.png")
    try Data([1]).write(to: oldSource)
    let confirmation = try AnnotateBottomBarView.DeleteConfirmation(at: oldSource)
    try Data([2]).write(to: currentSource)
    let state = makeAnnotateState()
    state.sourceURL = currentSource
    state.hasUnsavedChanges = true

    try AnnotateBottomBarView.deleteConfirmedScreenshot(
      confirmation, state: state,
      trash: { _ in XCTFail("Stale confirmation attempted to Trash the previous source") },
      removeReferences: { XCTFail("Stale confirmation removed references") },
      close: { XCTFail("Stale confirmation closed the new editor content") }
    )

    XCTAssertTrue(state.hasUnsavedChanges)
    XCTAssertEqual(state.sourceURL, currentSource)
    XCTAssertEqual(try Data(contentsOf: oldSource), Data([1]))
    XCTAssertEqual(try Data(contentsOf: currentSource), Data([2]))
  }

  func testDeletePreservesReplacementAtConfirmedSourcePath() throws {
    let source = tempDir.appendingPathComponent("capture.png")
    let archive = tempDir.appendingPathComponent("archived.png")
    let wouldBeTrashed = tempDir.appendingPathComponent("would-be-trashed.png")
    let original = Data("Original".utf8)
    let replacement = Data("Replaced".utf8)
    try original.write(to: source)
    let confirmation = try AnnotateBottomBarView.DeleteConfirmation(at: source)
    let state = makeAnnotateState()
    state.sourceURL = source
    state.hasUnsavedChanges = true

    // Keep the old inode alive and put another file at the exact approved URL.
    try FileManager.default.moveItem(at: source, to: archive)
    try replacement.write(to: source, options: .atomic)
    var actions: [String] = []

    try AnnotateBottomBarView.deleteConfirmedScreenshot(
      confirmation, state: state,
      trash: { url in
        try FileManager.default.moveItem(at: url, to: wouldBeTrashed)
        actions.append("trash")
      },
      removeReferences: { actions.append("references") },
      close: { actions.append("close") }
    )

    XCTAssertEqual(actions, [])
    XCTAssertTrue(state.hasUnsavedChanges)
    XCTAssertEqual(state.sourceURL, source)
    XCTAssertEqual(try? Data(contentsOf: source), replacement)
    XCTAssertEqual(try Data(contentsOf: archive), original)
  }

  func testDeleteNeverTrashesDirectoryAtSourcePath() throws {
    let source = tempDir.appendingPathComponent("capture.png")
    try Data([0]).write(to: source)
    let confirmation = try AnnotateBottomBarView.DeleteConfirmation(at: source)
    try FileManager.default.removeItem(at: source)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
    let protected = source.appendingPathComponent("keep")
    try Data([1]).write(to: protected)
    let state = makeAnnotateState()
    state.sourceURL = source
    state.hasUnsavedChanges = true

    XCTAssertThrowsError(try AnnotateBottomBarView.deleteConfirmedScreenshot(
      confirmation, state: state,
      trash: { _ in XCTFail("Delete attempted to Trash a directory") },
      removeReferences: { XCTFail("Directory rejection removed references") },
      close: { XCTFail("Directory rejection closed the editor") }
    ))

    XCTAssertTrue(state.hasUnsavedChanges)
    XCTAssertEqual(try Data(contentsOf: protected), Data([1]))
  }

  func testDeleteConfirmationRequiresAnExistingFile() throws {
    let source = tempDir.appendingPathComponent("capture.png")
    XCTAssertThrowsError(try AnnotateBottomBarView.DeleteConfirmation(at: source))

    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
    XCTAssertThrowsError(try AnnotateBottomBarView.DeleteConfirmation(at: source))
  }

  func testDeleteTrashesLeafSymlinkAndPreservesItsReferent() throws {
    let referent = tempDir.appendingPathComponent("original.png")
    let source = tempDir.appendingPathComponent("capture.png")
    let moved = tempDir.appendingPathComponent("moved.png")
    let original = Data("Original".utf8)
    try original.write(to: referent)
    try FileManager.default.createSymbolicLink(at: source, withDestinationURL: referent)
    let confirmation = try AnnotateBottomBarView.DeleteConfirmation(at: source)
    let state = makeAnnotateState()
    state.sourceURL = source
    state.hasUnsavedChanges = true

    try AnnotateBottomBarView.deleteConfirmedScreenshot(
      confirmation, state: state,
      trash: { try FileManager.default.moveItem(at: $0, to: moved) },
      removeReferences: {},
      close: {}
    )

    XCTAssertFalse(state.hasUnsavedChanges)
    XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: moved.path), referent.path)
    XCTAssertEqual(try Data(contentsOf: referent), original)
    XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
  }

  // MARK: - renderFinalImage (dims only)

  func testRenderFinalImageReturnsNonNilImageMatchingSourceDimensions() throws {
    let state = makeAnnotateState()
    state.loadImage(try makeImage(width: 200, height: 120))

    let rendered = try XCTUnwrap(AnnotateExporter.renderFinalImage(state: state))

    // Default state: no crop, backgroundStyle == .none (padding 0), 1x image.
    // Point-size equals source point-size; pixel dims equal source pixel dims.
    XCTAssertEqual(rendered.size.width, 200, accuracy: 0.0001)
    XCTAssertEqual(rendered.size.height, 120, accuracy: 0.0001)

    let renderedCG = try XCTUnwrap(AnnotateExporter.bestCGImage(from: rendered))
    XCTAssertEqual(renderedCG.width, 200)
    XCTAssertEqual(renderedCG.height, 120)
  }

  func testRenderFinalImageReturnsNilWhenNoSourceImage() {
    let state = makeAnnotateState()
    XCTAssertNil(AnnotateExporter.renderFinalImage(state: state))
  }

  func testRenderFinalImageWithAnnotationsKeepsSourceDimensions() throws {
    let state = makeAnnotateState()
    state.loadImage(try makeImage(width: 160, height: 160))
    state.annotations = [
      AnnotationItem(
        type: .rectangle,
        bounds: CGRect(x: 10, y: 10, width: 40, height: 40),
        properties: AnnotationProperties()
      )
    ]

    let rendered = try XCTUnwrap(AnnotateExporter.renderFinalImage(state: state))
    XCTAssertEqual(rendered.size.width, 160, accuracy: 0.0001)
    XCTAssertEqual(rendered.size.height, 160, accuracy: 0.0001)
  }

  func testRenderFinalImageUsesCombinedBoundsGapAndPadding() throws {
    let state = makeAnnotateState()
    state.loadImage(try makeImage(width: 200, height: 100))
    state.importImage(try makeImage(width: 100, height: 100))
    state.setCombineDirection(.horizontal)
    state.setCombineGap(10)
    state.padding = 24

    let rendered = try XCTUnwrap(AnnotateExporter.renderFinalImage(state: state))

    XCTAssertEqual(rendered.size.width, 358, accuracy: 0.001)
    XCTAssertEqual(rendered.size.height, 148, accuracy: 0.001)
  }

  // MARK: - saveToOriginal (writes to state.sourceURL)

  func testSaveToOriginalWritesReadableFileAndReturnsTrue() throws {
    let state = makeAnnotateState()
    let url = tempDir.appendingPathComponent("capture.png")
    state.loadImage(try makeImage(width: 80, height: 60), url: url)

    let didSave = AnnotateExporter.saveToOriginal(state: state)

    XCTAssertTrue(didSave)
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    let reloaded = try XCTUnwrap(NSImage(contentsOf: url))
    XCTAssertGreaterThan(reloaded.size.width, 0)
    XCTAssertGreaterThan(reloaded.size.height, 0)
  }

  func testSaveToOriginalReturnsFalseWhenNoSourceURL() throws {
    let state = makeAnnotateState()
    state.loadImage(try makeImage(width: 40, height: 40))  // no URL

    XCTAssertFalse(AnnotateExporter.saveToOriginal(state: state))
  }

  // MARK: - saveToFile (writes pre-rendered image to state.sourceURL)

  func testSaveToFileWritesRenderedImageToTempURLAndReturnsTrue() throws {
    let state = makeAnnotateState()
    let url = tempDir.appendingPathComponent("background-save.png")
    state.loadImage(try makeImage(width: 100, height: 100), url: url)
    let rendered = AnnotateExporter.renderFinalImage(state: state)

    let didSave = AnnotateExporter.saveToFile(image: rendered, state: state)

    XCTAssertTrue(didSave)
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    let reloaded = try XCTUnwrap(NSImage(contentsOf: url))
    XCTAssertGreaterThan(reloaded.size.width, 0)
  }

  func testSaveToFileReturnsFalseWhenImageIsNil() throws {
    let state = makeAnnotateState()
    let url = tempDir.appendingPathComponent("noimage.png")
    state.loadImage(try makeImage(width: 40, height: 40), url: url)

    XCTAssertFalse(AnnotateExporter.saveToFile(image: nil, state: state))
  }

  func testSaveToFileReturnsFalseWhenNoSourceURL() throws {
    let state = makeAnnotateState()
    state.loadImage(try makeImage(width: 40, height: 40))  // no URL
    let rendered = AnnotateExporter.renderFinalImage(state: state)

    XCTAssertFalse(AnnotateExporter.saveToFile(image: rendered, state: state))
  }

  // MARK: - CI-SKIP (NSPasteboard / NSSavePanel)

  // copyToClipboard mutates the shared NSPasteboard (process-global, nondeterministic
  // under parallel CI). Local-only smoke test: must not crash.
  func testCopyToClipboardRunsWithoutCrashing() throws {
    try skipIfRunningInCI("copyToClipboard touches shared NSPasteboard")
    let state = makeAnnotateState()
    state.loadImage(try makeImage(width: 50, height: 50))

    AnnotateExporter.copyToClipboard(state: state)
    // No return value; success = no crash + a non-nil render underneath.
    XCTAssertNotNil(AnnotateExporter.renderFinalImage(state: state))
  }

  // saveAs presents a modal NSSavePanel; there is no headless path, so this is
  // documented as CI-SKIP and intentionally not driven (would block on the panel).
  func testSaveAsIsCoveredByManualInteractionOnly() throws {
    try skipIfRunningInCI("saveAs presents a modal NSSavePanel (no headless path)")
    // Intentionally not invoked: AnnotateExporter.saveAs(state:) opens a modal
    // panel that cannot be dismissed in an automated run. Placeholder to record
    // the CI-SKIP classification without hanging the suite.
    XCTAssertTrue(true)
  }
}
