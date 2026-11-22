//
//  SnapzyConfigurationShortcutsImporter.swift
//  Snapzy
//
//  Shortcut import helpers for TOML configuration.
//

import Foundation

@MainActor
extension SnapzyConfigurationImporter {
  static func collectShortcuts(
    _ reader: inout SnapzyConfigurationReader,
    defaults: UserDefaults,
    mutations: inout [() -> Void]
  ) {
    if let enabled = reader.bool("shortcuts", "enabled") {
      mutations.append {
        enabled ? KeyboardShortcutManager.shared.enable() : KeyboardShortcutManager.shared.disable()
      }
    }

    for kind in GlobalShortcutKind.allCases {
      collectGlobalShortcut(&reader, kind: kind, mutations: &mutations)
    }

    collectOverlayShortcut(
      &reader,
      path: ["shortcuts", "overlay", "area_application_capture"],
      mutations: &mutations
    ) {
      CaptureOverlayShortcutSettings.setApplicationCaptureShortcut($0)
    }
    collectOverlayShortcut(
      &reader,
      path: ["shortcuts", "overlay", "recording_application_capture"],
      mutations: &mutations
    ) {
      CaptureOverlayShortcutSettings.setRecordingApplicationCaptureShortcut($0)
    }

    collectQuickAccessShortcut(&reader, mutations: &mutations)
    collectQuickAccessCardActionShortcuts(&reader, mutations: &mutations)
    collectAnnotateTools(&reader, mutations: &mutations)
    collectAnnotateActions(&reader, mutations: &mutations)
    collectVideoEditorShortcuts(&reader, defaults: defaults, mutations: &mutations)
  }

  private static func collectVideoEditorShortcuts(
    _ reader: inout SnapzyConfigurationReader,
    defaults: UserDefaults,
    mutations: inout [() -> Void]
  ) {
    let settings = defaults == .standard ? VideoEditorShortcutSettings.shared : VideoEditorShortcutSettings(defaults: defaults)
    var assignments = settings.shortcuts
    var touched: [VideoEditorShortcutAction] = []
    for action in VideoEditorShortcutAction.allCases {
      let path = ["shortcuts", "video_editor", action.rawValue]
      let key = reader.string(path + ["key"])
      let keyCode = reader.int(path + ["key_code"])
      let modifiers = reader.stringArray(path + ["modifiers"])
      guard key != nil || keyCode != nil || modifiers != nil else { continue }
      let pathName = path.joined(separator: ".")
      guard key != nil || keyCode != nil else {
        reader.error("\(pathName).modifiers requires key or key_code")
        continue
      }
      guard key == nil || keyCode == nil else {
        reader.error("\(pathName) cannot set both key and key_code")
        continue
      }
      if key == "" {
        assignments[action] = nil
        touched.append(action)
        continue
      }

      let shortcut: ShortcutConfig?
      if let key {
        shortcut = SnapzyConfigurationShortcutCodec.shortcut(
          key: key, modifiers: modifiers ?? [], requireModifier: false
        )
      } else if let code = keyCode.flatMap(UInt16.init(exactly:)),
                let carbon = SnapzyConfigurationShortcutCodec.carbonModifiers(from: modifiers ?? []) {
        shortcut = ShortcutConfig(keyCode: UInt32(code), modifiers: carbon)
      } else {
        shortcut = nil
      }
      guard let shortcut else {
        reader.error("\(pathName) has an invalid shortcut")
        continue
      }
      assignments[action] = shortcut
      touched.append(action)
    }

    guard !touched.isEmpty else { return }
    for action in touched {
      if let shortcut = assignments[action], let conflict = VideoEditorShortcutSettings.conflictingActionName(
        for: shortcut, excluding: action, in: assignments
      ) {
        reader.error("shortcuts.video_editor.\(action.rawValue) is already used by \(conflict)")
      }
    }
    mutations.append { settings.replaceShortcuts(with: assignments) }
  }

  private static func collectQuickAccessShortcut(
    _ reader: inout SnapzyConfigurationReader,
    mutations: inout [() -> Void]
  ) {
    let path = ["shortcuts", "quick_access", "edit_latest_capture"]
    let enabled = reader.bool(path + ["enabled"])
    let key = reader.string(path + ["key"])
    let modifiers = reader.stringArray(path + ["modifiers"])
    guard enabled != nil || key != nil || modifiers != nil else { return }

    if enabled == false || key == "" {
      mutations.append {
        QuickAccessManager.shared.openEditorShortcutEnabled = false
        QuickAccessManager.shared.setOpenEditorShortcut(nil)
      }
      return
    }

    if let enabled {
      mutations.append {
        QuickAccessManager.shared.openEditorShortcutEnabled = enabled
      }
    }

    if let key {
      guard let shortcut = SnapzyConfigurationShortcutCodec.shortcut(
        key: key,
        modifiers: modifiers ?? [],
        requireModifier: true
      ) else {
        reader.error("shortcuts.quick_access.edit_latest_capture has an invalid shortcut")
        return
      }
      mutations.append {
        QuickAccessManager.shared.setOpenEditorShortcut(shortcut)
      }
    }
  }

  private static func collectQuickAccessCardActionShortcuts(
    _ reader: inout SnapzyConfigurationReader,
    mutations: inout [() -> Void]
  ) {
    let root = ["shortcuts", "quick_access", "card_actions"]

    if let masterEnabled = reader.bool(root + ["enabled"]) {
      mutations.append {
        QuickAccessActionShortcutStore.shared.isEnabled = masterEnabled
      }
    }

    for action in QuickAccessActionKind.defaultOrder {
      let path = root + [action.configKey]
      let enabled = reader.bool(path + ["enabled"])
      let key = reader.string(path + ["key"])
      let modifiers = reader.stringArray(path + ["modifiers"])
      guard enabled != nil || key != nil || modifiers != nil else { continue }

      if let enabled {
        mutations.append {
          QuickAccessActionShortcutStore.shared.setEnabled(enabled, for: action)
        }
      }

      guard let key else { continue }

      if key.isEmpty {
        mutations.append {
          QuickAccessActionShortcutStore.shared.setShortcut(nil, for: action)
        }
        continue
      }

      // Card shortcuts consume the keystroke while a card is hovered, so a
      // modifier is mandatory and fn cannot be expressed as a Carbon hotkey.
      guard let shortcut = SnapzyConfigurationShortcutCodec.shortcut(
        key: key,
        modifiers: modifiers ?? [],
        requireModifier: true
      ), QuickAccessActionShortcutStore.hasRequiredModifier(shortcut) else {
        reader.error(
          "shortcuts.quick_access.card_actions.\(action.configKey) has an invalid shortcut"
        )
        continue
      }

      mutations.append {
        QuickAccessActionShortcutStore.shared.setShortcut(shortcut, for: action)
      }
    }
  }

  static func quickAccessSlots(
    from reader: inout SnapzyConfigurationReader
  ) -> [QuickAccessActionSlot: QuickAccessActionKind]? {
    var assignments: [QuickAccessActionSlot: QuickAccessActionKind] = [:]
    var sawValue = false

    for slot in QuickAccessActionSlot.allCases {
      guard let raw = reader.string(["quick_access", "slots", slot.configKey]) else { continue }
      sawValue = true
      if raw.isEmpty { continue }
      guard let action = QuickAccessActionKind(rawValue: raw) else {
        reader.error("quick_access.slots.\(slot.configKey) is not a known Quick Access action")
        continue
      }
      assignments[slot] = action
    }

    return sawValue ? assignments : nil
  }

  private static func collectGlobalShortcut(
    _ reader: inout SnapzyConfigurationReader,
    kind: GlobalShortcutKind,
    mutations: inout [() -> Void]
  ) {
    let path = ["shortcuts", "global", kind.configKey]
    let key = reader.string(path + ["key"])
    let modifiers = reader.stringArray(path + ["modifiers"])
    let enabled = reader.bool(path + ["enabled"])

    guard key != nil || modifiers != nil || enabled != nil else { return }
    guard key != nil || modifiers == nil else {
      reader.error("shortcuts.global.\(kind.configKey).modifiers requires key")
      return
    }

    if let key, key.isEmpty {
      mutations.append {
        KeyboardShortcutManager.shared.setShortcut(nil, for: kind)
        KeyboardShortcutManager.shared.setShortcutEnabled(false, for: kind)
      }
      return
    }

    if let key {
      guard let shortcut = SnapzyConfigurationShortcutCodec.shortcut(
        key: key,
        modifiers: modifiers ?? [],
        requireModifier: true
      ) else {
        reader.error("shortcuts.global.\(kind.configKey) has an invalid shortcut")
        return
      }
      mutations.append { KeyboardShortcutManager.shared.setShortcut(shortcut, for: kind) }
    }

    if let enabled {
      mutations.append { KeyboardShortcutManager.shared.setShortcutEnabled(enabled, for: kind) }
    }
  }

  private static func collectOverlayShortcut(
    _ reader: inout SnapzyConfigurationReader,
    path: [String],
    mutations: inout [() -> Void],
    apply: @escaping (CaptureOverlayShortcut?) -> Void
  ) {
    let enabled = reader.bool(path + ["enabled"])
    let key = reader.string(path + ["key"])
    let modifiers = reader.stringArray(path + ["modifiers"])
    guard enabled != nil || key != nil || modifiers != nil else { return }

    if enabled == false || key == "" {
      mutations.append { apply(nil) }
      return
    }

    guard key != nil || modifiers == nil else {
      reader.error("\(path.joined(separator: ".")).modifiers requires key")
      return
    }

    guard let key,
          let shortcut = SnapzyConfigurationShortcutCodec.overlayShortcut(
            key: key,
            modifiers: modifiers ?? []
          ) else {
      reader.error("\(path.joined(separator: ".")) has an invalid shortcut")
      return
    }

    mutations.append { apply(shortcut) }
  }

  private static func collectAnnotateTools(
    _ reader: inout SnapzyConfigurationReader,
    mutations: inout [() -> Void]
  ) {
    let disabled = disabledAnnotateTools(from: &reader)

    for tool in AnnotateShortcutManager.configurableTools {
      if let key = reader.string("shortcuts", "annotate_tools", tool.rawValue) {
        if key.isEmpty {
          mutations.append {
            AnnotateShortcutManager.shared.setShortcut(nil, for: tool)
          }
          continue
        }

        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedKey.count == 1,
              let shortcut = normalizedKey.first,
              shortcut.isLetter || shortcut.isNumber || shortcut.isPunctuation || shortcut.isSymbol else {
          reader.error("shortcuts.annotate_tools.\(tool.rawValue) must be a single letter, number, or special character")
          continue
        }

        mutations.append {
          AnnotateShortcutManager.shared.setShortcut(shortcut, for: tool)
        }
      }
      if let disabled {
        mutations.append {
          AnnotateShortcutManager.shared.setShortcutEnabled(!disabled.contains(tool), for: tool)
        }
      }
    }
  }

  private static func collectAnnotateActions(
    _ reader: inout SnapzyConfigurationReader,
    mutations: inout [() -> Void]
  ) {
    let disabled = disabledAnnotateActions(from: &reader)

    for kind in AnnotateActionShortcutKind.allCases {
      collectAnnotateAction(&reader, kind: kind, disabled: disabled, mutations: &mutations)
    }
  }

  private static func collectAnnotateAction(
    _ reader: inout SnapzyConfigurationReader,
    kind: AnnotateActionShortcutKind,
    disabled: Set<AnnotateActionShortcutKind>?,
    mutations: inout [() -> Void]
  ) {
    let path = ["shortcuts", "annotate_actions", kind.configKey]
    let key = reader.string(path + ["key"])
    let modifiers = reader.stringArray(path + ["modifiers"])
    let explicitEnabled = reader.bool(path + ["enabled"])

    guard key != nil || modifiers != nil || explicitEnabled != nil || disabled != nil else { return }
    guard key != nil || modifiers == nil else {
      reader.error("shortcuts.annotate_actions.\(kind.configKey).modifiers requires key")
      return
    }

    if let key, key.isEmpty {
      mutations.append {
        AnnotateShortcutManager.shared.setShortcut(nil, for: kind)
      }
      mutations.append {
        let enabled = explicitEnabled ?? (disabled.map { !$0.contains(kind) } ?? false)
        AnnotateShortcutManager.shared.setActionShortcutEnabled(enabled, for: kind)
      }
      return
    }

    if let key {
      guard let shortcut = SnapzyConfigurationShortcutCodec.shortcut(
        key: key,
        modifiers: modifiers ?? [],
        requireModifier: !kind.allowsSingleKey
      ) else {
        reader.error("shortcuts.annotate_actions.\(kind.configKey) has an invalid shortcut")
        return
      }
      mutations.append { AnnotateShortcutManager.shared.setShortcut(shortcut, for: kind) }
    }

    if explicitEnabled != nil || disabled != nil {
      let enabled = explicitEnabled ?? !(disabled?.contains(kind) ?? false)
      mutations.append {
        AnnotateShortcutManager.shared.setActionShortcutEnabled(enabled, for: kind)
      }
    }
  }

  private static func disabledAnnotateTools(
    from reader: inout SnapzyConfigurationReader
  ) -> Set<AnnotationToolType>? {
    guard let rawValues = reader.stringArray("shortcuts", "annotate_tools", "disabled") else { return nil }
    var disabled: Set<AnnotationToolType> = []

    for rawValue in rawValues {
      guard let tool = AnnotationToolType(rawValue: rawValue) else {
        reader.error("shortcuts.annotate_tools.disabled contains unknown tool \(rawValue)")
        continue
      }
      disabled.insert(tool)
    }

    return disabled
  }

  private static func disabledAnnotateActions(
    from reader: inout SnapzyConfigurationReader
  ) -> Set<AnnotateActionShortcutKind>? {
    guard let rawValues = reader.stringArray("shortcuts", "annotate_actions", "disabled") else { return nil }
    var disabled: Set<AnnotateActionShortcutKind> = []

    for rawValue in rawValues {
      guard let kind = AnnotateActionShortcutKind(rawValue: rawValue) else {
        reader.error("shortcuts.annotate_actions.disabled contains unknown action \(rawValue)")
        continue
      }
      disabled.insert(kind)
    }

    return disabled
  }
}

extension QuickAccessActionSlot {
  var configKey: String {
    switch self {
    case .centerTop: return "center_top"
    case .centerBottom: return "center_bottom"
    case .topTrailing: return "top_trailing"
    case .topLeading: return "top_leading"
    case .bottomLeading: return "bottom_leading"
    case .bottomTrailing: return "bottom_trailing"
    }
  }
}

@MainActor
private extension AnnotateShortcutManager {
  func setShortcut(_ config: ShortcutConfig?, for kind: AnnotateActionShortcutKind) {
    setActionShortcut(config, for: kind)
  }
}
