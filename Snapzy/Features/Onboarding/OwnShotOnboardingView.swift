//
//  OwnShotOnboardingView.swift
//  Snapzy
//
//  Экраны онбординга OwnShot используют системные иллюстрации и иконку приложения.
//

import AppKit
import SwiftUI

struct OwnShotOnboardingView: View {
  @ObservedObject var model: OwnShotOnboardingModel

  var body: some View {
    VStack(spacing: 0) {
      Spacer(minLength: 24)
      content
        .frame(maxWidth: .infinity)
        .transition(.opacity)
        .id(model.step)
      Spacer(minLength: 24)
      buttons
        .padding(.bottom, 32)
    }
    .padding(.horizontal, 48)
    .frame(width: OwnShotOnboardingWindowController.contentSize.width,
           height: OwnShotOnboardingWindowController.contentSize.height)
    .animation(.easeInOut(duration: 0.2), value: model.step)
    .alert(L10n.OwnShotOnboarding.shortcutsNotDisabledTitle, isPresented: $model.showsShortcutsNotDisabledAlert) {
      Button(L10n.Common.ok) {}
    } message: {
      Text(L10n.OwnShotOnboarding.shortcutsNotDisabledMessage)
    }
  }

  // MARK: - Content

  @ViewBuilder
  private var content: some View {
    switch model.step {
    case .welcome:
      basic(
        illustration: appIcon,
        title: L10n.OwnShotOnboarding.welcomeTitle,
        message: L10n.OwnShotOnboarding.welcomeMessage
      )
    case .defaultTool:
      basic(
        illustration: asset("onboardingShortcuts"),
        title: L10n.OwnShotOnboarding.defaultToolTitle,
        message: L10n.OwnShotOnboarding.defaultToolMessage(shortcuts: model.defaultShortcutsDescription)
      )
    case .systemShortcuts:
      systemShortcuts
    case .launchAtLogin:
      basic(
        illustration: symbol("power"),
        title: L10n.OwnShotOnboarding.launchAtLoginTitle,
        message: L10n.OwnShotOnboarding.launchAtLoginMessage
      )
    case .hideDesktopIcons:
      VStack(spacing: 18) {
        basic(
          illustration: asset("onboardingDesktopIcons"),
          title: L10n.OwnShotOnboarding.hideDesktopIconsTitle,
          message: L10n.OwnShotOnboarding.hideDesktopIconsMessage
        )
        Toggle(L10n.OwnShotOnboarding.hideDesktopIconsTitle, isOn: $model.hidesDesktopIcons)
          .toggleStyle(.switch)
          .fixedSize()
      }
    case .preferences:
      basic(
        illustration: asset("onboardingTweak"),
        title: L10n.OwnShotOnboarding.preferencesTitle,
        message: L10n.OwnShotOnboarding.preferencesMessage
      )
    case .finish:
      VStack(spacing: 16) {
        symbol("menubar.rectangle")
        title(L10n.OwnShotOnboarding.finishTitle)
        message(L10n.OwnShotOnboarding.finishMessage)
      }
    }
  }

  /// Шаги отключения стандартных сочетаний скриншотов в настройках macOS.
  private var systemShortcuts: some View {
    VStack(alignment: .leading, spacing: 18) {
      instruction(1, resource: "onboardingShortcuts1", L10n.OwnShotOnboarding.systemShortcutsStep1)
      instruction(2, resource: "onboardingShortcuts2", L10n.OwnShotOnboarding.systemShortcutsStep2)
      instruction(3, resource: "onboardingShortcuts3", L10n.OwnShotOnboarding.systemShortcutsStep3)
      instruction(4, icon: "switch.2", L10n.OwnShotOnboarding.systemShortcutsStep4)
    }
    .fixedSize(horizontal: false, vertical: true)
  }

  private func instruction(_ number: Int, icon: String? = nil, resource: String? = nil, _ markdown: String) -> some View {
    HStack(alignment: .center, spacing: 12) {
      Group {
        if let resource {
          OwnShotSymbols.image(resource)
            .font(.system(size: 20))
            .foregroundStyle(.secondary)
        } else if let icon {
          Image(systemName: icon)
            .font(.system(size: 18))
            .foregroundStyle(.secondary)
        }
      }
      .frame(width: 41)
      Text("\(number).")
        .font(.system(size: 14, weight: .semibold))
        .monospacedDigit()
      Text(Self.attributed(markdown))
        .font(.system(size: 14))
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private static func attributed(_ markdown: String) -> AttributedString {
    (try? AttributedString(
      markdown: markdown,
      options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    )) ?? AttributedString(markdown)
  }

  // MARK: - Buttons

  @ViewBuilder
  private var buttons: some View {
    let titles = Self.buttonTitles(for: model.step)
    HStack(spacing: 12) {
      if let secondary = titles.secondary {
        Button(secondary) { model.answer(.secondary) }
          .controlSize(.large)
          .keyboardShortcut(.cancelAction)
      }
      Button(titles.primary) { model.answer(.primary) }
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
    }
  }

  static func buttonTitles(for step: OwnShotOnboardingStep) -> (primary: String, secondary: String?) {
    switch step {
    case .welcome, .hideDesktopIcons, .preferences:
      return (L10n.OwnShotOnboarding.continueButton, nil)
    case .defaultTool, .launchAtLogin:
      return (L10n.OwnShotOnboarding.yesButton, L10n.OwnShotOnboarding.noButton)
    case .systemShortcuts:
      return (L10n.OwnShotOnboarding.continueButton, L10n.OwnShotOnboarding.skipButton)
    case .finish:
      return (L10n.OwnShotOnboarding.doneButton, nil)
    }
  }

  // MARK: - Pieces

  private func basic(illustration: some View, title: String, message: String) -> some View {
    VStack(spacing: 16) {
      illustration
      self.title(title)
      self.message(message)
    }
  }

  private func title(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 24, weight: .semibold))
      .multilineTextAlignment(.center)
  }

  private func message(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 14))
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .lineSpacing(3)
      .fixedSize(horizontal: false, vertical: true)
  }

  private func symbol(_ name: String) -> some View {
    Image(systemName: name)
      .font(.system(size: 56, weight: .light))
      .foregroundStyle(.secondary)
      .frame(height: 96)
  }

  /// Системная иллюстрация для шага онбординга.
  private func asset(_ name: String) -> some View {
    symbol(OwnShotSymbols.names[name] ?? "questionmark.circle")
  }

  private var appIcon: some View {
    Image(nsImage: NSApp.applicationIconImage ?? NSImage())
      .resizable()
      .frame(width: 96, height: 96)
  }
}
