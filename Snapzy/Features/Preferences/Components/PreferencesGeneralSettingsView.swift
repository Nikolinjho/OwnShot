//
//  GeneralSettingsView.swift
//  Snapzy
//
//  General preferences tab with startup, appearance, storage, updates, and help
//

import SwiftUI

struct GeneralSettingsView: View {
  @AppStorage(SoundManager.screenshotSoundKey) private var shutterSound = "System Default"
  @AppStorage(PreferencesKeys.hideDesktopIcons) private var hideDesktopIcons = false
  @AppStorage(PreferencesKeys.playSounds) private var playSounds = true
  @AppStorage(PreferencesKeys.showMenuBarIcon) private var showMenuBarIcon = true
  @AppStorage(PreferencesKeys.exportLocation) private var exportLocation = ""
  @AppStorage(PreferencesKeys.useLiquidGlass) private var useLiquidGlass = true
  @Environment(\.openWindow) private var openWindow
  @ObservedObject private var themeManager = ThemeManager.shared

  @State private var startAtLogin = LoginItemManager.isEnabled
  private let fileAccessManager = SandboxFileAccessManager.shared

  var body: some View {
    Form {
      Section("App") {
        SettingRow(title: "Launch at login", description: nil) {
          PreferencesToggle("Launch at login", isOn: $startAtLogin)
            .onChange(of: startAtLogin) { newValue in
              LoginItemManager.setEnabled(newValue)
            }
        }

        SettingRow(title: L10n.PreferencesGeneral.menuBarIconTitle, description: nil) {
          PreferencesToggle(L10n.PreferencesGeneral.menuBarIconTitle, isOn: $showMenuBarIcon)
            .onChange(of: showMenuBarIcon) { newValue in
              AppStatusBarController.shared.setMenuBarIconVisible(newValue)
            }
        }
      }

      Section("Capture") {
        VStack(alignment: .leading, spacing: 4) {
          SettingRow(title: "Hide desktop icons while capturing", description: nil) {
            PreferencesToggle("Hide desktop icons while capturing", isOn: $hideDesktopIcons)
          }
          Text("You can set a custom wallpaper to hide desktop icons in [wallpaper settings](ownshot://open-settings?tab=wallpaper).")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .tint(.blue)
            .environment(\.openURL, OpenURLAction { _ in
              PreferencesNavigationState.shared.select(.wallpaper)
              return .handled
            })
        }
      }
      Section("Sounds") {
        SettingRow(title: L10n.PreferencesGeneral.playSoundsTitle, description: nil) {
          PreferencesToggle(L10n.PreferencesGeneral.playSoundsTitle, isOn: $playSounds)
        }

        Picker("Shutter sound", selection: Binding(
          get: { SoundManager.normalizedScreenshotSound(shutterSound) },
          set: { shutterSound = $0 }
        )) {
          ForEach(SoundManager.shutterSoundNames, id: \.self) { Text($0).tag($0) }
        }
        .tint(.primary)
        .onChange(of: shutterSound) { _ in SoundManager.playScreenshotCapture() }
      }
      Section("Export") {
        SettingRow(title: "Export location", description: nil) {
          HStack(spacing: 10) {
            Label {
              Text(exportLocationDisplay).foregroundStyle(.secondary)
            } icon: {
              Image(nsImage: NSWorkspace.shared.icon(forFile: exportLocation))
                .resizable().scaledToFit().frame(width: 16, height: 16)
            }
            Button("Choose…") { chooseExportLocation() }
              .buttonStyle(.bordered)
              .controlSize(.regular)
              .tint(.primary)
          }
        }
        Text("Set the default save location used when saving from the Quick Access Overlay, After Capture, and other Save actions across the app.")
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Section {
        AfterCaptureMatrixView()
      } header: {
        VStack(alignment: .leading, spacing: 4) {
          Text("After Capture")
          Text("Decide what should happen after taking a screenshot or recording a video.")
            .font(.system(size: 11))
            .fontWeight(.regular)
            .foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
    .onAppear {
      startAtLogin = LoginItemManager.isEnabled
      initializeExportLocation()
    }
  }

  // MARK: - Helpers

  private var exportLocationDisplay: String {
    if exportLocation.isEmpty {
      return L10n.PreferencesGeneral.defaultSaveLocation
    }

    let folderName = URL(fileURLWithPath: exportLocation).lastPathComponent
    if fileAccessManager.hasPersistedExportPermission {
      return folderName
    }

    return L10n.PreferencesGeneral.accessNotGranted(folderName)
  }

  private func initializeExportLocation() {
    fileAccessManager.ensureExportLocationInitialized()
    exportLocation = fileAccessManager.exportLocationPath
  }

  private func chooseExportLocation() {
    if let url = fileAccessManager.chooseExportDirectory(
      message: L10n.PreferencesGeneral.chooseSaveLocationMessage,
      prompt: L10n.PreferencesGeneral.saveHereButton,
      directoryURL: fileAccessManager.resolvedExportDirectoryURL()
    ) {
      exportLocation = url.path
    }
  }

  private var bugReportDisplayAddress: String {
    CrashReportService.bugReportURL.absoluteString.replacingOccurrences(of: "https://", with: "")
  }

  private func openBugReportPage() {
    NSWorkspace.shared.open(CrashReportService.bugReportURL)
  }
}

#Preview {
  GeneralSettingsView()
    .frame(width: 600, height: 500)
}
