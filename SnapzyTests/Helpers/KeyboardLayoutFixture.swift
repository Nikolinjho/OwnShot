//
//  KeyboardLayoutFixture.swift
//  SnapzyTests
//
//  Подменяет источник раскладки для подписей клавиш, чтобы тесты не зависели
//  от раскладки, активной на машине.
//

import Carbon.HIToolbox
import XCTest
@testable import Snapzy

@MainActor
enum KeyboardLayoutFixture {
  /// Ставит раскладку US и возвращает её обратно после теста.
  static func useUSLayout(in testCase: XCTestCase) throws {
    let us = try inputSource(id: "com.apple.keylayout.US")
    replaceLayoutSource(in: testCase) { us }
  }

  /// Имитирует систему с активной раскладкой `currentID` и ASCII-совместимой `asciiCapableID`:
  /// подпись строится тем же выбором раскладки, что и в приложении.
  static func useSystemLayouts(
    currentID: String,
    asciiCapableID: String?,
    in testCase: XCTestCase
  ) throws {
    let current = try inputSource(id: currentID)
    let asciiCapable = try asciiCapableID.map { try inputSource(id: $0) }
    replaceLayoutSource(in: testCase) {
      ShortcutConfig.asciiCapableLayoutInputSource(current: current, asciiCapable: asciiCapable)
    }
  }

  static func inputSource(id: String) throws -> TISInputSource {
    let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
    let sources = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource]
    guard let source = sources?.first else {
      throw XCTSkip("В системе нет раскладки \(id)")
    }
    return source
  }

  private static func replaceLayoutSource(
    in testCase: XCTestCase,
    with source: @escaping () -> TISInputSource?
  ) {
    let original = ShortcutConfig.keyboardLayoutInputSource
    ShortcutConfig.keyboardLayoutInputSource = source
    testCase.addTeardownBlock { @MainActor in
      ShortcutConfig.keyboardLayoutInputSource = original
    }
  }
}
