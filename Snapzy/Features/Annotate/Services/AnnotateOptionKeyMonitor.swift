//
//  AnnotateOptionKeyMonitor.swift
//  Snapzy
//
//  Состояние Option для кнопки Save as… редактора.
//

import AppKit
import Combine

/// Option обходит диалог Save as (changelog CleanShot X 4.1): пока клавиша зажата,
/// кнопка называется Save и сохраняет в папку экспорта без диалога.
@MainActor
final class AnnotateOptionKeyMonitor: ObservableObject {
  static let shared = AnnotateOptionKeyMonitor()

  @Published private(set) var isOptionHeld = false
  private var monitor: Any?

  private init() {
    monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
      self?.update(flags: event.modifierFlags)
      return event
    }
    // Окно могло стать активным с уже зажатой клавишей.
    NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.update(flags: NSEvent.modifierFlags) }
    }
  }

  func update(flags: NSEvent.ModifierFlags) {
    let held = Self.isOptionHeld(flags)
    if held != isOptionHeld { isOptionHeld = held }
  }

  /// Только Option: с ⌘ или ⇧ работают свои сочетания.
  nonisolated static func isOptionHeld(_ flags: NSEvent.ModifierFlags) -> Bool {
    flags.intersection([.option, .command, .control, .shift]) == .option
  }

  static func saveButtonTitle(optionHeld: Bool) -> String {
    optionHeld ? L10n.Common.save : L10n.Common.saveAs
  }
}
