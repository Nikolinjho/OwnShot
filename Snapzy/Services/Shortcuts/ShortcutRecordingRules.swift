//
//  ShortcutRecordingRules.swift
//  Snapzy
//
//  Правила записи сочетания, общие для всех рекордеров страницы Shortcuts:
//  Escape отменяет запись и оставляет старое сочетание, Delete очищает его,
//  клик мимо поля отменяет запись. Поведение как у рекордера CleanShot X.
//

import AppKit
import Carbon.HIToolbox
import Foundation

/// Что сделать с нажатием во время записи.
enum ShortcutRecordingDecision: Equatable {
  /// Остановить запись, сочетание не менять.
  case cancel
  /// Очистить сочетание.
  case clear
  /// Записать новое сочетание.
  case record(ShortcutConfig)
  /// Продолжить ждать (например, буква без модификатора там, где он обязателен).
  case ignore
}

enum ShortcutRecordingRules {
  /// Модификаторы, которые учитываются при записи (без Caps Lock и цифрового блока).
  static let recordableModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift, .function]

  static func decision(
    keyCode: UInt16,
    modifiers rawModifiers: NSEvent.ModifierFlags,
    allowsSingleKey: Bool
  ) -> ShortcutRecordingDecision {
    let modifiers = rawModifiers.intersection(recordableModifiers)
    // Escape без модификаторов — «Use old shortcut» эталона.
    if Int(keyCode) == kVK_Escape, modifiers.subtracting(.function).isEmpty {
      return .cancel
    }
    // Delete и Forward Delete без модификаторов очищают сочетание; переключатель строки не трогаем.
    if Int(keyCode) == kVK_Delete || Int(keyCode) == kVK_ForwardDelete,
       modifiers.subtracting(.function).isEmpty {
      return .clear
    }
    let carbon = carbonModifiers(from: modifiers)
    if carbon != 0 {
      return .record(ShortcutConfig(keyCode: UInt32(keyCode), modifiers: carbon))
    }
    if allowsSingleKey {
      return .record(ShortcutConfig(keyCode: UInt32(keyCode), modifiers: 0))
    }
    return .ignore
  }

  /// Клавиша, которую рекордер Settings эталона не назначает: ⌫ без модификаторов.
  /// Эталон не очищает сочетание, а показывает лист «Shortcut is reserved for macOS» /
  /// «⌫ is used by macOS and cannot be assigned.» с кнопкой OK и продолжает запись
  /// (live 064, evidence/spec-064-live/set168-*). Возвращает символ клавиши для текста листа.
  static func reservedKeySymbol(keyCode: UInt16, modifiers rawModifiers: NSEvent.ModifierFlags) -> String? {
    let modifiers = rawModifiers.intersection(recordableModifiers).subtracting(.function)
    guard Int(keyCode) == kVK_Delete, modifiers.isEmpty else { return nil }
    return ShortcutConfig.keyCodeToString(UInt32(keyCode))
  }

  /// Кнопки поля во время записи в Settings, как у эталона: «Use old shortcut» – только при
  /// заданном сочетании, «Delete shortcut» (x) – всегда; Reset to default – если сочетание не дефолтное.
  static func recordingButtons(
    current: ShortcutConfig?,
    defaultShortcut: ShortcutConfig?
  ) -> (useOld: Bool, reset: Bool, delete: Bool) {
    (
      useOld: current != nil,
      reset: defaultShortcut != nil && current != defaultShortcut,
      delete: true
    )
  }

  /// Клик вне поля записи (и его кнопок) отменяет запись.
  /// `location` и `recorderFrame` — в одной системе координат окна.
  static func shouldCancelOnClick(at location: CGPoint, recorderFrame: CGRect) -> Bool {
    guard !recorderFrame.isEmpty else { return true }
    return !recorderFrame.contains(location)
  }

  /// Перевод точки события (начало координат снизу) в координаты SwiftUI `.global` (сверху).
  static func topLeftPoint(fromWindowPoint point: CGPoint, contentHeight: CGFloat) -> CGPoint {
    CGPoint(x: point.x, y: contentHeight - point.y)
  }

  /// Модификаторы, удерживаемые во время записи, — для подсказки в поле.
  static func heldModifierSymbols(_ rawModifiers: NSEvent.ModifierFlags) -> String {
    let modifiers = rawModifiers.intersection(recordableModifiers)
    var symbols = ""
    if modifiers.contains(.function) { symbols += "fn" }
    if modifiers.contains(.control) { symbols += "⌃" }
    if modifiers.contains(.option) { symbols += "⌥" }
    if modifiers.contains(.shift) { symbols += "⇧" }
    if modifiers.contains(.command) { symbols += "⌘" }
    return symbols
  }

  static func carbonModifiers(from modifiers: NSEvent.ModifierFlags) -> UInt32 {
    var carbon: UInt32 = 0
    if modifiers.contains(.command) { carbon |= UInt32(cmdKey) }
    if modifiers.contains(.shift) { carbon |= UInt32(shiftKey) }
    if modifiers.contains(.option) { carbon |= UInt32(optionKey) }
    if modifiers.contains(.control) { carbon |= UInt32(controlKey) }
    if modifiers.contains(.function) { carbon |= ShortcutConfig.functionCarbonModifier }
    return carbon
  }
}

extension ShortcutConfig {
  /// Сочетание одной строкой в порядке меню macOS (⌃⌥⇧⌘), как в текстах эталона: «⇧⌘1».
  var menuSymbolString: String {
    var symbols = ""
    if modifiers & Self.functionCarbonModifier != 0 { symbols += "fn" }
    if modifiers & UInt32(controlKey) != 0 { symbols += "⌃" }
    if modifiers & UInt32(optionKey) != 0 { symbols += "⌥" }
    if modifiers & UInt32(shiftKey) != 0 { symbols += "⇧" }
    if modifiers & UInt32(cmdKey) != 0 { symbols += "⌘" }
    return symbols + Self.keyCodeToDisplayString(keyCode)
  }
}
