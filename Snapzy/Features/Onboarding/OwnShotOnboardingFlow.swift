//
//  OwnShotOnboardingFlow.swift
//  Snapzy
//
//  Пошаговый онбординг как у эталона: классы ONWelcomeView … ONFinishView
//  (binary-strings.txt:16500–16512). Cloud (заглушка) и Statistics (телеметрия вне объёма)
//  пропускаются, остальные экраны идут в порядке объявления классов.
//

import Combine
import Foundation

enum OwnShotOnboardingStep: String, CaseIterable, Equatable {
  case welcome
  case defaultTool
  case systemShortcuts
  case launchAtLogin
  case hideDesktopIcons
  case preferences
  case finish
}

/// Какая из двух кнопок экрана нажата: основная (Yes/Continue) или вторая (No/Skip).
enum OwnShotOnboardingAnswer: Equatable {
  case primary
  case secondary
}

enum OwnShotOnboardingFlow {
  /// Следующий экран. nil – онбординг закончен.
  /// Экран System shortcuts повторяется, пока системные сочетания не выключены.
  static func next(
    after step: OwnShotOnboardingStep,
    answer: OwnShotOnboardingAnswer,
    hasSystemShortcutConflict: Bool,
    isLaunchAtLoginEnabled: Bool
  ) -> OwnShotOnboardingStep? {
    switch step {
    case .welcome:
      return .defaultTool
    case .defaultTool:
      if answer == .primary {
        // «Yes» сразу включает запуск при входе, отдельный экран не нужен.
        return hasSystemShortcutConflict ? .systemShortcuts : .hideDesktopIcons
      }
      return isLaunchAtLoginEnabled ? .hideDesktopIcons : .launchAtLogin
    case .systemShortcuts:
      if answer == .primary, hasSystemShortcutConflict { return .systemShortcuts }
      return .hideDesktopIcons
    case .launchAtLogin:
      return .hideDesktopIcons
    case .hideDesktopIcons:
      return .preferences
    case .preferences:
      return .finish
    case .finish:
      return nil
    }
  }
}

/// Первый запуск: онбординг показывается один раз (onboardingDisplayed у эталона).
/// Кто уже видел Settings › Permissions прошлых версий OwnShot, онбординг не получает.
enum OwnShotOnboardingLaunch {
  static let displayedKey = "ownshot.onboardingDisplayed"
  static let legacyPermissionsKey = "ownshot.didPresentPermissions"

  static func shouldPresentOnLaunch(defaults: UserDefaults = .standard) -> Bool {
    !defaults.bool(forKey: displayedKey) && !defaults.bool(forKey: legacyPermissionsKey)
  }

  static func markPresented(defaults: UserDefaults = .standard) {
    defaults.set(true, forKey: displayedKey)
  }
}

/// Побочные эффекты онбординга. В тестах подменяются, чтобы не трогать Carbon и SMAppService.
@MainActor
protocol OwnShotOnboardingActions {
  var defaultShortcutsDescription: String { get }
  var isLaunchAtLoginEnabled: Bool { get }
  var hidesDesktopIcons: Bool { get }
  func assignSystemDefaultShortcuts() -> Bool
  func hasSystemShortcutConflict() -> Bool
  func setLaunchAtLogin(_ enabled: Bool)
  func setHidesDesktopIcons(_ enabled: Bool)
}

@MainActor
struct OwnShotOnboardingLiveActions: OwnShotOnboardingActions {
  var defaultShortcutsDescription: String {
    [ShortcutConfig.defaultFullscreen, .defaultArea, .defaultRecording]
      .map(\.displayString)
      .joined(separator: " ")
  }

  var isLaunchAtLoginEnabled: Bool { LoginItemManager.isEnabled }

  var hidesDesktopIcons: Bool {
    UserDefaults.standard.bool(forKey: PreferencesKeys.hideDesktopIcons)
  }

  func assignSystemDefaultShortcuts() -> Bool {
    SystemScreenshotShortcutManager.shared.assignOwnShotDefaults(confirmed: true)
  }

  func hasSystemShortcutConflict() -> Bool {
    SystemScreenshotShortcutManager.shared.hasConflictingSystemShortcuts()
  }

  func setLaunchAtLogin(_ enabled: Bool) {
    guard LoginItemManager.isEnabled != enabled else { return }
    LoginItemManager.setEnabled(enabled)
  }

  func setHidesDesktopIcons(_ enabled: Bool) {
    UserDefaults.standard.set(enabled, forKey: PreferencesKeys.hideDesktopIcons)
  }
}

@MainActor
final class OwnShotOnboardingModel: ObservableObject {
  @Published private(set) var step: OwnShotOnboardingStep = .welcome
  @Published var showsShortcutsNotDisabledAlert = false
  @Published var hidesDesktopIcons: Bool {
    didSet {
      guard oldValue != hidesDesktopIcons else { return }
      actions.setHidesDesktopIcons(hidesDesktopIcons)
    }
  }

  private let actions: OwnShotOnboardingActions
  private let onFinish: () -> Void

  init(actions: OwnShotOnboardingActions, onFinish: @escaping () -> Void) {
    self.actions = actions
    self.onFinish = onFinish
    self.hidesDesktopIcons = actions.hidesDesktopIcons
  }

  var defaultShortcutsDescription: String { actions.defaultShortcutsDescription }

  func answer(_ answer: OwnShotOnboardingAnswer) {
    switch (step, answer) {
    case (.defaultTool, .primary):
      if !actions.assignSystemDefaultShortcuts() {
        DiagnosticLogger.shared.log(.warning, .ui, "Onboarding could not assign system default shortcuts")
      }
      actions.setLaunchAtLogin(true)
    case (.launchAtLogin, _):
      actions.setLaunchAtLogin(answer == .primary)
    default:
      break
    }

    // Конфликт проверяется только там, где он влияет на переход.
    let needsConflictCheck = step == .defaultTool && answer == .primary
      || step == .systemShortcuts && answer == .primary
    let hasConflict = needsConflictCheck && actions.hasSystemShortcutConflict()

    guard let next = OwnShotOnboardingFlow.next(
      after: step,
      answer: answer,
      hasSystemShortcutConflict: hasConflict,
      isLaunchAtLoginEnabled: actions.isLaunchAtLoginEnabled
    ) else {
      onFinish()
      return
    }

    if step == .systemShortcuts, next == .systemShortcuts {
      showsShortcutsNotDisabledAlert = true
      return
    }
    step = next
  }
}
