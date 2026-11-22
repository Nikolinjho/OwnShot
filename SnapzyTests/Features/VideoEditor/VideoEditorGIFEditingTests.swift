import AppKit
import AVFoundation
import ImageIO
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import Snapzy

@MainActor
final class VideoEditorGIFEditingTests: XCTestCase {
  func testКороткийGIFМожноОбрезатьДоОдногоКадра() async throws {
    let source = try makeGIF()
    defer { try? FileManager.default.removeItem(at: source) }
    let state = VideoEditorState(url: source)
    await state.loadMetadata()

    XCTAssertEqual(state.duration.seconds, 0.7, accuracy: 0.001)
    guard state.duration.seconds > 0 else { return }
    state.setTrimStart(CMTime(seconds: 0.2, preferredTimescale: 600))
    state.setTrimEnd(CMTime(seconds: 0.5, preferredTimescale: 600))
    XCTAssertEqual(state.trimStart.seconds, 0.2, accuracy: 0.001)
    XCTAssertEqual(state.trimEnd.seconds, 0.5, accuracy: 0.001)
    XCTAssertEqual(state.trimmedDuration.seconds, 0.3, accuracy: 0.001)
    XCTAssertTrue(state.hasUnsavedChanges)

    state.undo()
    XCTAssertEqual(state.trimEnd.seconds, 0.7, accuracy: 0.001)
    state.undo()
    XCTAssertFalse(state.hasUnsavedChanges)
    state.redo()
    state.redo()
    XCTAssertEqual(state.trimmedDuration.seconds, 0.3, accuracy: 0.001)

    let recipe = VideoEditorSessionData.snapshot(from: state, sourceSnapshotURL: source)
    let encoded = try JSONEncoder().encode(PersistedVideoEditorEditState(sessionData: recipe))
    let saved = try JSONDecoder().decode(PersistedVideoEditorEditState.self, from: encoded)
    let reopened = VideoEditorState(url: source, sessionData: saved.sessionData(
      sourceSnapshotURL: source, recordingMetadata: nil
    ))
    await reopened.loadMetadata()
    XCTAssertEqual(reopened.trimStart.seconds, 0.2, accuracy: 0.001)
    XCTAssertEqual(reopened.trimEnd.seconds, 0.5, accuracy: 0.001)
    XCTAssertFalse(reopened.hasUnsavedChanges)
  }

  func testОбрезанныйGIFСохраняетсяИВосстанавливаетРедактирование() async throws {
    try skipIfRunningInCI("Требуется нативное окно редактора")
    let source = try makeGIF()
    defer { try? FileManager.default.removeItem(at: source) }
    let controller = VideoEditorWindowController(url: source)
    let window = try XCTUnwrap(controller.window)
    let hosting = try XCTUnwrap(window.contentView as? NSHostingView<VideoEditorMainView>)
    let state = hosting.rootView.state
    let preferences = PreferencesManager.shared
    let copiesRecording = preferences.isActionEnabled(.copyFile, for: .recording)
    let theme = ThemeManager.shared
    let previousAppearance = theme.preferredAppearance
    preferences.setAction(.copyFile, for: .recording, enabled: false)
    defer {
      theme.preferredAppearance = previousAppearance
      preferences.setAction(.copyFile, for: .recording, enabled: copiesRecording)
      if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .abort) }
      if window.isVisible {
        state.markAsSaved()
        window.close()
      }
    }

    controller.showWindow()
    await state.loadMetadata()
    state.setGIFTrimFrame(1, isStart: true)
    state.setGIFTrimFrame(1, isStart: false)
    XCTAssertEqual(state.gifSelectedFrames, 1...1)
    XCTAssertTrue(state.hasUnsavedChanges)

    if #available(macOS 14.0, *), ProcessInfo.processInfo.environment["OWNSHOT_STUDIO_SNAPSHOTS"] == "1" {
      for mode in [AppearanceMode.light, .dark] {
        theme.preferredAppearance = mode
        try await Task.sleep(for: .milliseconds(150))
        try await attachWindow(window, name: "gif-editor-\(mode.rawValue)")
      }
    }

    try XCTUnwrap(hosting.rootView.onSave)()
    try await confirmReplacement(in: window)
    let output = try XCTUnwrap(GIFResizer.metadata(for: source))
    XCTAssertEqual(output.frameCount, 1)
    XCTAssertEqual(output.duration, 0.3, accuracy: 0.001)
    XCTAssertEqual(output.size, CGSize(width: 20, height: 10))

    let recipe = try XCTUnwrap(VideoEditorSessionStore.shared.load(for: source))
    let reopenedController = VideoEditorWindowController(url: source, sessionData: recipe)
    reopenedController.showWindow()
    let reopenedWindow = try XCTUnwrap(reopenedController.window)
    let reopenedHosting = try XCTUnwrap(reopenedWindow.contentView as? NSHostingView<VideoEditorMainView>)
    let reopened = reopenedHosting.rootView.state
    defer {
      if let sheet = reopenedWindow.attachedSheet { reopenedWindow.endSheet(sheet, returnCode: .abort) }
      if reopenedWindow.isVisible {
        reopened.markAsSaved()
        reopenedWindow.close()
      }
    }
    await reopened.loadMetadata()
    XCTAssertEqual(reopened.gifFrameCount, 3)
    XCTAssertEqual(reopened.gifSelectedFrames, 1...1)
    XCTAssertFalse(reopened.hasUnsavedChanges)
    XCTAssertNil((reopenedWindow as? VideoEditorWindow)?.onTogglePlayback)

    reopened.resetTrim()
    try XCTUnwrap(reopenedHosting.rootView.onSave)()
    try await confirmReplacement(in: reopenedWindow)
    let restored = try XCTUnwrap(GIFResizer.metadata(for: source))
    XCTAssertEqual(restored.frameCount, 3)
    XCTAssertEqual(restored.duration, 0.7, accuracy: 0.001)
  }

  private func confirmReplacement(in window: NSWindow) async throws {
    let confirmation = try XCTUnwrap(window.attachedSheet)
    window.endSheet(confirmation, returnCode: .alertFirstButtonReturn)
    let deadline = ContinuousClock.now + .seconds(5)
    while window.isVisible, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertFalse(window.isVisible)
  }

  @available(macOS 14.0, *)
  private func attachWindow(_ window: NSWindow, name: String) async throws {
    let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
    let capturedWindow = try XCTUnwrap(content.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
    let configuration = SCStreamConfiguration()
    configuration.width = Int(window.frame.width * window.backingScaleFactor)
    configuration.height = Int(window.frame.height * window.backingScaleFactor)
    let image = try await SCScreenshotManager.captureImage(
      contentFilter: SCContentFilter(desktopIndependentWindow: capturedWindow), configuration: configuration
    )
    let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    let attachment = XCTAttachment(data: png, uniformTypeIdentifier: UTType.png.identifier)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private func makeGIF() throws -> URL {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("OwnShot-GIF-\(UUID()).gif")
    let delays = [0.2, 0.3, 0.2]
    let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
      path as CFURL, UTType.gif.identifier as CFString, delays.count, nil
    ))
    for (index, delay) in delays.enumerated() {
      let image = try XCTUnwrap(TestImageFactory.solidColor(width: 20, height: 10, red: UInt8(index * 80)))
      let properties = [
        kCGImagePropertyGIFDictionary as String: [
          kCGImagePropertyGIFUnclampedDelayTime as String: delay,
          kCGImagePropertyGIFDelayTime as String: delay,
        ],
      ]
      CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    }
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return path
  }
}
