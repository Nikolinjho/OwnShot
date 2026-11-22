//
//  ShortcutValidationService.swift
//  Snapzy
//
//  Centralized validation rules for editable keyboard shortcuts
//

import Foundation

enum ShortcutValidationSeverity: Equatable {
  case warning
  case error
}

/// Offer attached to a duplicate-shortcut rejection: the user can swap shortcuts
/// with the action that already owns the combination instead of being blocked.
struct ShortcutSwapProposal: Equatable {
  enum Owner: Equatable {
    case global(GlobalShortcutKind)
    case annotateAction(AnnotateActionShortcutKind)
    case quickAccessAction(QuickAccessActionKind)
    case annotateTool(AnnotationToolType)
  }

  enum Value: Equatable {
    case combo(ShortcutConfig)
    case key(Character)
  }

  /// Action currently holding the requested shortcut.
  let owner: Owner
  /// Shortcut the user just tried to record.
  let value: Value
}

struct ShortcutValidationIssue: Equatable {
  let severity: ShortcutValidationSeverity
  /// Заголовок поповера, как у эталона: «Shortcut is used for another action».
  var title: String? = nil
  let message: String
  var swapProposal: ShortcutSwapProposal? = nil
  /// Unique per validation run, so recording the same rejected combo again still counts
  /// as a change and re-presents the popover (and its Swap offer) after it was dismissed.
  let occurrenceID = UUID()
}

enum ShortcutValidationDecision: Equatable {
  case accept(issue: ShortcutValidationIssue?)
  case reject(issue: ShortcutValidationIssue)
}

@MainActor
final class ShortcutValidationService {

  static let shared = ShortcutValidationService()

  func validateGlobalShortcut(
    _ config: ShortcutConfig?,
    for kind: GlobalShortcutKind
  ) -> ShortcutValidationDecision {
    guard let config else { return .accept(issue: nil) }

    if allInOneShortcut() == config {
      return .reject(issue: duplicateIssue(config, ownerName: "All-In-One"))
    }

    if let conflictKind = conflictingGlobalShortcut(for: config, excluding: kind) {
      return .reject(issue: duplicateIssue(config, ownerName: conflictKind.displayName, swapProposal: ShortcutSwapProposal(owner: .global(conflictKind), value: .combo(config))))
    }

    if let conflictKind = conflictingAnnotateActionShortcut(for: config, excluding: nil) {
      return .reject(issue: duplicateIssue(config, ownerName: conflictKind.displayName, swapProposal: ShortcutSwapProposal(owner: .annotateAction(conflictKind), value: .combo(config))))
    }

    let matchesScreenshotHotkey = !SystemScreenshotShortcutManager.shared.conflictDescriptions(
      for: kind,
      shortcut: config
    ).isEmpty
    if matchesScreenshotHotkey || isReservedBySystem(config) {
      return Self.systemReservedDecision(config, isDefault: config == Self.defaultGlobalShortcut(for: kind))
    }

    return .accept(issue: nil)
  }

  /// Сочетание занято включённым сочетанием macOS. Как у эталона, новое сочетание
  /// не назначается. Исключение — дефолт OwnShot (⇧⌘3, ⇧⌘4, ⇧⌘5 совпадают с macOS):
  /// сброс к нему проходит с предупреждением, иначе Reset to default был бы недоступен.
  static func systemReservedDecision(_ config: ShortcutConfig, isDefault: Bool) -> ShortcutValidationDecision {
    if isDefault {
      return .accept(issue: ShortcutValidationIssue(
        severity: .warning,
        title: L10n.ShortcutValidation.reservedForMacOSTitle,
        message: L10n.ShortcutValidation.usedByMacOSDefault(config.menuSymbolString)
      ))
    }
    return .reject(issue: ShortcutValidationIssue(
      severity: .error,
      title: L10n.ShortcutValidation.reservedForMacOSTitle,
      message: L10n.ShortcutValidation.usedByMacOS(config.menuSymbolString)
    ))
  }

  /// Дефолтные сочетания глобальных команд (для исключения при проверке на macOS).
  static func defaultGlobalShortcut(for kind: GlobalShortcutKind) -> ShortcutConfig? {
    switch kind {
    case .fullscreen: return .defaultFullscreen
    case .area: return .defaultArea
    case .repeatArea: return .defaultRepeatArea
    case .areaAnnotate: return .defaultAreaAnnotate
    case .recording: return .defaultRecording
    case .scrollingCapture: return .defaultScrollingCapture
    case .ocr: return .defaultOCR
    case .smartElement: return .defaultSmartElement
    case .measureScreen: return .defaultMeasureScreen
    case .objectCutout: return .defaultObjectCutout
    case .activeWindow: return .defaultActiveWindowCapture
    case .annotate: return .defaultAnnotate
    case .videoEditor: return .defaultVideoEditor
    case .cloudUploads: return .defaultCloudUploads
    case .shortcutList: return .defaultShortcutList
    case .history: return .defaultHistory
    default: return nil
    }
  }

  /// Дубликат: заголовок и текст как у эталона («⇧⌘1 is assigned to "Capture Area".»).
  func duplicateIssue(
    _ config: ShortcutConfig,
    ownerName: String,
    swapProposal: ShortcutSwapProposal? = nil
  ) -> ShortcutValidationIssue {
    ShortcutValidationIssue(
      severity: .error,
      title: L10n.ShortcutValidation.usedForAnotherActionTitle,
      message: L10n.ShortcutValidation.assignedTo(config.menuSymbolString, ownerName),
      swapProposal: swapProposal
    )
  }

  func validateAllInOneShortcut(_ config: ShortcutConfig?) -> ShortcutValidationDecision {
    guard let config else { return .accept(issue: nil) }
    if let kind = conflictingGlobalShortcut(for: config, excluding: nil) {
      return .reject(issue: duplicateIssue(config, ownerName: kind.displayName))
    }
    if let kind = conflictingAnnotateActionShortcut(for: config, excluding: nil) {
      return .reject(issue: duplicateIssue(config, ownerName: kind.displayName))
    }
    return .accept(issue: nil)
  }

  /// Проверка сочетания, записанного в строке All-In-One: как `validateAllInOneShortcut`,
  /// плюс запрет системных сочетаний macOS. Use System Default Shortcuts сознательно
  /// назначает ⇧⌘5 и идёт мимо этой проверки.
  func validateRecordedAllInOneShortcut(_ config: ShortcutConfig?) -> ShortcutValidationDecision {
    let decision = validateAllInOneShortcut(config)
    guard case .accept = decision, let config, isReservedBySystem(config) else { return decision }
    return Self.systemReservedDecision(config, isDefault: false)
  }

  func validateAnnotateActionShortcut(
    _ config: ShortcutConfig?,
    for kind: AnnotateActionShortcutKind
  ) -> ShortcutValidationDecision {
    guard let config else { return .accept(issue: nil) }

    if allInOneShortcut() == config {
      return .reject(issue: duplicateIssue(config, ownerName: "All-In-One"))
    }

    if let conflictKind = conflictingAnnotateActionShortcut(for: config, excluding: kind) {
      return .reject(issue: duplicateIssue(config, ownerName: conflictKind.displayName, swapProposal: ShortcutSwapProposal(owner: .annotateAction(conflictKind), value: .combo(config))))
    }

    if let conflictKind = conflictingGlobalShortcut(for: config, excluding: nil) {
      return .reject(issue: duplicateIssue(config, ownerName: conflictKind.displayName, swapProposal: ShortcutSwapProposal(owner: .global(conflictKind), value: .combo(config))))
    }

    return .accept(issue: nil)
  }

  /// Quick Access card actions live in their own namespace: they are only
  /// registered while a card is hovered, so they may reuse Annotate keys. They do
  /// shadow global shortcuts during hover, which is a warning rather than a block.
  func validateQuickAccessActionShortcut(
    _ config: ShortcutConfig?,
    for action: QuickAccessActionKind
  ) -> ShortcutValidationDecision {
    guard let config else { return .accept(issue: nil) }

    if QuickAccessActionShortcutStore.containsFunctionModifier(config) {
      return .reject(issue: ShortcutValidationIssue(
        severity: .error,
        message: L10n.ShortcutValidation.quickAccessFnUnsupported
      ))
    }

    guard QuickAccessActionShortcutStore.hasRequiredModifier(config) else {
      return .reject(issue: ShortcutValidationIssue(
        severity: .error,
        message: L10n.ShortcutValidation.quickAccessModifierRequired
      ))
    }

    if let conflictAction = conflictingQuickAccessActionShortcut(for: config, excluding: action) {
      return .reject(issue: duplicateIssue(config, ownerName: conflictAction.settingsTitle, swapProposal: ShortcutSwapProposal(owner: .quickAccessAction(conflictAction), value: .combo(config))))
    }

    if let conflictKind = conflictingGlobalShortcut(for: config, excluding: nil) {
      return .accept(issue: ShortcutValidationIssue(
        severity: .warning,
        message: L10n.ShortcutValidation.quickAccessShadowsGlobal(conflictKind.displayName)
      ))
    }

    return .accept(issue: nil)
  }

  func validateAnnotateToolShortcut(
    _ key: Character,
    for tool: AnnotationToolType
  ) -> ShortcutValidationDecision {
    if let conflictTool = AnnotateShortcutManager.shared.conflictingTool(for: key, excluding: tool) {
      return .reject(issue: ShortcutValidationIssue(
        severity: .error,
        title: L10n.ShortcutValidation.usedForAnotherActionTitle,
        message: L10n.ShortcutValidation.assignedTo(String(key).uppercased(), conflictTool.shortcutSettingsTitle),
        swapProposal: ShortcutSwapProposal(owner: .annotateTool(conflictTool), value: .key(key))
      ))
    }

    return .accept(issue: nil)
  }

  func validateCaptureOverlayShortcut(
    _ shortcut: CaptureOverlayShortcut?,
    for kind: CaptureOverlayShortcutKind
  ) -> ShortcutValidationDecision {
    guard let shortcut else { return .accept(issue: nil) }
    guard let config = shortcut.independentShortcutConfig else {
      return .accept(issue: nil)
    }

    if let conflictKind = conflictingGlobalShortcut(for: config, excluding: nil) {
      return .reject(issue: duplicateIssue(config, ownerName: conflictKind.displayName))
    }

    if let conflictKind = conflictingAnnotateActionShortcut(for: config, excluding: nil) {
      return .reject(issue: duplicateIssue(config, ownerName: conflictKind.displayName))
    }

    if let conflictKind = conflictingCaptureOverlayShortcut(for: config, excluding: kind) {
      return .reject(issue: duplicateIssue(config, ownerName: conflictKind.displayName))
    }

    let matchesScreenshotHotkey = !SystemScreenshotShortcutManager.shared.conflictDescriptions(
      for: kind.systemConflictKind,
      shortcut: config
    ).isEmpty
    if matchesScreenshotHotkey || isReservedBySystem(config) {
      return Self.systemReservedDecision(config, isDefault: false)
    }

    return .accept(issue: nil)
  }

  private func conflictingGlobalShortcut(
    for config: ShortcutConfig,
    excluding excludedKind: GlobalShortcutKind?
  ) -> GlobalShortcutKind? {
    GlobalShortcutKind.allCases.first(where: {
      $0 != excludedKind
        && KeyboardShortcutManager.shared.isShortcutEnabled(for: $0)
        && KeyboardShortcutManager.shared.shortcut(for: $0) == config
    })
  }

  private func conflictingAnnotateActionShortcut(
    for config: ShortcutConfig,
    excluding excludedKind: AnnotateActionShortcutKind?
  ) -> AnnotateActionShortcutKind? {
    AnnotateActionShortcutKind.allCases.first(where: {
      $0 != excludedKind
        && AnnotateShortcutManager.shared.isActionShortcutEnabled(for: $0)
        && AnnotateShortcutManager.shared.shortcut(for: $0) == config
    })
  }

  private func conflictingQuickAccessActionShortcut(
    for config: ShortcutConfig,
    excluding excludedAction: QuickAccessActionKind
  ) -> QuickAccessActionKind? {
    QuickAccessActionKind.allCases.first(where: {
      $0 != excludedAction
        && QuickAccessActionShortcutStore.shared.isEnabled(for: $0)
        && QuickAccessActionShortcutStore.shared.shortcut(for: $0) == config
    })
  }

  private func conflictingCaptureOverlayShortcut(
    for config: ShortcutConfig,
    excluding excludedKind: CaptureOverlayShortcutKind
  ) -> CaptureOverlayShortcutKind? {
    [CaptureOverlayShortcutKind.applicationCapture, .applicationRecording].first(where: {
      $0 != excludedKind
        && CaptureOverlayShortcutSettings.shortcut(for: $0)?.independentShortcutConfig == config
    })
  }

  private let allInOneShortcut: @MainActor () -> ShortcutConfig?
  /// Проверка на включённое системное сочетание macOS; подменяется в тестах.
  private let isReservedBySystem: @MainActor (ShortcutConfig) -> Bool

  init(
    allInOneShortcut: @escaping @MainActor () -> ShortcutConfig? = { OwnShotAllInOneShortcut.shared.shortcut },
    isReservedBySystem: @escaping @MainActor (ShortcutConfig) -> Bool = {
      SystemScreenshotShortcutManager.shared.isReservedBySystem($0)
    }
  ) {
    self.allInOneShortcut = allInOneShortcut
    self.isReservedBySystem = isReservedBySystem
  }
}

private extension CaptureOverlayShortcutKind {
  var systemConflictKind: GlobalShortcutKind {
    switch self {
    case .applicationCapture:
      return .area
    case .applicationRecording:
      return .recording
    }
  }
}

private extension AnnotateActionShortcutKind {
  var displayName: String { settingsTitle }
}
