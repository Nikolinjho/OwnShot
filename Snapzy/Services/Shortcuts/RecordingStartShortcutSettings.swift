//
//  RecordingStartShortcutSettings.swift
//  Snapzy
//
//  Клавиши запуска записи из панели перед стартом: Start Video Recording (⏎)
//  и Start GIF Recording (⌥⏎), как в Settings → Shortcuts у CleanShot X.
//

import AppKit
import Carbon.HIToolbox
import Foundation

enum RecordingStartShortcutKind: String, CaseIterable {
  case video
  case gif

  var settingsTitle: String {
    switch self {
    case .video: return "Start Video Recording"
    case .gif: return "Start GIF Recording"
    }
  }

  var outputMode: RecordingOutputMode {
    switch self {
    case .video: return .video
    case .gif: return .gif
    }
  }

  var defaultShortcut: ShortcutConfig {
    switch self {
    case .video: return ShortcutConfig(keyCode: UInt32(kVK_Return), modifiers: 0)
    case .gif: return ShortcutConfig(keyCode: UInt32(kVK_Return), modifiers: UInt32(optionKey))
    }
  }

  fileprivate var defaultsKey: String { "recordingStart.\(rawValue)Shortcut" }
}

enum RecordingStartShortcutSettings {
  /// Подмена для тестов.
  static var defaults: UserDefaults = .standard
  private static let explicitEmptyShortcutData = Data("null".utf8)

  static func shortcut(for kind: RecordingStartShortcutKind) -> ShortcutConfig? {
    guard let data = defaults.data(forKey: kind.defaultsKey) else { return kind.defaultShortcut }
    if data == explicitEmptyShortcutData { return nil }
    return (try? JSONDecoder().decode(ShortcutConfig.self, from: data)) ?? kind.defaultShortcut
  }

  static func setShortcut(_ config: ShortcutConfig?, for kind: RecordingStartShortcutKind) {
    guard let config else {
      defaults.set(explicitEmptyShortcutData, forKey: kind.defaultsKey)
      return
    }
    guard let data = try? JSONEncoder().encode(config) else { return }
    defaults.set(data, forKey: kind.defaultsKey)
  }

  static func reset(_ kind: RecordingStartShortcutKind) {
    defaults.removeObject(forKey: kind.defaultsKey)
  }

  /// Какой режим записи запускает клавиша. GIF проверяется первым: его сочетание шире.
  /// Return и Enter на цифровом блоке считаются одной клавишей, Fn не учитывается.
  static func outputMode(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> RecordingOutputMode? {
    for kind in [RecordingStartShortcutKind.gif, .video] {
      guard let config = shortcut(for: kind) else { continue }
      if matches(config, keyCode: keyCode, modifiers: modifiers) { return kind.outputMode }
    }
    return nil
  }

  static func matches(_ config: ShortcutConfig, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
    guard normalizedKeyCode(UInt32(keyCode)) == normalizedKeyCode(config.keyCode) else { return false }
    var carbon: UInt32 = 0
    if modifiers.contains(.command) { carbon |= UInt32(cmdKey) }
    if modifiers.contains(.shift) { carbon |= UInt32(shiftKey) }
    if modifiers.contains(.option) { carbon |= UInt32(optionKey) }
    if modifiers.contains(.control) { carbon |= UInt32(controlKey) }
    let expected = config.modifiers & ~ShortcutConfig.functionCarbonModifier
    return carbon == expected
  }

  private static func normalizedKeyCode(_ keyCode: UInt32) -> UInt32 {
    keyCode == UInt32(kVK_ANSI_KeypadEnter) ? UInt32(kVK_Return) : keyCode
  }
}
