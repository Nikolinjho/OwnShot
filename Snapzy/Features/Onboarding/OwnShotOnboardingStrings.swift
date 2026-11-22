//
//  OwnShotOnboardingStrings.swift
//  Snapzy
//
//  Тексты онбординга OwnShot. Английские значения эталона (binary-strings.txt:9520–9555,
//  10739–10748), имя продукта заменено на OwnShot. Подписи кнопок в статике не найдены.
//

import Foundation

extension L10n {
  nonisolated enum OwnShotOnboarding {
    static let windowTitle = string("onboarding.ownshot.window-title", defaultValue: "Welcome to OwnShot", comment: "Onboarding window title")

    static let welcomeTitle = string("onboarding.ownshot.welcome-title", defaultValue: "Welcome to OwnShot", comment: "First onboarding screen title")
    static let welcomeMessage = string("onboarding.ownshot.welcome-message", defaultValue: "Let's walk you through a quick configuration\nand tailor OwnShot to your needs.", comment: "First onboarding screen text")

    static let defaultToolTitle = string("onboarding.ownshot.default-tool-title", defaultValue: "Set as default screenshot tool?", comment: "Onboarding screen that assigns macOS screenshot shortcuts to OwnShot")
    static let defaultToolMessage = string("onboarding.ownshot.default-tool-message", defaultValue: "Do you want to assign shortcuts\nto OwnShot and enable launching at login?", comment: "Onboarding default tool screen text without the shortcut list")
    static func defaultToolMessage(shortcuts: String) -> String {
      format("onboarding.ownshot.default-tool-message-shortcuts", defaultValue: "Do you want to assign %@\nshortcuts to OwnShot and enable launching at login?", comment: "Onboarding default tool screen text with the shortcut list", shortcuts)
    }

    static let systemShortcutsStep1 = string("onboarding.ownshot.system-shortcuts-step-1", defaultValue: "Open [System Settings](x-apple.systempreferences:com.apple.Keyboard-Settings.extension).", comment: "Instruction to disable macOS screenshot shortcuts, step 1")
    static let systemShortcutsStep2 = string("onboarding.ownshot.system-shortcuts-step-2", defaultValue: "Open **Keyboard** panel and click on **Keyboard Shortcuts...** button.", comment: "Instruction to disable macOS screenshot shortcuts, step 2")
    static let systemShortcutsStep3 = string("onboarding.ownshot.system-shortcuts-step-3", defaultValue: "Choose **Screenshots** from the list on the left.", comment: "Instruction to disable macOS screenshot shortcuts, step 3")
    static let systemShortcutsStep4 = string("onboarding.ownshot.system-shortcuts-step-4", defaultValue: "Turn off all shortcuts.", comment: "Instruction to disable macOS screenshot shortcuts, step 4")
    static let shortcutsNotDisabledTitle = string("onboarding.ownshot.shortcuts-not-disabled-title", defaultValue: "Shortcuts not disabled", comment: "Alert title when macOS screenshot shortcuts are still enabled")
    static let shortcutsNotDisabledMessage = string("onboarding.ownshot.shortcuts-not-disabled-message", defaultValue: "It looks like you haven't disabled Screenshots shortcuts.", comment: "Alert text when macOS screenshot shortcuts are still enabled")

    static let launchAtLoginTitle = string("onboarding.ownshot.launch-at-login-title", defaultValue: "Launch at login", comment: "Onboarding launch at login screen title")
    static let launchAtLoginMessage = string("onboarding.ownshot.launch-at-login-message", defaultValue: "Would you like to have OwnShot ready\nas soon as your Mac boots up?", comment: "Onboarding launch at login screen text")

    static let hideDesktopIconsTitle = string("onboarding.ownshot.hide-desktop-icons-title", defaultValue: "Hide desktop icons", comment: "Onboarding desktop icons screen title and switch label")
    static let hideDesktopIconsMessage = string("onboarding.ownshot.hide-desktop-icons-message", defaultValue: "Would you like to have your desktop icons hidden\nautomatically while capturing your screen?", comment: "Onboarding desktop icons screen text")

    static let preferencesTitle = string("onboarding.ownshot.preferences-title", defaultValue: "Tweak your workflow", comment: "Onboarding settings screen title")
    static let preferencesMessage = string("onboarding.ownshot.preferences-message", defaultValue: "You can adjust all the settings and set your own\nkeyboard shortcuts later in the app Preferences.", comment: "Onboarding settings screen text")

    static let finishTitle = string("onboarding.ownshot.finish-title", defaultValue: "OwnShot is ready to use!", comment: "Last onboarding screen title")
    static let finishMessage = string("onboarding.ownshot.finish-message", defaultValue: "You can access the app through the menu bar icon or by using the defined keyboard shortcuts.", comment: "Last onboarding screen text")

    static let continueButton = string("onboarding.ownshot.continue", defaultValue: "Continue", comment: "Onboarding primary button")
    static let yesButton = string("onboarding.ownshot.yes", defaultValue: "Yes", comment: "Onboarding button that accepts the suggestion")
    static let noButton = string("onboarding.ownshot.no", defaultValue: "No", comment: "Onboarding button that declines the suggestion")
    static let skipButton = string("onboarding.ownshot.skip", defaultValue: "Skip", comment: "Onboarding button that skips the step")
    static let doneButton = string("onboarding.ownshot.done", defaultValue: "Done", comment: "Onboarding button that closes the last screen")
  }
}
