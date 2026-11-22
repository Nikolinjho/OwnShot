//
//  ScrollingCaptureShortcutSettings.swift
//  Snapzy
//
//  Клавиша Start/Stop Capturing для Scrolling Capture (⏎ по умолчанию), как в
//  Settings → Shortcuts у CleanShot X. На время сессии регистрируется глобально,
//  поэтому работает и когда активно другое приложение.
//

import AppKit
import Carbon.HIToolbox
import Foundation

enum ScrollingCaptureShortcutSettings {
  /// Подмена для тестов.
  static var defaults: UserDefaults = .standard
  static let defaultsKey = "scrollingCapture.startStopShortcut"
  private static let explicitEmptyShortcutData = Data("null".utf8)

  static let defaultStartStopShortcut = ShortcutConfig(keyCode: UInt32(kVK_Return), modifiers: 0)

  /// Текущее сочетание. nil — пользователь очистил его клавишей Delete.
  static var startStopShortcut: ShortcutConfig? {
    guard let data = defaults.data(forKey: defaultsKey) else { return defaultStartStopShortcut }
    if data == explicitEmptyShortcutData { return nil }
    return (try? JSONDecoder().decode(ShortcutConfig.self, from: data)) ?? defaultStartStopShortcut
  }

  static func setStartStopShortcut(_ config: ShortcutConfig?) {
    guard let config else {
      defaults.set(explicitEmptyShortcutData, forKey: defaultsKey)
      return
    }
    guard let data = try? JSONEncoder().encode(config) else { return }
    defaults.set(data, forKey: defaultsKey)
  }

  static func reset() {
    defaults.removeObject(forKey: defaultsKey)
  }

  /// Совпадает ли нажатие с Start/Stop Capturing. Return и Enter на цифровом блоке — одна клавиша.
  static func matchesStartStop(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
    guard let config = startStopShortcut else { return false }
    return RecordingStartShortcutSettings.matches(config, keyCode: keyCode, modifiers: modifiers)
  }

  /// Коды клавиш для глобальной регистрации: у Return добавляется Enter цифрового блока.
  static func registrationKeyCodes(for config: ShortcutConfig) -> [UInt32] {
    if config.keyCode == UInt32(kVK_Return) || config.keyCode == UInt32(kVK_ANSI_KeypadEnter) {
      return [UInt32(kVK_Return), UInt32(kVK_ANSI_KeypadEnter)]
    }
    return [config.keyCode]
  }
}

/// Глобальная регистрация Start/Stop Capturing на время сессии Scrolling Capture.
/// Вне сессии клавиша не занята, чтобы ⏎ работал в других приложениях как обычно.
@MainActor
final class ScrollingCaptureSessionHotKey {
  static let shared = ScrollingCaptureSessionHotKey()

  typealias RegisterHotKey = @MainActor (_ keyCode: UInt32, _ modifiers: UInt32, _ id: UInt32) -> Bool
  typealias UnregisterHotKey = @MainActor (_ id: UInt32) -> Void

  private static let signature: OSType = 0x4F535343 // 'OSSC'

  private let shortcutProvider: @MainActor () -> ShortcutConfig?
  private let registerOverride: RegisterHotKey?
  private let unregisterOverride: UnregisterHotKey?
  private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
  private var registeredIDs: [UInt32] = []
  private var lastRegistrationID: UInt32 = 0
  private var handler: EventHandlerRef?
  private var onTrigger: (() -> Void)?

  /// Есть ли сейчас глобальная регистрация. false — работает только локальный монитор.
  var isActive: Bool { !registeredIDs.isEmpty }

  init(
    shortcutProvider: @escaping @MainActor () -> ShortcutConfig? = { ScrollingCaptureShortcutSettings.startStopShortcut },
    register: RegisterHotKey? = nil,
    unregister: UnregisterHotKey? = nil
  ) {
    self.shortcutProvider = shortcutProvider
    self.registerOverride = register
    self.unregisterOverride = unregister
  }

  /// Регистрирует клавишу. Возвращает false, если сочетания нет, в нём Fn
  /// (Carbon его не поддерживает) или регистрация не удалась.
  @discardableResult
  func activate(onTrigger: @escaping () -> Void) -> Bool {
    deactivate()
    guard let config = shortcutProvider(),
          config.modifiers & ShortcutConfig.functionCarbonModifier == 0 else { return false }
    self.onTrigger = onTrigger
    for keyCode in ScrollingCaptureShortcutSettings.registrationKeyCodes(for: config) {
      lastRegistrationID &+= 1
      let id = lastRegistrationID
      if register(keyCode: keyCode, modifiers: config.modifiers, id: id) {
        registeredIDs.append(id)
      }
    }
    if registeredIDs.isEmpty { self.onTrigger = nil }
    return isActive
  }

  func deactivate() {
    for id in registeredIDs {
      if let unregisterOverride {
        unregisterOverride(id)
      } else if let ref = hotKeyRefs.removeValue(forKey: id) {
        UnregisterEventHotKey(ref)
      }
    }
    registeredIDs.removeAll()
    onTrigger = nil
  }

  /// Вызов из обработчика Carbon (и из тестов).
  func handleHotKey(id: UInt32) {
    guard registeredIDs.contains(id) else { return }
    onTrigger?()
  }

  private func register(keyCode: UInt32, modifiers: UInt32, id: UInt32) -> Bool {
    if let registerOverride { return registerOverride(keyCode, modifiers, id) }
    installHandlerIfNeeded()
    var ref: EventHotKeyRef?
    let status = RegisterEventHotKey(
      keyCode,
      modifiers,
      EventHotKeyID(signature: Self.signature, id: id),
      GetApplicationEventTarget(),
      0,
      &ref
    )
    guard status == noErr, let ref else { return false }
    hotKeyRefs[id] = ref
    return true
  }

  private func installHandlerIfNeeded() {
    guard handler == nil else { return }
    var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
      guard let event, let context else { return OSStatus(eventNotHandledErr) }
      var hotKeyID = EventHotKeyID()
      GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
      )
      guard hotKeyID.signature == 0x4F535343 else { return OSStatus(eventNotHandledErr) }
      let id = hotKeyID.id
      MainActor.assumeIsolated {
        Unmanaged<ScrollingCaptureSessionHotKey>.fromOpaque(context).takeUnretainedValue().handleHotKey(id: id)
      }
      return noErr
    }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
  }
}
