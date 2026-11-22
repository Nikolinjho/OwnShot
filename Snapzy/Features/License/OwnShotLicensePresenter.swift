//
//  OwnShotLicensePresenter.swift
//  Snapzy
//
//  Экраны заглушки лицензирования: alert'ы License Manager и Unlink Device,
//  окно активации и подтверждение выхода. Сети и хранения ключа нет.
//

import AppKit
import SwiftUI

@MainActor
final class OwnShotLicensePresenter {
  static let shared = OwnShotLicensePresenter()

  private var activationWindow: NSWindow?

  private init() {}

  var isActivationWindowVisible: Bool { activationWindow?.isVisible ?? false }

  // MARK: - About

  func showLicenseManager() {
    showPersonalBuildAlert(message: L10n.License.managerMessage)
  }

  func showUnlinkDevice() {
    showPersonalBuildAlert(message: L10n.License.unlinkMessage)
  }

  // MARK: - Активация

  func showActivationWindow() {
    // Тестовый хост не открывает окна и не забирает фокус.
    guard !AppLaunchPolicy().isRunningUnderXCTest else { return }
    let window: NSWindow
    if let existing = activationWindow {
      window = existing
    } else {
      window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 480, height: 150),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
      )
      window.title = L10n.License.activationWindowTitle
      window.isReleasedWhenClosed = false
      window.contentView = NSHostingView(rootView: OwnShotActivationView(
        onActivate: { [weak self] key in self?.activate(key: key) },
        onLostLicense: { [weak self] in self?.showPersonalBuildAlert(message: L10n.License.lostLicenseMessage) }
      ))
      window.center()
      activationWindow = window
    }
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  private func activate(key: String) {
    let alert = NSAlert()
    switch OwnShotLicense.activationOutcome(for: key) {
    case .invalidKey:
      alert.alertStyle = .warning
      alert.messageText = L10n.License.activationErrorTitle
      alert.informativeText = L10n.License.invalidKey
      alert.addButton(withTitle: L10n.Common.ok)
      runModal(alert)
    case .notCheckedPersonalBuild:
      alert.messageText = L10n.License.activationSuccessfulTitle
      alert.informativeText = "\(L10n.License.thankYou("OwnShot"))\n\n\(L10n.License.keyNotChecked)"
      alert.addButton(withTitle: L10n.License.doneButton)
      runModal(alert)
      activationWindow?.close()
    }
  }

  // MARK: - Выход

  /// Возвращает false, если пользователь отменил выход из окна активации.
  func confirmQuitIfNeeded() -> Bool {
    guard OwnShotLicense.shouldConfirmQuit(activationWindowVisible: isActivationWindowVisible) else { return true }
    let alert = NSAlert()
    alert.messageText = L10n.License.quitTitle
    alert.informativeText = L10n.License.quitMessage
    alert.addButton(withTitle: L10n.License.quitButton)
    alert.addButton(withTitle: L10n.License.cancelButton)
    return alert.runModal() == .alertFirstButtonReturn
  }

  // MARK: - Helpers

  private func showPersonalBuildAlert(message: String) {
    let alert = NSAlert()
    alert.messageText = L10n.License.personalBuildTitle
    alert.informativeText = message
    alert.addButton(withTitle: L10n.Common.ok)
    runModal(alert)
  }

  private func runModal(_ alert: NSAlert) {
    guard !AppLaunchPolicy().isRunningUnderXCTest else { return }
    NSApp.activate(ignoringOtherApps: true)
    alert.runModal()
  }
}

/// Окно активации. Раскладка повторяет окна Legit из эталона: иконка 64 pt слева,
/// справа заголовок, поле ключа и кнопки внизу.
private struct OwnShotActivationView: View {
  let onActivate: (String) -> Void
  let onLostLicense: () -> Void

  @State private var key = ""

  var body: some View {
    VStack(spacing: 16) {
      HStack(alignment: .top, spacing: 20) {
        Image(nsImage: NSApp.applicationIconImage)
          .resizable()
          .frame(width: 64, height: 64)

        VStack(alignment: .leading, spacing: 10) {
          Text(L10n.License.activationWindowTitle)
            .font(.system(size: 13, weight: .bold))
          TextField(L10n.License.keyPlaceholder, text: $key)
            .textFieldStyle(.roundedBorder)
            .onSubmit { onActivate(key) }
        }
      }

      HStack {
        Spacer()
        Button(L10n.License.lostLicenseButton, action: onLostLicense)
        Button(L10n.License.activateButton) { onActivate(key) }
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 480)
  }
}
