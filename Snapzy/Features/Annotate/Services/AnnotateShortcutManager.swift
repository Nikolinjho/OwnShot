//
//  AnnotateShortcutManager.swift
//  Snapzy
//
//  Manages keyboard shortcuts for annotation tools (local, single-key)
//  and configurable action shortcuts (modifier+key combos)
//

import AppKit
import Carbon.HIToolbox
import Combine
import Foundation

enum AnnotateActionShortcutKind: String, CaseIterable, Codable {
  case copyAndClose
  case toggleSidebar
  case togglePin
  case cloudUpload
  case autoRedactSensitiveData
  // Команды редактора из Settings → Shortcuts в CleanShot X; хранятся в extraActionShortcuts.
  case copyObject
  case duplicateObject
  case save
  case saveAs
  case print
  case addNewScreenshot
  case addScreenshotFromFile
  case increaseToolSize
  case decreaseToolSize

  /// Команды с хранением в общем словаре (без отдельного свойства на каждую).
  static let extraKinds: [AnnotateActionShortcutKind] = [
    .copyObject, .duplicateObject, .save, .saveAs, .print,
    .addNewScreenshot, .addScreenshotFromFile, .increaseToolSize, .decreaseToolSize,
  ]

  var isExtraKind: Bool { Self.extraKinds.contains(self) }

  /// Однобуквенные сочетания без модификаторов допустимы только для этих команд.
  var allowsSingleKey: Bool {
    switch self {
    case .toggleSidebar, .increaseToolSize, .decreaseToolSize: return true
    default: return false
    }
  }

  /// Название строки в настройках, как в CleanShot X.
  var settingsTitle: String {
    switch self {
    // Сочетание ⇧⌘C и название как у CleanShot; редактор после копирования остаётся открытым.
    case .copyAndClose: return "Copy Screenshot to Clipboard"
    case .toggleSidebar: return "Background Tool"
    case .togglePin: return "Pin to the Screen"
    case .cloudUpload: return "Upload to Cloud"
    case .autoRedactSensitiveData: return L10n.ShortcutOverlay.autoRedactSensitiveData
    case .copyObject: return "Copy Object to Clipboard"
    case .duplicateObject: return "Duplicate Object"
    case .save: return "Save"
    case .saveAs: return "Save as"
    case .print: return "Print"
    case .addNewScreenshot: return "Add New Screenshot"
    case .addScreenshotFromFile: return "Add Screenshot From File"
    case .increaseToolSize: return "Increase Tool Size"
    case .decreaseToolSize: return "Decrease Tool Size"
    }
  }
}

/// Manager for annotation tool keyboard shortcuts
@MainActor
final class AnnotateShortcutManager: ObservableObject {

  static let shared = AnnotateShortcutManager()

  /// Current shortcut bindings (tool -> key)
  @Published private(set) var shortcuts: [AnnotationToolType: Character] = [:]
  @Published private(set) var disabledToolShortcuts: Set<AnnotationToolType> = []

  /// Configurable action shortcuts (modifier+key combos)
  @Published private(set) var copyAndCloseShortcut: ShortcutConfig?
  @Published private(set) var toggleSidebarShortcut: ShortcutConfig?
  @Published private(set) var togglePinShortcut: ShortcutConfig?
  @Published private(set) var cloudUploadShortcut: ShortcutConfig?
  @Published private(set) var autoRedactSensitiveDataShortcut: ShortcutConfig?
  @Published private(set) var disabledActionShortcuts: Set<AnnotateActionShortcutKind> = []
  /// Сочетания команд из `AnnotateActionShortcutKind.extraKinds`.
  @Published private(set) var extraActionShortcuts: [AnnotateActionShortcutKind: ShortcutConfig] = [:]

  /// UserDefaults key prefix
  private let keyPrefix = "annotate.shortcut."
  private let copyAndCloseKey = "annotate.action.copyAndClose"
  private let toggleSidebarKey = "annotate.action.toggleSidebar"
  private let togglePinKey = "annotate.action.togglePin"
  /// Флаг однократного перехода на пустой дефолт «Pin to the Screen».
  private let togglePinEmptyDefaultMigrationKey = "annotate.action.togglePin.emptyDefaultMigrated"
  private let cloudUploadKey = "annotate.action.cloudUpload"
  private let autoRedactSensitiveDataKey = "annotate.action.autoRedactSensitiveData"
  private let disabledToolShortcutsKey = PreferencesKeys.disabledAnnotateToolShortcuts
  private let disabledActionShortcutsKey = PreferencesKeys.disabledAnnotateActionShortcuts
  private let explicitEmptyActionShortcutData = Data("null".utf8)

  /// Tools that support shortcuts (excludes mockup - internal only)
  static let configurableTools: [AnnotationToolType] = [
    .crop, .cutOut, .selection, .rectangle, .filledRectangle, .oval, .arrow,
    .line, .text, .highlighter, .blur, .spotlight, .counter, .measure, .watermark, .pencil
  ]

  /// Default: ⌘⇧C
  static let defaultCopyAndClose = ShortcutConfig(
    keyCode: UInt32(kVK_ANSI_C),
    modifiers: UInt32(cmdKey | shiftKey)
  )

  /// Default: B
  static let defaultToggleSidebar = ShortcutConfig(
    keyCode: UInt32(kVK_ANSI_B),
    modifiers: 0
  )

  /// «Pin to the Screen»: как в CleanShot X, по умолчанию без сочетания.
  static let defaultTogglePin: ShortcutConfig? = nil

  /// Прежний дефолт ⌃⌘P. Остаётся у пользователей, которые пользовались OwnShot до смены дефолта.
  static let legacyDefaultTogglePin = ShortcutConfig(
    keyCode: UInt32(kVK_ANSI_P),
    modifiers: UInt32(cmdKey | controlKey)
  )

  /// Какое сочетание записать при переходе на пустой дефолт «Pin to the Screen».
  /// Сохранённое значение (своё сочетание или явная очистка) не трогаем.
  /// Пользователь, прошедший онбординг до смены дефолта, жил с ⌃⌘P — фиксируем его явно.
  /// Новый пользователь получает пустой дефолт.
  static func togglePinMigrationValue(hasStoredValue: Bool, isExistingUser: Bool) -> ShortcutConfig? {
    guard !hasStoredValue, isExistingUser else { return nil }
    return legacyDefaultTogglePin
  }

  /// Default: ⌘U
  static let defaultCloudUpload = ShortcutConfig(
    keyCode: UInt32(kVK_ANSI_U),
    modifiers: UInt32(cmdKey)
  )

  /// No default shortcut; available for users who want a local Annotate action key.
  static let defaultAutoRedactSensitiveData: ShortcutConfig? = nil

  /// Дефолт любой команды редактора. Для extra-команд значения взяты из CleanShot X.
  static func defaultShortcut(for kind: AnnotateActionShortcutKind) -> ShortcutConfig? {
    let command = UInt32(cmdKey)
    let commandShift = UInt32(cmdKey | shiftKey)
    switch kind {
    case .copyAndClose: return defaultCopyAndClose
    case .toggleSidebar: return defaultToggleSidebar
    case .togglePin: return defaultTogglePin
    case .cloudUpload: return defaultCloudUpload
    case .autoRedactSensitiveData: return defaultAutoRedactSensitiveData
    case .copyObject: return ShortcutConfig(keyCode: UInt32(kVK_ANSI_C), modifiers: command)
    case .duplicateObject: return ShortcutConfig(keyCode: UInt32(kVK_ANSI_D), modifiers: command)
    case .save: return ShortcutConfig(keyCode: UInt32(kVK_ANSI_S), modifiers: command)
    case .saveAs: return ShortcutConfig(keyCode: UInt32(kVK_ANSI_S), modifiers: commandShift)
    case .print: return ShortcutConfig(keyCode: UInt32(kVK_ANSI_P), modifiers: command)
    case .addNewScreenshot: return ShortcutConfig(keyCode: UInt32(kVK_ANSI_I), modifiers: commandShift)
    case .addScreenshotFromFile: return ShortcutConfig(keyCode: UInt32(kVK_ANSI_I), modifiers: command)
    case .increaseToolSize: return ShortcutConfig(keyCode: UInt32(kVK_ANSI_Equal), modifiers: 0)
    case .decreaseToolSize: return ShortcutConfig(keyCode: UInt32(kVK_ANSI_Minus), modifiers: 0)
    }
  }

  private init() {
    copyAndCloseShortcut = Self.defaultCopyAndClose
    toggleSidebarShortcut = Self.defaultToggleSidebar
    togglePinShortcut = Self.defaultTogglePin
    cloudUploadShortcut = Self.defaultCloudUpload
    autoRedactSensitiveDataShortcut = Self.defaultAutoRedactSensitiveData
    loadShortcuts()
    loadDisabledToolShortcuts()
    loadActionShortcuts()
    loadDisabledActionShortcuts()
  }

  // MARK: - Lookup

  /// Get tool for a given key press
  func tool(for key: Character) -> AnnotationToolType? {
    shortcuts.first { isShortcutEnabled(for: $0.key) && $0.value == key }?.key
  }

  /// Get current shortcut for a tool
  func shortcut(for tool: AnnotationToolType) -> Character? {
    shortcuts[tool]
  }

  func isShortcutEnabled(for tool: AnnotationToolType) -> Bool {
    !disabledToolShortcuts.contains(tool)
  }

  func setShortcutEnabled(_ enabled: Bool, for tool: AnnotationToolType) {
    guard isShortcutEnabled(for: tool) != enabled else { return }
    var updated = disabledToolShortcuts
    if enabled {
      updated.remove(tool)
    } else {
      updated.insert(tool)
    }
    disabledToolShortcuts = updated
    saveDisabledToolShortcuts()
  }

  // MARK: - Mutation

  /// Set shortcut for a tool (nil to clear)
  func setShortcut(_ key: Character?, for tool: AnnotationToolType) {
    if let key = key {
      shortcuts[tool] = key
    } else {
      shortcuts.removeValue(forKey: tool)
    }
    saveShortcut(for: tool)
  }

  /// Reset all shortcuts to defaults
  func resetToDefaults() {
    for tool in Self.configurableTools {
      shortcuts[tool] = tool.defaultShortcut
      saveShortcut(for: tool)
    }
    disabledToolShortcuts = []
    saveDisabledToolShortcuts()

    // Reset action shortcuts
    disabledActionShortcuts = []
    saveDisabledActionShortcuts()
    setCopyAndCloseShortcut(Self.defaultCopyAndClose)
    setToggleSidebarShortcut(Self.defaultToggleSidebar)
    setTogglePinShortcut(Self.defaultTogglePin)
    setCloudUploadShortcut(Self.defaultCloudUpload)
    setAutoRedactSensitiveDataShortcut(Self.defaultAutoRedactSensitiveData)
    for kind in AnnotateActionShortcutKind.extraKinds {
      setActionShortcut(Self.defaultShortcut(for: kind), for: kind)
    }
  }

  // MARK: - Action Shortcut Mutation

  /// Единая точка назначения для любой команды редактора.
  func setActionShortcut(_ config: ShortcutConfig?, for kind: AnnotateActionShortcutKind) {
    switch kind {
    case .copyAndClose: setCopyAndCloseShortcut(config)
    case .toggleSidebar: setToggleSidebarShortcut(config)
    case .togglePin: setTogglePinShortcut(config)
    case .cloudUpload: setCloudUploadShortcut(config)
    case .autoRedactSensitiveData: setAutoRedactSensitiveDataShortcut(config)
    default:
      var updated = extraActionShortcuts
      updated[kind] = config
      extraActionShortcuts = updated
      saveActionShortcut(config, forKey: actionKey(for: kind))
    }
  }

  /// Совпадает ли событие с включённой командой редактора.
  func matchesAction(_ kind: AnnotateActionShortcutKind, event: NSEvent) -> Bool {
    guard isActionShortcutEnabled(for: kind), let config = shortcut(for: kind) else { return false }
    return matchesShortcut(config, event: event)
  }

  private func actionKey(for kind: AnnotateActionShortcutKind) -> String {
    "annotate.action.\(kind.rawValue)"
  }

  func setCopyAndCloseShortcut(_ config: ShortcutConfig?) {
    copyAndCloseShortcut = config
    saveActionShortcut(config, forKey: copyAndCloseKey)
  }

  func setToggleSidebarShortcut(_ config: ShortcutConfig?) {
    toggleSidebarShortcut = config
    saveActionShortcut(config, forKey: toggleSidebarKey)
  }

  func setTogglePinShortcut(_ config: ShortcutConfig?) {
    togglePinShortcut = config
    saveActionShortcut(config, forKey: togglePinKey)
  }

  func setCloudUploadShortcut(_ config: ShortcutConfig?) {
    cloudUploadShortcut = config
    saveActionShortcut(config, forKey: cloudUploadKey)
  }

  func setAutoRedactSensitiveDataShortcut(_ config: ShortcutConfig?) {
    autoRedactSensitiveDataShortcut = config
    saveActionShortcut(config, forKey: autoRedactSensitiveDataKey)
  }

  func isActionShortcutEnabled(for kind: AnnotateActionShortcutKind) -> Bool {
    !disabledActionShortcuts.contains(kind)
  }

  func shortcut(for kind: AnnotateActionShortcutKind) -> ShortcutConfig? {
    switch kind {
    case .copyAndClose:
      return copyAndCloseShortcut
    case .toggleSidebar:
      return toggleSidebarShortcut
    case .togglePin:
      return togglePinShortcut
    case .cloudUpload:
      return cloudUploadShortcut
    case .autoRedactSensitiveData:
      return autoRedactSensitiveDataShortcut
    default:
      return extraActionShortcuts[kind]
    }
  }

  func setActionShortcutEnabled(_ enabled: Bool, for kind: AnnotateActionShortcutKind) {
    guard isActionShortcutEnabled(for: kind) != enabled else { return }
    var updated = disabledActionShortcuts
    if enabled {
      updated.remove(kind)
    } else {
      updated.insert(kind)
    }
    disabledActionShortcuts = updated
    saveDisabledActionShortcuts()
  }

  /// Check if an NSEvent matches the Copy & Close shortcut
  func matchesCopyAndClose(_ event: NSEvent) -> Bool {
    guard isActionShortcutEnabled(for: .copyAndClose) else { return false }
    guard let copyAndCloseShortcut else { return false }
    return matchesShortcut(copyAndCloseShortcut, event: event)
  }

  /// Check if an NSEvent matches the Toggle Sidebar shortcut
  func matchesToggleSidebar(_ event: NSEvent) -> Bool {
    guard isActionShortcutEnabled(for: .toggleSidebar) else { return false }
    guard let toggleSidebarShortcut else { return false }
    return matchesShortcut(toggleSidebarShortcut, event: event)
  }

  /// Check if an NSEvent matches the Toggle Pin shortcut
  func matchesTogglePin(_ event: NSEvent) -> Bool {
    guard isActionShortcutEnabled(for: .togglePin) else { return false }
    guard let togglePinShortcut else { return false }
    return matchesShortcut(togglePinShortcut, event: event)
  }

  /// Check if an NSEvent matches the Cloud Upload shortcut
  func matchesCloudUpload(_ event: NSEvent) -> Bool {
    guard isActionShortcutEnabled(for: .cloudUpload) else { return false }
    guard let cloudUploadShortcut else { return false }
    return matchesShortcut(cloudUploadShortcut, event: event)
  }

  /// Check if an NSEvent matches the Auto Redact Sensitive Data shortcut.
  func matchesAutoRedactSensitiveData(_ event: NSEvent) -> Bool {
    guard isActionShortcutEnabled(for: .autoRedactSensitiveData) else { return false }
    guard let autoRedactSensitiveDataShortcut else { return false }
    return matchesShortcut(autoRedactSensitiveDataShortcut, event: event)
  }

  // MARK: - Validation

  /// Check if key conflicts with another tool's shortcut
  func conflictingTool(for key: Character, excluding tool: AnnotationToolType) -> AnnotationToolType? {
    shortcuts.first {
      $0.key != tool && isShortcutEnabled(for: $0.key) && $0.value == key
    }?.key
  }

  // MARK: - Persistence

  private func loadShortcuts() {
    for tool in Self.configurableTools {
      let key = keyPrefix + tool.rawValue
      if let stored = UserDefaults.standard.string(forKey: key) {
        if let char = stored.first {
          shortcuts[tool] = char
        } else {
          shortcuts.removeValue(forKey: tool)
        }
      } else {
        // Use default if not customized
        shortcuts[tool] = tool.defaultShortcut
      }
    }
  }

  private func loadDisabledToolShortcuts() {
    guard let rawValues = UserDefaults.standard.array(forKey: disabledToolShortcutsKey) as? [String] else {
      disabledToolShortcuts = []
      return
    }
    disabledToolShortcuts = Set(rawValues.compactMap(AnnotationToolType.init(rawValue:)))
  }

  private func saveShortcut(for tool: AnnotationToolType) {
    let key = keyPrefix + tool.rawValue
    if let shortcut = shortcuts[tool] {
      UserDefaults.standard.set(String(shortcut), forKey: key)
    } else {
      UserDefaults.standard.set("", forKey: key)
    }
  }

  private func saveDisabledToolShortcuts() {
    let rawValues = disabledToolShortcuts.map(\.rawValue).sorted()
    UserDefaults.standard.set(rawValues, forKey: disabledToolShortcutsKey)
  }

  // MARK: - Action Shortcut Persistence

  private func loadActionShortcuts() {
    migrateTogglePinToEmptyDefaultIfNeeded()
    copyAndCloseShortcut = loadActionShortcut(forKey: copyAndCloseKey, defaultValue: Self.defaultCopyAndClose)
    toggleSidebarShortcut = loadActionShortcut(forKey: toggleSidebarKey, defaultValue: Self.defaultToggleSidebar)
    togglePinShortcut = loadActionShortcut(forKey: togglePinKey, defaultValue: Self.defaultTogglePin)
    cloudUploadShortcut = loadActionShortcut(forKey: cloudUploadKey, defaultValue: Self.defaultCloudUpload)
    autoRedactSensitiveDataShortcut = loadActionShortcut(
      forKey: autoRedactSensitiveDataKey,
      defaultValue: Self.defaultAutoRedactSensitiveData
    )
    var extras: [AnnotateActionShortcutKind: ShortcutConfig] = [:]
    for kind in AnnotateActionShortcutKind.extraKinds {
      extras[kind] = loadActionShortcut(forKey: actionKey(for: kind), defaultValue: Self.defaultShortcut(for: kind))
    }
    extraActionShortcuts = extras
  }

  /// Выполняется один раз: при первом запуске версии с пустым дефолтом решаем, сохранить ли ⌃⌘P.
  private func migrateTogglePinToEmptyDefaultIfNeeded() {
    let defaults = UserDefaults.standard
    guard !defaults.bool(forKey: togglePinEmptyDefaultMigrationKey) else { return }
    defaults.set(true, forKey: togglePinEmptyDefaultMigrationKey)
    let value = Self.togglePinMigrationValue(
      hasStoredValue: defaults.data(forKey: togglePinKey) != nil,
      isExistingUser: defaults.bool(forKey: PreferencesKeys.onboardingCompleted)
    )
    if let value {
      saveActionShortcut(value, forKey: togglePinKey)
    }
  }

  private func loadDisabledActionShortcuts() {
    guard let rawValues = UserDefaults.standard.array(forKey: disabledActionShortcutsKey) as? [String] else {
      disabledActionShortcuts = []
      return
    }
    disabledActionShortcuts = Set(rawValues.compactMap(AnnotateActionShortcutKind.init(rawValue:)))
  }

  private func saveActionShortcut(_ config: ShortcutConfig?, forKey key: String) {
    guard let config else {
      UserDefaults.standard.set(explicitEmptyActionShortcutData, forKey: key)
      return
    }
    if let data = try? JSONEncoder().encode(config) {
      UserDefaults.standard.set(data, forKey: key)
    }
  }

  private func loadActionShortcut(forKey key: String, defaultValue: ShortcutConfig?) -> ShortcutConfig? {
    guard let data = UserDefaults.standard.data(forKey: key) else { return defaultValue }
    if data == explicitEmptyActionShortcutData {
      return nil
    }
    return (try? JSONDecoder().decode(ShortcutConfig.self, from: data)) ?? defaultValue
  }

  private func saveDisabledActionShortcuts() {
    let rawValues = disabledActionShortcuts.map(\.rawValue).sorted()
    UserDefaults.standard.set(rawValues, forKey: disabledActionShortcutsKey)
  }

  /// Check if an NSEvent matches a given ShortcutConfig
  private func matchesShortcut(_ config: ShortcutConfig, event: NSEvent) -> Bool {
    config.matches(event: event)
  }
}

extension AnnotationToolType {
  /// Название строки в Settings → Shortcuts, как в CleanShot X (с суффиксом «Tool»).
  var shortcutSettingsTitle: String {
    switch self {
    case .selection: return "Move Tool"
    case .crop: return "Crop & Resize Tool"
    case .cutOut: return "Cut Out Tool"
    case .rectangle: return "Rectangle Tool"
    case .filledRectangle: return "Filled Rectangle Tool"
    case .oval: return "Ellipse Tool"
    case .arrow: return "Arrow Tool"
    case .line: return "Line Tool"
    case .text: return "Text Tool"
    case .highlighter: return "Highlighter Tool"
    case .blur: return "Redaction Tool"
    case .spotlight: return "Spotlight Tool"
    case .counter: return "Counter Tool"
    case .watermark: return "Watermark Tool"
    case .pencil: return "Draw Tool"
    case .measure: return "Measure Tool"
    case .mockup: return "Mockup Tool"
    }
  }
}
