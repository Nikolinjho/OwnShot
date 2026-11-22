//
//  PreferencesShortcutsLayout.swift
//  Snapzy
//
//  Группы страницы Settings → Shortcuts. Порядок групп и строк повторяет
//  CleanShot X (evidence/spec-055-live/settings-shortcuts.txt); строки OwnShot
//  без аналога у эталона идут отдельными группами после строк эталона.
//

import Foundation

/// Заголовок страницы: одна или несколько групп (секций формы) под одним названием.
enum ShortcutsPage: String, CaseIterable, Identifiable {
  case general
  case screenshots
  case screenRecording
  case scrollingCapture
  case ocr
  case quickAccessOverlay
  case pin
  case annotate
  case annotateTools
  case videoEditor
  // Расширения OwnShot.
  case tools
  case history
  case quickAccessCard
  case annotateReference

  var id: String { rawValue }

  var title: String {
    switch self {
    case .general: return L10n.PreferencesShortcuts.groupGeneral
    case .screenshots: return L10n.PreferencesShortcuts.groupScreenshots
    case .screenRecording: return L10n.PreferencesShortcuts.groupScreenRecording
    case .scrollingCapture: return L10n.PreferencesShortcuts.groupScrollingCapture
    case .ocr: return L10n.PreferencesShortcuts.groupOCR
    case .quickAccessOverlay: return L10n.PreferencesShortcuts.groupQuickAccessOverlay
    case .pin: return L10n.PreferencesShortcuts.groupPin
    case .annotate: return L10n.PreferencesShortcuts.groupAnnotate
    case .annotateTools: return L10n.PreferencesShortcuts.groupAnnotateTools
    case .videoEditor:
      return L10n.string(
        "preferences-shortcuts.group-video-editor",
        defaultValue: "Video Editor",
        comment: "Group title for Video Editor keyboard shortcuts"
      )
    case .tools: return L10n.ShortcutOverlay.toolsSection
    case .history: return L10n.Preferences.historyTab
    case .quickAccessCard: return L10n.PreferencesShortcuts.groupQuickAccessCard
    case .annotateReference: return L10n.ShortcutOverlay.annotateReference
    }
  }

  /// Значок у заголовка группы, как у эталона (шестерёнка у General, камера у Screenshots…).
  var symbolName: String {
    switch self {
    case .general: return "gearshape.fill"
    case .screenshots: return "camera.fill"
    case .screenRecording: return "record.circle"
    case .scrollingCapture: return "scroll"
    case .ocr: return "text.viewfinder"
    case .quickAccessOverlay: return "square.stack.fill"
    case .pin: return "pin.fill"
    case .annotate: return "pencil.tip.crop.circle"
    case .annotateTools: return "pencil.and.outline"
    case .videoEditor: return "film"
    case .tools: return "wrench.and.screwdriver.fill"
    case .history: return "clock.arrow.circlepath"
    case .quickAccessCard: return "rectangle.on.rectangle"
    case .annotateReference: return "keyboard"
    }
  }

  /// Секции формы под заголовком страницы. У эталона Screenshots — две секции.
  static func groups(for page: ShortcutsPage) -> [ShortcutsGroup] {
    switch page {
    case .general: return [.general]
    case .screenshots: return [.screenshots, .screenshotActions, .screenshotExtras]
    case .screenRecording: return [.screenRecording, .screenRecordingExtras]
    case .scrollingCapture: return [.scrollingCapture]
    case .ocr: return [.ocr]
    case .quickAccessOverlay: return [.quickAccessOverlay]
    case .pin: return [.pin]
    case .annotate: return [.annotate, .annotateExtras]
    case .annotateTools: return [.annotateTools]
    case .videoEditor: return [.videoEditor]
    case .tools: return [.tools]
    case .history: return [.history]
    case .quickAccessCard: return [.quickAccessCard]
    case .annotateReference: return [.annotateReference]
    }
  }
}

/// Одна секция формы со строками сочетаний.
enum ShortcutsGroup: String, CaseIterable, Hashable {
  case general
  case screenshots
  case screenshotActions
  case screenshotExtras
  case screenRecording
  case screenRecordingExtras
  case scrollingCapture
  case ocr
  case quickAccessOverlay
  case pin
  case annotate
  case annotateExtras
  case annotateTools
  case videoEditor
  case tools
  case history
  case quickAccessCard
  case annotateReference

  static var selectWindowTitle: String { L10n.PreferencesShortcuts.selectWindowTitle }
  static var startStopCapturingTitle: String { L10n.PreferencesShortcuts.startStopCapturingTitle }

  static let quickAccessOverlayKinds: [GlobalShortcutKind] = [.toggleOverlays, .saveAllOverlays, .closeAllOverlays]
  static let pinKinds: [GlobalShortcutKind] = [
    .chooseAndPinImage, .togglePinsVisibility, .closeAllPins, .pinLastScreenshot,
  ]
  /// Команды редактора в группе Annotate, после Open File / Open From Clipboard / Annotate Last Screenshot.
  static let annotateActionKinds: [AnnotateActionShortcutKind] = [
    .copyObject, .duplicateObject, .save, .saveAs, .copyAndClose, .cloudUpload, .print,
    .togglePin, .addNewScreenshot, .addScreenshotFromFile,
  ]
  /// Начало группы Annotate tools: размер инструмента и Background Tool.
  static let annotateToolSizeKinds: [AnnotateActionShortcutKind] = [
    .increaseToolSize, .decreaseToolSize, .toggleSidebar,
  ]
  /// Инструменты в порядке эталона; Cut Out, Measure и Watermark — расширения OwnShot, в конце.
  static let orderedTools: [AnnotationToolType] = {
    let reference: [AnnotationToolType] = [
      .selection, .crop, .pencil, .highlighter, .line, .text, .arrow, .counter,
      .oval, .blur, .spotlight, .rectangle, .filledRectangle,
    ]
    let configurable = AnnotateShortcutManager.configurableTools
    return reference.filter(configurable.contains) + configurable.filter { !reference.contains($0) }
  }()

  /// Названия строк в порядке показа (и для поиска).
  var rowTitles: [String] {
    switch self {
    case .general:
      return ["All-In-One"] + [GlobalShortcutKind.toggleDesktopIcons, .history, .restoreLastCapture].map(\.displayName)
    case .screenshots:
      return [GlobalShortcutKind.area, .repeatArea, .fullscreen, .activeWindow, .delayedCapture].map(\.displayName)
    case .screenshotActions:
      return [GlobalShortcutKind.areaCopy.displayName, GlobalShortcutKind.areaSave.displayName,
              "Capture Area & Upload to Cloud",
              GlobalShortcutKind.areaAnnotate.displayName, GlobalShortcutKind.areaPin.displayName]
    case .screenshotExtras:
      return [CaptureOverlayShortcutKind.applicationCapture.displayName]
        + [GlobalShortcutKind.delayedFullscreen, .objectCutout, .smartElement].map(\.displayName)
    case .screenRecording:
      return [GlobalShortcutKind.recording.displayName, Self.selectWindowTitle]
        + RecordingStartShortcutKind.allCases.map(\.settingsTitle)
        + [GlobalShortcutKind.pauseResumeRecording, .restartRecording, .toggleCameraFullscreen].map(\.displayName)
    case .screenRecordingExtras:
      return [GlobalShortcutKind.togglePenRecording, .deleteRecording].map(\.displayName)
    case .scrollingCapture:
      return [GlobalShortcutKind.scrollingCapture.displayName, Self.startStopCapturingTitle]
    case .ocr:
      return [GlobalShortcutKind.ocr, .ocrWithLineBreaks, .ocrWithoutLineBreaks].map(\.displayName)
    case .quickAccessOverlay:
      return Self.quickAccessOverlayKinds.map(\.displayName)
    case .pin:
      return Self.pinKinds.map(\.displayName)
    case .annotate:
      return [GlobalShortcutKind.openFile, .openFromClipboard, .annotateLastScreenshot].map(\.displayName)
        + Self.annotateActionKinds.map(\.settingsTitle)
    case .annotateExtras:
      return [AnnotateActionShortcutKind.autoRedactSensitiveData.settingsTitle]
    case .annotateTools:
      return Self.annotateToolSizeKinds.map(\.settingsTitle) + Self.orderedTools.map(\.shortcutSettingsTitle)
    case .videoEditor:
      return VideoEditorShortcutAction.allCases.map(\.settingsTitle)
    case .tools:
      return [GlobalShortcutKind.annotate, .videoEditor, .cloudUploads, .pickColor, .measureScreen, .shortcutList]
        .map(\.displayName)
    case .history:
      return [L10n.PreferencesHistory.toggleModeShortcutTitle]
    case .quickAccessCard:
      return [L10n.PreferencesShortcuts.editLatestCapture, L10n.PreferencesShortcuts.cardActionsEnableTitle]
        + QuickAccessActionKind.defaultOrder.map(\.settingsTitle)
    case .annotateReference:
      return [L10n.ShortcutOverlay.undo, L10n.ShortcutOverlay.redo, L10n.ShortcutOverlay.deleteAnnotation,
              L10n.ShortcutOverlay.cancelDeselect, L10n.ShortcutOverlay.confirmCrop,
              L10n.ShortcutOverlay.nudgeAnnotation, L10n.ShortcutOverlay.nudgeTenPixels]
    }
  }

  var searchTitles: [String] {
    self == .videoEditor ? rowTitles + [ShortcutsPage.videoEditor.title] : rowTitles
  }
}
