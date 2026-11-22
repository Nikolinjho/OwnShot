//
//  AnnotateShortcutManagerTests.swift
//  SnapzyTests
//
//  Unit tests for AnnotateShortcutManager lookup, conflict detection, and enable/disable.
//

import XCTest
@testable import Snapzy

@MainActor
final class AnnotateShortcutManagerTests: XCTestCase {

  private var manager: AnnotateShortcutManager!

  override func setUp() async throws {
    try await super.setUp()
    manager = AnnotateShortcutManager.shared
    manager.resetToDefaults()
  }

  override func tearDown() async throws {
    manager.resetToDefaults()
    try await super.tearDown()
  }

  // MARK: - Lookup

  func testToolForKey_findsMappedTool() {
    manager.setShortcut("r", for: .rectangle)
    XCTAssertEqual(manager.tool(for: "r"), .rectangle)
  }

  func testToolForKey_findsMappedNumericKey() {
    manager.setShortcut("1", for: .rectangle)
    XCTAssertEqual(manager.tool(for: "1"), .rectangle)
  }

  func testToolForKey_returnsNilForUnmappedKey() {
    XCTAssertNil(manager.tool(for: "z"))
  }

  func testShortcutForTool_returnsSetValue() {
    manager.setShortcut("t", for: .text)
    XCTAssertEqual(manager.shortcut(for: .text), "t")
  }

  // MARK: - Enable / Disable

  func testIsShortcutEnabled_defaultIsTrue() {
    XCTAssertTrue(manager.isShortcutEnabled(for: .rectangle))
  }

  func testSetShortcutEnabled_disablesAndEnables() {
    manager.setShortcutEnabled(false, for: .rectangle)
    XCTAssertFalse(manager.isShortcutEnabled(for: .rectangle))

    manager.setShortcutEnabled(true, for: .rectangle)
    XCTAssertTrue(manager.isShortcutEnabled(for: .rectangle))
  }

  func testToolForKey_skipsDisabledShortcuts() {
    manager.setShortcut("r", for: .rectangle)
    manager.setShortcutEnabled(false, for: .rectangle)
    XCTAssertNil(manager.tool(for: "r"))
  }

  // MARK: - Conflicts

  func testConflictingTool_findsConflict() {
    manager.setShortcut("z", for: .rectangle)
    manager.setShortcut("z", for: .oval)
    XCTAssertEqual(manager.conflictingTool(for: "z", excluding: .oval), .rectangle)
  }

  func testConflictingTool_findsNumericConflict() {
    manager.setShortcut("2", for: .rectangle)
    manager.setShortcut("2", for: .oval)
    XCTAssertEqual(manager.conflictingTool(for: "2", excluding: .oval), .rectangle)
  }

  func testConflictingTool_excludesSelf() {
    manager.setShortcut("z", for: .rectangle)
    XCTAssertNil(manager.conflictingTool(for: "z", excluding: .rectangle))
  }

  func testConflictingTool_ignoresDisabledTools() {
    manager.setShortcut("z", for: .rectangle)
    manager.setShortcutEnabled(false, for: .rectangle)
    manager.setShortcut("z", for: .oval)
    XCTAssertNil(manager.conflictingTool(for: "z", excluding: .oval))
  }

  // MARK: - Reset

  func testResetToDefaults_restoresDefaults() {
    manager.setShortcut("z", for: .rectangle)
    manager.setShortcutEnabled(false, for: .rectangle)
    manager.resetToDefaults()
    XCTAssertEqual(manager.shortcut(for: .rectangle), AnnotationToolType.rectangle.defaultShortcut)
    XCTAssertTrue(manager.isShortcutEnabled(for: .rectangle))
  }

  // MARK: - Action Shortcuts

  func testActionShortcutEnabled_defaultIsTrue() {
    XCTAssertTrue(manager.isActionShortcutEnabled(for: .copyAndClose))
  }

  func testSetActionShortcutEnabled_toggles() {
    manager.setActionShortcutEnabled(false, for: .copyAndClose)
    XCTAssertFalse(manager.isActionShortcutEnabled(for: .copyAndClose))
    manager.setActionShortcutEnabled(true, for: .copyAndClose)
    XCTAssertTrue(manager.isActionShortcutEnabled(for: .copyAndClose))
  }

  func testShortcutForAction_returnsConfig() {
    XCTAssertNotNil(manager.shortcut(for: .copyAndClose))
    XCTAssertNotNil(manager.shortcut(for: .toggleSidebar))
  }

  func testAutoRedactSensitiveDataShortcut_defaultsToUnsetButEnabled() {
    XCTAssertNil(manager.shortcut(for: .autoRedactSensitiveData))
    XCTAssertTrue(manager.isActionShortcutEnabled(for: .autoRedactSensitiveData))
  }

  func testSpotlightShortcut_isConfigurableAndMappable() {
    XCTAssertTrue(AnnotateShortcutManager.configurableTools.contains(.spotlight))
    XCTAssertEqual(manager.shortcut(for: .spotlight), "h")

    manager.setShortcut("z", for: .spotlight)
    XCTAssertEqual(manager.shortcut(for: .spotlight), "z")
    XCTAssertEqual(manager.tool(for: "z"), .spotlight)
  }
}

@MainActor
final class OwnShotNavigationAndDefaultsTests: XCTestCase {
  func testРазделыНастроекСледуютПорядкуЭталона() {
    XCTAssertEqual(PreferencesTab.sidebarOrder.map(\.rawValue), ["general", "shortcuts", "quickAccess", "wallpaper", "capture", "recording", "annotate", "cloud", "advanced", "about"])
  }
  func testРазметкаИспользуетКлавишиЭталонаБезКонфликтов() {
    let expected: [AnnotationToolType: Character] = [.crop: "k", .oval: "e", .highlighter: "m", .blur: "p", .spotlight: "h", .counter: "c", .pencil: "d"]
    for (tool, key) in expected { XCTAssertEqual(tool.defaultShortcut, key) }
    XCTAssertEqual(AnnotateShortcutManager.defaultToggleSidebar.keyCode, 11)
    XCTAssertEqual(AnnotateShortcutManager.defaultToggleSidebar.modifiers, 0)
    let keys = AnnotationToolType.allCases.map(\.defaultShortcut)
    XCTAssertEqual(Set(keys).count, keys.count)
  }
  func testВложенныеНастройкиСохраняютИсториюНавигации() {
    let state = PreferencesNavigationState(initialTab: .advanced)
    state.select(.permissions)
    state.goBack()
    XCTAssertEqual(state.selectedTab, .advanced)
    state.goForward()
    XCTAssertEqual(state.selectedTab, .permissions)
  }
}


@MainActor
final class OwnShotShutterSoundTests: XCTestCase {
  func testВыбранныйЗвукЗатвораЧитаетсяИзСохранённыхНастроек() {
    let name = "ownshot.shutter.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    XCTAssertEqual(SoundManager.selectedScreenshotSound(defaults: defaults), "System Default")
    defaults.set("Pop", forKey: SoundManager.screenshotSoundKey)
    XCTAssertEqual(SoundManager.selectedScreenshotSound(defaults: defaults), "Pop")
    defaults.set("Missing Sound", forKey: SoundManager.screenshotSoundKey)
    XCTAssertEqual(SoundManager.selectedScreenshotSound(defaults: defaults), "System Default")
  }
}
