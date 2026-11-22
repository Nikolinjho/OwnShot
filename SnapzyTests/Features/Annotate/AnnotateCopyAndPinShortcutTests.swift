//
//  AnnotateCopyAndPinShortcutTests.swift
//  SnapzyTests
//
//  «Copy Screenshot to Clipboard» не закрывает редактор, «Pin to the Screen» без дефолта (паритет с CleanShot X).
//

import Carbon.HIToolbox
import XCTest
@testable import Snapzy

@MainActor
final class AnnotateCopyAndPinShortcutTests: XCTestCase {

  // MARK: - Copy Screenshot to Clipboard

  func testCopyShortcutKeepsEditorOpen() {
    XCTAssertFalse(AnnotateCopyCompletionPolicy.shouldClose(after: .shortcut))
    XCTAssertFalse(
      AnnotateCopyCompletionPolicy.shouldClose(userInfo: AnnotateCopyCompletionPolicy.userInfo(for: .shortcut))
    )
  }

  func testCopyButtonStillClosesEditor() {
    XCTAssertTrue(AnnotateCopyCompletionPolicy.shouldClose(after: .bottomBarButton))
    XCTAssertTrue(
      AnnotateCopyCompletionPolicy.shouldClose(userInfo: AnnotateCopyCompletionPolicy.userInfo(for: .bottomBarButton))
    )
  }

  func testCopyNotificationWithoutFlagClosesEditor() {
    XCTAssertTrue(AnnotateCopyCompletionPolicy.shouldClose(userInfo: nil))
    XCTAssertTrue(AnnotateCopyCompletionPolicy.shouldClose(userInfo: ["other": 1]))
  }

  func testCopyShortcutDefaultIsCommandShiftC() {
    XCTAssertEqual(
      AnnotateShortcutManager.defaultShortcut(for: .copyAndClose),
      ShortcutConfig(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(cmdKey | shiftKey))
    )
    XCTAssertEqual(AnnotateActionShortcutKind.copyAndClose.settingsTitle, "Copy Screenshot to Clipboard")
  }

  // MARK: - Pin to the Screen

  func testPinToScreenHasNoDefaultShortcut() {
    XCTAssertNil(AnnotateShortcutManager.defaultTogglePin)
    XCTAssertNil(AnnotateShortcutManager.defaultShortcut(for: .togglePin))
    XCTAssertEqual(AnnotateActionShortcutKind.togglePin.settingsTitle, "Pin to the Screen")
  }

  func testPinMigrationKeepsLegacyShortcutForExistingUserWithoutStoredValue() {
    XCTAssertEqual(
      AnnotateShortcutManager.togglePinMigrationValue(hasStoredValue: false, isExistingUser: true),
      ShortcutConfig(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(cmdKey | controlKey))
    )
  }

  func testPinMigrationLeavesNewUserWithoutShortcut() {
    XCTAssertNil(AnnotateShortcutManager.togglePinMigrationValue(hasStoredValue: false, isExistingUser: false))
  }

  func testPinMigrationDoesNotOverwriteStoredValue() {
    XCTAssertNil(AnnotateShortcutManager.togglePinMigrationValue(hasStoredValue: true, isExistingUser: true))
    XCTAssertNil(AnnotateShortcutManager.togglePinMigrationValue(hasStoredValue: true, isExistingUser: false))
  }

  func testResetToDefaultsClearsPinShortcut() {
    let manager = AnnotateShortcutManager.shared
    let original = manager.togglePinShortcut
    defer { manager.setTogglePinShortcut(original) }

    manager.setTogglePinShortcut(ShortcutConfig(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(cmdKey | optionKey)))
    manager.resetToDefaults()
    XCTAssertNil(manager.togglePinShortcut)
  }

  // MARK: - Copy и исходный файл

  func testCopyWritesOnlyOwnCaptureWithQuickAccessCard() {
    XCTAssertTrue(AnnotateWindowController.copyWritesSourceFile(quickAccessItemId: UUID()))
  }

  func testCopyKeepsExternallyOpenedFileUntouched() {
    // open-annotate, History и Open With открывают файл без карточки Quick Access
    XCTAssertFalse(AnnotateWindowController.copyWritesSourceFile(quickAccessItemId: nil))
  }
}
