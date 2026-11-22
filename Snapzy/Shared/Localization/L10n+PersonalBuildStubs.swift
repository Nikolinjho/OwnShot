//
//  L10n+PersonalBuildStubs.swift
//  OwnShot
//
//  Строки UI-заглушек личной сборки: раздел Analytics и ссылки в About,
//  пункты Raycast AI Chat. Тексты пунктов взяты из CleanShot X 5.0.1.
//

import Foundation

extension L10n {
  nonisolated enum PersonalBuildStubs {
    // MARK: - About › Links

    static let websiteLink = string(
      "personal-build-stubs.link.website",
      defaultValue: "Website",
      comment: "About link row that opens the OwnShot repository"
    )
    static let changelogLink = string(
      "personal-build-stubs.link.changelog",
      defaultValue: "Changelog",
      comment: "About link row that opens the OwnShot status document in docs"
    )
    static let contactLink = string(
      "personal-build-stubs.link.contact",
      defaultValue: "Contact Us",
      comment: "About link row, disabled in the personal build"
    )
    static let twitterLink = string(
      "personal-build-stubs.link.twitter",
      defaultValue: "Twitter / X",
      comment: "About link row, disabled in the personal build"
    )
    static let youtubeLink = string(
      "personal-build-stubs.link.youtube",
      defaultValue: "YouTube",
      comment: "About link row, disabled in the personal build"
    )
    static let linkUnavailableHelp = string(
      "personal-build-stubs.link.unavailable-help",
      defaultValue: "OwnShot is a personal build and has no page here.",
      comment: "Tooltip of a disabled About link row"
    )

    // MARK: - About › Analytics

    static let analyticsTitle = string(
      "personal-build-stubs.analytics.title",
      defaultValue: "Analytics",
      comment: "About section header"
    )
    static let shareUsageStatistics = string(
      "personal-build-stubs.analytics.share-usage-statistics",
      defaultValue: "Share my usage statistics",
      comment: "About toggle; the value is stored locally and nothing is sent"
    )
    static let analyticsHint = string(
      "personal-build-stubs.analytics.hint",
      defaultValue: "OwnShot is a personal build and does not collect usage statistics. This setting stays on this Mac, nothing is sent.",
      comment: "Description under the usage statistics toggle"
    )

    // MARK: - Raycast AI Chat

    static let sendToRaycastAIChat = string(
      "personal-build-stubs.raycast.send",
      defaultValue: "Send to Raycast AI Chat",
      comment: "Annotate button tooltip and pinned screenshot menu item"
    )
    static let sendToRaycastAIChatMenuItem = string(
      "personal-build-stubs.raycast.send-menu-item",
      defaultValue: "Send To Raycast AI Chat...",
      comment: "Quick Access card context menu item"
    )
    static let captureAreaAndSendToRaycast = string(
      "personal-build-stubs.raycast.capture-area-shortcut",
      defaultValue: "Capture Area & Send to Raycast AI Chat",
      comment: "Settings › Shortcuts row title"
    )
    static let notAvailable = string(
      "personal-build-stubs.not-available",
      defaultValue: "Not Available",
      comment: "Placeholder instead of a shortcut recorder"
    )
    static let raycastUnavailableTitle = string(
      "personal-build-stubs.raycast.unavailable-title",
      defaultValue: "Raycast AI Chat is not available",
      comment: "Alert title shown instead of sending a screenshot to Raycast"
    )
    static let raycastUnavailableMessage = string(
      "personal-build-stubs.raycast.unavailable-message",
      defaultValue: "The Raycast integration is not available in the personal build of OwnShot. The screenshot was not sent.",
      comment: "Alert message shown instead of sending a screenshot to Raycast"
    )
  }
}
