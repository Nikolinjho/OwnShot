//
//  ScreenRecordingPermissionAlert.swift
//  Snapzy
//
//  Alert отказа в Screen Recording с текстами эталона.
//

import AppKit

@MainActor
enum ScreenRecordingPermissionAlert {
  struct Content: Equatable {
    let title: String
    let message: String
    let buttons: [String]
  }

  static var content: Content {
    Content(
      title: L10n.ScreenRecordingPermissionAlert.title,
      message: L10n.ScreenRecordingPermissionAlert.message,
      buttons: [L10n.Common.openSystemSettings, L10n.Common.cancel]
    )
  }

  /// Возвращает true, если нажата Open System Settings. В тестах alert не показывается.
  @discardableResult
  static func present() -> Bool {
    guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return false }
    let content = content
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = content.title
    alert.informativeText = content.message
    content.buttons.forEach { alert.addButton(withTitle: $0) }
    NSApp.activate(ignoringOtherApps: true)
    return alert.runModal() == .alertFirstButtonReturn
  }
}
