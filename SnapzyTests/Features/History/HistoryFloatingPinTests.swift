//
//  HistoryFloatingPinTests.swift
//  SnapzyTests
//
//  Unit tests for History Floating Panel pin functionality (Issue #552).
//

import AppKit
import Carbon.HIToolbox
import SwiftUI
import XCTest
@testable import Snapzy

@MainActor
final class HistoryFloatingPinTests: XCTestCase {

  override func setUp() async throws {
    try await super.setUp()
    HistoryFloatingManager.shared.hide()
  }

  override func tearDown() async throws {
    HistoryFloatingManager.shared.hide()
    try await super.tearDown()
  }

  // MARK: - Manager Pin State

  func testInitialPinState_isFalse() {
    XCTAssertFalse(HistoryFloatingManager.shared.isPinned)
  }

  func testTogglePin_togglesState() {
    let manager = HistoryFloatingManager.shared
    XCTAssertFalse(manager.isPinned)

    manager.togglePin()
    XCTAssertTrue(manager.isPinned)

    manager.togglePin()
    XCTAssertFalse(manager.isPinned)
  }

  func testHide_resetsPinnedState() {
    let manager = HistoryFloatingManager.shared
    manager.togglePin()
    XCTAssertTrue(manager.isPinned)

    manager.hide()
    XCTAssertFalse(manager.isPinned)
  }

  func testПовторныйURLОставляетТоЖеЗакреплённоеОкноИстории() async throws {
    guard !NSScreen.screens.isEmpty else { throw XCTSkip("Тесту нужен оконный сервер") }
    let manager = HistoryFloatingManager.shared
    let previousEnabled = manager.isEnabled
    let previousSearch = manager.searchText
    let previousFilter = manager.expandedFilter
    let previousTimeFilter = manager.expandedTimeFilter
    let defaults = UserDefaults.standard
    let previousURLSetting = defaults.object(forKey: PreferencesKeys.urlSchemeEnabled)
    defaults.set(true, forKey: PreferencesKeys.urlSchemeEnabled)
    manager.isEnabled = false
    defer {
      manager.hide()
      manager.searchText = previousSearch
      manager.expandedFilter = previousFilter
      manager.expandedTimeFilter = previousTimeFilter
      manager.isEnabled = previousEnabled
      defaults.set(previousURLSetting, forKey: PreferencesKeys.urlSchemeEnabled)
    }
    try await waitForHistoryToClose(manager)
    let handler = SnapzyDeepLinkHandler(screenCaptureViewModel: ScreenCaptureViewModel())
    let url = try XCTUnwrap(URL(string: "ownshot://open-history"))
    handler.handle(url)

    let panel = try XCTUnwrap(NSApp.windows.compactMap { $0 as? HistoryFloatingPanel }.first { $0.isVisible })
    XCTAssertEqual(manager.presentationMode, .expanded)
    manager.togglePin()
    manager.searchText = "URL fixture"

    handler.handle(url)

    XCTAssertTrue(manager.isPinned)
    XCTAssertEqual(manager.presentationMode, .expanded)
    XCTAssertEqual(manager.searchText, "URL fixture")
    try await Task.sleep(for: .milliseconds(500))
    XCTAssertTrue(panel.isVisible)
    let current = NSApp.windows.compactMap { $0 as? HistoryFloatingPanel }.first { $0.isVisible }
    XCTAssertTrue(current === panel)

    guard panel.isVisible else { return }
    let content = try XCTUnwrap(panel.contentView)
    let theme = ThemeManager.shared
    let previousAppearance = theme.preferredAppearance
    defer { theme.preferredAppearance = previousAppearance }
    for (mode, appearance) in [(AppearanceMode.light, NSAppearance.Name.aqua), (.dark, .darkAqua)] {
      theme.preferredAppearance = mode
      try await Task.sleep(for: .milliseconds(150))
      XCTAssertEqual(content.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), appearance)
      content.layoutSubtreeIfNeeded()
      let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
      content.cacheDisplay(in: content.bounds, to: bitmap)
      let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
      attachment.name = "open-history-repeat-\(mode.rawValue)"
      attachment.lifetime = .keepAlways
      add(attachment)
    }
  }

  func testURLОткрываетКомпактнуюИсториюВоВремяОтложенногоСкрытия() async throws {
    guard !NSScreen.screens.isEmpty else { throw XCTSkip("Тесту нужен оконный сервер") }
    let manager = HistoryFloatingManager.shared
    let previousEnabled = manager.isEnabled
    let defaults = UserDefaults.standard
    let previousURLSetting = defaults.object(forKey: PreferencesKeys.urlSchemeEnabled)
    defaults.set(true, forKey: PreferencesKeys.urlSchemeEnabled)
    manager.isEnabled = true
    defer {
      manager.hide()
      manager.isEnabled = previousEnabled
      defaults.set(previousURLSetting, forKey: PreferencesKeys.urlSchemeEnabled)
    }
    try await waitForHistoryToClose(manager)
    let oldPanels = Set(NSApp.windows.compactMap { $0 as? HistoryFloatingPanel }.map(\.windowNumber))
    let handler = SnapzyDeepLinkHandler(screenCaptureViewModel: ScreenCaptureViewModel())
    let url = try XCTUnwrap(URL(string: "ownshot://open-history"))

    handler.handle(url)
    let panel = try XCTUnwrap(NSApp.windows.compactMap { $0 as? HistoryFloatingPanel }
      .first { $0.isVisible && !oldPanels.contains($0.windowNumber) })
    XCTAssertEqual(manager.presentationMode, .compact)
    manager.hide()
    handler.handle(url)

    try await Task.sleep(for: .milliseconds(500))
    XCTAssertTrue(panel.isVisible)
    XCTAssertEqual(manager.presentationMode, .compact)
  }

  func testHistoryПриСкрытииTopCenterДвижетсяВверхВWindowServer() async throws {
    try XCTSkipUnless(!NSScreen.screens.isEmpty, "Требуется оконный сервер")
    try XCTSkipIf(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, "Для направления требуется обычная анимация")
    struct Sample: Encodable {
      let milliseconds: Double
      let y: Double?
      let alpha: Double?
      let visible: Bool
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

    for mode in [HistoryFloatingPresentationMode.compact, .expanded] {
      let controller = HistoryFloatingPanelController()
      let layoutScreen = ScreenUtility.activeScreen()
      let scale = HistoryFloatingLayout.defaultScale
      let knownWindows = Set(NSApp.windows.compactMap { $0 as? HistoryFloatingPanel }.map(\.windowNumber))
      controller.show(
        Color.primary,
        size: HistoryFloatingLayout.panelSize(for: scale, mode: mode, on: layoutScreen),
        position: .topCenter,
        cornerRadius: HistoryFloatingLayout.cornerRadius(for: scale, mode: mode, on: layoutScreen),
        edgePadding: HistoryFloatingLayout.edgePadding(for: mode),
        anchorsToScreenEdges: mode == .compact
      )
      defer { controller.hide() }
      let panel = try XCTUnwrap(NSApp.windows.compactMap { $0 as? HistoryFloatingPanel }
        .first { $0.isVisible && !knownWindows.contains($0.windowNumber) })
      let windowID = try XCTUnwrap(CGWindowID(exactly: panel.windowNumber))
      var started = DispatchTime.now().uptimeNanoseconds
      func sample() -> Sample {
        let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]]
        let ownWindow = windows?.first { ($0[kCGWindowNumber as String] as? UInt32) == windowID }
        let bounds = (ownWindow?[kCGWindowBounds as String] as? NSDictionary).flatMap {
          CGRect(dictionaryRepresentation: $0 as CFDictionary)
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        return Sample(milliseconds: elapsed, y: bounds.map { Double($0.minY) },
          alpha: ownWindow?[kCGWindowAlpha as String] as? Double, visible: panel.isVisible)
      }
      let deadline = ContinuousClock.now + .seconds(2)
      var initial = sample()
      var opening = [initial]
      while initial.visible, (initial.alpha ?? 0) < 0.99, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(12))
        initial = sample()
        opening.append(initial)
      }
      guard initial.visible, (initial.alpha ?? 0) >= 0.99 else {
        XCTFail("WindowServer не подтвердил полностью видимую панель перед скрытием")
        return
      }
      // Прозрачность достигает 1 раньше завершения AppKit-анимации появления.
      try await Task.sleep(for: .milliseconds(140))
      let screen = try XCTUnwrap(panel.screen)
      let screens = NSScreen.screens.map(\.frame)
      let frame = panel.frame
      let screenTop = screen.frame.maxY
      let hasScreenAbove = screens.contains {
        $0 != screen.frame && $0.maxY > screenTop && $0.minY < screenTop + frame.height
          && $0.maxX > frame.minX && $0.minX < frame.maxX
      }
      let displayTop = Double(CGDisplayBounds(ScreenUtility.displayID(of: screen)).minY)
      started = DispatchTime.now().uptimeNanoseconds
      initial = sample()
      let startY = try XCTUnwrap(initial.y)
      controller.hide()

      var samples = [initial]
      let hideDeadline = ContinuousClock.now + .seconds(1)
      while panel.isVisible, ContinuousClock.now < hideDeadline {
        samples.append(sample())
        try await Task.sleep(for: .milliseconds(12))
      }
      samples.append(sample())
      let suffix = mode == .compact ? "compact" : "expanded"
      for (phase, frames) in [("show", opening), ("hide", samples)] {
        let attachment = XCTAttachment(data: try encoder.encode(frames), uniformTypeIdentifier: "public.json")
        attachment.name = "history-\(phase)-\(suffix)"
        attachment.lifetime = .keepAlways
        add(attachment)
      }
      let observedMotion = samples.filter(\.visible).compactMap(\.y)
      if !hasScreenAbove {
        XCTAssertTrue(observedMotion.contains { $0 < startY - 10 }, "Координата CG уменьшается при движении вверх")
      }
      XCTAssertTrue(observedMotion.allSatisfy { $0 <= startY + 2 })
      let crossedWhileVisible = samples.contains {
        $0.visible && ($0.alpha ?? 0) > 0.05 && ($0.y ?? .infinity) < displayTop - 1
      }
      print("QA-100 \(mode == .compact ? "compact" : "expanded") displays=\(screens.count) screenAbove=\(hasScreenAbove)")
      XCTAssertEqual(crossedWhileVisible, !hasScreenAbove)
      XCTAssertGreaterThanOrEqual(try XCTUnwrap(samples.last).milliseconds, 260,
        "Верхняя панель должна успеть плавно затухнуть")
      XCTAssertFalse(panel.isVisible)
      XCTAssertFalse(controller.isVisible)
    }
  }

  private func waitForHistoryToClose(_ manager: HistoryFloatingManager) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while manager.isVisible, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertFalse(manager.isVisible)
  }

  // MARK: - Panel Window Level

  func testPanelWindowLevel_elevatesWhenPinned() {
    let panel = HistoryFloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200))
    XCTAssertEqual(panel.level, .floating)

    panel.updateWindowLevel(isPinned: true)
    let expectedPinnedLevel = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
    XCTAssertEqual(panel.level, expectedPinnedLevel)

    // Higher than AnnotateWindow.activeEditorLevel (.floating + 1)
    let annotateActiveLevel = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
    XCTAssertGreaterThan(panel.level.rawValue, annotateActiveLevel.rawValue)

    panel.updateWindowLevel(isPinned: false)
    XCTAssertEqual(panel.level, .floating)
  }

  func testLocalArrowMonitorRoutesAppDispatchedPanelArrow() throws {
    let panel = HistoryFloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200))
    panel.makeKeyAndOrderFront(nil)
    panel.installLocalArrowEventMonitor()
    defer {
      panel.removeLocalArrowEventMonitor()
      panel.close()
    }

    XCTAssertTrue(panel.isKeyWindow)
    let expectation = expectation(forNotification: .historyMoveFocus, object: panel) { notification in
      notification.userInfo?["keyCode"] as? UInt16 == 124 &&
        notification.userInfo?["extendsSelection"] as? Bool == false
    }

    NSApp.sendEvent(
      try makeArrowEvent(
        keyCode: 124,
        modifiers: [.numericPad, .function],
        windowNumber: panel.windowNumber
      )
    )
    wait(for: [expectation], timeout: 1.0)
  }

  func testLocalArrowMonitorRoutesShiftAppDispatchedPanelArrow() throws {
    let panel = HistoryFloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200))
    panel.makeKeyAndOrderFront(nil)
    panel.installLocalArrowEventMonitor()
    defer {
      panel.removeLocalArrowEventMonitor()
      panel.close()
    }

    let expectation = expectation(forNotification: .historyMoveFocus, object: panel) { notification in
      notification.userInfo?["keyCode"] as? UInt16 == 125 &&
        notification.userInfo?["extendsSelection"] as? Bool == true
    }

    NSApp.sendEvent(
      try makeArrowEvent(
        keyCode: 125,
        modifiers: [.numericPad, .function, .shift],
        windowNumber: panel.windowNumber
      )
    )
    wait(for: [expectation], timeout: 1.0)
  }

  func testLocalArrowMonitorPassesSearchTextInputArrowThrough() throws {
    let panel = HistoryFloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200))
    panel.makeKeyAndOrderFront(nil)
    let searchField = NSSearchField(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
    searchField.stringValue = "abcdef"
    panel.contentView?.addSubview(searchField)
    XCTAssertTrue(panel.makeFirstResponder(searchField))
    let fieldEditor = try XCTUnwrap(searchField.currentEditor() as? NSTextView)
    XCTAssertTrue(panel.firstResponder === fieldEditor)
    fieldEditor.setSelectedRange(NSRange(location: 3, length: 0))
    panel.installLocalArrowEventMonitor()
    defer {
      panel.removeLocalArrowEventMonitor()
      panel.close()
    }

    NSApp.sendEvent(
      try makeArrowEvent(
        keyCode: 123,
        modifiers: [.numericPad, .function],
        windowNumber: panel.windowNumber
      )
    )

    XCTAssertEqual(fieldEditor.selectedRange().location, 2)
  }

  func testLocalArrowMonitorDoesNotRouteArrowTargetedAtAnotherWindow() throws {
    let panel = HistoryFloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200))
    let otherWindow = KeyableHistoryTestPanel(contentRect: NSRect(x: 300, y: 300, width: 100, height: 100))
    let otherWindowTextView = ArrowTrackingHistoryTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
    otherWindow.contentView?.addSubview(otherWindowTextView)
    panel.makeKeyAndOrderFront(nil)
    panel.installLocalArrowEventMonitor()
    otherWindow.makeKeyAndOrderFront(nil)
    defer {
      panel.removeLocalArrowEventMonitor()
      panel.close()
      otherWindow.close()
    }

    XCTAssertTrue(otherWindow.isKeyWindow)
    XCTAssertFalse(panel.isKeyWindow)
    XCTAssertTrue(otherWindow.makeFirstResponder(otherWindowTextView))
    XCTAssertTrue(otherWindow.firstResponder === otherWindowTextView)

    let unexpectedNotification = expectation(forNotification: .historyMoveFocus, object: panel, handler: nil)
    unexpectedNotification.isInverted = true

    NSApp.sendEvent(
      try makeArrowEvent(
        keyCode: 124,
        modifiers: [.numericPad, .function],
        windowNumber: otherWindow.windowNumber
      )
    )

    wait(for: [unexpectedNotification], timeout: 0.1)
    XCTAssertTrue(otherWindowTextView.didReceiveArrowKeyDown)
  }

  // MARK: - Shortcut Handling (⌘P)

  func testCmdPTogglesPin() {
    let manager = HistoryFloatingManager.shared
    let panel = HistoryFloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200))

    XCTAssertFalse(manager.isPinned)

    let event = NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: .command,
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      characters: "p",
      charactersIgnoringModifiers: "p",
      isARepeat: false,
      keyCode: 35
    )

    guard let event else {
      XCTFail("Failed to create Cmd+P event")
      return
    }

    let handled = panel.performKeyEquivalent(with: event)
    XCTAssertTrue(handled)
    XCTAssertTrue(manager.isPinned)

    let handledSecond = panel.performKeyEquivalent(with: event)
    XCTAssertTrue(handledSecond)
    XCTAssertFalse(manager.isPinned)
  }

  func testCmdP_ignoredWhenTextInputActive() {
    let manager = HistoryFloatingManager.shared
    let panel = HistoryFloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200))

    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 50, height: 50))
    panel.contentView?.addSubview(textView)
    let madeFirstResponder = panel.makeFirstResponder(textView)
    XCTAssertTrue(madeFirstResponder)

    XCTAssertFalse(manager.isPinned)

    let event = NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: .command,
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      characters: "p",
      charactersIgnoringModifiers: "p",
      isARepeat: false,
      keyCode: 35
    )

    guard let event else {
      XCTFail("Failed to create Cmd+P event")
      return
    }

    let handled = panel.performKeyEquivalent(with: event)
    XCTAssertFalse(handled)
    XCTAssertFalse(manager.isPinned)
  }

  // MARK: - Localization

  func testPinLocalizationKeys_existAndAreNonEmpty() {
    let pinTitle = L10n.PreferencesHistory.pinPanel
    let unpinTitle = L10n.PreferencesHistory.unpinPanel

    XCTAssertFalse(pinTitle.isEmpty)
    XCTAssertFalse(unpinTitle.isEmpty)
    XCTAssertTrue(pinTitle.contains("⌘P"))
    XCTAssertTrue(unpinTitle.contains("⌘P"))
  }

  private func makeArrowEvent(
    keyCode: UInt16,
    modifiers: NSEvent.ModifierFlags,
    windowNumber: Int
  ) throws -> NSEvent {
    let characters: String
    switch keyCode {
    case 123: characters = "\u{F702}"
    case 124: characters = "\u{F703}"
    case 125: characters = "\u{F701}"
    case 126: characters = "\u{F700}"
    default: throw XCTSkip("Expected an arrow key code, got \(keyCode)")
    }

    return try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: 0,
        windowNumber: windowNumber,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: keyCode
      )
    )
  }
}

@MainActor
private final class ArrowTrackingHistoryTextView: NSTextView {
  private(set) var didReceiveArrowKeyDown = false

  override func keyDown(with event: NSEvent) {
    if HistoryFloatingNavigationDirection(keyCode: event.keyCode) != nil {
      didReceiveArrowKeyDown = true
    }
    super.keyDown(with: event)
  }
}

@MainActor
private final class KeyableHistoryTestPanel: NSPanel {
  override var canBecomeKey: Bool { true }

  init(contentRect: NSRect) {
    super.init(
      contentRect: contentRect,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
  }
}
