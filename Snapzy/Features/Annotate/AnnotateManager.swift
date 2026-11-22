//
//  AnnotateManager.swift
//  Snapzy
//
//  Singleton manager for opening and tracking annotation windows
//

import AppKit
import Foundation

enum AnnotateCanvasDefaults {
  nonisolated static let cornerRadius: CGFloat = 0
  nonisolated static let shadowRadius: CGFloat = 15
  nonisolated static let shadowOffsetX: CGFloat = 0
  nonisolated static let shadowOffsetY: CGFloat = 8
}

/// In-memory annotation session data for re-editing annotations
struct AnnotationCanvasEffects {
  var backgroundStyle: BackgroundStyle = .none
  var isBlurredBackgroundEnabled: Bool = false
  var blurredBackgroundEffect: BlurredBackgroundEffect = .soft
  var padding: CGFloat = 0
  var inset: CGFloat = 0
  // Эталон: Auto-balance по умолчанию выключен.
  var autoBalance: Bool = false
  // Эталон: Shadow по умолчанию 0.
  var shadowIntensity: CGFloat = 0
  var cornerRadius: CGFloat = AnnotateCanvasDefaults.cornerRadius
  var imageAlignment: ImageAlignment = .center
  var aspectRatio: AspectRatioOption = .auto
  var aspectRatioOrientation: AspectRatioOrientation = .horizontal
}

/// In-memory annotation session data for re-editing annotations
/// Preserved until the Quick Access card is dismissed
/// In-memory snapshot of an active combine (stitch) session — the layout flags that are
/// not otherwise derivable from the annotation array. Source pixels persist via
/// `embeddedImageAssetsData`; only these flags need explicit capture/restore.
struct CombineSessionSnapshot: Equatable {
  var mode: CombineImagesMode
  var direction: CombineImagesDirection
  var gap: CGFloat
  var freeBoundsByAnnotationID: [UUID: CGRect]
}

struct AnnotationSessionData {
  /// Compressed PNG data of the original image (before any annotations were baked)
  let originalImageData: Data
  var annotations: [AnnotationItem]
  var canvasEffects: AnnotationCanvasEffects
  /// Selected canvas preset id at the moment session was cached.
  var selectedCanvasPresetId: UUID?
  /// True when current canvas values diverged from selected preset at cache time.
  var isSelectedCanvasPresetDirty: Bool = false
  /// Applied crop rectangle in image coordinates (if any)
  var cropRect: CGRect?
  /// Whether background cutout was active in this editing session.
  var isCutoutApplied: Bool = false
  /// PNG data for the cutout source image (alpha preserved) when cutout is active.
  var cutoutImageData: Data? = nil
  /// True if current crop was auto-applied by cutout logic.
  var didCutoutAutoApplyCrop: Bool = false
  /// Stored auto-applied crop rect to preserve deterministic toggle-off behavior.
  var cutoutAutoAppliedCropRect: CGRect? = nil
  /// Imported image assets referenced by `.embeddedImage(assetId)` annotations.
  var embeddedImageAssetsData: [UUID: Data] = [:]
  /// Active combine/stitch session flags, if the session was in combine mode.
  var combineSession: CombineSessionSnapshot? = nil
  /// Logical (point-space) size of the source image when the session was cached.
  /// Annotations live in this coordinate space, so restores must apply it verbatim
  /// instead of re-deriving density from the current main display — native-density
  /// (1×) captures would otherwise get a mismatched canvas (issue #414 follow-up).
  var sourceLogicalSize: CGSize? = nil
  var originalCropSourceSize: OriginalCropSourceSize? = nil
}

/// Manages annotation window instances
@MainActor
final class AnnotateManager {

  static let shared = AnnotateManager()

  private var windowControllers: [UUID: AnnotateWindowController] = [:]
  private var manualWindowControllers: [UUID: AnnotateWindowController] = [:]

  /// In-memory cache: original image + annotations, keyed by QuickAccessItem.id
  private var sessionCache: [UUID: AnnotationSessionData] = [:]

  private var preferencesObserver: NSObjectProtocol?
  private init() {
    preferencesObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
      Task { @MainActor in
        guard let self, self.hasOpenWindows else { return }
        self.becomeRegularApp()
      }
    }
  }

  // MARK: - Activation Policy Management

  /// Switch to regular app mode (visible in Dock + Cmd+Tab)
  private func becomeRegularApp() {
    guard OwnShotAnnotatePreferences().showDockIcon else {
      let otherWindowsNeedDock = NSApp.windows.contains {
        $0.isVisible && !($0 is AnnotateWindow) && $0.className != "NSStatusBarWindow" && $0.level == .normal
      }
      if !VideoEditorManager.shared.hasOpenWindows && !otherWindowsNeedDock {
        NSApp.setActivationPolicy(.accessory)
      }
      return
    }
    if NSApp.activationPolicy() != .regular {
      NSApp.setActivationPolicy(.regular)
    }
  }

  /// Switch back to accessory mode (menu bar only) if no windows open
  private func becomeAccessoryAppIfNeeded() {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      guard self.windowControllers.isEmpty && self.manualWindowControllers.isEmpty else { return }
      guard !VideoEditorManager.shared.hasOpenWindows else { return }
      NSApp.revertActivationPolicyToAccessoryIfNeeded()
    }
  }

  /// Check if any annotate windows are open
  var hasOpenWindows: Bool {
    !windowControllers.isEmpty || !manualWindowControllers.isEmpty
  }

  /// Open annotation window for a quick access item
  func openAnnotation(for item: QuickAccessItem) {
    // Check if already open for this item
    if let existing = windowControllers[item.id] {
      existing.showWindow()
      DiagnosticLogger.shared.log(.info, .action, "Annotate window reused for item \(item.id)")
      return
    }

    guard NSScreen.screens.isEmpty == false else {
      DiagnosticLogger.shared.log(.error, .action, "Annotate open failed: no screens available")
      return
    }

    // Switch to regular app mode for Cmd+Tab visibility
    becomeRegularApp()

    let sessionData = sessionCache[item.id] ?? AnnotationSessionStore.shared.load(for: item.url)
    if let sessionData, sessionCache[item.id] == nil {
      sessionCache[item.id] = sessionData
    }
    let controller = AnnotateWindowController(item: item, sessionData: sessionData)
    windowControllers[item.id] = controller
    DiagnosticLogger.shared.log(.info, .action, "Annotate window opened for item \(item.id)")

    // Pause Quick Access countdown for this item + newer items
    QuickAccessManager.shared.pauseCountdownForEditingItem(item.id)

    // Remove from tracking when window closes
    let itemId = item.id
    if let window = controller.window {
      NotificationCenter.default.addObserver(
        forName: NSWindow.willCloseNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.windowControllers.removeValue(forKey: itemId)
          self?.becomeAccessoryAppIfNeeded()

          // Resume Quick Access countdown
          QuickAccessManager.shared.resumeCountdownForEditingItem(itemId)
        }
      }
    }

    controller.showWindow()
    QuickAccessManager.shared.setWindowOpen(id: item.id, isOpen: true)
  }

  /// Close all annotation windows
  func closeAll() {
    for controller in Array(windowControllers.values) {
      controller.window?.close()
    }
    windowControllers.removeAll()

    for controller in Array(manualWindowControllers.values) {
      controller.window?.close()
    }
    manualWindowControllers.removeAll()

    becomeAccessoryAppIfNeeded()
  }

  /// Check if annotation window is open for item
  func isOpen(for itemId: UUID) -> Bool {
    windowControllers[itemId] != nil
  }

  func isEditingFile(at url: URL) -> Bool {
    let filePath = SandboxFileAccessManager.directoryEntryPath(for: url)
    func ownsFile(_ controller: AnnotateWindowController) -> Bool {
      guard let sourceURL = (controller.window as? AnnotateWindow)?.interactionState?.sourceURL else {
        return false
      }
      return SandboxFileAccessManager.directoryEntryPath(for: sourceURL) == filePath
    }
    return windowControllers.values.contains(where: ownsFile) || manualWindowControllers.values.contains(where: ownsFile)
  }

  /// Open annotation window directly from a file URL (used by post-capture auto-open)
  func openAnnotation(url: URL, sessionData: AnnotationSessionData? = nil) {
    guard NSScreen.screens.isEmpty == false else {
      DiagnosticLogger.shared.log(.error, .action, "Annotate open failed: no screens available")
      return
    }

    // If Quick Access has this item, reuse it to link the annotation window
    if let existingItem = QuickAccessManager.shared.items.first(where: { $0.url == url }) {
      openAnnotation(for: existingItem)
      return
    }

    // Switch to regular app mode for Cmd+Tab visibility
    becomeRegularApp()

    let restoredSessionData: AnnotationSessionData?
    if sessionData == nil, OwnShotProjectFormat.isProjectURL(url) {
      // Проект OwnShot сам несёт исходник и аннотации; sidecar к нему не привязывается.
      guard let projectData = Self.readProject(at: url) else { return }
      restoredSessionData = projectData
    } else {
      restoredSessionData = sessionData ?? AnnotationSessionStore.shared.load(for: url)
    }
    // Без сохранённой сессии окно строится из файла: отсутствующий или битый файл
    // раньше открывался пустым холстом 400×300, теперь – ошибка, как у эталона.
    if restoredSessionData == nil, let issue = Self.fileOpenIssue(at: url) {
      Self.presentFileOpenError(issue, url: url)
      return
    }
    let controller = AnnotateWindowController(url: url, sessionData: restoredSessionData)
    trackStandaloneFileWindow(controller)
    DiagnosticLogger.shared.log(.info, .action, "Annotate window opened for URL \(url.lastPathComponent)")
    controller.showWindow()
  }

  func trackStandaloneFileWindow(_ controller: AnnotateWindowController) {
    let controllerId = UUID()
    windowControllers[controllerId] = controller

    // Remove from tracking when window closes
    if let window = controller.window {
      NotificationCenter.default.addObserver(
        forName: NSWindow.willCloseNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.windowControllers.removeValue(forKey: controllerId)
          self?.becomeAccessoryAppIfNeeded()
        }
      }
    }
  }

  /// Open empty annotation window for drag-drop workflow
  func openEmptyAnnotation() {
    guard NSScreen.screens.isEmpty == false else {
      DiagnosticLogger.shared.log(.error, .action, "Annotate open failed: no screens available")
      return
    }

    // Switch to regular app mode for Cmd+Tab visibility
    becomeRegularApp()

    let controller = AnnotateWindowController()
    let controllerId = UUID()
    manualWindowControllers[controllerId] = controller
    DiagnosticLogger.shared.log(.info, .action, "Annotate manual window opened")

    // Clear reference when window closes
    if let window = controller.window {
      NotificationCenter.default.addObserver(
        forName: NSWindow.willCloseNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.manualWindowControllers.removeValue(forKey: controllerId)
          self?.becomeAccessoryAppIfNeeded()
        }
      }
    }

    controller.showWindow()
    controller.handleManualOpenClipboardImageBehavior()
  }

  func openCombineImages(urls: [URL]) {
    guard urls.count >= 2, NSScreen.screens.isEmpty == false else { return }
    becomeRegularApp()

    let controller = AnnotateWindowController(combineImageURLs: urls)
    let controllerID = UUID()
    manualWindowControllers[controllerID] = controller

    if let window = controller.window {
      NotificationCenter.default.addObserver(
        forName: NSWindow.willCloseNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.manualWindowControllers.removeValue(forKey: controllerID)
          self?.becomeAccessoryAppIfNeeded()
        }
      }
    }

    controller.showWindow()
  }

  // MARK: - Session Cache

  /// Save annotation session data for re-editing
  func saveSessionData(
    for itemId: UUID,
    originalImageData: Data,
    annotations: [AnnotationItem],
    canvasEffects: AnnotationCanvasEffects,
    selectedCanvasPresetId: UUID? = nil,
    isSelectedCanvasPresetDirty: Bool = false,
    cropRect: CGRect?,
    isCutoutApplied: Bool = false,
    cutoutImageData: Data? = nil,
    didCutoutAutoApplyCrop: Bool = false,
    cutoutAutoAppliedCropRect: CGRect? = nil,
    embeddedImageAssetsData: [UUID: Data] = [:]
  ) {
    sessionCache[itemId] = AnnotationSessionData(
      originalImageData: originalImageData,
      annotations: annotations,
      canvasEffects: canvasEffects,
      selectedCanvasPresetId: selectedCanvasPresetId,
      isSelectedCanvasPresetDirty: isSelectedCanvasPresetDirty,
      cropRect: cropRect,
      isCutoutApplied: isCutoutApplied,
      cutoutImageData: cutoutImageData,
      didCutoutAutoApplyCrop: didCutoutAutoApplyCrop,
      cutoutAutoAppliedCropRect: cutoutAutoAppliedCropRect,
      embeddedImageAssetsData: embeddedImageAssetsData
    )
  }

  func saveSessionData(_ sessionData: AnnotationSessionData, for itemId: UUID) {
    sessionCache[itemId] = sessionData
  }

  /// Get cached session data for an item
  func getSessionData(for itemId: UUID) -> AnnotationSessionData? {
    sessionCache[itemId]
  }

  /// Clear session data when QA card is dismissed
  func clearSessionData(for itemId: UUID) {
    sessionCache.removeValue(forKey: itemId)
  }

  func makeSessionData(for state: AnnotateState, originalImageData: Data? = nil) -> AnnotationSessionData? {
    // Annotations, crop and `sourceLogicalSize` are in the transformed image's space,
    // so a rotated/cut source must persist its own pixels, not the loaded file bytes.
    if state.isSourceImageTransformed {
      guard let transformedData = state.transformedSourceImageData() else { return nil }
      return AnnotationSessionData.snapshot(from: state, originalImageData: transformedData)
    }

    let resolvedOriginalImageData = originalImageData
      ?? state.quickAccessItemId.flatMap { sessionCache[$0]?.originalImageData }
      ?? state.sourceURL.flatMap { Self.readFileData(from: $0) }

    guard let resolvedOriginalImageData else { return nil }
    return AnnotationSessionData.snapshot(from: state, originalImageData: resolvedOriginalImageData)
  }

  private static func readProject(at url: URL) -> AnnotationSessionData? {
    do {
      return try SandboxFileAccessManager.shared.withScopedAccess(to: url) {
        try OwnShotProjectStore.read(from: url)
      }
    } catch {
      DiagnosticLogger.shared.logError(.annotate, error, "Project open failed")
      let issue: FileOpenIssue = FileManager.default.fileExists(atPath: url.path) ? .projectUnreadable : .missing
      presentFileOpenError(issue, url: url)
      return nil
    }
  }

  // MARK: - Ошибки открытия файла

  /// Причина, по которой файл нельзя открыть в редакторе.
  enum FileOpenIssue: Equatable {
    case missing
    case undecodable
    case projectUnreadable
  }

  /// Проверка изображения до создания окна. nil – файл можно открывать.
  static func fileOpenIssue(at url: URL, fileManager: FileManager = .default) -> FileOpenIssue? {
    guard url.isFileURL else { return nil }
    return SandboxFileAccessManager.shared.withScopedAccess(to: url) {
      guard fileManager.fileExists(atPath: url.path) else { return .missing }
      return AnnotateState.loadImageWithCorrectScale(from: url) == nil ? .undecodable : nil
    }
  }

  /// Заголовок эталона «An error occurred while opening the file» (binary-strings.txt:9837),
  /// причина – строками эталона для документа (:9831–9836) или текстом про проект.
  static func fileOpenErrorText(for issue: FileOpenIssue, url: URL) -> (title: String, message: String) {
    let title = L10n.string(
      "annotate.file-open-error.title",
      defaultValue: "An error occurred while opening the file",
      comment: "Alert title when a file can't be opened in the editor"
    )
    let reason: String
    switch issue {
    case .missing:
      reason = L10n.string(
        "annotate.file-open-error.not-found",
        defaultValue: "Image object not found.",
        comment: "Alert reason when the file to open doesn't exist"
      )
    case .undecodable:
      reason = L10n.string(
        "annotate.file-open-error.cannot-decode",
        defaultValue: "Image object cannot be decoded.",
        comment: "Alert reason when the file to open isn't a readable image"
      )
    case .projectUnreadable:
      reason = L10n.string(
        "annotate.project-open-failed-message",
        defaultValue: "The file is damaged or was saved in an unsupported format.",
        comment: "Alert message when an OwnShot project file can't be read"
      )
    }
    return (title, "\"\(url.lastPathComponent)\"\n\(reason)")
  }

  /// Под XCTest alert не показывается: модальные окна в тестовом хосте запрещены.
  private static func presentFileOpenError(_ issue: FileOpenIssue, url: URL) {
    DiagnosticLogger.shared.log(.warning, .annotate, "File can't be opened in editor", context: [
      "file": url.lastPathComponent,
      "issue": "\(issue)",
    ])
    guard AppLaunchPolicy().shouldStartInteractiveApplication else { return }
    let text = fileOpenErrorText(for: issue, url: url)
    let alert = NSAlert()
    alert.messageText = text.title
    alert.informativeText = text.message
    alert.alertStyle = .warning
    alert.addButton(withTitle: L10n.Common.ok)
    NSApp.activate(ignoringOtherApps: true)
    alert.runModal()
  }

  private static func readFileData(from url: URL) -> Data? {
    SandboxFileAccessManager.shared.withScopedAccess(to: url) {
      try? Data(contentsOf: url)
    }
  }
}

extension AnnotationSessionData {
  static func snapshot(from state: AnnotateState, originalImageData: Data) -> AnnotationSessionData {
    let cutoutSnapshot = state.cutoutSnapshot()
    return AnnotationSessionData(
      originalImageData: originalImageData,
      annotations: state.annotations,
      canvasEffects: state.canvasEffectsSnapshot,
      selectedCanvasPresetId: state.selectedCanvasPresetId,
      isSelectedCanvasPresetDirty: state.isSelectedCanvasPresetDirty,
      cropRect: state.cropRect,
      isCutoutApplied: cutoutSnapshot.isApplied,
      cutoutImageData: cutoutSnapshot.cutoutImageData,
      didCutoutAutoApplyCrop: cutoutSnapshot.didAutoApplyCrop,
      cutoutAutoAppliedCropRect: cutoutSnapshot.autoAppliedCropRect,
      embeddedImageAssetsData: state.embeddedImageAssetsSnapshotData(),
      combineSession: state.combineSessionSnapshot(),
      sourceLogicalSize: state.sourceImage?.size,
      originalCropSourceSize: state.originalCropSourceSize
    )
  }
}
