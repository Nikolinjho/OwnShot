//
//  QuickAccessPinMenuLayout.swift
//  Snapzy
//
//  Контекстное меню закреплённого скриншота: состав, порядок и клавиши как в CleanShot X.
//

import AppKit

enum QuickAccessPinMenuCommand: Hashable {
  case close
  case openAnnotation
  case copy
  case uploadToCloud
  case extractText
  case saveAs
  /// Заглушка Raycast AI Chat: только при установленном Raycast, без отправки.
  case sendToRaycastAIChat
  case lock
  case zoom(Int)
  case opacity(Int)
  case shadow
  case roundedCorners
  case border
}

enum QuickAccessPinMenuEntry: Equatable {
  case command(QuickAccessPinMenuCommand)
  /// Неактивный заголовок секции (Zoom, Opacity).
  case header(QuickAccessPinMenuHeader)
  case separator
}

enum QuickAccessPinMenuHeader: Equatable {
  case zoom
  case opacity
}

/// Клавиша пункта меню. Пустые модификаторы – клавиша без ⌘, как у Opacity.
struct QuickAccessPinMenuKey: Equatable {
  let key: String
  let modifiers: NSEvent.ModifierFlags

  static func command(_ key: String) -> QuickAccessPinMenuKey {
    QuickAccessPinMenuKey(key: key, modifiers: .command)
  }

  static func plain(_ key: String) -> QuickAccessPinMenuKey {
    QuickAccessPinMenuKey(key: key, modifiers: [])
  }
}

enum QuickAccessPinMenuLayout {
  static let zoomPercents = [50, 100, 200]
  static let opacityPercents = [20, 50, 100]

  /// Прозрачность заблокированного pin под курсором: в эталоне устоявшаяся alpha 64/255.
  static let lockedHoverOpacity: Double = 64.0 / 255.0

  static func entries(includesCloud: Bool, includesRaycast: Bool = false) -> [QuickAccessPinMenuEntry] {
    var entries: [QuickAccessPinMenuEntry] = [
      .command(.close),
      .separator,
      .command(.openAnnotation),
      .command(.copy),
    ]
    if includesCloud {
      entries.append(.command(.uploadToCloud))
    }
    entries += [
      .command(.extractText),
      .command(.saveAs),
    ]
    if includesRaycast {
      entries.append(.command(.sendToRaycastAIChat))
    }
    entries += [
      .separator,
      .command(.lock),
      .separator,
      .header(.zoom),
    ]
    entries += zoomPercents.map { .command(.zoom($0)) }
    entries += [.separator, .header(.opacity)]
    entries += opacityPercents.map { .command(.opacity($0)) }
    entries += [
      .separator,
      .command(.shadow),
      .command(.roundedCorners),
      .command(.border),
    ]
    return entries
  }

  /// Клавиши из снимка эталона. У Extract text, Zoom 50/200%, Shadow,
  /// Rounded Corners и Border клавиш нет.
  static func key(for command: QuickAccessPinMenuCommand) -> QuickAccessPinMenuKey? {
    switch command {
    case .close: return .command("w")
    case .openAnnotation: return .command("e")
    case .copy: return .command("c")
    case .uploadToCloud: return .command("u")
    case .saveAs: return .command("s")
    case .lock: return .command("l")
    case .zoom(100): return .command("0")
    case .opacity(20): return .plain("2")
    case .opacity(50): return .plain("5")
    case .opacity(100): return .plain("0")
    default: return nil
    }
  }

  /// Команда для нажатой клавиши, когда pin в фокусе.
  static func command(
    forCharacters characters: String?,
    modifiers: NSEvent.ModifierFlags,
    includesCloud: Bool
  ) -> QuickAccessPinMenuCommand? {
    guard let characters = characters?.lowercased(), !characters.isEmpty else { return nil }
    let relevant = modifiers.intersection([.command, .option, .control, .shift])
    let candidates = entries(includesCloud: includesCloud).compactMap { entry -> QuickAccessPinMenuCommand? in
      if case .command(let command) = entry { return command }
      return nil
    }
    return candidates.first { command in
      guard let key = key(for: command) else { return false }
      return key.key == characters && key.modifiers == relevant
    }
  }
}
