//
//  QuickAccessSettingsView.swift
//  Snapzy
//
//  Quick Access (floating overlay) settings tab
//

import SwiftUI

extension QuickAccessPinZoomMode {
  var title: String {
    switch self {
    case .windowFollowsImage: L10n.PreferencesQuickAccess.pinZoomModeWindow
    case .fixedViewport: L10n.PreferencesQuickAccess.pinZoomModeFixed
    }
  }
}

struct QuickAccessAdvancedSettingsView: View {
  @ObservedObject private var manager = QuickAccessManager.shared
  @ObservedObject private var trackpadSwipeModeStore = QuickAccessTrackpadSwipeModeStore.shared
  @ObservedObject private var pinZoomModeStore = QuickAccessPinZoomModeStore.shared
  @AppStorage(PreferencesKeys.quickAccessPlaySounds) private var playSounds = true
  @AppStorage(PreferencesKeys.quickAccessOpenInFinderAfterSave) private var openInFinderAfterSave = true

  @State private var positionIsLeft: Bool = false

  var body: some View {
    Form {
      Section(L10n.PreferencesQuickAccess.positionSection) {
        SettingRow(title: L10n.PreferencesQuickAccess.screenEdgeTitle, description: L10n.PreferencesQuickAccess.screenEdgeDescription) {
          Picker("", selection: $positionIsLeft) {
            Text(L10n.PreferencesQuickAccess.left).tag(true)
            Text(L10n.PreferencesQuickAccess.right).tag(false)
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .onChange(of: positionIsLeft) { newValue in
            manager.setPosition(newValue ? .bottomLeft : .bottomRight)
          }
        }
      }

      Section(L10n.PreferencesQuickAccess.appearanceSection) {
        SettingRow(title: L10n.PreferencesQuickAccess.overlaySizeTitle, description: L10n.PreferencesQuickAccess.overlaySizeDescription) {
          HStack(spacing: 8) {
            Text(verbatim: "S")
              .font(.caption)
              .foregroundColor(.secondary)
            Slider(value: $manager.overlayScale.stepped(by: QuickAccessOverlaySizeScale.step, in: QuickAccessOverlaySizeScale.range), in: QuickAccessOverlaySizeScale.range)
              .frame(width: 100)
            Text(verbatim: "L")
              .font(.caption)
              .foregroundColor(.secondary)
          }
        }
      }

      Section(L10n.PreferencesQuickAccess.behaviorsSection) {
        SettingRow(title: L10n.PreferencesQuickAccess.floatingOverlayTitle, description: L10n.PreferencesQuickAccess.floatingOverlayDescription) {
          PreferencesToggle(L10n.PreferencesQuickAccess.floatingOverlayTitle, isOn: $manager.isEnabled)
        }

        SettingRow(title: L10n.PreferencesQuickAccess.autoCloseTitle, description: autoCloseDescription, descriptionStyle: .subtitle) {
          PreferencesToggle(L10n.PreferencesQuickAccess.autoCloseTitle, isOn: $manager.autoDismissEnabled)
        }

        SettingRow(title: L10n.PreferencesQuickAccess.hideCardWhenWindowOpenTitle, description: L10n.PreferencesQuickAccess.hideCardWhenWindowOpenDescription) {
          PreferencesToggle(L10n.PreferencesQuickAccess.hideCardWhenWindowOpenTitle, isOn: $manager.hideCardWhenWindowOpen)
        }

        SettingRow(title: L10n.PreferencesQuickAccess.animationStyleTitle, description: L10n.PreferencesQuickAccess.animationStyleDescription) {
          Picker("", selection: $manager.animationStyle) {
            ForEach(QuickAccessAnimationStyle.allCases) { style in
              Text(style.displayName).tag(style)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .fixedSize()
          .frame(width: 150, alignment: .trailing)
        }

        SettingRow(title: L10n.PreferencesQuickAccess.soundEffectsTitle, description: L10n.PreferencesQuickAccess.soundEffectsDescription) {
          PreferencesToggle(L10n.PreferencesQuickAccess.soundEffectsTitle, isOn: $playSounds)
        }

        if manager.autoDismissEnabled {
          HStack(spacing: 12) {
            Image(systemName: "clock")
              .font(.title2)
              .foregroundColor(.secondary)
              .frame(width: 28)

            Text(L10n.PreferencesQuickAccess.closeAfter)
              .fontWeight(.medium)

            Spacer()

            Slider(value: $manager.autoDismissDelay.stepped(by: 1, in: 3...30), in: 3...30)
              .frame(width: 120)

            Text("\(Int(manager.autoDismissDelay))s")
              .frame(width: 35)
              .monospacedDigit()
              .foregroundColor(.secondary)
          }
          .padding(.vertical, 4)
        }

        if manager.autoDismissEnabled {
          SettingRow(title: L10n.PreferencesQuickAccess.pauseOnHoverTitle, description: L10n.PreferencesQuickAccess.pauseOnHoverDescription) {
            PreferencesToggle(L10n.PreferencesQuickAccess.pauseOnHoverTitle, isOn: $manager.pauseCountdownOnHover)
          }
        }

        SettingRow(title: L10n.PreferencesQuickAccess.dragAndDropTitle, description: L10n.PreferencesQuickAccess.dragAndDropDescription) {
          PreferencesToggle(L10n.PreferencesQuickAccess.dragAndDropTitle, isOn: $manager.dragDropEnabled)
        }

        SettingRow(title: L10n.PreferencesQuickAccess.openInFinderAfterSaveTitle, description: L10n.PreferencesQuickAccess.openInFinderAfterSaveDescription) {
          PreferencesToggle(L10n.PreferencesQuickAccess.openInFinderAfterSaveTitle, isOn: $openInFinderAfterSave)
        }

        SettingRow(title: L10n.PreferencesQuickAccess.twoFingerSwipeTitle, description: L10n.PreferencesQuickAccess.twoFingerSwipeDescription) {
          PreferencesToggle(L10n.PreferencesQuickAccess.twoFingerSwipeTitle, isOn: $manager.twoFingerSwipeToDismissEnabled)
        }

        if manager.twoFingerSwipeToDismissEnabled {
          SettingRow(title: L10n.PreferencesQuickAccess.swipeSensitivityTitle, description: L10n.PreferencesQuickAccess.swipeSensitivityDescription) {
            HStack(spacing: 8) {
              Slider(value: $manager.swipeSensitivity.stepped(by: 0.25, in: 0.5...3.0), in: 0.5...3.0)
                .frame(width: 100)
              Text("\(Int(manager.swipeSensitivity * 100))%")
                .frame(width: 42)
                .monospacedDigit()
                .foregroundColor(.secondary)
            }
          }
        }
      }

      if manager.twoFingerSwipeToDismissEnabled {
        Section(L10n.PreferencesQuickAccess.swipeActionsSection) {
          SettingRow(
            title: L10n.PreferencesQuickAccess.trackpadSwipeModeTitle,
            description: L10n.PreferencesQuickAccess.trackpadSwipeModeDescription
          ) {
            Picker("", selection: Binding(
              get: { trackpadSwipeModeStore.mode },
              set: { trackpadSwipeModeStore.setMode($0) }
            )) {
              ForEach(QuickAccessTrackpadSwipeMode.allCases) { mode in
                Text(mode.displayName).tag(mode)
              }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .frame(width: 200, alignment: .trailing)
          }

          Text(L10n.PreferencesQuickAccess.swipeActionsDescription)
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.vertical, 2)
        }
      }
      QuickAccessActionCustomizationView(manager: manager)

      Section(L10n.PreferencesQuickAccess.pinZoomSection) {
        PinZoomModeComparisonPreview(
          selectedMode: pinZoomModeStore.mode,
          onSelect: { mode in
            pinZoomModeStore.setMode(mode)
            QuickAccessPinWindowManager.shared.setPinZoomMode(mode)
          }
        )
      }

    }
    .formStyle(.grouped)
    .onAppear {
      positionIsLeft = manager.position.isLeftSide
    }
  }

  // MARK: - Helpers

  private var autoCloseDescription: String {
    if manager.autoDismissEnabled {
      return L10n.PreferencesQuickAccess.closesAfter(Int(manager.autoDismissDelay))
    }
    return L10n.PreferencesQuickAccess.keepOpenUntilDismissed
  }
}

struct QuickAccessSettingsView: View {
  @ObservedObject private var manager = QuickAccessManager.shared
  @AppStorage("ownshot.quickAccess.moveToActiveScreen") private var moveToActiveScreen = true
  @AppStorage("ownshot.quickAccess.closeAfterDragging") private var closeAfterDragging = true
  @AppStorage("ownshot.quickAccess.autoCloseAction") private var autoCloseAction = "saveAndClose"
  @AppStorage("ownshot.quickAccess.saveButtonBehavior") private var saveButtonBehavior = "exportLocation"

  var body: some View {
    Form {
      Section("Appearance") {
        Picker("Position on screen", selection: Binding(
          get: { manager.position.isLeftSide },
          set: { manager.setPosition($0 ? .bottomLeft : .bottomRight) }
        )) {
          Text("Left").tag(true)
          Text("Right").tag(false)
        }
        .tint(.primary)
        SettingRow(title: "Move to active screen", description: "Active screen is the screen where your cursor is pointing.", descriptionStyle: .subtitle, alignment: .top) {
          PreferencesToggle("Move to active screen", isOn: $moveToActiveScreen)
        }
        SettingRow(title: "Overlay size", description: nil) {
          Slider(value: $manager.overlayScale, in: QuickAccessOverlaySizeScale.range, step: QuickAccessOverlaySizeScale.step)
            .labelsHidden()
            .frame(minWidth: 170, maxWidth: 170)
            .accessibilityLabel("Overlay size")
        }
      }
      Section("Behavior") {
        Toggle("Auto-close", isOn: $manager.autoDismissEnabled)
        Picker("Action", selection: $autoCloseAction) {
          Text("Save and Close").tag("saveAndClose")
          Text("Close").tag("close")
        }.tint(.primary).disabled(!manager.autoDismissEnabled)
        Picker("Interval", selection: $manager.autoDismissDelay) {
          ForEach([5.0, 10, 15, 30, 60, 120, 300, 600], id: \.self) { interval in
            Text(interval < 60 ? "\(Int(interval)) seconds" : interval == 60 ? "1 minute" : "\(Int(interval / 60)) minutes")
              .tag(interval)
          }
          if ![5.0, 10, 15, 30, 60, 120, 300, 600].contains(manager.autoDismissDelay) {
            Text("\(Int(manager.autoDismissDelay)) seconds").tag(manager.autoDismissDelay)
          }
        }.tint(.primary).disabled(!manager.autoDismissEnabled)
      }
      Section {
        SettingRow(title: "Close after dragging", description: QuickAccessSettingsHints.closeAfterDragging(closeAfterDragging), descriptionStyle: .subtitle, alignment: .top) {
          PreferencesToggle("Close after dragging", isOn: $closeAfterDragging)
        }
        SettingRow(title: "Close after uploading", description: nil) {
          Button { _ = OwnShotFeaturePolicy.allow(.cloud) } label: {
            Toggle("", isOn: .constant(false)).labelsHidden()
              .allowsHitTesting(false).accessibilityHidden(true)
          }
          .buttonStyle(.plain)
          .help("Cloud · Coming later")
          .accessibilityLabel("Close after uploading · Coming later")
        }
        VStack(alignment: .leading, spacing: 4) {
          Picker("Save button behavior", selection: $saveButtonBehavior) {
            Text("Save to \"Export location\"").tag("exportLocation")
            Text(L10n.PreferencesQuickAccess.saveButtonAskForDestination).tag("chooseDestination")
          }.tint(.primary)
          Text(QuickAccessSettingsHints.saveButton(behavior: saveButtonBehavior))
            .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.bottom, 1)
      }
    }
    .formStyle(.grouped)
  }
}

#Preview { QuickAccessSettingsView().frame(width: 590, height: 660) }
