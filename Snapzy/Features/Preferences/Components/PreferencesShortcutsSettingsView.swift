//
//  PreferencesShortcutsSettingsView.swift
//  Snapzy
//
//  Keyboard shortcuts configuration tab
//

import AppKit
import Carbon.HIToolbox
import SwiftUI

struct ShortcutsSettingsView: View {
  @ObservedObject private var allInOneShortcut = OwnShotAllInOneShortcut.shared
  @State private var fullscreenShortcut: ShortcutConfig?
  @State private var areaShortcut: ShortcutConfig?
  @State private var repeatAreaShortcut: ShortcutConfig?
  @State private var delayedCaptureShortcut: ShortcutConfig?
  @State private var delayedFullscreenShortcut: ShortcutConfig?
  @State private var areaAnnotateShortcut: ShortcutConfig?
  @State private var activeWindowShortcut: ShortcutConfig?
  @State private var areaApplicationCaptureShortcut: CaptureOverlayShortcut?
  @State private var recordingApplicationCaptureShortcut: CaptureOverlayShortcut?
  @State private var scrollingCaptureShortcut: ShortcutConfig?
  @State private var objectCutoutShortcut: ShortcutConfig?
  @State private var ocrShortcut: ShortcutConfig?
  @State private var smartElementShortcut: ShortcutConfig?
  @State private var recordingShortcut: ShortcutConfig?
  @State private var pauseResumeRecordingShortcut: ShortcutConfig?
  @State private var togglePenRecordingShortcut: ShortcutConfig?
  @State private var restartRecordingShortcut: ShortcutConfig?
  @State private var deleteRecordingShortcut: ShortcutConfig?
  @State private var annotateShortcut: ShortcutConfig?
  @State private var videoEditorShortcut: ShortcutConfig?
  @State private var cloudUploadsShortcut: ShortcutConfig?
  @State private var shortcutListShortcut: ShortcutConfig?
  @State private var pickColorShortcut: ShortcutConfig?
  @State private var measureScreenShortcut: ShortcutConfig?
  @State private var historyShortcut: ShortcutConfig?
  @State private var openEditorShortcut: ShortcutConfig?
  @State private var openEditorShortcutEnabled: Bool
  @State private var copyAndCloseShortcut: ShortcutConfig?
  @State private var toggleSidebarShortcut: ShortcutConfig?
  @State private var togglePinShortcut: ShortcutConfig?
  @State private var cloudUploadShortcut: ShortcutConfig?
  @State private var autoRedactSensitiveDataShortcut: ShortcutConfig?
  @State private var globalShortcutEnabled: [GlobalShortcutKind: Bool]
  @State private var annotateActionEnabled: [AnnotateActionShortcutKind: Bool]
  @State private var globalValidationIssues: [GlobalShortcutKind: ShortcutValidationIssue] = [:]
  @State private var captureOverlayValidationIssues: [CaptureOverlayShortcutKind: ShortcutValidationIssue] = [:]
  @State private var annotateActionValidationIssues: [AnnotateActionShortcutKind: ShortcutValidationIssue] = [:]
  @State private var annotateToolValidationIssues: [AnnotationToolType: ShortcutValidationIssue] = [:]
  @State private var shortcutsEnabled: Bool
  @State private var showDisableConfirmation: Bool = false
  @State private var isConfirmedDisable: Bool = false
  @State private var hasSystemConflict: Bool = false
  @State private var isRefreshingConflict: Bool = false
  @State private var accessibilityGranted: Bool = AXIsProcessTrusted()
  @State private var searchText = ""
  @State private var showSystemDefaultsConfirmation = false
  @State private var showSystemDefaultsFailure = false
  @State private var additionalShortcuts: [GlobalShortcutKind: ShortcutConfig] = [:]
  @State private var recordingStartShortcuts: [RecordingStartShortcutKind: ShortcutConfig?] = Dictionary(
    uniqueKeysWithValues: RecordingStartShortcutKind.allCases.map { ($0, RecordingStartShortcutSettings.shortcut(for: $0)) }
  )
  @State private var scrollingStartStopShortcut: ShortcutConfig? = ScrollingCaptureShortcutSettings.startStopShortcut
  @State private var allInOneValidationIssue: ShortcutValidationIssue?
  /// Bumped by Quick Access reset so the card-action rows drop stale validation highlights.
  @State private var quickAccessResetCount = 0

  private let manager = KeyboardShortcutManager.shared
  private let validator = ShortcutValidationService.shared
  @ObservedObject private var annotateManager = AnnotateShortcutManager.shared
  @ObservedObject private var videoEditorShortcuts = VideoEditorShortcutSettings.shared
  @State private var videoEditorShortcutIssues: [VideoEditorShortcutAction: ShortcutValidationIssue] = [:]
  @ObservedObject private var historyFloatingManager = HistoryFloatingManager.shared

  init() {
    _fullscreenShortcut = State(initialValue: KeyboardShortcutManager.shared.shortcut(for: .fullscreen))
    _areaShortcut = State(initialValue: KeyboardShortcutManager.shared.shortcut(for: .area))
    _repeatAreaShortcut = State(initialValue: KeyboardShortcutManager.shared.shortcut(for: .repeatArea))
    _delayedCaptureShortcut = State(initialValue: KeyboardShortcutManager.shared.shortcut(for: .delayedCapture))
    _delayedFullscreenShortcut = State(initialValue: KeyboardShortcutManager.shared.shortcut(for: .delayedFullscreen))
    _areaAnnotateShortcut = State(initialValue: KeyboardShortcutManager.shared.shortcut(for: .areaAnnotate))
    _activeWindowShortcut = State(initialValue: KeyboardShortcutManager.shared.shortcut(for: .activeWindow))
    _areaApplicationCaptureShortcut = State(
      initialValue: CaptureOverlayShortcutSettings.applicationCaptureShortcut
    )
    _recordingApplicationCaptureShortcut = State(
      initialValue: CaptureOverlayShortcutSettings.recordingApplicationCaptureShortcut
    )
    _scrollingCaptureShortcut = State(initialValue: KeyboardShortcutManager.shared.shortcut(for: .scrollingCapture))
    _objectCutoutShortcut = State(initialValue: KeyboardShortcutManager.shared.shortcut(for: .objectCutout))
    _ocrShortcut = State(initialValue: KeyboardShortcutManager.shared.shortcut(for: .ocr))
    _smartElementShortcut = State(initialValue: KeyboardShortcutManager.shared.shortcut(for: .smartElement))
    _recordingShortcut = State(initialValue: KeyboardShortcutManager.shared.shortcut(for: .recording))
    _pauseResumeRecordingShortcut = State(
      initialValue: KeyboardShortcutManager.shared.shortcut(for: .pauseResumeRecording)
    )
    _togglePenRecordingShortcut = State(
      initialValue: KeyboardShortcutManager.shared.shortcut(for: .togglePenRecording)
    )
    _restartRecordingShortcut = State(
      initialValue: KeyboardShortcutManager.shared.shortcut(for: .restartRecording)
    )
    _deleteRecordingShortcut = State(
      initialValue: KeyboardShortcutManager.shared.shortcut(for: .deleteRecording)
    )
    _annotateShortcut = State(initialValue: KeyboardShortcutManager.shared.shortcut(for: .annotate))
    _videoEditorShortcut = State(initialValue: KeyboardShortcutManager.shared.shortcut(for: .videoEditor))
    _cloudUploadsShortcut = State(initialValue: KeyboardShortcutManager.shared.shortcut(for: .cloudUploads))
    _shortcutListShortcut = State(initialValue: KeyboardShortcutManager.shared.shortcut(for: .shortcutList))
    _pickColorShortcut = State(initialValue: KeyboardShortcutManager.shared.shortcut(for: .pickColor))
    _measureScreenShortcut = State(initialValue: KeyboardShortcutManager.shared.shortcut(for: .measureScreen))
    _historyShortcut = State(initialValue: KeyboardShortcutManager.shared.shortcut(for: .history))
    _openEditorShortcut = State(initialValue: QuickAccessManager.shared.openEditorShortcut)
    _openEditorShortcutEnabled = State(initialValue: QuickAccessManager.shared.openEditorShortcutEnabled)
    _copyAndCloseShortcut = State(initialValue: AnnotateShortcutManager.shared.copyAndCloseShortcut)
    _toggleSidebarShortcut = State(initialValue: AnnotateShortcutManager.shared.toggleSidebarShortcut)
    _togglePinShortcut = State(initialValue: AnnotateShortcutManager.shared.togglePinShortcut)
    _cloudUploadShortcut = State(initialValue: AnnotateShortcutManager.shared.cloudUploadShortcut)
    _autoRedactSensitiveDataShortcut = State(
      initialValue: AnnotateShortcutManager.shared.autoRedactSensitiveDataShortcut
    )
    _globalShortcutEnabled = State(
      initialValue: Dictionary(
        uniqueKeysWithValues: GlobalShortcutKind.allCases.map {
          ($0, KeyboardShortcutManager.shared.isShortcutEnabled(for: $0))
        }
      )
    )
    _annotateActionEnabled = State(
      initialValue: Dictionary(
        uniqueKeysWithValues: AnnotateActionShortcutKind.allCases.map {
          ($0, AnnotateShortcutManager.shared.isActionShortcutEnabled(for: $0))
        }
      )
    )
    _shortcutsEnabled = State(initialValue: KeyboardShortcutManager.shared.isEnabled)
    _hasSystemConflict = State(
      initialValue: SystemScreenshotShortcutManager.shared.hasConflictingSystemShortcuts()
    )
  }

  var body: some View {
    Form {
      if !searchText.isEmpty && !ShortcutsPage.allCases.contains(where: { pageMatchesSearch($0) }) {
        Section { Text("No Shortcuts Found").foregroundStyle(.secondary) }
      }
      overview
    }
    .formStyle(.grouped)
    .environment(\.ownShotShortcutSearch, searchText)
    .environment(\.ownShotWideShortcutRecorder, true)
    // Поле поиска эталона – широкое справа в панели окна (326×36 pt), как NSSearchToolbarItem.
    .searchable(
      text: $searchText,
      placement: .toolbar,
      prompt: Text(L10n.PreferencesShortcuts.searchPrompt)
    )
    .alert("Set as Default Screenshot Tool?", isPresented: $showSystemDefaultsConfirmation) {
      Button(L10n.Common.cancel, role: .cancel) {}
      Button("Use System Defaults") { useSystemDefaults() }
    } message: {
      Text("Assign ⇧⌘3 to Capture Fullscreen, ⇧⌘4 to Capture Area, and ⇧⌘5 to All-In-One. Existing assignments using these combinations will be replaced. Launch at login is managed separately in General. Disable the matching macOS screenshot shortcuts in System Settings to avoid conflicts.")
    }
    .alert("Could Not Assign Shortcuts", isPresented: $showSystemDefaultsFailure) {
      Button("OK", role: .cancel) {}
    } message: {
      Text("These shortcuts are already in use or could not be registered. Your previous assignments were preserved. Choose different shortcuts for conflicting Annotate actions, or disable the matching macOS screenshot shortcuts in System Settings and try again.")
    }
    .onChange(of: shortcutsEnabled) { newValue in
      if newValue {
        manager.enable()
        // Re-check system conflicts when enabling
        hasSystemConflict =
          SystemScreenshotShortcutManager.shared.hasConflictingSystemShortcuts()
      } else {
        if isConfirmedDisable {
          // User confirmed disable, proceed
          isConfirmedDisable = false
          manager.disable()
        } else {
          // Revert toggle and show confirmation
          shortcutsEnabled = true
          showDisableConfirmation = true
        }
      }
    }
    .alert(L10n.PreferencesShortcuts.disableShortcutsTitle, isPresented: $showDisableConfirmation) {
      Button(L10n.Common.cancel, role: .cancel) {}
      Button(L10n.Common.disable, role: .destructive) {
        isConfirmedDisable = true
        shortcutsEnabled = false
      }
    } message: {
      Text(L10n.PreferencesShortcuts.disableShortcutsMessage)
    }
    .onAppear {
      accessibilityGranted = AXIsProcessTrusted()
    }
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
      accessibilityGranted = AXIsProcessTrusted()
    }
  }

  // MARK: - Overview

  /// Группы и порядок строк как в Settings → Shortcuts у CleanShot X
  /// (evidence/spec-055-live/settings-shortcuts.txt). Строки OwnShot идут после строк эталона.
  @ViewBuilder
  private var overview: some View {
    ForEach(ShortcutsPage.allCases.filter { pageMatchesSearch($0) }) { page in
      let groups = ShortcutsPage.groups(for: page).filter { groupMatchesSearch($0) }
      ForEach(Array(groups.enumerated()), id: \.element) { index, group in
        // Строки не гасятся при выключенных сочетаниях: у эталона страница всегда обычного
        // цвета, а о выключенных сочетаниях говорит раздел Options ниже.
        Section {
          groupRows(group)
        } header: {
          if index == 0 {
            Label(page.title, systemImage: page.symbolName)
              .labelStyle(ShortcutsPageHeaderLabelStyle())
          }
        }
      }
    }

    Section {
      Toggle(L10n.PreferencesShortcuts.enableShortcutsTitle, isOn: $shortcutsEnabled)
      SystemShortcutConflictBadge(hasConflict: hasSystemConflict, isRefreshing: isRefreshingConflict, onRefresh: refreshSystemConflict)
    } header: {
      Text("Options")
    }

    if shortcutsEnabled {
      if showsFnAccessibilityHint {
        Section {
          HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
              .font(.system(size: 14))
              .foregroundColor(.orange)

            Text(L10n.PreferencesShortcuts.fnAccessibilityHint)
              .font(.system(size: 11))
              .foregroundColor(.secondary)
              .fixedSize(horizontal: false, vertical: true)

            Spacer()

            Button(L10n.Common.openSettings) {
              if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
              }
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
          }
        }
      }
    } else {
      Section {
        HStack(spacing: 10) {
          Image(systemName: "keyboard.badge.ellipsis")
            .font(.system(size: 16))
            .foregroundColor(.secondary)
          Text(L10n.PreferencesShortcuts.shortcutsOff)
            .font(.system(size: 12))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }

    // Lives in the scroll content (not a pinned inset) so it never floats over rows.
    Section {
    } footer: {
      HStack {
        Spacer()
        Button("Use System Default Shortcuts…") {
          showSystemDefaultsConfirmation = true
        }
        Button("Restore Defaults") {
          resetToDefaults()
        }
        .controlSize(.regular)
      }
    }
  }

  private func pageMatchesSearch(_ page: ShortcutsPage) -> Bool {
    ShortcutsPage.groups(for: page).contains { groupMatchesSearch($0) }
  }

  private func groupMatchesSearch(_ group: ShortcutsGroup) -> Bool {
    group.searchTitles.contains { OwnShotShortcutSearch.matches(searchText, title: $0) }
  }

  @ViewBuilder
  private func groupRows(_ group: ShortcutsGroup) -> some View {
    switch group {
    case .general: generalRows
    case .screenshots: screenshotRows
    case .screenshotActions: screenshotActionRows
    case .screenshotExtras: screenshotExtraRows
    case .screenRecording: screenRecordingRows
    case .screenRecordingExtras: screenRecordingExtraRows
    case .scrollingCapture: scrollingCaptureRows
    case .ocr: ocrRows
    case .quickAccessOverlay: ForEach(ShortcutsGroup.quickAccessOverlayKinds, id: \.self) { additionalShortcutRow($0) }
    case .pin: ForEach(ShortcutsGroup.pinKinds, id: \.self) { additionalShortcutRow($0) }
    case .annotate: annotateRows
    case .annotateExtras: annotateActionRow(.autoRedactSensitiveData)
    case .annotateTools: annotateToolKeysRows
    case .videoEditor: videoEditorRows
    case .tools: toolsRows
    case .history: historyRows
    case .quickAccessCard:
      quickAccessRows
      QuickAccessActionShortcutRows(resetCount: quickAccessResetCount)
    case .annotateReference: annotateReferenceRows
    }
  }

  private var videoEditorRows: some View {
    ForEach(VideoEditorShortcutAction.allCases) { action in
      ShortcutRecorderView(
        label: action.settingsTitle,
        footnote: action.isAvailable ? nil : OwnShotDeferredFeature.cloud.message,
        shortcut: Binding(
          get: { videoEditorShortcuts.shortcut(for: action) },
          set: { _ in }
        ),
        defaultShortcut: action.defaultShortcut,
        validationIssue: videoEditorShortcutIssues[action],
        allowsSingleKey: true,
        onShortcutChanged: { shortcut in
          if let shortcut, let owner = VideoEditorShortcutSettings.conflictingActionName(
            for: shortcut, excluding: action, in: videoEditorShortcuts.shortcuts
          ) {
            videoEditorShortcutIssues[action] = ShortcutValidationIssue(
              severity: .error,
              title: L10n.ShortcutValidation.usedForAnotherActionTitle,
              message: L10n.ShortcutValidation.assignedTo(shortcut.menuSymbolString, owner)
            )
            return false
          }
          videoEditorShortcutIssues.removeValue(forKey: action)
          return videoEditorShortcuts.setShortcut(shortcut, for: action)
        }
      )
      .disabled(!action.isAvailable)
    }
    .environment(
      \.ownShotShortcutSearch,
      OwnShotShortcutSearch.matches(searchText, title: ShortcutsPage.videoEditor.title) ? "" : searchText
    )
  }

  @ViewBuilder
  private var generalRows: some View {
    ShortcutRecorderView(
      label: "All-In-One",
      description: "Open all capture modes with an editable selection",
      shortcut: Binding(get: { allInOneShortcut.shortcut }, set: { _ in }),
      validationIssue: allInOneValidationIssue,
      onShortcutChanged: handleAllInOneShortcutChange
    )
    additionalShortcutRow(.toggleDesktopIcons)
    ShortcutRecorderView(
      label: GlobalShortcutKind.history.displayName,
      description: L10n.PreferencesShortcuts.openHistoryDescription,
      shortcut: $historyShortcut,
      defaultShortcut: .defaultHistory,
      isEnabled: globalEnabledBinding(for: .history),
      validationIssue: globalValidationIssues[.history],
      onSwap: swapAction(for: .global(.history)),
      onShortcutChanged: { handleGlobalShortcutChange($0, for: .history) }
    )
    additionalShortcutRow(.restoreLastCapture)
  }

  private func additionalShortcutRow(_ kind: GlobalShortcutKind) -> some View {
    ShortcutRecorderView(
      label: kind.displayName,
      shortcut: Binding(get: { additionalShortcuts[kind] ?? manager.shortcut(for: kind) }, set: { additionalShortcuts[kind] = $0 }),
      isEnabled: globalEnabledBinding(for: kind),
      validationIssue: globalValidationIssues[kind],
      onSwap: swapAction(for: .global(kind)),
      onShortcutChanged: { handleGlobalShortcutChange($0, for: kind) }
    )
  }

  private func globalRow(
    _ kind: GlobalShortcutKind,
    label: String? = nil,
    description: String = "",
    footnote: String? = nil,
    shortcut: Binding<ShortcutConfig?>,
    defaultShortcut: ShortcutConfig?
  ) -> some View {
    ShortcutRecorderView(
      label: label ?? kind.displayName,
      description: description,
      footnote: footnote,
      shortcut: shortcut,
      defaultShortcut: defaultShortcut,
      isEnabled: globalEnabledBinding(for: kind),
      validationIssue: globalValidationIssues[kind],
      onSwap: swapAction(for: .global(kind)),
      onShortcutChanged: { handleGlobalShortcutChange($0, for: kind) }
    )
  }

  @ViewBuilder
  private var screenshotRows: some View {
    globalRow(.area, label: L10n.Actions.captureArea, description: L10n.PreferencesShortcuts.captureAreaDescription, shortcut: $areaShortcut, defaultShortcut: .defaultArea)
    globalRow(.repeatArea, description: L10n.PreferencesShortcuts.captureRepeatAreaDescription, shortcut: $repeatAreaShortcut, defaultShortcut: .defaultRepeatArea)
    globalRow(.fullscreen, label: L10n.Actions.captureFullscreen, description: L10n.PreferencesShortcuts.captureFullscreenDescription, shortcut: $fullscreenShortcut, defaultShortcut: .defaultFullscreen)
    globalRow(.activeWindow, description: L10n.PreferencesShortcuts.captureActiveWindowDescription, shortcut: $activeWindowShortcut, defaultShortcut: .defaultActiveWindowCapture)
    globalRow(.delayedCapture, description: L10n.PreferencesShortcuts.captureDelayedDescription, shortcut: $delayedCaptureShortcut, defaultShortcut: nil)
  }

  @ViewBuilder
  private var screenshotActionRows: some View {
    additionalShortcutRow(.areaCopy)
    additionalShortcutRow(.areaSave)
    HStack {
      Text("Capture Area & Upload to Cloud")
      Spacer()
      Text("Not Available").foregroundStyle(.secondary)
    }
    .disabled(true)
    .shortcutSearchable("Capture Area & Upload to Cloud")
    globalRow(.areaAnnotate, description: L10n.PreferencesShortcuts.captureAreaAnnotateDescription, shortcut: $areaAnnotateShortcut, defaultShortcut: .defaultAreaAnnotate)
    additionalShortcutRow(.areaPin)
    // Capture Area & Send to Raycast AI Chat: у эталона только при установленном Raycast.
    // Интеграции в личной сборке нет, поэтому вместо записи сочетания – Not Available.
    if OwnShotRaycastStub.isMenuVisible {
      HStack {
        Text(L10n.PersonalBuildStubs.captureAreaAndSendToRaycast)
        Spacer()
        Text(L10n.PersonalBuildStubs.notAvailable).foregroundStyle(.secondary)
      }
      .disabled(true)
      .help(L10n.PersonalBuildStubs.raycastUnavailableMessage)
      .shortcutSearchable(L10n.PersonalBuildStubs.captureAreaAndSendToRaycast)
    }
  }

  /// Команды OwnShot без аналога в группе Screenshots эталона.
  @ViewBuilder
  private var screenshotExtraRows: some View {
    CaptureOverlayShortcutRecorderRow(
      label: CaptureOverlayShortcutKind.applicationCapture.displayName,
      description: L10n.PreferencesShortcuts.applicationCaptureDescription,
      shortcut: $areaApplicationCaptureShortcut,
      defaultShortcut: CaptureOverlayShortcutSettings.defaultApplicationCaptureShortcut,
      isEnabled: globalEnabledBinding(for: .area),
      validationIssue: captureOverlayValidationIssues[.applicationCapture]
    ) { newShortcut in
      handleCaptureOverlayShortcutChange(newShortcut, for: .applicationCapture)
    }
    globalRow(.delayedFullscreen, label: L10n.Actions.captureDelayedFullscreen, description: L10n.PreferencesShortcuts.captureDelayedFullscreenDescription, shortcut: $delayedFullscreenShortcut, defaultShortcut: nil)
    globalRow(.objectCutout, description: "Select an area, isolate the subject, and optionally auto-crop", shortcut: $objectCutoutShortcut, defaultShortcut: .defaultObjectCutout)
    globalRow(.smartElement, label: L10n.Actions.captureSmartElement, description: L10n.PreferencesShortcuts.smartElementCaptureDescription, shortcut: $smartElementShortcut, defaultShortcut: .defaultSmartElement)
  }

  @ViewBuilder
  private var screenRecordingRows: some View {
    globalRow(.recording, description: L10n.PreferencesShortcuts.recordVideoDescription, shortcut: $recordingShortcut, defaultShortcut: .defaultRecording)
    // Select Window (␣) эталона: выбор окна в оверлее записи.
    CaptureOverlayShortcutRecorderRow(
      label: ShortcutsGroup.selectWindowTitle,
      description: L10n.PreferencesShortcuts.applicationRecordingDescription,
      shortcut: $recordingApplicationCaptureShortcut,
      defaultShortcut: CaptureOverlayShortcutSettings.defaultRecordingApplicationCaptureShortcut,
      isEnabled: globalEnabledBinding(for: .recording),
      validationIssue: captureOverlayValidationIssues[.applicationRecording]
    ) { newShortcut in
      handleCaptureOverlayShortcutChange(newShortcut, for: .applicationRecording)
    }
    ForEach(RecordingStartShortcutKind.allCases, id: \.self) { kind in
      ShortcutRecorderView(
        label: kind.settingsTitle,
        description: "Starts recording from the toolbar shown before recording",
        shortcut: Binding(
          get: { recordingStartShortcuts[kind] ?? RecordingStartShortcutSettings.shortcut(for: kind) },
          set: { recordingStartShortcuts[kind] = $0 }
        ),
        defaultShortcut: kind.defaultShortcut,
        allowsSingleKey: true,
        onShortcutChanged: { config in
          RecordingStartShortcutSettings.setShortcut(config, for: kind)
          recordingStartShortcuts[kind] = config
          return true
        }
      )
    }
    globalRow(.pauseResumeRecording, label: L10n.Actions.pauseResumeRecording, description: L10n.PreferencesShortcuts.pauseResumeRecordingDescription, footnote: L10n.PreferencesShortcuts.activeOnlyWhileRecording, shortcut: $pauseResumeRecordingShortcut, defaultShortcut: nil)
    globalRow(.restartRecording, description: L10n.PreferencesShortcuts.restartRecordingDescription, footnote: L10n.PreferencesShortcuts.activeOnlyWhileRecording, shortcut: $restartRecordingShortcut, defaultShortcut: nil)
    additionalShortcutRow(.toggleCameraFullscreen)
  }

  @ViewBuilder
  private var screenRecordingExtraRows: some View {
    globalRow(.togglePenRecording, label: L10n.Actions.togglePenRecording, description: L10n.PreferencesShortcuts.togglePenRecordingDescription, footnote: L10n.PreferencesShortcuts.activeOnlyWhileRecording, shortcut: $togglePenRecordingShortcut, defaultShortcut: nil)
    globalRow(.deleteRecording, label: L10n.Actions.deleteRecording, description: L10n.PreferencesShortcuts.deleteRecordingDescription, footnote: L10n.PreferencesShortcuts.activeOnlyWhileRecording, shortcut: $deleteRecordingShortcut, defaultShortcut: nil)
  }

  @ViewBuilder
  private var scrollingCaptureRows: some View {
    globalRow(.scrollingCapture, description: "Guided session for long screenshots", shortcut: $scrollingCaptureShortcut, defaultShortcut: .defaultScrollingCapture)
    ShortcutRecorderView(
      label: ShortcutsGroup.startStopCapturingTitle,
      description: L10n.PreferencesShortcuts.startStopCapturingDescription,
      shortcut: $scrollingStartStopShortcut,
      defaultShortcut: ScrollingCaptureShortcutSettings.defaultStartStopShortcut,
      allowsSingleKey: true,
      onShortcutChanged: { config in
        ScrollingCaptureShortcutSettings.setStartStopShortcut(config)
        scrollingStartStopShortcut = config
        return true
      }
    )
  }

  @ViewBuilder
  private var ocrRows: some View {
    globalRow(.ocr, description: L10n.PreferencesShortcuts.captureTextDescription, shortcut: $ocrShortcut, defaultShortcut: .defaultOCR)
    additionalShortcutRow(.ocrWithLineBreaks)
    additionalShortcutRow(.ocrWithoutLineBreaks)
  }

  @ViewBuilder
  private var toolsRows: some View {
    globalRow(.annotate, label: L10n.Actions.openAnnotate, description: L10n.PreferencesShortcuts.openAnnotateDescription, shortcut: $annotateShortcut, defaultShortcut: .defaultAnnotate)
    globalRow(.videoEditor, label: L10n.Actions.openVideoEditor, description: L10n.PreferencesShortcuts.openVideoEditorDescription, shortcut: $videoEditorShortcut, defaultShortcut: .defaultVideoEditor)
    globalRow(.cloudUploads, label: L10n.Actions.cloudUploads, description: L10n.PreferencesShortcuts.cloudUploadsDescription, shortcut: $cloudUploadsShortcut, defaultShortcut: .defaultCloudUploads)
    globalRow(.pickColor, label: L10n.Actions.pickColor, description: L10n.PreferencesShortcuts.pickColorDescription, shortcut: $pickColorShortcut, defaultShortcut: nil)
    globalRow(.measureScreen, label: L10n.Actions.measureScreen, description: L10n.PreferencesShortcuts.measureScreenDescription, shortcut: $measureScreenShortcut, defaultShortcut: .defaultMeasureScreen)
    globalRow(.shortcutList, label: L10n.Actions.showShortcutList, description: L10n.PreferencesShortcuts.shortcutListDescription, shortcut: $shortcutListShortcut, defaultShortcut: .defaultShortcutList)
  }

  @ViewBuilder
  private var historyRows: some View {
    ShortcutRecorderView(
      label: L10n.PreferencesHistory.toggleModeShortcutTitle,
      description: L10n.PreferencesHistory.toggleModeShortcutDescription,
      shortcut: $historyFloatingManager.toggleModeShortcut,
      defaultShortcut: HistoryFloatingManager.defaultToggleModeShortcut,
      isEnabled: $historyFloatingManager.isToggleModeShortcutEnabled,
      onShortcutChanged: { config in
        historyFloatingManager.toggleModeShortcut = config
        return true
      }
    )
    .disabled(!historyFloatingManager.isEnabled)
    .opacity(historyFloatingManager.isEnabled ? 1.0 : 0.6)
  }

  @ViewBuilder
  private var quickAccessRows: some View {
    ShortcutRecorderView(
      label: L10n.PreferencesShortcuts.editLatestCapture,
      description: L10n.PreferencesShortcuts.editLatestCaptureDescription,
      shortcut: $openEditorShortcut,
      defaultShortcut: QuickAccessManager.defaultOpenEditorShortcut,
      isEnabled: Binding(
        get: { openEditorShortcutEnabled },
        set: { newValue in
          openEditorShortcutEnabled = newValue
          QuickAccessManager.shared.openEditorShortcutEnabled = newValue
        }
      ),
      onShortcutChanged: { config in
        QuickAccessManager.shared.setOpenEditorShortcut(config)
        return true
      }
    )
  }

  @ViewBuilder
  private var annotateRows: some View {
    additionalShortcutRow(.openFile)
    additionalShortcutRow(.openFromClipboard)
    additionalShortcutRow(.annotateLastScreenshot)
    ForEach(ShortcutsGroup.annotateActionKinds, id: \.self) { kind in
      annotateActionRow(kind)
    }
  }

  private func annotateActionRow(_ kind: AnnotateActionShortcutKind) -> some View {
    ShortcutRecorderView(
      label: kind.settingsTitle,
      description: annotateActionDescription(kind),
      shortcut: Binding(
        get: { annotateManager.shortcut(for: kind) },
        set: { _ in }
      ),
      defaultShortcut: AnnotateShortcutManager.defaultShortcut(for: kind),
      isEnabled: annotateActionEnabledBinding(for: kind),
      validationIssue: annotateActionValidationIssues[kind],
      onSwap: swapAction(for: .annotateAction(kind)),
      allowsSingleKey: kind.allowsSingleKey,
      onShortcutChanged: { handleAnnotateActionShortcutChange($0, for: kind) }
    )
  }

  private func annotateActionDescription(_ kind: AnnotateActionShortcutKind) -> String {
    switch kind {
    case .copyAndClose: return L10n.PreferencesShortcuts.copyAndCloseDescription
    case .toggleSidebar: return "Shows the background sidebar"
    case .togglePin: return L10n.PreferencesShortcuts.togglePinDescription
    case .cloudUpload: return L10n.PreferencesShortcuts.cloudUploadDescription
    case .autoRedactSensitiveData: return L10n.PreferencesShortcuts.autoRedactSensitiveDataDescription
    default: return ""
    }
  }

  @ViewBuilder
  private var annotateToolKeysRows: some View {
    ForEach(ShortcutsGroup.annotateToolSizeKinds, id: \.self) { kind in
      annotateActionRow(kind)
    }
    ForEach(ShortcutsGroup.orderedTools, id: \.self) { tool in
      SingleKeyRecorderView(
        tool: tool,
        shortcut: bindingForTool(tool),
        isEnabled: toolEnabledBinding(for: tool),
        validationIssue: annotateToolValidationIssues[tool],
        onChanged: { handleAnnotateToolShortcutChange($0, for: tool) },
        conflictingTool: conflictForTool(tool),
        context: toolContext(for: tool),
        defaultShortcut: tool.defaultShortcut,
        onSwap: toolSwapAction(for: tool),
        title: tool.shortcutSettingsTitle
      )
      .shortcutSearchable(tool.shortcutSettingsTitle)
    }
  }

  @ViewBuilder
  private var annotateReferenceRows: some View {
    // Save и Save as настраиваются в группе Annotate.
    ReadOnlyShortcutRow(label: L10n.ShortcutOverlay.undo, shortcut: "⌘ Z")
    ReadOnlyShortcutRow(label: L10n.ShortcutOverlay.redo, shortcut: "⌘ ⇧ Z")
    ReadOnlyShortcutRow(label: L10n.ShortcutOverlay.deleteAnnotation, shortcut: "⌫")
    ReadOnlyShortcutRow(label: L10n.ShortcutOverlay.cancelDeselect, shortcut: "⎋")
    ReadOnlyShortcutRow(label: L10n.ShortcutOverlay.confirmCrop, shortcut: "↩")
    ReadOnlyShortcutRow(
      label: L10n.ShortcutOverlay.nudgeAnnotation,
      shortcut: "← → ↑ ↓"
    )
    ReadOnlyShortcutRow(
      label: L10n.ShortcutOverlay.nudgeTenPixels,
      shortcut: "⇧ ← → ↑ ↓"
    )
  }

  // MARK: - All-In-One

  /// All-In-One проверяется так же, как остальные строки, и показывает причину отказа.
  private func handleAllInOneShortcutChange(_ config: ShortcutConfig?) -> Bool {
    switch validator.validateRecordedAllInOneShortcut(config) {
    case .reject(let issue):
      allInOneValidationIssue = issue
      return false
    case .accept(let issue):
      guard allInOneShortcut.update(config) else { return false }
      allInOneValidationIssue = issue
      return true
    }
  }


  // MARK: - Actions

  /// Show the Accessibility hint only when an Fn-based binding exists and the
  /// permission the Fn key monitors rely on is missing.
  private var showsFnAccessibilityHint: Bool {
    shortcutsEnabled && manager.hasFnBoundShortcuts && !accessibilityGranted
  }

  private func resetCaptureSection(refresh: Bool = true) {
    for kind in [GlobalShortcutKind.areaCopy, .areaSave, .areaPin, .ocrWithLineBreaks, .ocrWithoutLineBreaks] {
      _ = handleGlobalShortcutChange(nil, for: kind)
      globalShortcutEnabled[kind] = true
      manager.setShortcutEnabled(true, for: kind)
    }
    fullscreenShortcut = .defaultFullscreen
    areaShortcut = .defaultArea
    repeatAreaShortcut = .defaultRepeatArea
    delayedCaptureShortcut = nil
    delayedFullscreenShortcut = nil
    areaAnnotateShortcut = .defaultAreaAnnotate
    activeWindowShortcut = .defaultActiveWindowCapture
    areaApplicationCaptureShortcut = CaptureOverlayShortcutSettings.defaultApplicationCaptureShortcut
    scrollingCaptureShortcut = .defaultScrollingCapture
    objectCutoutShortcut = .defaultObjectCutout
    ocrShortcut = .defaultOCR
    smartElementShortcut = .defaultSmartElement

    let captureKinds: [GlobalShortcutKind] = [
      .fullscreen, .area, .repeatArea, .delayedCapture, .delayedFullscreen, .areaAnnotate, .activeWindow, .scrollingCapture, .objectCutout, .ocr,
      .smartElement,
    ]
    for kind in captureKinds {
      globalShortcutEnabled[kind] = true
      manager.setShortcutEnabled(true, for: kind)
      globalValidationIssues.removeValue(forKey: kind)
    }
    captureOverlayValidationIssues.removeValue(forKey: .applicationCapture)

    manager.setFullscreenShortcut(.defaultFullscreen)
    manager.setAreaShortcut(.defaultArea)
    manager.setRepeatAreaShortcut(.defaultRepeatArea)
    manager.setDelayedCaptureShortcut(nil)
    manager.setDelayedFullscreenShortcut(nil)
    manager.setAreaAnnotateShortcut(.defaultAreaAnnotate)
    manager.setActiveWindowShortcut(.defaultActiveWindowCapture)
    manager.setScrollingCaptureShortcut(.defaultScrollingCapture)
    manager.setObjectCutoutShortcut(.defaultObjectCutout)
    manager.setOCRShortcut(.defaultOCR)
    manager.setSmartElementShortcut(.defaultSmartElement)
    CaptureOverlayShortcutSettings.resetApplicationCaptureShortcut()
    ScrollingCaptureShortcutSettings.reset()
    scrollingStartStopShortcut = ScrollingCaptureShortcutSettings.startStopShortcut

    if refresh {
      manager.refreshShortcutRegistration()
      hasSystemConflict = SystemScreenshotShortcutManager.shared.hasConflictingSystemShortcuts()
    }
  }

  private func resetRecordingSection(refresh: Bool = true) {
    recordingShortcut = .defaultRecording
    recordingApplicationCaptureShortcut = CaptureOverlayShortcutSettings.defaultRecordingApplicationCaptureShortcut
    pauseResumeRecordingShortcut = nil
    togglePenRecordingShortcut = nil
    restartRecordingShortcut = nil
    deleteRecordingShortcut = nil

    globalShortcutEnabled[.recording] = true
    globalShortcutEnabled[.pauseResumeRecording] = true
    globalShortcutEnabled[.togglePenRecording] = true
    globalShortcutEnabled[.restartRecording] = true
    globalShortcutEnabled[.deleteRecording] = true

    manager.setShortcutEnabled(true, for: .recording)
    manager.setShortcutEnabled(true, for: .pauseResumeRecording)
    manager.setShortcutEnabled(true, for: .togglePenRecording)
    manager.setShortcutEnabled(true, for: .restartRecording)
    manager.setShortcutEnabled(true, for: .deleteRecording)

    globalValidationIssues.removeValue(forKey: .recording)
    globalValidationIssues.removeValue(forKey: .pauseResumeRecording)
    globalValidationIssues.removeValue(forKey: .togglePenRecording)
    globalValidationIssues.removeValue(forKey: .restartRecording)
    globalValidationIssues.removeValue(forKey: .deleteRecording)
    captureOverlayValidationIssues.removeValue(forKey: .applicationRecording)

    manager.setRecordingShortcut(.defaultRecording)
    manager.setPauseResumeRecordingShortcut(nil)
    manager.setTogglePenRecordingShortcut(nil)
    manager.setRestartRecordingShortcut(nil)
    manager.setDeleteRecordingShortcut(nil)
    CaptureOverlayShortcutSettings.resetRecordingApplicationCaptureShortcut()

    _ = handleGlobalShortcutChange(nil, for: .toggleCameraFullscreen)
    globalShortcutEnabled[.toggleCameraFullscreen] = true
    manager.setShortcutEnabled(true, for: .toggleCameraFullscreen)
    for kind in RecordingStartShortcutKind.allCases {
      RecordingStartShortcutSettings.reset(kind)
      recordingStartShortcuts[kind] = RecordingStartShortcutSettings.shortcut(for: kind)
    }

    if refresh {
      manager.refreshShortcutRegistration()
      hasSystemConflict = SystemScreenshotShortcutManager.shared.hasConflictingSystemShortcuts()
    }
  }

  private func resetToolsSection(refresh: Bool = true) {
    annotateShortcut = .defaultAnnotate
    videoEditorShortcut = .defaultVideoEditor
    cloudUploadsShortcut = .defaultCloudUploads
    shortcutListShortcut = .defaultShortcutList
    pickColorShortcut = nil
    measureScreenShortcut = .defaultMeasureScreen

    let toolsKinds: [GlobalShortcutKind] = [.annotate, .videoEditor, .cloudUploads, .shortcutList, .pickColor, .measureScreen]
    for kind in toolsKinds {
      globalShortcutEnabled[kind] = true
      manager.setShortcutEnabled(true, for: kind)
      globalValidationIssues.removeValue(forKey: kind)
    }

    manager.setAnnotateShortcut(.defaultAnnotate)
    manager.setVideoEditorShortcut(.defaultVideoEditor)
    manager.setCloudUploadsShortcut(.defaultCloudUploads)
    manager.setShortcutListShortcut(.defaultShortcutList)
    manager.setPickColorShortcut(nil)
    manager.setMeasureScreenShortcut(.defaultMeasureScreen)

    if refresh {
      manager.refreshShortcutRegistration()
      hasSystemConflict = SystemScreenshotShortcutManager.shared.hasConflictingSystemShortcuts()
    }
  }

  private func resetHistorySection(refresh: Bool = true) {
    historyShortcut = .defaultHistory
    globalShortcutEnabled[.history] = true
    manager.setShortcutEnabled(true, for: .history)
    globalValidationIssues.removeValue(forKey: .history)
    manager.setHistoryShortcut(.defaultHistory)

    HistoryFloatingManager.shared.resetToggleModeShortcut()

    if refresh {
      manager.refreshShortcutRegistration()
      hasSystemConflict = SystemScreenshotShortcutManager.shared.hasConflictingSystemShortcuts()
    }
  }

  private func resetQuickAccessSection() {
    openEditorShortcut = QuickAccessManager.defaultOpenEditorShortcut
    QuickAccessManager.shared.setOpenEditorShortcut(QuickAccessManager.defaultOpenEditorShortcut)
    openEditorShortcutEnabled = false
    QuickAccessManager.shared.openEditorShortcutEnabled = false
    QuickAccessActionShortcutStore.shared.resetToDefaults()
    quickAccessResetCount += 1
  }

  private func resetAnnotateActionsSection() {
    copyAndCloseShortcut = AnnotateShortcutManager.defaultCopyAndClose
    toggleSidebarShortcut = AnnotateShortcutManager.defaultToggleSidebar
    togglePinShortcut = AnnotateShortcutManager.defaultTogglePin
    cloudUploadShortcut = AnnotateShortcutManager.defaultCloudUpload
    autoRedactSensitiveDataShortcut = AnnotateShortcutManager.defaultAutoRedactSensitiveData

    for kind in AnnotateActionShortcutKind.allCases {
      annotateActionEnabled[kind] = true
      annotateManager.setActionShortcutEnabled(true, for: kind)
      annotateActionValidationIssues.removeValue(forKey: kind)
    }

    annotateManager.setCopyAndCloseShortcut(AnnotateShortcutManager.defaultCopyAndClose)
    annotateManager.setToggleSidebarShortcut(AnnotateShortcutManager.defaultToggleSidebar)
    annotateManager.setTogglePinShortcut(AnnotateShortcutManager.defaultTogglePin)
    annotateManager.setCloudUploadShortcut(AnnotateShortcutManager.defaultCloudUpload)
    annotateManager.setAutoRedactSensitiveDataShortcut(AnnotateShortcutManager.defaultAutoRedactSensitiveData)
    for kind in AnnotateActionShortcutKind.extraKinds {
      annotateManager.setActionShortcut(AnnotateShortcutManager.defaultShortcut(for: kind), for: kind)
    }
  }

  private func resetAnnotateToolKeysSection() {
    for tool in AnnotateShortcutManager.configurableTools {
      annotateManager.setShortcut(tool.defaultShortcut, for: tool)
      annotateManager.setShortcutEnabled(true, for: tool)
      annotateToolValidationIssues.removeValue(forKey: tool)
    }
  }

  private func resetGeneralSection() {
    _ = allInOneShortcut.update(nil)
    allInOneValidationIssue = nil
    resetHistorySection()
    for kind in [GlobalShortcutKind.toggleDesktopIcons, .restoreLastCapture, .openFile, .openFromClipboard, .annotateLastScreenshot]
      + ShortcutsGroup.quickAccessOverlayKinds + ShortcutsGroup.pinKinds {
      manager.setShortcutEnabled(true, for: kind)
      globalShortcutEnabled[kind] = true
      _ = handleGlobalShortcutChange(nil, for: kind)
    }
  }

  private func useSystemDefaults() {
    guard SystemScreenshotShortcutManager.shared.assignOwnShotDefaults(confirmed: true) else {
      showSystemDefaultsFailure = true
      return
    }
    fullscreenShortcut = manager.shortcut(for: .fullscreen)
    areaShortcut = manager.shortcut(for: .area)
    repeatAreaShortcut = manager.shortcut(for: .repeatArea)
    delayedCaptureShortcut = manager.shortcut(for: .delayedCapture)
    delayedFullscreenShortcut = manager.shortcut(for: .delayedFullscreen)
    areaAnnotateShortcut = manager.shortcut(for: .areaAnnotate)
    activeWindowShortcut = manager.shortcut(for: .activeWindow)
    scrollingCaptureShortcut = manager.shortcut(for: .scrollingCapture)
    objectCutoutShortcut = manager.shortcut(for: .objectCutout)
    ocrShortcut = manager.shortcut(for: .ocr)
    smartElementShortcut = manager.shortcut(for: .smartElement)
    recordingShortcut = manager.shortcut(for: .recording)
    pauseResumeRecordingShortcut = manager.shortcut(for: .pauseResumeRecording)
    togglePenRecordingShortcut = manager.shortcut(for: .togglePenRecording)
    restartRecordingShortcut = manager.shortcut(for: .restartRecording)
    deleteRecordingShortcut = manager.shortcut(for: .deleteRecording)
    annotateShortcut = manager.shortcut(for: .annotate)
    videoEditorShortcut = manager.shortcut(for: .videoEditor)
    cloudUploadsShortcut = manager.shortcut(for: .cloudUploads)
    shortcutListShortcut = manager.shortcut(for: .shortcutList)
    pickColorShortcut = manager.shortcut(for: .pickColor)
    measureScreenShortcut = manager.shortcut(for: .measureScreen)
    historyShortcut = manager.shortcut(for: .history)
    additionalShortcuts.removeAll()
    for kind in GlobalShortcutKind.allCases { globalShortcutEnabled[kind] = manager.isShortcutEnabled(for: kind) }
    globalValidationIssues.removeAll()
    shortcutsEnabled = true
    hasSystemConflict = SystemScreenshotShortcutManager.shared.hasConflictingSystemShortcuts()
    SystemScreenshotShortcutManager.shared.openSystemScreenshotSettings()
  }

  private func resetToDefaults() {
    resetGeneralSection()
    resetCaptureSection(refresh: false)
    resetRecordingSection(refresh: false)
    resetToolsSection(refresh: false)
    resetQuickAccessSection()
    resetAnnotateActionsSection()
    resetAnnotateToolKeysSection()
    videoEditorShortcuts.resetToDefaults()
    videoEditorShortcutIssues.removeAll()

    manager.refreshShortcutRegistration()
    hasSystemConflict = SystemScreenshotShortcutManager.shared.hasConflictingSystemShortcuts()
  }

  /// Re-check system shortcut conflict status with spinner animation
  private func refreshSystemConflict() {
    isRefreshingConflict = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
      withAnimation(.easeInOut(duration: 0.3)) {
        hasSystemConflict = SystemScreenshotShortcutManager.shared.hasConflictingSystemShortcuts()
      }
      isRefreshingConflict = false
    }
  }

  // MARK: - Annotation Tool Helpers

  private func bindingForTool(_ tool: AnnotationToolType) -> Binding<Character?> {
    Binding(
      get: { annotateManager.shortcut(for: tool) },
      set: { annotateManager.setShortcut($0, for: tool) }
    )
  }

  private func toolEnabledBinding(for tool: AnnotationToolType) -> Binding<Bool> {
    Binding(
      get: { annotateManager.isShortcutEnabled(for: tool) },
      set: { newValue in
        if newValue, let key = annotateManager.shortcut(for: tool) {
          switch validator.validateAnnotateToolShortcut(key, for: tool) {
          case .accept(let issue):
            annotateToolValidationIssues[tool] = issue
          case .reject(let issue):
            annotateToolValidationIssues[tool] = issue
            return
          }
        }

        annotateManager.setShortcutEnabled(newValue, for: tool)
        if !newValue {
          annotateToolValidationIssues.removeValue(forKey: tool)
        }
      }
    )
  }

  private func globalEnabledBinding(for kind: GlobalShortcutKind) -> Binding<Bool> {
    Binding(
      get: { globalShortcutEnabled[kind] ?? true },
      set: { newValue in
        if newValue {
          switch validator.validateGlobalShortcut(manager.shortcut(for: kind), for: kind) {
          case .accept(let issue):
            globalValidationIssues[kind] = issue
          case .reject(let issue):
            globalValidationIssues[kind] = issue
            return
          }
        }

        globalShortcutEnabled[kind] = newValue
        manager.setShortcutEnabled(newValue, for: kind)
        if !newValue {
          globalValidationIssues.removeValue(forKey: kind)
        }
        if kind.isSystemConflictRelevant {
          hasSystemConflict = SystemScreenshotShortcutManager.shared.hasConflictingSystemShortcuts()
        }
      }
    )
  }

  private func annotateActionEnabledBinding(for kind: AnnotateActionShortcutKind) -> Binding<Bool> {
    Binding(
      get: { annotateActionEnabled[kind] ?? true },
      set: { newValue in
        if newValue {
          switch validator.validateAnnotateActionShortcut(annotateManager.shortcut(for: kind), for: kind) {
          case .accept(let issue):
            annotateActionValidationIssues[kind] = issue
          case .reject(let issue):
            annotateActionValidationIssues[kind] = issue
            return
          }
        }

        annotateActionEnabled[kind] = newValue
        annotateManager.setActionShortcutEnabled(newValue, for: kind)
        if !newValue {
          annotateActionValidationIssues.removeValue(forKey: kind)
        }
      }
    )
  }

  // MARK: - Shortcut Swap

  /// Swap closure for a combo row whose last rejection named another action as owner.
  /// Supports global ↔ global, annotate action ↔ annotate action, and across the two.
  private func swapAction(for editing: ShortcutSwapProposal.Owner) -> (() -> Void)? {
    guard let proposal = validationIssue(for: editing)?.swapProposal,
          case .combo(let requested) = proposal.value,
          isComboOwner(proposal.owner) else { return nil }
    return { performComboSwap(editing: editing, owner: proposal.owner, requested: requested) }
  }

  private func validationIssue(for owner: ShortcutSwapProposal.Owner) -> ShortcutValidationIssue? {
    switch owner {
    case .global(let kind): return globalValidationIssues[kind]
    case .annotateAction(let kind): return annotateActionValidationIssues[kind]
    case .quickAccessAction, .annotateTool: return nil
    }
  }

  private func isComboOwner(_ owner: ShortcutSwapProposal.Owner) -> Bool {
    switch owner {
    case .global, .annotateAction: return true
    case .quickAccessAction, .annotateTool: return false
    }
  }

  private func currentComboShortcut(for owner: ShortcutSwapProposal.Owner) -> ShortcutConfig? {
    switch owner {
    case .global(let kind): return manager.shortcut(for: kind)
    case .annotateAction(let kind): return annotateManager.shortcut(for: kind)
    case .quickAccessAction, .annotateTool: return nil
    }
  }

  @discardableResult
  private func applyComboShortcut(_ config: ShortcutConfig?, to owner: ShortcutSwapProposal.Owner) -> Bool {
    switch owner {
    case .global(let kind): return handleGlobalShortcutChange(config, for: kind)
    case .annotateAction(let kind): return handleAnnotateActionShortcutChange(config, for: kind)
    case .quickAccessAction, .annotateTool: return false
    }
  }

  /// Clears the owner first so no two actions ever hold the same combo, then hands the
  /// requested combo to the edited row and the edited row's old combo to the owner.
  private func performComboSwap(
    editing: ShortcutSwapProposal.Owner,
    owner: ShortcutSwapProposal.Owner,
    requested: ShortcutConfig
  ) {
    let ownerOriginal = currentComboShortcut(for: owner)
    let editingOriginal = currentComboShortcut(for: editing)
    guard ownerOriginal == requested else { return }

    applyComboShortcut(nil, to: owner)
    guard applyComboShortcut(requested, to: editing) else {
      applyComboShortcut(ownerOriginal, to: owner)
      return
    }
    applyComboShortcut(editingOriginal, to: owner)
  }

  private func toolSwapAction(for tool: AnnotationToolType) -> (() -> Void)? {
    guard let proposal = annotateToolValidationIssues[tool]?.swapProposal,
          case .annotateTool(let ownerTool) = proposal.owner,
          case .key(let requested) = proposal.value else { return nil }
    return {
      guard annotateManager.shortcut(for: ownerTool) == requested else { return }
      let editingOriginal = annotateManager.shortcut(for: tool)
      _ = handleAnnotateToolShortcutChange(nil, for: ownerTool)
      guard handleAnnotateToolShortcutChange(requested, for: tool) else {
        _ = handleAnnotateToolShortcutChange(requested, for: ownerTool)
        return
      }
      _ = handleAnnotateToolShortcutChange(editingOriginal, for: ownerTool)
    }
  }

  private func conflictForTool(_ tool: AnnotationToolType) -> AnnotationToolType? {
    guard annotateManager.isShortcutEnabled(for: tool),
          let key = annotateManager.shortcut(for: tool) else { return nil }
    return annotateManager.conflictingTool(for: key, excluding: tool)
  }

  private func handleGlobalShortcutChange(_ config: ShortcutConfig?, for kind: GlobalShortcutKind) -> Bool {
    switch validator.validateGlobalShortcut(config, for: kind) {
    case .accept(let issue):
      globalValidationIssues[kind] = issue
      switch kind {
      case .fullscreen:
        fullscreenShortcut = config
        manager.setFullscreenShortcut(config)
      case .area:
        areaShortcut = config
        manager.setAreaShortcut(config)
      case .repeatArea:
        repeatAreaShortcut = config
        manager.setRepeatAreaShortcut(config)
      case .delayedCapture:
        delayedCaptureShortcut = config
        manager.setDelayedCaptureShortcut(config)
      case .delayedFullscreen:
        delayedFullscreenShortcut = config
        manager.setDelayedFullscreenShortcut(config)
      case .areaAnnotate:
        areaAnnotateShortcut = config
        manager.setAreaAnnotateShortcut(config)
      case .activeWindow:
        activeWindowShortcut = config
        manager.setActiveWindowShortcut(config)
      case .scrollingCapture:
        scrollingCaptureShortcut = config
        manager.setScrollingCaptureShortcut(config)
      case .recording:
        recordingShortcut = config
        manager.setRecordingShortcut(config)
      case .pauseResumeRecording:
        pauseResumeRecordingShortcut = config
        manager.setPauseResumeRecordingShortcut(config)
      case .togglePenRecording:
        togglePenRecordingShortcut = config
        manager.setTogglePenRecordingShortcut(config)
      case .restartRecording:
        restartRecordingShortcut = config
        manager.setRestartRecordingShortcut(config)
      case .deleteRecording:
        deleteRecordingShortcut = config
        manager.setDeleteRecordingShortcut(config)
      case .annotate:
        annotateShortcut = config
        manager.setAnnotateShortcut(config)
      case .videoEditor:
        videoEditorShortcut = config
        manager.setVideoEditorShortcut(config)
      case .cloudUploads:
        cloudUploadsShortcut = config
        manager.setCloudUploadsShortcut(config)
      case .shortcutList:
        shortcutListShortcut = config
        manager.setShortcutListShortcut(config)
      case .ocr:
        ocrShortcut = config
        manager.setOCRShortcut(config)
      case .smartElement:
        smartElementShortcut = config
        manager.setSmartElementShortcut(config)
      case .objectCutout:
        objectCutoutShortcut = config
        manager.setObjectCutoutShortcut(config)
      case .history:
        historyShortcut = config
        manager.setHistoryShortcut(config)
      case .pickColor:
        pickColorShortcut = config
        manager.setPickColorShortcut(config)
      case .toggleDesktopIcons:
        additionalShortcuts[.toggleDesktopIcons] = config
        manager.setToggleDesktopIconsShortcut(config)
      case .restoreLastCapture:
        additionalShortcuts[.restoreLastCapture] = config
        manager.setRestoreLastCaptureShortcut(config)
      case .areaCopy:
        additionalShortcuts[.areaCopy] = config
        manager.setAreaCopyShortcut(config)
      case .areaSave:
        additionalShortcuts[.areaSave] = config
        manager.setAreaSaveShortcut(config)
      case .areaPin:
        additionalShortcuts[.areaPin] = config
        manager.setAreaPinShortcut(config)
      case .measureScreen:
        measureScreenShortcut = config
        manager.setMeasureScreenShortcut(config)
      case .ocrWithLineBreaks, .ocrWithoutLineBreaks, .toggleCameraFullscreen,
           .toggleOverlays, .saveAllOverlays, .closeAllOverlays,
           .chooseAndPinImage, .togglePinsVisibility, .closeAllPins, .pinLastScreenshot,
           .openFile, .openFromClipboard, .annotateLastScreenshot:
        additionalShortcuts[kind] = config
        manager.setExtraShortcut(config, for: kind)
      }

      if kind.isSystemConflictRelevant {
        hasSystemConflict = SystemScreenshotShortcutManager.shared.hasConflictingSystemShortcuts()
      }
      return true
    case .reject(let issue):
      globalValidationIssues[kind] = issue
      return false
    }
  }

  private func handleAnnotateActionShortcutChange(
    _ config: ShortcutConfig?,
    for kind: AnnotateActionShortcutKind
  ) -> Bool {
    switch validator.validateAnnotateActionShortcut(config, for: kind) {
    case .accept(let issue):
      annotateActionValidationIssues[kind] = issue
      switch kind {
      case .copyAndClose:
        copyAndCloseShortcut = config
        annotateManager.setCopyAndCloseShortcut(config)
      case .toggleSidebar:
        toggleSidebarShortcut = config
        annotateManager.setToggleSidebarShortcut(config)
      case .togglePin:
        togglePinShortcut = config
        annotateManager.setTogglePinShortcut(config)
      case .cloudUpload:
        cloudUploadShortcut = config
        annotateManager.setCloudUploadShortcut(config)
      case .autoRedactSensitiveData:
        autoRedactSensitiveDataShortcut = config
        annotateManager.setAutoRedactSensitiveDataShortcut(config)
      default:
        annotateManager.setActionShortcut(config, for: kind)
      }
      return true
    case .reject(let issue):
      annotateActionValidationIssues[kind] = issue
      return false
    }
  }

  private func handleCaptureOverlayShortcutChange(
    _ shortcut: CaptureOverlayShortcut?,
    for kind: CaptureOverlayShortcutKind
  ) -> Bool {
    switch validator.validateCaptureOverlayShortcut(shortcut, for: kind) {
    case .accept(let issue):
      captureOverlayValidationIssues[kind] = issue
      switch kind {
      case .applicationCapture:
        areaApplicationCaptureShortcut = shortcut
        CaptureOverlayShortcutSettings.setApplicationCaptureShortcut(shortcut)
      case .applicationRecording:
        recordingApplicationCaptureShortcut = shortcut
        CaptureOverlayShortcutSettings.setRecordingApplicationCaptureShortcut(shortcut)
      }
      manager.refreshShortcutRegistration()
      hasSystemConflict = SystemScreenshotShortcutManager.shared.hasConflictingSystemShortcuts()
      return true
    case .reject(let issue):
      captureOverlayValidationIssues[kind] = issue
      return false
    }
  }

  private func handleAnnotateToolShortcutChange(
    _ key: Character?,
    for tool: AnnotationToolType
  ) -> Bool {
    guard let key else {
      annotateToolValidationIssues.removeValue(forKey: tool)
      annotateManager.setShortcut(nil, for: tool)
      return true
    }

    switch validator.validateAnnotateToolShortcut(key, for: tool) {
    case .accept(let issue):
      annotateToolValidationIssues[tool] = issue
      annotateManager.setShortcut(key, for: tool)
      return true
    case .reject(let issue):
      annotateToolValidationIssues[tool] = issue
      return false
    }
  }

  /// Recording annotation supports a subset of tools
  private static let recordingTools: Set<AnnotationToolType> = [
    .selection, .rectangle, .oval, .arrow, .line, .pencil, .highlighter,
  ]

  /// Screenshot annotation tools (all configurable except crop handled separately)
  private static let screenshotTools: Set<AnnotationToolType> = [
    .selection, .rectangle, .oval, .arrow, .line, .text,
    .highlighter, .blur, .counter, .pencil,
  ]

  private func toolContext(for tool: AnnotationToolType) -> AnnotationToolContext {
    let inScreenshot = Self.screenshotTools.contains(tool)
    let inRecording = Self.recordingTools.contains(tool)
    if inScreenshot, inRecording { return .both }
    if inRecording { return .recordingOnly }
    return .screenshotOnly
  }
}

private struct CaptureOverlayShortcutRecorderRow: View {
  let label: String
  let description: String
  @Binding var shortcut: CaptureOverlayShortcut?
  let defaultShortcut: CaptureOverlayShortcut?
  let isEnabled: Binding<Bool>
  let validationIssue: ShortcutValidationIssue?
  let onShortcutChanged: (CaptureOverlayShortcut?) -> Bool

  @StateObject private var recorder = ShortcutRecordingController()

  var body: some View {
    HStack(spacing: 12) {
      // Как у эталона: без значка ⓘ, описание – во всплывающей подсказке.
      Text(label)
        .help(description)

      Spacer()

      HStack(spacing: 6) {
        shortcutRecorderButton
        if recorder.isRecording {
          ShortcutRecordingAuxButtons(
            canUseOld: true,
            canReset: defaultShortcut != nil && shortcut != defaultShortcut,
            onUseOld: { recorder.stop() },
            onReset: {
              recorder.stop()
              resetToDefault()
            }
          )
        }
      }
      .background(ShortcutRecorderAnchor(controller: recorder))
      // Поле не раздувает строку: у эталона строка сочетания 42 pt.
      .settingsRowHeight(SettingsRowMetrics.shortcutRecorderHeight)
    }
    // Действия бывшей шестерёнки – в контекстном меню строки, как у эталона.
    .contentShape(Rectangle())
    .contextMenu {
      ShortcutOptionsMenuItems(
        isEnabled: isEnabled,
        isDefault: shortcut == defaultShortcut,
        onReset: resetToDefault
      )
      .disabled(recorder.isRecording)
    }
    .opacity(rowOpacity)
    .onChange(of: isEnabled.wrappedValue) { newValue in
      if !newValue {
        recorder.stop()
      }
    }
    .onDisappear {
      recorder.stop()
    }
    .shortcutSearchable(label)
  }

  private var shortcutRecorderButton: some View {
    Button {
      startRecording()
    } label: {
      Group {
        if recorder.isRecording {
          KeyCapRecordingView(minWidth: 100, heldModifiers: recorder.heldModifiers)
        } else {
          ShortcutFieldView(shortcut: shortcut.map(\.menuSymbolString))
        }
      }
      .frame(width: ShortcutFieldView.size.width, height: ShortcutFieldView.size.height)
    }
    .buttonStyle(ShortcutKeycapButtonStyle(isRecording: recorder.isRecording))
    .shortcutValidationHighlight(issue: validationIssue)
    .disabled(!isEnabled.wrappedValue)
    .help(isEnabled.wrappedValue ? L10n.ShortcutRecorder.clickToRecord : L10n.ShortcutRecorder.turnOnToEdit)
  }

  private var rowOpacity: Double {
    isEnabled.wrappedValue ? 1 : 0.62
  }

  private func resetToDefault() {
    if onShortcutChanged(defaultShortcut) {
      shortcut = defaultShortcut
    }
  }

  private func startRecording() {
    guard isEnabled.wrappedValue else { return }
    recorder.start { [recorder] event in
      switch ShortcutRecordingRules.decision(keyCode: event.keyCode, modifiers: event.modifierFlags, allowsSingleKey: true) {
      case .cancel:
        recorder.stop()
        return
      case .clear:
        _ = onShortcutChanged(nil)
        recorder.stop()
        return
      case .record, .ignore:
        break
      }

      guard let newShortcut = CaptureOverlayShortcut(from: event) else { return }
      // При конфликте запись продолжается, поповер подсказывает причину.
      if onShortcutChanged(newShortcut) {
        shortcut = newShortcut
        recorder.stop()
      }
    }
  }
}

// MARK: - System Shortcut Conflict Badge

/// Toolbar badge summarising whether macOS screenshot shortcuts overlap Snapzy's.
/// Clicking it opens a popover with the details, fix-up steps and a re-check button.
private struct SystemShortcutConflictBadge: View {
  let hasConflict: Bool
  let isRefreshing: Bool
  let onRefresh: () -> Void

  @State private var isPresented = false

  var body: some View {
    Button {
      isPresented.toggle()
    } label: {
      Image(systemName: hasConflict ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(tint)
        .frame(width: 24, height: 24)
        .background(Circle().fill(tint.opacity(0.15)))
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    // Equal inset on every side so the circle sits centred in the toolbar capsule.
    .padding(6)
    .accessibilityLabel(
      hasConflict ? L10n.PreferencesShortcuts.conflictBadge : L10n.PreferencesShortcuts.noConflictsBadge
    )
    .help(hasConflict ? L10n.PreferencesShortcuts.systemConflictTitle : L10n.PreferencesShortcuts.noConflictsDetected)
    .popover(isPresented: $isPresented, arrowEdge: .bottom) {
      popoverContent
        .padding(16)
        .frame(width: 340)
    }
  }

  private var tint: Color { hasConflict ? .orange : .green }

  @ViewBuilder
  private var popoverContent: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: hasConflict ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
          .font(.system(size: 18))
          .foregroundColor(tint)

        VStack(alignment: .leading, spacing: 2) {
          Text(hasConflict ? L10n.PreferencesShortcuts.systemConflictTitle : L10n.PreferencesShortcuts.noConflictsDetected)
            .font(.system(size: 13, weight: .semibold))
          Text(hasConflict ? L10n.PreferencesShortcuts.systemConflictDescription : L10n.PreferencesShortcuts.noConflictsDescription)
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      if hasConflict {
        VStack(alignment: .leading, spacing: 6) {
          Text(L10n.PreferencesShortcuts.howToDisable)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.secondary)
            .tracking(0.8)

          PreferencesGuideStep(step: "1", text: L10n.Onboarding.guideStep1)
          PreferencesGuideStep(step: "2", text: L10n.Onboarding.guideStep2)
          PreferencesGuideStep(step: "3", text: L10n.Onboarding.guideStep3)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          Radius.rect(Radius.card)
            .fill(Color.orange.opacity(0.06))
        )
      }

      HStack(spacing: 8) {
        if hasConflict {
          Button {
            SystemScreenshotShortcutManager.shared.openSystemScreenshotSettings()
          } label: {
            Label(L10n.PreferencesShortcuts.openKeyboardShortcutsSettings, systemImage: "gear")
          }
        }

        Spacer(minLength: 0)

        Button(action: onRefresh) {
          Label {
            Text(L10n.Common.refresh)
          } icon: {
            Image(systemName: "arrow.clockwise")
              .rotationEffect(.degrees(isRefreshing ? 360 : 0))
              .animation(
                isRefreshing
                  ? .linear(duration: 0.8).repeatForever(autoreverses: false)
                  : .default,
                value: isRefreshing
              )
          }
        }
        .disabled(isRefreshing)
      }
      .controlSize(.regular)
    }
  }
}

// MARK: - Guide Step Component

private struct PreferencesGuideStep: View {
  let step: String
  let text: String

  var body: some View {
    HStack(spacing: 8) {
      Text(step)
        .font(.system(size: 10, weight: .bold, design: .monospaced))
        .foregroundColor(.orange)
        .frame(width: 18, height: 18)
        .background(
          Circle()
            .fill(Color.orange.opacity(0.15))
        )

      Text(.init(text)) // Supports **bold** markdown
        .font(.system(size: 12))
        .foregroundColor(.primary)
    }
  }
}

#Preview {
  ShortcutsSettingsView()
    .frame(width: 600, height: 500)
}

// MARK: - Read-Only Shortcut Row

private struct ReadOnlyShortcutRow: View {
  let label: String
  let shortcut: String

  var body: some View {
    HStack(spacing: 12) {
      Text(label)

      Spacer()

      if shouldUseKeycaps {
        KeyCapGroupView(parts: shortcutParts)
      } else {
        Text(shortcut)
          .font(.system(.body, design: .monospaced))
          .foregroundColor(.secondary)
          .padding(.horizontal, 12)
          .padding(.vertical, 6)
          .background(
            Radius.rect(Radius.ornament)
              .fill(Color.gray.opacity(0.1))
          )
      }
    }
    .shortcutSearchable(label)
  }

  /// Split the display string (e.g. "⌘ ⇧ Z" or "← → ↑ ↓") into individual parts
  private var shortcutParts: [String] {
    shortcut
      .split(separator: " ")
      .map(String.init)
  }

  private var shouldUseKeycaps: Bool {
    shortcutParts.filter { !modifierTokens.contains($0) }.count <= 1
  }

  private var modifierTokens: Set<String> {
    ["⌘", "⇧", "⌥", "⌃"]
  }
}
