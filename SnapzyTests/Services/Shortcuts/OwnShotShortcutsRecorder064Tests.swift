//
//  OwnShotShortcutsRecorder064Tests.swift
//  SnapzyTests
//
//  Паритет spec-064 (SET-168): ⌫ во время записи показывает лист «Shortcut is reserved
//  for macOS», очистка – кнопкой (x) «Delete shortcut», «Use old shortcut» – только при
//  заданном сочетании. Замер эталона: evidence/spec-064-live/set168-*.
//

import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Snapzy

@MainActor
final class OwnShotShortcutsRecorder064Tests: XCTestCase {
  // MARK: - ⌫ во время записи

  func testDeleteБезМодификаторовЗарезервированСимволом() {
    XCTAssertEqual(ShortcutRecordingRules.reservedKeySymbol(keyCode: UInt16(kVK_Delete), modifiers: []), "⌫")
    // Caps Lock и Fn не меняют решения.
    XCTAssertEqual(ShortcutRecordingRules.reservedKeySymbol(keyCode: UInt16(kVK_Delete), modifiers: [.capsLock, .function]), "⌫")
  }

  func testDeleteСМодификаторомНеЗарезервирован() {
    XCTAssertNil(ShortcutRecordingRules.reservedKeySymbol(keyCode: UInt16(kVK_Delete), modifiers: [.command]))
    XCTAssertNil(ShortcutRecordingRules.reservedKeySymbol(keyCode: UInt16(kVK_Delete), modifiers: [.control, .shift]))
  }

  func testДругиеКлавишиНеЗарезервированы() {
    XCTAssertNil(ShortcutRecordingRules.reservedKeySymbol(keyCode: UInt16(kVK_ForwardDelete), modifiers: []))
    XCTAssertNil(ShortcutRecordingRules.reservedKeySymbol(keyCode: UInt16(kVK_Escape), modifiers: []))
    XCTAssertNil(ShortcutRecordingRules.reservedKeySymbol(keyCode: UInt16(kVK_ANSI_K), modifiers: [.control, .option]))
  }

  func testЛистТекстКакУЭталона() {
    let alert = ShortcutRecordingController.makeReservedKeyAlert(symbol: "⌫")
    XCTAssertEqual(alert.messageText, "Shortcut is reserved for macOS")
    XCTAssertEqual(alert.informativeText, "⌫ is used by macOS and cannot be assigned.")
    XCTAssertEqual(alert.buttons.map(\.title), ["OK"])
  }

  func testВТестовомХостеЛистНеПоказываетсяИЗаписьИдёт() {
    let controller = ShortcutRecordingController()
    controller.start { _ in }
    defer { controller.stop() }
    controller.presentReservedKeySheet(symbol: "⌫")
    XCTAssertFalse(controller.isShowingReservedKeySheet)
    XCTAssertTrue(controller.isRecording)
  }

  // MARK: - Кнопки поля во время записи

  func testПустоеПолеТолькоКнопкаDelete() {
    let buttons = ShortcutRecordingRules.recordingButtons(current: nil, defaultShortcut: nil)
    XCTAssertFalse(buttons.useOld)
    XCTAssertFalse(buttons.reset)
    XCTAssertTrue(buttons.delete)
  }

  func testЗаданноеСочетаниеUseOldИDelete() {
    let value = ShortcutConfig(keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(controlKey | optionKey | cmdKey))
    let buttons = ShortcutRecordingRules.recordingButtons(current: value, defaultShortcut: nil)
    XCTAssertTrue(buttons.useOld)
    XCTAssertFalse(buttons.reset)
    XCTAssertTrue(buttons.delete)
  }

  func testНедефолтноеСочетаниеПоказываетReset() {
    let defaultValue = ShortcutConfig(keyCode: UInt32(kVK_ANSI_4), modifiers: UInt32(cmdKey | shiftKey))
    let value = ShortcutConfig(keyCode: UInt32(kVK_ANSI_1), modifiers: UInt32(cmdKey | shiftKey))
    XCTAssertTrue(ShortcutRecordingRules.recordingButtons(current: value, defaultShortcut: defaultValue).reset)
    XCTAssertFalse(ShortcutRecordingRules.recordingButtons(current: defaultValue, defaultShortcut: defaultValue).reset)
  }

  func testТекстКнопкиDelete() {
    XCTAssertEqual(L10n.ShortcutRecorder.deleteShortcut, "Delete shortcut")
  }
}
