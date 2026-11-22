//
//  QuickAccessBulkActions.swift
//  Snapzy
//
//  Save All и Close All для всех карточек Quick Access.
//

import AppKit
import Foundation

/// Ответ на диалог подтверждения Close All.
enum QuickAccessCloseAllDecision: Equatable {
  case close(suppressFutureConfirmation: Bool)
  case cancel
}

enum QuickAccessBulkActions {
  /// Как в CleanShot X: Save All и Close All есть в меню только при нескольких карточках.
  static func isAvailable(itemCount: Int) -> Bool {
    itemCount > 1
  }

  /// Несохранённые – карточки, чей файл ещё лежит во временной папке захвата.
  /// Импортированные файлы уже на диске, обрабатываемые и сохраняемые сейчас пропускаем.
  static func unsavedItemIDs(
    in items: [QuickAccessItem],
    isTemporary: (URL) -> Bool,
    excluding busyIDs: Set<UUID> = []
  ) -> [UUID] {
    items
      .filter { !$0.processingState.isProcessing && !busyIDs.contains($0.id) && isTemporary($0.url) }
      .map(\.id)
  }
}

/// Запоминает выбор Don't ask for confirmation для Close All.
struct QuickAccessCloseAllConfirmation {
  static let skipConfirmationKey = "ownshot.quickAccess.closeAllSkipConfirmation"

  let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  var requiresPrompt: Bool {
    !defaults.bool(forKey: Self.skipConfirmationKey)
  }

  /// Показывает диалог, если пользователь не отключил подтверждение.
  /// Флажок запоминается только вместе с Close All: Cancel ничего не сохраняет.
  func shouldClose(prompt: () -> QuickAccessCloseAllDecision) -> Bool {
    guard requiresPrompt else { return true }
    switch prompt() {
    case .close(let suppressFutureConfirmation):
      if suppressFutureConfirmation {
        defaults.set(true, forKey: Self.skipConfirmationKey)
      }
      return true
    case .cancel:
      return false
    }
  }
}

/// Нативный alert подтверждения Close All.
@MainActor
enum QuickAccessCloseAllAlert {
  static func run() -> QuickAccessCloseAllDecision {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = L10n.QuickAccess.closeAllConfirmTitle
    alert.informativeText = L10n.QuickAccess.closeAllConfirmMessage
    alert.showsSuppressionButton = true
    alert.suppressionButton?.title = L10n.QuickAccess.closeAllConfirmSuppression
    alert.suppressionButton?.state = .off

    let closeButton = alert.addButton(withTitle: L10n.QuickAccess.closeAllConfirmButton)
    closeButton.hasDestructiveAction = true
    alert.addButton(withTitle: L10n.Common.cancel)

    // Панель Quick Access висит очень высоко, alert должен быть над ней.
    alert.window.level = NSWindow.Level(rawValue: QuickAccessLayout.alertWindowLevel)
    NSApp.activate(ignoringOtherApps: true)

    guard alert.runModal() == .alertFirstButtonReturn else { return .cancel }
    return .close(suppressFutureConfirmation: alert.suppressionButton?.state == .on)
  }
}

// MARK: - Localization

extension L10n.QuickAccess {
  static let saveAll = L10n.string(
    "quick-access.save-all",
    defaultValue: "Save All...",
    comment: "Quick Access context menu item that saves every unsaved card"
  )
  static let closeAll = L10n.string(
    "quick-access.close-all",
    defaultValue: "Close All...",
    comment: "Quick Access context menu item that closes every card"
  )
  static let closeAllConfirmTitle = L10n.string(
    "quick-access.close-all.confirm-title",
    defaultValue: "Do you want to close all overlays?",
    comment: "Close All confirmation alert title"
  )
  static let closeAllConfirmMessage = L10n.string(
    "quick-access.close-all.confirm-message",
    defaultValue: "Your media will be lost if you didn't save it.",
    comment: "Close All confirmation alert message"
  )
  static let closeAllConfirmSuppression = L10n.string(
    "quick-access.close-all.confirm-suppression",
    defaultValue: "Don't ask for confirmation",
    comment: "Close All confirmation alert checkbox that skips the alert next time"
  )
  static let closeAllConfirmButton = L10n.string(
    "quick-access.close-all.confirm-button",
    defaultValue: "Close All",
    comment: "Close All confirmation alert destructive button"
  )
}
