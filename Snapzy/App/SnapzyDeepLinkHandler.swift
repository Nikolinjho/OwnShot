//
//  SnapzyDeepLinkHandler.swift
//  Snapzy
//
//  Handles snapzy:// automation URLs for external launchers and workflows.
//

import AppKit
import ImageIO
import UniformTypeIdentifiers
import Foundation

@MainActor
struct SnapzyDeepLinkHandler {
  private let screenCaptureViewModel: ScreenCaptureViewModel

  init(screenCaptureViewModel: ScreenCaptureViewModel) {
    self.screenCaptureViewModel = screenCaptureViewModel
  }

  func handle(_ url: URL) {
    guard UserDefaults.standard.object(forKey: PreferencesKeys.urlSchemeEnabled) as? Bool ?? true else {
      DiagnosticLogger.shared.log(
        .info,
        .action,
        "Ignored deeplink because URL scheme is disabled in preferences",
        context: ["url": url.absoluteString]
      )
      return
    }

    guard let action = SnapzyDeepLinkAction(url: url) else {
      DiagnosticLogger.shared.log(
        .warning,
        .action,
        "Ignored unsupported deeplink",
        context: [
          "scheme": url.scheme ?? "",
          "host": url.host ?? "",
          "path": url.path,
        ]
      )
      return
    }

    DiagnosticLogger.shared.log(
      .info,
      .action,
      "Handling deeplink",
      context: ["action": action.logName]
    )

    switch action {
    case .allInOne:
      screenCaptureViewModel.captureAllInOne()
    case .automation(let request):
      handleAutomation(request)
    case .captureFullscreen:
      screenCaptureViewModel.captureFullscreen()
    case .captureArea:
      screenCaptureViewModel.captureArea()
    case .captureRepeatArea:
      screenCaptureViewModel.captureRepeatArea()
    case .captureDelayed:
      screenCaptureViewModel.captureDelayed()
    case .captureDelayedFullscreen:
      screenCaptureViewModel.captureDelayedFullscreen()
    case .captureApplication:
      screenCaptureViewModel.captureApplication()
    case .captureActiveWindow:
      screenCaptureViewModel.captureActiveWindow()
    case .captureAreaAnnotate:
      screenCaptureViewModel.captureAreaAnnotate()
    case .captureScrolling:
      screenCaptureViewModel.captureScrolling()
    case .captureOCR:
      screenCaptureViewModel.captureOCR()
    case .captureSmartElement:
      SmartElementCaptureController.shared.startCapture()
    case .captureObjectCutout:
      screenCaptureViewModel.captureObjectCutout()
    case .recordScreen:
      screenCaptureViewModel.startRecordingFlow()
    case .recordApplication:
      screenCaptureViewModel.startApplicationRecordingFlow()
    case .openAnnotate:
      // Без filepath эталон открывает выбор файла, а не пустой редактор.
      NSApp.activate(ignoringOtherApps: true)
      let picker = NSOpenPanel()
      picker.allowedContentTypes = [.image, OwnShotProjectFormat.contentType]
      picker.allowsMultipleSelection = false
      guard picker.runModal() == .OK, let url = picker.url else { return }
      AnnotateManager.shared.openAnnotation(url: url)
    case .openCombine(let fileURLs):
      if fileURLs.count >= 2 {
        AnnotateManager.shared.openCombineImages(urls: fileURLs)
      } else {
        CombineImagesCoordinator.shared.presentPicker()
      }
      NSApp.activate(ignoringOtherApps: true)
    case .openVideoEditor:
      VideoEditorManager.shared.openEmptyEditor()
      NSApp.activate(ignoringOtherApps: true)
    case .openCloudUploads:
      _ = OwnShotFeaturePolicy.allow(.cloud)
    case .openHistory:
      HistoryFloatingManager.shared.show()
    case .pickColor:
      screenCaptureViewModel.pickColor()
    case .measureScreen:
      screenCaptureViewModel.measureScreen()
    case .showShortcuts:
      ShortcutOverlayManager.shared.toggle()
    case .openSettings(let tab):
      AppStatusBarController.shared.openPreferencesWindow(tab: tab)
    }
  }

  private func handleAutomation(_ request: OwnShotAutomationRequest) {
    if request.command == "all-in-one" {
      guard let area = request.resolvedArea() else { NSSound.beep(); return }
      screenCaptureViewModel.captureAllInOne(on: area.screen, selection: request.bounds == nil ? nil : area.rect)
      return
    }
    if request.command.hasSuffix("desktop-icons") {
      switch request.command {
      case "hide-desktop-icons": OwnShotDesktopIconsController.shared.setHidden(true)
      case "show-desktop-icons": OwnShotDesktopIconsController.shared.setHidden(false)
      default: OwnShotDesktopIconsController.shared.toggle()
      }
      return
    }
    if let file = request.fileURL {
      guard FileManager.default.fileExists(atPath: file.path) else { NSSound.beep(); return }
      switch request.command {
      case "pin": Task { await QuickAccessManager.shared.pinScreenshot(url: file) }
      case "add-quick-access-overlay":
        let target = file.resolvingSymlinksInPath()
        let values = try? target.resourceValues(forKeys: [.isRegularFileKey])
        guard values?.isRegularFile == true else { NSSound.beep(); return }
        let isVideo = ThumbnailGenerator.isVideoFile(file)
        let isImage = UTType(filenameExtension: file.pathExtension)?.conforms(to: .image) == true
        if !isVideo, !isImage {
          guard let source = CGImageSourceCreateWithURL(target as CFURL, nil),
                CGImageSourceGetStatus(source) == .statusComplete,
                CGImageSourceGetType(source) != nil else { NSSound.beep(); return }
        }
        Task { await QuickAccessManager.shared.addExternalMedia(url: file, isVideo: isVideo) }
      case "capture-text": screenCaptureViewModel.captureText(from: file, language: request.language, preserveBreaks: request.preserveBreaks)
      case "open-annotate":
        // Файл, открытый через open-annotate, эталон добавляет в History, как Open With.
        HistoryExternalFileRecorder.record(file)
        AnnotateManager.shared.openAnnotation(url: file)
      default:
        break
      }
      return
    }
    switch request.command {
    case "pin":
      let picker = NSOpenPanel()
      picker.allowedContentTypes = [.image]
      picker.allowsMultipleSelection = false
      guard picker.runModal() == .OK, let url = picker.url else { return }
      Task { await QuickAccessManager.shared.pinScreenshot(url: url) }
    case "open-from-clipboard": screenCaptureViewModel.openAnnotationFromClipboard()
    case "restore-recently-closed": screenCaptureViewModel.restoreRecentlyClosedCapture()
    case "capture-previous-area": screenCaptureViewModel.captureRepeatArea(action: request.action)
    case "record-screen":
      guard let rect = request.resolvedRect() else { NSSound.beep(); return }
      screenCaptureViewModel.startRecordingFlow(initialSelection: rect)
    case "capture-area", "capture-fullscreen", "capture-window", "self-timer", "scrolling-capture", "capture-text":
      guard let rect = request.resolvedRect() else { NSSound.beep(); return }
      switch request.command {
      case "capture-text":
        if request.bounds == nil { screenCaptureViewModel.captureOCR(language: request.language, preserveBreaks: request.preserveBreaks) }
        else { screenCaptureViewModel.captureOCR(rect: rect, language: request.language, preserveBreaks: request.preserveBreaks) }
      case "scrolling-capture":
        if request.bounds == nil { screenCaptureViewModel.captureScrolling(startImmediately: request.startImmediately, autoScroll: request.autoScroll) }
        else { screenCaptureViewModel.captureScrolling(rect: rect, startImmediately: request.startImmediately, autoScroll: request.autoScroll) }
      case "self-timer":
        if request.bounds == nil, request.mode != "fullscreen" { screenCaptureViewModel.captureDelayedArea(action: request.action) }
        else { screenCaptureViewModel.captureDelayedRegion(rect, action: request.action, rememberArea: request.remembersArea) }
      case "capture-window": screenCaptureViewModel.captureApplication(action: request.action)
      case "capture-area" where request.bounds == nil: screenCaptureViewModel.captureArea(action: request.action)
      default: screenCaptureViewModel.captureRegion(rect, action: request.action, rememberArea: request.remembersArea)
      }
    default: break
    }
  }

}

enum SnapzyDeepLinkAction: Equatable {
  case allInOne
  case automation(OwnShotAutomationRequest)
  case captureFullscreen
  case captureArea
  case captureRepeatArea
  case captureDelayed
  case captureDelayedFullscreen
  case captureApplication
  case captureActiveWindow
  case captureAreaAnnotate
  case captureScrolling
  case captureOCR
  case captureSmartElement
  case captureObjectCutout
  case recordScreen
  case recordApplication
  case openAnnotate
  case openCombine([URL])
  case openVideoEditor
  case openCloudUploads
  case openHistory
  case pickColor
  case measureScreen
  case showShortcuts
  case openSettings(PreferencesTab?)
  init?(url: URL) {
    guard url.scheme?.lowercased() == "ownshot" else { return nil }

    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    let host = url.host?.lowercased()
    let pathParts = url.path.split(separator: "/").map { $0.lowercased() }
    let parts = ([host] + pathParts).compactMap { $0 }
    let command = parts.joined(separator: "/")
    let parameterAliases: [String: String] = ["capture/area": "capture-area", "area": "capture-area", "screenshot/area": "capture-area", "capture/fullscreen": "capture-fullscreen", "fullscreen": "capture-fullscreen", "capture/screen": "capture-fullscreen", "capture/window": "capture-window", "capture/application": "capture-window", "capture/ocr": "capture-text", "capture/text": "capture-text", "ocr": "capture-text", "text": "capture-text", "capture/scrolling": "scrolling-capture", "capture-scrolling": "scrolling-capture", "capture/delayed": "self-timer", "capture-delayed": "self-timer", "open/annotate": "open-annotate", "annotate": "open-annotate"]
    let parameterCommand = parameterAliases[command] ?? command

    let queryNames = Set((components?.queryItems ?? []).map { $0.name.lowercased() })
    let geometryParameters: Set<String> = ["bounds", "x", "y", "width", "height", "display"]
    if ["all-in-one", "record-screen"].contains(command), !queryNames.isDisjoint(with: geometryParameters) {
      var geometryComponents = components
      geometryComponents?.queryItems = components?.queryItems?.filter {
        geometryParameters.contains($0.name.lowercased())
      }
      guard let request = OwnShotAutomationRequest(command: command, components: geometryComponents) else { return nil }
      self = .automation(request)
      return
    }
    if ["capture/delayed", "capture-delayed", "delayed-capture", "screenshot/delayed"].contains(command), queryNames.isDisjoint(with: geometryParameters.union(["action"])) {
      self = Self.delayedCaptureAction(from: components)
      return
    }
    let parameterCommands: Set<String> = ["capture-area", "capture-text", "capture-fullscreen", "capture-window", "self-timer", "scrolling-capture"]
    let fileCommands = OwnShotAutomationRequest.fileCommands
    let utilityCommands: Set<String> = ["open-from-clipboard", "restore-recently-closed", "toggle-desktop-icons", "hide-desktop-icons", "show-desktop-icons"]
    if parameterCommand == "pin" || fileCommands.contains(parameterCommand) && !(components?.queryItems ?? []).isEmpty || utilityCommands.contains(parameterCommand) || (parameterCommands.contains(parameterCommand) && !(components?.queryItems ?? []).isEmpty) {
      guard let request = OwnShotAutomationRequest(command: parameterCommand, components: components) else { return nil }
      if fileCommands.contains(parameterCommand), parameterCommand != "pin", request.fileURL == nil {
        // open-annotate без filepath тоже открывает выбор файла.
        if parameterCommand == "open-annotate" { self = .openAnnotate; return }
        return nil
      }
      self = .automation(request)
      return
    }
    if ["pin", "add-quick-access-overlay"].contains(command) { return nil }
    switch command {
    case "all-in-one": self = .allInOne
    case "capture/fullscreen", "capture-screen", "capture-fullscreen", "fullscreen", "screenshot/fullscreen":
      self = .captureFullscreen
    case "capture/area", "capture-area", "area", "screenshot/area":
      self = .captureArea
    case "capture/repeat-area", "repeat-area", "capture-repeat-area", "capture-previous-area", "screenshot/repeat-area":
      var actionComponents = components
      actionComponents?.queryItems = components?.queryItems?.filter { $0.name.lowercased() == "action" }
      if let request = OwnShotAutomationRequest(command: "capture-previous-area", components: actionComponents),
         let action = request.action, ["copy", "save", "annotate", "upload", "pin"].contains(action) {
        self = .automation(request)
      } else {
        self = .captureRepeatArea
      }
    case "capture/delayed", "delayed-capture", "capture-delayed", "self-timer", "screenshot/delayed":
      self = Self.delayedCaptureAction(from: components)
    case "capture/delayed-fullscreen", "delayed-fullscreen", "capture-delayed-fullscreen",
      "screenshot/delayed-fullscreen":
      self = .captureDelayedFullscreen
    case "capture/application", "capture/window", "application-capture", "capture-window", "window-capture", "screenshot/window":
      self = .captureApplication
    case "capture/active-window", "capture/focused-window", "active-window-capture",
      "active-window", "screenshot/active-window":
      self = .captureActiveWindow
    case "capture/area-annotate", "capture-area-annotate", "area-annotate", "screenshot/area-annotate":
      self = .captureAreaAnnotate
    case "capture/scrolling", "scrolling-capture", "capture-scrolling", "scrolling", "screenshot/scrolling":
      self = .captureScrolling
    case "capture/ocr", "capture/text", "capture-text", "ocr", "text":
      self = .captureOCR
    case "capture/smart-element", "smart-element", "capture-smart-element", "smart":
      self = .captureSmartElement
    case "capture/object-cutout", "object-cutout", "capture-object-cutout", "cutout":
      self = .captureObjectCutout
    case "record/screen", "record-screen", "screen-recording", "recording", "record":
      self = .recordScreen
    case "record/application", "record/window", "application-recording", "window-recording", "recording/window":
      self = .recordApplication
    case "open/annotate", "annotate", "open-annotate":
      self = .openAnnotate
    case "open/combine", "combine", "combine-images", "open-combine":
      self = .openCombine(Self.combineFileURLs(from: components))
    case "open/video-editor", "video-editor", "edit-video", "open-video-editor":
      self = .openVideoEditor
    case "open/cloud-uploads", "cloud-uploads", "uploads", "open-uploads":
      self = .openCloudUploads
    case "open/history", "history", "capture-history", "open-history":
      self = .openHistory
    case "tools/pick-color", "pick-color", "color-picker":
      self = .pickColor
    case "tools/measure", "tools/ruler", "measure", "ruler", "screen-ruler", "measure-screen":
      self = .measureScreen
    case "show/shortcuts", "shortcuts", "keyboard-shortcuts", "show-shortcuts":
      self = .showShortcuts
    case "settings", "preferences", "open-settings":
      self = .openSettings(Self.preferencesTab(from: components, pathParts: pathParts))
    case let value where value.hasPrefix("settings/"):
      self = .openSettings(Self.preferencesTab(from: components, pathParts: pathParts))
    case let value where value.hasPrefix("preferences/"):
      self = .openSettings(Self.preferencesTab(from: components, pathParts: pathParts))
    default:
      return nil
    }
  }

  var logName: String {
    switch self {
    case .allInOne: return "allInOne"
    case .automation(let request): return request.command
    case .captureFullscreen: return "captureFullscreen"
    case .captureArea: return "captureArea"
    case .captureRepeatArea: return "captureRepeatArea"
    case .captureDelayed: return "captureDelayed"
    case .captureDelayedFullscreen: return "captureDelayedFullscreen"
    case .captureApplication: return "captureApplication"
    case .captureActiveWindow: return "captureActiveWindow"
    case .captureAreaAnnotate: return "captureAreaAnnotate"
    case .captureScrolling: return "captureScrolling"
    case .captureOCR: return "captureOCR"
    case .captureSmartElement: return "captureSmartElement"
    case .captureObjectCutout: return "captureObjectCutout"
    case .recordScreen: return "recordScreen"
    case .recordApplication: return "recordApplication"
    case .openAnnotate: return "openAnnotate"
    case .openCombine(let fileURLs): return "openCombine(\(fileURLs.count))"
    case .openVideoEditor: return "openVideoEditor"
    case .openCloudUploads: return "openCloudUploads"
    case .openHistory: return "openHistory"
    case .pickColor: return "pickColor"
    case .measureScreen: return "measureScreen"
    case .showShortcuts: return "showShortcuts"
    case .openSettings(let tab): return "openSettings(\(String(describing: tab)))"
    }
  }

  /// `snapzy://capture/delayed?mode=fullscreen` captures the whole display.
  /// Any other mode, including a missing query, keeps area selection.
  private static func delayedCaptureAction(from components: URLComponents?) -> SnapzyDeepLinkAction {
    let mode = components?.queryItems?
      .first(where: { $0.name.lowercased() == "mode" })?
      .value?
      .lowercased()
    return mode == "fullscreen" ? .captureDelayedFullscreen : .captureDelayed
  }

  private static func combineFileURLs(from components: URLComponents?) -> [URL] {
    components?.queryItems?
      .filter { $0.name.lowercased() == "file" }
      .compactMap { item in
        guard let value = item.value, !value.isEmpty else { return nil }
        if let url = URL(string: value), url.isFileURL {
          return url.standardizedFileURL
        }
        return URL(fileURLWithPath: (value as NSString).expandingTildeInPath).standardizedFileURL
      } ?? []
  }

  private static func preferencesTab(from components: URLComponents?, pathParts: [String]) -> PreferencesTab? {
    let queryTab = components?.queryItems?
      .first(where: { $0.name.lowercased() == "tab" })?
      .value?
      .lowercased()

    let pathTab = pathParts.first
    return preferencesTab(named: queryTab ?? pathTab)
  }

  private static func preferencesTab(named name: String?) -> PreferencesTab? {
    switch name {
    case "wallpaper": return .wallpaper
    case "recording": return .recording
    case "general":
      return .general
    case "menubar", "menu-bar":
      return .menuBar
    case "capture", "screenshots", "screenshot":
      return .capture
    case "annotate", "annotation", "annotations":
      return .annotate
    case "quick-access", "quickaccess":
      return .quickAccess
    case "history":
      return .history
    case "shortcuts", "keyboard-shortcuts":
      return .shortcuts
    case "permissions", "privacy":
      return .permissions
    case "command-line", "commandline", "cli":
      return .commandLine
    case "cloud", "uploads":
      return .cloud
    case "advanced", "configuration", "config", "toml":
      return .advanced
    case "about":
      return .about
    default:
      return nil
    }
  }
}
