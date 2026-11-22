//
//  PreferencesAboutSettingsView.swift
//  Snapzy
//
//  Redesigned About tab following clean, card-based Hand Mirror aesthetic.
//

import AppKit
import SwiftUI

struct AboutSettingsView: View {
  /// Локальный флаг Analytics: ничего не отправляется.
  @AppStorage(OwnShotUsageStatistics.defaultsKey) private var shareUsageStatistics = false

  private var appVersion: String {
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    // Как у эталона: только версия и сборка, без имени приложения.
    return "\(version) (\(build))"
  }

  @StateObject private var updatesViewModel = CheckForUpdatesViewModel(updater: UpdaterManager.shared.updater)

  var body: some View {
    GeometryReader { proxy in
      ScrollView {
        VStack(spacing: 0) {
          // Шапка эталона: иконка, имя, версия, копирайт одной строкой.
          // Атрибуция Snapzy (BSD 3-Clause) – в окне Acknowledgments.
          heroSection

          // Updates, License, Links, Analytics и Acknowledgments в порядке About эталона.
          updatesCard
            .padding(.top, AboutLayout.heroToCards)

          licenseCard
            .padding(.top, AboutLayout.cardSpacing)

          linksSection
            .padding(.top, AboutLayout.sectionSpacing)

          analyticsSection
            .padding(.top, AboutLayout.sectionSpacing)

          Button("Acknowledgments") { OwnShotAcknowledgmentsWindowController.shared.show() }
            .buttonStyle(.link)
            .padding(.top, AboutLayout.sectionSpacing)

          Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, minHeight: proxy.size.height)
        .padding(.horizontal, AboutLayout.horizontalInset)
        .padding(.top, AboutLayout.topInset)
        .padding(.bottom, 28)
      }
    }
  }

  // MARK: - Hero Section

  /// Шапка по PNG эталона (live 062): видимая иконка 78 pt (кадр 96 pt), имя 24 pt,
  /// версия 11 pt, копирайт 10 pt; от копирайта до Updates 46 pt.
  private var heroSection: some View {
    VStack(spacing: 0) {
      Image(nsImage: NSApp.applicationIconImage)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(width: 96, height: 96)

      Text(verbatim: "OwnShot")
        .font(.system(size: 24, weight: .semibold))
        .foregroundStyle(Color.primary)
        .padding(.top, 5)

      versionStatusLabel
        .padding(.top, 4)

      Text(verbatim: OwnShotAcknowledgments.aboutCopyrightLine)
        .font(.system(size: 10))
        .foregroundStyle(Color.secondary.opacity(0.7))
        .padding(.top, 12)
    }
  }

  // MARK: - Updates

  /// Строки Updates как в эталоне. Источника обновлений у локальной сборки нет,
  /// поэтому кнопка и переключатель видны, но выключены.
  private var updatesCard: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Updates")
        Spacer()
        Button("Check for Updates") {}
          .disabled(true)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 10)

      divider

      HStack {
        Text("Automatically check for updates")
        Spacer()
        PreferencesToggle("Automatically check for updates", isOn: .constant(false))
          .disabled(true)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
    }
    .font(.system(size: 13))
    .cardContainer()
    .help("OwnShot is a local build. Automatic updates are not configured.")
  }

  // MARK: - License

  /// Группа License как в эталоне. Лицензии у личной сборки нет,
  /// поэтому обе кнопки показывают сообщение вместо сетевых действий.
  private var licenseCard: some View {
    HStack {
      Text(L10n.License.sectionTitle)
      Spacer()
      Button(L10n.License.managerButton) { OwnShotLicensePresenter.shared.showLicenseManager() }
      Button(L10n.License.unlinkButton) { OwnShotLicensePresenter.shared.showUnlinkDevice() }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .font(.system(size: 13))
    .cardContainer()
  }

  // MARK: - Links

  private var linksSection: some View {
    VStack(alignment: .leading, spacing: AboutLayout.headerToCard) {
      sectionHeader("Links")

      VStack(spacing: 0) {
        ForEach(Array(OwnShotAboutLink.all.enumerated()), id: \.element.id) { index, link in
          if index > 0 { divider }
          if let url = link.url {
            Link(destination: url) { linkRow(link) }
              .buttonStyle(.plain)
              .accessibilityLabel(link.title)
          } else {
            // Строка эталона без своего адреса: видна, но не открывает чужой аккаунт.
            Button {} label: { linkRow(link) }
              .buttonStyle(.plain)
              .disabled(true)
              .help(L10n.PersonalBuildStubs.linkUnavailableHelp)
              .accessibilityLabel(link.title)
          }
        }
      }
      .cardContainer()
    }
  }

  private var versionStatusLabel: some View {
    HStack(spacing: 6) {
      Text(appVersion)
        .font(.system(size: 11, weight: .regular))
        .foregroundStyle(Color.secondary)

      if let lastCheck = updatesViewModel.lastUpdateCheckDate {
        Text("•")
          .font(.system(size: 10))
          .foregroundStyle(Color.secondary.opacity(0.5))

        HStack(spacing: 3) {
          Text(L10n.PreferencesAbout.checkedLabel)
          Text(lastCheck, style: .relative)
        }
        .font(.system(size: 11, weight: .regular))
        .foregroundStyle(Color.secondary)
      }
    }
  }

  private func linkRow(_ link: OwnShotAboutLink) -> some View {
    HStack(spacing: 12) {
      Image(systemName: link.systemImage)
        .font(.system(size: 14))
        .frame(width: 20)
      Text(link.title)
        .font(.system(size: 13))
      Spacer()
      Image(systemName: "arrow.up.right")
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(Color.secondary)
    }
    .foregroundStyle(link.isEnabled ? Color.primary : Color.secondary)
    .contentShape(Rectangle())
    .padding(.horizontal, 16)
    .frame(height: AboutLayout.linkRowHeight)
  }

  // MARK: - Analytics

  /// Раздел Analytics как у эталона. Флаг хранится локально, телеметрии нет.
  private var analyticsSection: some View {
    VStack(alignment: .leading, spacing: AboutLayout.headerToCard) {
      sectionHeader(L10n.PersonalBuildStubs.analyticsTitle)

      VStack(alignment: .leading, spacing: 4) {
        HStack {
          Text(L10n.PersonalBuildStubs.shareUsageStatistics)
          Spacer()
          PreferencesToggle(L10n.PersonalBuildStubs.shareUsageStatistics, isOn: $shareUsageStatistics)
        }
        Text(L10n.PersonalBuildStubs.analyticsHint)
          .font(.system(size: 11))
          .foregroundStyle(Color.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .font(.system(size: 13))
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      .cardContainer()
    }
  }

  // MARK: - Helpers

  private func sectionHeader(_ title: String) -> some View {
    Text(title)
      .font(.system(size: 13, weight: .semibold))
      .padding(.horizontal, AboutLayout.headerInset)
      .accessibilityAddTraits(.isHeader)
  }

  private var divider: some View {
    Rectangle()
      .fill(Color.primary.opacity(0.08))
      .frame(height: 1)
      .padding(.horizontal, 12)
  }
}

/// Отступы About по PNG эталона (live 062), как у групп Form на других вкладках.
private enum AboutLayout {
  static let topInset: CGFloat = 20.5
  static let horizontalInset: CGFloat = 20
  static let heroToCards: CGFloat = 46
  static let cardSpacing: CGFloat = 10
  /// От конца группы до начала следующей группы с заголовком.
  static let sectionSpacing: CGFloat = 30
  static let headerToCard: CGFloat = 10
  static let headerInset: CGFloat = 10
  static let linkRowHeight: CGFloat = 44
}

private extension View {
  func cardContainer() -> some View {
    background {
      Radius.rect(Radius.card)
        .fill(Color.primary.opacity(0.04))
    }
    .clipShape(Radius.rect(Radius.card))
    .frame(maxWidth: .infinity)
  }
}

#Preview {
  AboutSettingsView()
    .frame(width: 700, height: 600)
}
