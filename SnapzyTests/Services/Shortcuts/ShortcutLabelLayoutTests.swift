//
//  ShortcutLabelLayoutTests.swift
//  SnapzyTests
//
//  Подписи сочетаний латиницей при не-ASCII раскладке, как у эталона (⌃⌘P, ⇧⌘C).
//

import Carbon.HIToolbox
import XCTest
@testable import Snapzy

@MainActor
final class ShortcutLabelLayoutTests: XCTestCase {
  private let russianID = "com.apple.keylayout.Russian"
  private let usID = "com.apple.keylayout.US"

  func testRussianLayout_isNotASCIICapable() throws {
    let russian = try KeyboardLayoutFixture.inputSource(id: russianID)
    XCTAssertFalse(ShortcutConfig.isASCIICapable(russian))
    XCTAssertTrue(ShortcutConfig.isASCIICapable(try KeyboardLayoutFixture.inputSource(id: usID)))
  }

  func testNonASCIILayout_choosesASCIICapableSource() throws {
    let russian = try KeyboardLayoutFixture.inputSource(id: russianID)
    let us = try KeyboardLayoutFixture.inputSource(id: usID)
    let chosen = ShortcutConfig.asciiCapableLayoutInputSource(current: russian, asciiCapable: us)
    XCTAssertTrue(chosen === us)
  }

  func testNonASCIILayout_withoutASCIICapable_fallsBackToUS() throws {
    let russian = try KeyboardLayoutFixture.inputSource(id: russianID)
    let chosen = try XCTUnwrap(
      ShortcutConfig.asciiCapableLayoutInputSource(current: russian, asciiCapable: nil)
    )
    let id = TISGetInputSourceProperty(chosen, kTISPropertyInputSourceID)
      .map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String }
    XCTAssertEqual(id, usID)
  }

  func testASCIICapableLayout_isKeptAsIs() throws {
    let us = try KeyboardLayoutFixture.inputSource(id: usID)
    let chosen = ShortcutConfig.asciiCapableLayoutInputSource(current: us, asciiCapable: nil)
    XCTAssertTrue(chosen === us)
  }

  func testRussianLayout_shortcutLabelsAreLatin() throws {
    try KeyboardLayoutFixture.useSystemLayouts(currentID: russianID, asciiCapableID: usID, in: self)

    let pin = ShortcutConfig(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(cmdKey | controlKey))
    let copy = ShortcutConfig(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(cmdKey | shiftKey))

    XCTAssertEqual(pin.displayString, "⌘ ⌃ P")
    XCTAssertEqual(copy.displayString, "⌘ ⇧ C")
    XCTAssertEqual(copy.displayParts, ["⌘", "⇧", "C"])
    XCTAssertEqual(pin.menuKeyEquivalent, "p")
    XCTAssertEqual(ShortcutConfig.keyCodeToDisplayString(UInt32(kVK_ANSI_Comma)), ",")
    XCTAssertEqual(
      CaptureOverlayShortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: 0).displayString,
      "A"
    )
  }
}
