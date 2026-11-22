//
//  QuickAccessHoverShortcutRegistry.swift
//  Snapzy
//
//  Routes Quick Access card action shortcuts only while the pointer is over a
//  card, with exact key/modifier matching.
//
//  The Quick Access panel is a non-activating panel (`canBecomeKey == false`), so
//  keyboard events never route to it — the frontmost app owns the keyboard while
//  the user hovers a card. The previous Carbon path consumed registered card
//  events by action ID without an application-level exact-match/pass-through
//  gate. The event-tap path below sees the complete event and consumes only an
//  exact registered binding. When Accessibility is unavailable, the passive
//  monitor fallback never consumes events; external-app delivery and action
//  triggering are therefore best-effort.
//
//  Because these bindings shadow the frontmost app while registered, every path
//  that ends a hover must tear them down. `QuickAccessManager` owns the hover
//  state and is the single caller of `setHoveredItem`.
//

import AppKit
import Combine
import Foundation

@MainActor
final class QuickAccessHoverShortcutRegistry {
  /// Called on the main actor when a registered binding fires.
  var onTrigger: ((QuickAccessCardShortcutTrigger) -> Void)?

  private let store: QuickAccessActionShortcutStore
  private let installsEventMonitors: Bool
  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private var globalKeyMonitor: Any?
  private var localKeyMonitor: Any?
  private var hoveredItemID: UUID?
  private var hoverGeneration: UInt64 = 0
  private var isHoverActive: Bool { hoveredItemID != nil }
  private var isRegistered = false
  private var pendingDisarm: DispatchWorkItem?
  private var storeObservers: Set<AnyCancellable> = []

  /// Delay before the event tap/monitors are physically removed after hover ends.
  ///
  /// Moving the pointer between cards produces an exit+enter pair within
  /// milliseconds. Coalescing keeps the routing infrastructure alive across
  /// that transition; `isHoverActive` still gates every trigger and unmatched
  /// events are always returned to the system.
  private static let disarmDelay: TimeInterval = 0.25

  init(store: QuickAccessActionShortcutStore? = nil, installsEventMonitors: Bool = true) {
    self.store = store ?? .shared
    self.installsEventMonitors = installsEventMonitors
    observeStore()
  }

  deinit {
    // QuickAccessManager owns this registry for the app lifetime, but teardown
    // here also protects the unretained event-tap callback if that ownership
    // ever changes.
    pendingDisarm?.cancel()
    if let runLoopSource {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
      CFRunLoopSourceInvalidate(runLoopSource)
    }
    if let eventTap {
      CGEvent.tapEnable(tap: eventTap, enable: false)
      CFMachPortInvalidate(eventTap)
    }
    if let globalKeyMonitor {
      NSEvent.removeMonitor(globalKeyMonitor)
    }
    if let localKeyMonitor {
      NSEvent.removeMonitor(localKeyMonitor)
    }
  }

  // MARK: - Hover lifecycle

  func setHoveredItem(_ id: UUID?) {
    guard id != hoveredItemID else { return }
    let wasActive = isHoverActive
    hoveredItemID = id
    hoverGeneration &+= 1
    guard installsEventMonitors, isHoverActive != wasActive else { return }
    if isHoverActive {
      arm()
    } else {
      scheduleDisarm()
    }
  }

  /// Registers bindings unless they are still registered from the current hover
  /// session — the common case when the pointer moves directly between cards.
  private func arm() {
    if let pendingDisarm {
      pendingDisarm.cancel()
      self.pendingDisarm = nil
    }
    guard !isRegistered else { return }
    registerAll()
  }

  private func scheduleDisarm() {
    pendingDisarm?.cancel()
    let work = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated {
        guard let self, !self.isHoverActive else { return }
        self.pendingDisarm = nil
        self.unregisterAll()
      }
    }
    pendingDisarm = work
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.disarmDelay, execute: work)
  }

  /// Re-applies the current bindings without changing hover state. Used when the
  /// user edits a shortcut while a card happens to be hovered.
  func refreshRegistration() {
    guard installsEventMonitors, isHoverActive else { return }
    unregisterAll()
    registerAll()
  }

  // MARK: - Registration

  private func registerAll() {
    guard !store.activeBindings.isEmpty else {
      isRegistered = true
      return
    }

    if installEventTap() {
      isRegistered = true
      return
    }

    installMonitorFallback()
    isRegistered = true
  }

  private func unregisterAll() {
    if let runLoopSource {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
      CFRunLoopSourceInvalidate(runLoopSource)
    }
    if let eventTap {
      CGEvent.tapEnable(tap: eventTap, enable: false)
      CFMachPortInvalidate(eventTap)
    }
    if let globalKeyMonitor {
      NSEvent.removeMonitor(globalKeyMonitor)
    }
    if let localKeyMonitor {
      NSEvent.removeMonitor(localKeyMonitor)
    }

    runLoopSource = nil
    eventTap = nil
    globalKeyMonitor = nil
    localKeyMonitor = nil
    isRegistered = false
  }

  private func installEventTap() -> Bool {
    let eventMask = CGEventMask(1) << CGEventMask(CGEventType.keyDown.rawValue)
    guard let eventTap = CGEvent.tapCreate(
      tap: .cgSessionEventTap,
      place: .headInsertEventTap,
      options: .defaultTap,
      eventsOfInterest: eventMask,
      callback: Self.tapCallback,
      userInfo: Unmanaged.passUnretained(self).toOpaque()
    ) else {
      DiagnosticLogger.shared.log(
        .debug,
        .action,
        "Quick access exact shortcut tap unavailable; using passive monitors"
      )
      return false
    }

    guard let runLoopSource = CFMachPortCreateRunLoopSource(nil, eventTap, 0) else {
      CFMachPortInvalidate(eventTap)
      return false
    }

    self.eventTap = eventTap
    self.runLoopSource = runLoopSource
    CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
    CGEvent.tapEnable(tap: eventTap, enable: true)
    return true
  }

  private func installMonitorFallback() {
    globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) {
      [weak self] event in
      MainActor.assumeIsolated {
        _ = self?.handleObservedKeyDown(event)
      }
    }

    localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
      [weak self] event in
      let handled = MainActor.assumeIsolated {
        self?.handleObservedKeyDown(event) ?? false
      }
      // Local monitors may consume an exact action for Snapzy's own windows;
      // the global monitor is observational and cannot consume external-app
      // events. Unregistered local events always continue to the responder.
      return handled ? nil : event
    }
  }

  private static let tapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let registry = Unmanaged<QuickAccessHoverShortcutRegistry>
      .fromOpaque(userInfo)
      .takeUnretainedValue()
    return MainActor.assumeIsolated {
      registry.handleTapEvent(type: type, event: event)
    }
  }

  /// Routes an event from the session tap. Returning the original event keeps
  /// every unregistered combination flowing to the focused application.
  private func handleTapEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if let eventTap {
        CGEvent.tapEnable(tap: eventTap, enable: true)
      }
      return Unmanaged.passUnretained(event)
    }

    guard type == .keyDown,
          let keyEvent = NSEvent(cgEvent: event),
          shouldConsumeTapKeyDown(keyEvent) else {
      return Unmanaged.passUnretained(event)
    }
    return nil
  }

  /// Returns whether the session tap should consume the key.
  func shouldConsumeTapKeyDown(_ keyEvent: NSEvent) -> Bool {
    guard let hoveredItemID,
          let action = Self.matchingAction(for: keyEvent, bindings: store.activeBindings) else {
      return false
    }

    if !keyEvent.isARepeat {
      let generation = hoverGeneration
      let trigger = QuickAccessCardShortcutTrigger(itemID: hoveredItemID, action: action)
      DispatchQueue.main.async { [weak self] in
        MainActor.assumeIsolated {
          // A key accepted for one hover must never act on a different card.
          guard let self, self.hoverGeneration == generation else { return }
          self.onTrigger?(trigger)
        }
      }
    }
    // Consume repeats of an exact binding as well. They must not leak through
    // to the frontmost app just because Quick Access intentionally suppresses
    // repeated action dispatch.
    return true
  }

  /// Handles an AppKit monitor event. Returns whether the local event should be
  /// consumed; global monitor callbacks remain passive by platform contract.
  private func handleObservedKeyDown(_ event: NSEvent) -> Bool {
    guard let hoveredItemID,
          let action = Self.matchingAction(for: event, bindings: store.activeBindings) else {
      return false
    }
    if !event.isARepeat {
      onTrigger?(QuickAccessCardShortcutTrigger(itemID: hoveredItemID, action: action))
    }
    return true
  }

  // MARK: - Store observation

  private func observeStore() {
    // `@Published` emits in `willSet`, so the store still reports the previous
    // values inside the sink. Hop a runloop turn before reading `activeBindings`.
    store.$shortcuts
      .dropFirst()
      .sink { [weak self] _ in self?.scheduleRefresh() }
      .store(in: &storeObservers)

    store.$disabledActions
      .dropFirst()
      .sink { [weak self] _ in self?.scheduleRefresh() }
      .store(in: &storeObservers)

    store.$isEnabled
      .dropFirst()
      .sink { [weak self] _ in self?.scheduleRefresh() }
      .store(in: &storeObservers)
  }

  private func scheduleRefresh() {
    guard isHoverActive else { return }
    DispatchQueue.main.async { [weak self] in
      MainActor.assumeIsolated {
        self?.refreshRegistration()
      }
    }
  }

  // MARK: - Exact matching

  /// Testable routing seam shared by the event tap and monitor fallback.
  /// `ShortcutConfig.matches(event:)` compares the complete supported modifier
  /// set, so a binding such as ⌘P never matches ⌘⇧P, ⌘⌥P, or ⌃⌘P.
  static func matchingAction(
    for event: NSEvent,
    bindings: [(action: QuickAccessActionKind, shortcut: ShortcutConfig)]
  ) -> QuickAccessActionKind? {
    guard event.type == .keyDown else { return nil }
    return bindings.first { $0.shortcut.matches(event: event) }?.action
  }
}
