//
//  OwnShotPersonalBuildStubs.swift
//  OwnShot
//
//  UI-заглушки личной сборки (решение владельца 14.11.2026): телеметрия
//  и Raycast AI Chat выглядят как в CleanShot X, но ничего не отправляют.
//

import AppKit

/// Переключатель «Share my usage statistics» в About. Значение хранится
/// только в UserDefaults, телеметрии у OwnShot нет.
nonisolated enum OwnShotUsageStatistics {
  /// Имя ключа как у эталона (analyticsAllowed).
  static let defaultsKey = "analyticsAllowed"

  /// Как у эталона, по умолчанию выключено.
  static func isAllowed(in defaults: UserDefaults = .standard) -> Bool {
    defaults.bool(forKey: defaultsKey)
  }

  static func setAllowed(_ allowed: Bool, in defaults: UserDefaults = .standard) {
    defaults.set(allowed, forKey: defaultsKey)
  }
}

/// Заглушка «Send to Raycast AI Chat». Как у эталона, пункты видны только
/// при установленном Raycast (в живом меню без Raycast пункта нет).
/// Действие ничего не передаёт и только сообщает, что интеграции нет.
nonisolated enum OwnShotRaycastStub {
  /// Bundle ID, по которым эталон ищет Raycast.
  static let bundleIdentifiers = ["com.raycast.macos", "com.raycast-x.macos"]

  /// Локальный поиск приложения через LaunchServices, без сети.
  static func isRaycastInstalled(
    lookup: (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
  ) -> Bool {
    bundleIdentifiers.contains { lookup($0) != nil }
  }

  /// Видимость пунктов определяется один раз за запуск, как у меню эталона.
  static let isMenuVisible: Bool = isRaycastInstalled()

  /// ⌘R в редакторе: changelog эталона 4.7.3.
  static func isSendShortcut(characters: String?, modifiers: NSEvent.ModifierFlags) -> Bool {
    modifiers.intersection(.deviceIndependentFlagsMask) == .command
      && characters?.lowercased() == "r"
  }

  /// Показывает сообщение вместо отправки и возвращает его текст.
  @MainActor
  @discardableResult
  static func send() -> String {
    let message = L10n.PersonalBuildStubs.raycastUnavailableMessage
    // Тестовый хост не открывает модальных окон.
    guard !AppLaunchPolicy().isRunningUnderXCTest else { return message }
    // Меню и клавиша успевают завершиться до модального alert'а.
    DispatchQueue.main.async {
      let alert = NSAlert()
      alert.messageText = L10n.PersonalBuildStubs.raycastUnavailableTitle
      alert.informativeText = message
      alert.addButton(withTitle: L10n.Common.ok)
      NSApp.activate(ignoringOtherApps: true)
      alert.runModal()
    }
    return message
  }
}
