//
//  VideoEditorWindowInputTests.swift
//  SnapzyTests
//
//  Regression tests for editor-window key-equivalent routing.
//

import AppKit
import AVKit
import CoreMedia
@testable import Snapzy
import SwiftUI
import XCTest

@MainActor
final class VideoEditorWindowInputTests: XCTestCase {
  private var testVideoURL: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Fixtures/Recording/quick-access-url.mp4")
  }

  func testUnhandledCommandCIsConsumedWithoutFallingThroughToWindowKeyDown() {
    let window = VideoEditorWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300)
    )
    guard let event = NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: [.command],
      timestamp: 0,
      windowNumber: window.windowNumber,
      context: nil,
      characters: "c",
      charactersIgnoringModifiers: "c",
      isARepeat: false,
      keyCode: 8
    ) else {
      XCTFail("Could not create Command-C event")
      return
    }

    XCTAssertTrue(window.performKeyEquivalent(with: event))
  }

  func testEscapeCancelsRenameWhenToolbarTextFieldIsFirstResponder() throws {
    let state = VideoEditorState(url: testVideoURL)
    state.isRenamingFile = true

    let hostingView = NSHostingView(rootView: VideoEditorToolbarView(state: state))
    let window = VideoEditorWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 100)
    )
    window.contentView = hostingView
    window.makeKeyAndOrderFront(nil)
    defer { window.close() }

    hostingView.layoutSubtreeIfNeeded()
    let textField = try XCTUnwrap(firstTextField(in: hostingView))
    XCTAssertTrue(window.makeFirstResponder(textField))

    let event = try XCTUnwrap(NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: [],
      timestamp: 0,
      windowNumber: window.windowNumber,
      context: nil,
      characters: "\u{1B}",
      charactersIgnoringModifiers: "\u{1B}",
      isARepeat: false,
      keyCode: 53
    ))

    window.sendEvent(event)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

    XCTAssertFalse(state.isRenamingFile)
  }

  func testSpaceControlsEditorPlaybackWhenVideoViewHasFocus() throws {
    let playerView = AVPlayerView()
    playerView.player = AVPlayer()
    playerView.controlsStyle = .none
    var isPlaying = false
    let window = VideoEditorWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 450)
    )
    window.contentView = playerView
    window.onTogglePlayback = { isPlaying.toggle() }
    window.makeKeyAndOrderFront(nil)
    defer { window.close() }
    XCTAssertTrue(window.makeFirstResponder(playerView))

    let event = try XCTUnwrap(NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: [],
      timestamp: 0,
      windowNumber: window.windowNumber,
      context: nil,
      characters: " ",
      charactersIgnoringModifiers: " ",
      isARepeat: false,
      keyCode: 49
    ))
    window.sendEvent(event)

    XCTAssertTrue(isPlaying, "Space must use the editor's playback command")
    window.sendEvent(event)
    XCTAssertFalse(isPlaying, "A second Space must pause the same editor transport")
  }

  func testSpaceRemainsTextInputWhenRenamingFile() throws {
    let state = VideoEditorState(url: testVideoURL)
    state.isRenamingFile = true
    let hostingView = NSHostingView(rootView: VideoEditorToolbarView(state: state))
    let window = VideoEditorWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 100)
    )
    window.onTogglePlayback = { state.togglePlayback() }
    window.contentView = hostingView
    window.makeKeyAndOrderFront(nil)
    defer { window.close() }

    hostingView.layoutSubtreeIfNeeded()
    let textField = try XCTUnwrap(firstTextField(in: hostingView))
    XCTAssertTrue(window.makeFirstResponder(textField))
    let event = try XCTUnwrap(NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: [],
      timestamp: 0,
      windowNumber: window.windowNumber,
      context: nil,
      characters: " ",
      charactersIgnoringModifiers: " ",
      isARepeat: false,
      keyCode: 49
    ))
    window.sendEvent(event)

    XCTAssertFalse(state.isPlaying, "Typing a space must not toggle playback")
  }

  func testСочетанияВидеоРедактораОбрабатываютРазрезаниеИПереходККадру() throws {
    let window = VideoEditorWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420))
    defer { window.close() }
    var actions: [VideoEditorShortcutAction] = []
    window.onEditorShortcut = { action, _ in
      actions.append(action)
      return true
    }

    let split = try keyEvent(for: window, keyCode: 11, text: "b", modifiers: [.command])
    let next = try keyEvent(for: window, keyCode: 124, text: "\u{F703}", modifiers: [.numericPad, .function])
    XCTAssertTrue(window.performKeyEquivalent(with: split))
    window.sendEvent(next)
    XCTAssertEqual(actions, [.splitClip, .nextFrame])
  }

  func testПереназначениеИЭкспортРаботаютВОкнеЗаписи() async throws {
    try skipIfRunningInCI("Требуется нативное окно редактора")
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Fixtures/Recording/quick-access-url.mp4")
    let settings = VideoEditorShortcutSettings.shared
    let originals = settings.shortcuts
    settings.resetToDefaults()
    let controller = VideoEditorWindowController(url: url)
    let window = try XCTUnwrap(controller.window as? VideoEditorWindow)
    let hosting = try XCTUnwrap(window.contentView as? NSHostingView<VideoEditorMainView>)
    let state = hosting.rootView.state
    defer {
      if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertThirdButtonReturn) }
      state.markAsSaved()
      window.close()
      settings.replaceShortcuts(with: originals)
    }

    controller.showWindow()
    await state.loadMetadata()
    XCTAssertEqual(state.clips.count, 1)

    state.seek(to: CMTime(seconds: 0.5, preferredTimescale: 600))
    let split = try keyEvent(for: window, keyCode: 11, text: "b", modifiers: [.command])
    window.sendEvent(split)
    XCTAssertEqual(state.clips.count, 2)

    let remap = ShortcutConfig(keyCode: 11, modifiers: ShortcutRecordingRules.carbonModifiers(from: .option))
    XCTAssertTrue(settings.setShortcut(remap, for: .splitClip))
    state.seek(to: CMTime(seconds: 1.3, preferredTimescale: 600))
    XCTAssertFalse(window.performKeyEquivalent(with: split))
    XCTAssertEqual(state.clips.count, 2)
    let remapped = try keyEvent(for: window, keyCode: 11, text: "b", modifiers: [.option])
    window.sendEvent(remapped)
    XCTAssertEqual(state.clips.count, 3)

    let export = try keyEvent(for: window, keyCode: 14, text: "e", modifiers: [.command])
    XCTAssertTrue(window.performKeyEquivalent(with: export))
    XCTAssertNotNil(window.attachedSheet)
  }

  private func keyEvent(
    for window: NSWindow, keyCode: UInt16, text: String, modifiers: NSEvent.ModifierFlags
  ) throws -> NSEvent {
    try XCTUnwrap(NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: modifiers,
      timestamp: 0,
      windowNumber: window.windowNumber,
      context: nil,
      characters: text,
      charactersIgnoringModifiers: text,
      isARepeat: false,
      keyCode: keyCode
    ))
  }

  private func firstTextField(in view: NSView) -> NSTextField? {
    if let textField = view as? NSTextField {
      return textField
    }

    for subview in view.subviews {
      if let textField = firstTextField(in: subview) {
        return textField
      }
    }

    return nil
  }
}
