//
//  L10n+License.swift
//  Snapzy
//
//  Строки заглушки лицензирования: группа License в About, окно активации
//  и сообщения о том, что OwnShot – личная сборка.
//

import Foundation

extension L10n {
  nonisolated enum License {
    static let sectionTitle = string(
      "license.section-title",
      defaultValue: "License",
      comment: "About row title for license actions"
    )
    static let managerButton = string(
      "license.manager-button",
      defaultValue: "License Manager…",
      comment: "About button that opens the license manager"
    )
    static let unlinkButton = string(
      "license.unlink-button",
      defaultValue: "Unlink Device…",
      comment: "About button that unlinks this Mac from the license"
    )
    static let personalBuildTitle = string(
      "license.personal-build-title",
      defaultValue: "OwnShot is a personal build",
      comment: "Alert title shown instead of license actions"
    )
    static let managerMessage = string(
      "license.manager-message",
      defaultValue: "There is no license or account to manage. All features are available on this Mac.",
      comment: "Alert message for License Manager in a personal build"
    )
    static let unlinkMessage = string(
      "license.unlink-message",
      defaultValue: "This Mac is not linked to a license, so there is no device to unlink.",
      comment: "Alert message for Unlink Device in a personal build"
    )
    static let lostLicenseMessage = string(
      "license.lost-license-message",
      defaultValue: "There is no license to recover. All features are available on this Mac.",
      comment: "Alert message for the lost license link in a personal build"
    )
    static let activateMenuItem = string(
      "license.activate-menu-item",
      defaultValue: "Activate...",
      comment: "Status menu item that opens the activation window"
    )
    static let activationWindowTitle = string(
      "license.activation-window-title",
      defaultValue: "Activate OwnShot",
      comment: "Activation window title"
    )
    static let keyPlaceholder = string(
      "license.key-placeholder",
      defaultValue: "License key...",
      comment: "Placeholder of the license key field"
    )
    static let activateButton = string(
      "license.activate-button",
      defaultValue: "Activate",
      comment: "Activation window button"
    )
    static let lostLicenseButton = string(
      "license.lost-license-button",
      defaultValue: "Lost your license?",
      comment: "Activation window link for a lost license"
    )
    static let activationErrorTitle = string(
      "license.activation-error-title",
      defaultValue: "Activation error",
      comment: "Alert title when the license key is rejected"
    )
    static let invalidKey = string(
      "license.invalid-key",
      defaultValue: "Please enter a valid license key.",
      comment: "Alert message for an empty or malformed license key"
    )
    static let activationSuccessfulTitle = string(
      "license.activation-successful-title",
      defaultValue: "Activation Successful",
      comment: "Alert title after the activation form is submitted"
    )
    static let keyNotChecked = string(
      "license.key-not-checked",
      defaultValue: "OwnShot is a personal build, so the key was not checked. All features are already available.",
      comment: "Explains that the personal build does not verify license keys"
    )
    static let doneButton = string(
      "license.done-button",
      defaultValue: "Done",
      comment: "Button that closes the activation result"
    )
    static let quitTitle = string(
      "license.quit-title",
      defaultValue: "Are you sure you want to quit?",
      comment: "Alert title when quitting with the activation window open"
    )
    static let quitMessage = string(
      "license.quit-message",
      defaultValue: "This will cancel the current activation process.",
      comment: "Alert message when quitting with the activation window open"
    )
    static let quitButton = string(
      "license.quit-button",
      defaultValue: "Quit",
      comment: "Confirms quitting during activation"
    )
    static let cancelButton = string(
      "license.cancel-button",
      defaultValue: "Cancel",
      comment: "Keeps the app running during activation"
    )

    static func thankYou(_ productName: String) -> String {
      format(
        "license.thank-you",
        defaultValue: "Thank you for choosing %@!",
        comment: "Activation result greeting; the argument is the app name",
        productName
      )
    }
  }
}
