//
//  OwnShotOnboardingWindowController.swift
//  Snapzy
//
//  Окно онбординга OwnShot (у эталона CleanShot_X.Onboarding: NSWindowController со слайдами).
//  Открывается при первом запуске вместо Settings › Permissions и по .showOnboarding.
//

import AppKit
import SwiftUI

@MainActor
final class OwnShotOnboardingWindowController: NSObject, NSWindowDelegate {
  static let shared = OwnShotOnboardingWindowController()

  static let contentSize = NSSize(width: 620, height: 460)

  private var window: NSWindow?
  private var model: OwnShotOnboardingModel?

  var isVisible: Bool { window?.isVisible ?? false }

  /// Под XCTest и без экранов окно не создаётся: модальные окна в тестовом хосте запрещены.
  func show(launchPolicy: AppLaunchPolicy = AppLaunchPolicy()) {
    guard launchPolicy.shouldStartInteractiveApplication else {
      DiagnosticLogger.shared.log(.debug, .ui, "Onboarding window skipped in non-interactive host")
      return
    }

    if let window {
      NSApp.activate(ignoringOtherApps: true)
      window.makeKeyAndOrderFront(nil)
      return
    }

    let model = OwnShotOnboardingModel(actions: OwnShotOnboardingLiveActions()) { [weak self] in
      self?.close()
    }
    self.model = model

    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: Self.contentSize),
      styleMask: [.titled, .closable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.title = L10n.OwnShotOnboarding.windowTitle
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.isMovableByWindowBackground = true
    window.isReleasedWhenClosed = false
    window.delegate = self
    window.contentView = NSHostingView(rootView: OwnShotOnboardingView(model: model))
    window.center()
    self.window = window

    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    DiagnosticLogger.shared.log(.info, .ui, "Onboarding window shown")
  }

  func close() {
    window?.close()
  }

  // MARK: - NSWindowDelegate

  func windowWillClose(_ notification: Notification) {
    let closingWindow = notification.object as? NSWindow
    window = nil
    model = nil
    NSApp.revertActivationPolicyToAccessoryIfNeeded(excluding: closingWindow)
    DiagnosticLogger.shared.log(.info, .ui, "Onboarding window closed")
  }
}
