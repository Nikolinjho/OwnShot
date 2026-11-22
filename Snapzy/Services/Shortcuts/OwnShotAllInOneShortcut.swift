import AppKit
import Carbon.HIToolbox
import Combine

@MainActor
final class OwnShotAllInOneShortcut: ObservableObject {
  static let shared = OwnShotAllInOneShortcut()
  @Published private(set) var shortcut: ShortcutConfig?
  var onInvoke: (() -> Void)?
  private var hotkey: EventHotKeyRef?
  private var handler: EventHandlerRef?
  private let storageKey = "ownshot.allInOneShortcut"
  private let signature: OSType = 0x4F534149
  private let defaults: UserDefaults
  private let registerOverride: (@MainActor (ShortcutConfig) -> Bool)?
  private let unregisterOverride: (@MainActor () -> Void)?
  private(set) var isHotkeyRegistered = false
  private let manager: KeyboardShortcutManager
  private var registrationObservation: AnyCancellable?

  init(
    defaults: UserDefaults = .standard,
    manager: KeyboardShortcutManager = .shared,
    registerShortcut: (@MainActor (ShortcutConfig) -> Bool)? = nil,
    unregisterShortcut: (@MainActor () -> Void)? = nil
  ) {
    self.manager = manager
    self.defaults = defaults
    self.registerOverride = registerShortcut
    self.unregisterOverride = unregisterShortcut
    if let data = defaults.data(forKey: storageKey) { shortcut = try? JSONDecoder().decode(ShortcutConfig.self, from: data) }
    if registerShortcut == nil {
      var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
      InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
        guard let event, let context else { return OSStatus(eventNotHandledErr) }
        var id = EventHotKeyID()
        GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
        guard id.signature == 0x4F534149 else { return OSStatus(eventNotHandledErr) }
        MainActor.assumeIsolated {
          let owner = Unmanaged<OwnShotAllInOneShortcut>.fromOpaque(context).takeUnretainedValue()
          if KeyboardShortcutManager.shared.isEnabled, !KeyboardShortcutManager.shared.isTemporarilySuspended { owner.onInvoke?() }
        }
        return noErr
      }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    registrationObservation = manager.$shortcutRegistrationEnabled
      .combineLatest(manager.$videoEditorShortcutOverrides)
      .sink { [weak self] enabled, overrides in
        guard let self else { return }
        self.unregister()
        if enabled { _ = self.register(shouldRegister: true, editorOverrides: overrides) }
      }
  }

  @discardableResult func update(_ config: ShortcutConfig?) -> Bool {
    if let config {
      guard config.modifiers != 0, config.modifiers & ShortcutConfig.functionCarbonModifier == 0 else { return false }
      if case .reject = ShortcutValidationService.shared.validateAllInOneShortcut(config) {
        NSSound.beep()
        return false
      }
    }
    let old = shortcut
    unregister()
    shortcut = config
    if !register() { shortcut = old; _ = register(); return false }
    if let config, let data = try? JSONEncoder().encode(config) { defaults.set(data, forKey: storageKey) }
    else { defaults.removeObject(forKey: storageKey) }
    return true
  }

  private func unregister() {
    if isHotkeyRegistered { unregisterOverride?() }
    if let hotkey { UnregisterEventHotKey(hotkey) }
    hotkey = nil
    isHotkeyRegistered = false
  }

  @discardableResult private func register(
    shouldRegister: Bool? = nil, editorOverrides: [ShortcutConfig]? = nil
  ) -> Bool {
    let enabled = shouldRegister ?? (manager.isEnabled && !manager.isTemporarilySuspended)
    guard enabled, let shortcut,
          !(editorOverrides ?? manager.videoEditorShortcutOverrides).contains(shortcut)
    else { return true }
    if let registerOverride {
      isHotkeyRegistered = registerOverride(shortcut)
      return isHotkeyRegistered
    }
    let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, EventHotKeyID(signature: signature, id: 1), GetApplicationEventTarget(), 0, &hotkey)
    isHotkeyRegistered = status == noErr
    return isHotkeyRegistered
  }
}
