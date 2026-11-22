//
//  AnnotateWindowController.swift
//  Snapzy
//
//  Controller managing annotation window lifecycle
//

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

enum AnnotateDragCompletionAction: Equatable {
  case closeAndDismiss
  case restore(presentation: AnnotateDragRestorePresentation)
}

enum AnnotateDragRestorePresentation: Equatable {
  case background
  case foreground
}

/// Откуда пришла команда копирования в редакторе.
enum AnnotateCopySource: Equatable {
  /// Сочетание «Copy Screenshot to Clipboard» (⇧⌘C).
  case shortcut
  /// Кнопка копирования в нижней панели редактора («Copy & Close»).
  case bottomBarButton
}

/// Закрывать ли редактор после копирования.
/// Как в CleanShot X: сочетание ⇧⌘C только копирует, окно остаётся открытым.
/// Кнопка нижней панели сохраняет прежнее поведение OwnShot «Copy & Close».
enum AnnotateCopyCompletionPolicy {
  /// Ключ userInfo уведомления `.annotateCopyAndClose` со значением Bool.
  static let closeAfterCopyUserInfoKey = "closeAfterCopy"

  static func shouldClose(after source: AnnotateCopySource) -> Bool {
    switch source {
    case .shortcut: return false
    case .bottomBarButton: return true
    }
  }

  static func userInfo(for source: AnnotateCopySource) -> [String: Any] {
    [closeAfterCopyUserInfoKey: shouldClose(after: source)]
  }

  /// Без ключа в userInfo закрываем окно: так вели себя все отправители до появления ключа.
  static func shouldClose(userInfo: [AnyHashable: Any]?) -> Bool {
    (userInfo?[closeAfterCopyUserInfoKey] as? Bool) ?? true
  }
}

enum AnnotateDragCompletionPolicy {
  static func action(
    success: Bool,
    closeAfterDrag: Bool,
    bringForwardAfterDrag: Bool
  ) -> AnnotateDragCompletionAction {
    guard success else { return .restore(presentation: .foreground) }
    if closeAfterDrag {
      return .closeAndDismiss
    }
    return .restore(presentation: bringForwardAfterDrag ? .foreground : .background)
  }
}

/// Manages annotation window lifecycle and content
@MainActor
final class AnnotateWindowController: NSWindowController, NSWindowDelegate {

  /// Доля высоты видимой области для огромного снимка: эталон открывает 10000×10000
  /// в окне 990×972 на экране с видимой высотой 1080 (b4-zoom-small-huge.txt).
  nonisolated static let oversizedImageWindowHeightFraction: CGFloat = 0.9

  /// Широкий снимок вписывается в окно. Длинный узкий снимок открывается
  /// в 100% с вертикальной прокруткой, как результат Scrolling Capture эталона.
  nonisolated static func opensOversizedImageFitted(imageSize: CGSize?, visibleSize: CGSize) -> Bool {
    guard let imageSize, imageSize.width > 0, imageSize.height > 0 else { return false }
    return imageSize.width > visibleSize.width
  }

  nonisolated static func initialWindowSize(visibleSize: CGSize, imageSize: CGSize? = nil) -> CGSize {
    let base = CGSize(width: min(990, visibleSize.width), height: min(500, visibleSize.height))
    guard let imageSize,
          imageSize.width > visibleSize.width || imageSize.height > visibleSize.height else { return base }
    let grownHeight = (visibleSize.height * oversizedImageWindowHeightFraction).rounded(.down)
    return CGSize(width: base.width, height: min(visibleSize.height, max(base.height, grownHeight)))
  }

  private static var visibleScreenSize: CGSize {
    NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
  }

  /// Начальная рамка окна: обычное окно по центру экрана, выросшее – по центру видимой области.
  private static func initialWindowFrame(imageSize: CGSize?) -> NSRect {
    let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let size = initialWindowSize(visibleSize: visibleFrame.size, imageSize: imageSize)
    if size.height > min(500, visibleFrame.height) {
      return NSRect(
        x: visibleFrame.minX + (visibleFrame.width - size.width) / 2,
        y: visibleFrame.minY + (visibleFrame.height - size.height) / 2,
        width: size.width,
        height: size.height
      )
    }
    let screenFrame = NSScreen.main?.frame ?? NSScreen.screens.first?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    return NSRect(
      x: (screenFrame.width - size.width) / 2,
      y: (screenFrame.height - size.height) / 2,
      width: size.width,
      height: size.height
    )
  }

  private let fileAccessManager = SandboxFileAccessManager.shared
  private var sourceFileAccess: SandboxFileAccessManager.ScopedAccess?
  private let state: AnnotateState
  private let quickAccessItemId: UUID?
  private var cancellables = Set<AnyCancellable>()
  private var isExportingHEIC = false
  private var isSavingRasterInPlace = false

  private var isSavingImage: Bool { isExportingHEIC || isSavingRasterInPlace }
  private static var activeHEICDestinations: Set<String> = []

  /// Compressed PNG data of the original source image (before annotations are baked).
  /// Captured on first open, reused across saves for session caching.
  private var originalImageData: Data?

  /// Apply the configured startup tool (Settings > Annotate) and persist explicit
  /// tool choices when "Remember Last Tool" is enabled — same behavior as the
  /// inline area-annotate overlay.
  private func applyStartupToolPreference() {
    state.selectedTool = AnnotateToolPreference.initialTool()
    state.onToolActivated = { tool in
      AnnotateToolPreference.remember(tool)
    }
  }

  init(item: QuickAccessItem, sessionData: AnnotationSessionData? = nil) {
    self.quickAccessItemId = item.id
    self.sourceFileAccess = fileAccessManager.beginAccessingURL(item.url)

    if let sessionData = sessionData {
      // Restore from cache: decompress original image + editable annotations
      let image = NSImage(data: sessionData.originalImageData)
        .map({ img in Self.restoredSessionImage(img, sourceLogicalSize: sessionData.sourceLogicalSize) })
        ?? item.thumbnail
      self.originalImageData = sessionData.originalImageData
      self.state = AnnotateState(
        image: image,
        url: item.url,
        quickAccessItemId: item.id,
        cloudURL: item.cloudURL,
        cloudKey: item.cloudKey,
        isCloudStale: item.isCloudStale,
        appliesDefaultCanvasPresetOnNewImages: false,
        // Восстановленная сессия открывается как раньше – вписанной в окно.
        opensAtActualSize: false,
        originalCropSourceSize: sessionData.originalCropSourceSize
      )
      self.state.restoreEmbeddedImageAssets(from: sessionData.embeddedImageAssetsData)
      self.state.annotations = sessionData.annotations
      self.state.applyCanvasEffects(
        sessionData.canvasEffects,
        preferredSelectedCanvasPresetId: sessionData.selectedCanvasPresetId,
        preferredPresetDirtyState: sessionData.isSelectedCanvasPresetDirty
      )
      self.state.cropRect = sessionData.cropRect
      self.state.isCropActive = false
      self.state.restoreBackgroundCutout(
        isApplied: sessionData.isCutoutApplied,
        cutoutImageData: sessionData.cutoutImageData,
        didAutoApplyCrop: sessionData.didCutoutAutoApplyCrop,
        autoAppliedCropRect: sessionData.cutoutAutoAppliedCropRect
      )
      if let combineSession = sessionData.combineSession {
        self.state.restoreCombineSession(combineSession)
      }
    } else {
      // First open: load image from disk and capture raw file bytes (fast, no re-encoding)
      let image = Self.loadImageWithCorrectScale(from: item.url) ?? item.thumbnail
      self.originalImageData = Self.readFileData(from: item.url)
      self.state = AnnotateState(
        image: image, url: item.url, quickAccessItemId: item.id, cloudURL: item.cloudURL,
        cloudKey: item.cloudKey, isCloudStale: item.isCloudStale,
        // Огромный снимок открывается вписанным, остальные – в 100%.
        opensAtActualSize: !Self.opensOversizedImageFitted(imageSize: image.size, visibleSize: Self.visibleScreenSize)
      )
    }

    // Окно 990×500; под огромный снимок вырастает по высоте (ANN-302).
    let initialFrame = Self.initialWindowFrame(imageSize: sessionData == nil ? state.sourceImage?.size : nil)

    let window = AnnotateWindow(contentRect: initialFrame)

    window.setFrame(initialFrame, display: false)
    super.init(window: window)

    window.delegate = self
    window.interactionState = state
    applyStartupToolPreference()
    setupContent()
    setupKeyboardShortcutObservers()
    setupSourceURLObservation()
    setupBackgroundPanelWindowGrowth()
  }

  /// Empty initializer for drag-drop workflow
  init() {
    self.quickAccessItemId = nil
    self.originalImageData = nil
    self.state = AnnotateState()
    // Manual session: sourceURL becomes the first user-picked file, so combine saves
    // must not silently overwrite it. Combine-picker convenience init inherits this.
    self.state.isManualImportSession = true

    // Default window size for empty canvas
    let initialSize = Self.initialWindowSize(visibleSize: NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900))
    let defaultWidth = initialSize.width
    let defaultHeight = initialSize.height

    let screenFrame = NSScreen.main?.frame ?? NSScreen.screens.first?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

    let origin = NSPoint(
      x: (screenFrame.width - defaultWidth) / 2,
      y: (screenFrame.height - defaultHeight) / 2
    )

    let window = AnnotateWindow(
      contentRect: NSRect(origin: origin, size: NSSize(width: defaultWidth, height: defaultHeight))
    )

    window.setFrame(NSRect(origin: origin, size: initialSize), display: false)
    super.init(window: window)

    window.delegate = self
    window.interactionState = state
    applyStartupToolPreference()
    setupContent()
    setupKeyboardShortcutObservers()
    setupSourceURLObservation()
    setupBackgroundPanelWindowGrowth()
  }

  convenience init(combineImageURLs: [URL]) {
    self.init()
    guard let firstURL = combineImageURLs.first,
          state.importImage(from: firstURL) else { return }
    for url in combineImageURLs.dropFirst() {
      _ = state.importImage(from: url)
    }
    state.activateCombineMode(preferredMode: .autoStitch)
  }

  /// URL-only initializer for post-capture auto-open flow
  init(url: URL, sessionData: AnnotationSessionData? = nil) {
    self.quickAccessItemId = nil
    self.sourceFileAccess = SandboxFileAccessManager.shared.beginAccessingURL(url)

    if let sessionData {
      let image = NSImage(data: sessionData.originalImageData)
        .map({ img in Self.restoredSessionImage(img, sourceLogicalSize: sessionData.sourceLogicalSize) })
        ?? Self.loadImageWithCorrectScale(from: url)
        ?? NSImage(size: NSSize(width: 400, height: 300))
      self.originalImageData = sessionData.originalImageData
      self.state = AnnotateState(
        image: image,
        url: url,
        appliesDefaultCanvasPresetOnNewImages: false,
        // Сессия или проект OwnShot открываются как раньше – вписанными в окно.
        opensAtActualSize: false,
        originalCropSourceSize: sessionData.originalCropSourceSize
      )
      self.state.restoreEmbeddedImageAssets(from: sessionData.embeddedImageAssetsData)
      self.state.annotations = sessionData.annotations
      self.state.applyCanvasEffects(
        sessionData.canvasEffects,
        preferredSelectedCanvasPresetId: sessionData.selectedCanvasPresetId,
        preferredPresetDirtyState: sessionData.isSelectedCanvasPresetDirty
      )
      self.state.cropRect = sessionData.cropRect
      self.state.isCropActive = false
      self.state.restoreBackgroundCutout(
        isApplied: sessionData.isCutoutApplied,
        cutoutImageData: sessionData.cutoutImageData,
        didAutoApplyCrop: sessionData.didCutoutAutoApplyCrop,
        autoAppliedCropRect: sessionData.cutoutAutoAppliedCropRect
      )
      if let combineSession = sessionData.combineSession {
        self.state.restoreCombineSession(combineSession)
      }
    } else {
      let image = Self.loadImageWithCorrectScale(from: url)
        ?? NSImage(size: NSSize(width: 400, height: 300))
      self.originalImageData = Self.readFileData(from: url)
      self.state = AnnotateState(
        image: image,
        url: url,
        // Огромный снимок открывается вписанным, остальные – в 100%.
        opensAtActualSize: !Self.opensOversizedImageFitted(imageSize: image.size, visibleSize: Self.visibleScreenSize)
      )
    }

    // Окно 990×500; под огромный снимок вырастает по высоте (ANN-302).
    let initialFrame = Self.initialWindowFrame(imageSize: sessionData == nil ? state.sourceImage?.size : nil)

    let window = AnnotateWindow(contentRect: initialFrame)

    window.setFrame(initialFrame, display: false)
    super.init(window: window)

    window.delegate = self
    window.interactionState = state
    applyStartupToolPreference()
    setupContent()
    setupKeyboardShortcutObservers()
    setupSourceURLObservation()
    setupBackgroundPanelWindowGrowth()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    sourceFileAccess?.stop()
    cancellables.removeAll()
  }

  private func setupContent() {
    let capturedState = self.state
    guard let annotateWindow = window as? AnnotateWindow else { return }
    let eventRouter = AnnotateWindowEventRouter(window: annotateWindow)
    // Минимум задаётся и содержимому: NSHostingView пересчитывает ограничения NSWindow.
    let titlebarHeight = annotateWindow.frame.height - annotateWindow.contentLayoutRect.height
    let mainView = AnnotateMainView(state: capturedState, eventRouter: eventRouter)
      .frame(minWidth: 990, minHeight: max(0, 450 - titlebarHeight))
    window?.contentView = NSHostingView(rootView: mainView)
    (window as? AnnotateWindow)?.onEscape = { [weak self] in
      self?.discardEditsAndClose() ?? false
    }
  }

  private func discardEditsAndClose() -> Bool {
    guard let window = self.window else { return false }
    guard !isSavingRasterInPlace else { return true }
    if let quickAccessItemId {
      DiagnosticLogger.shared.log(
        .info,
        .action,
        "Annotate window close request via Esc",
        context: ["itemId": quickAccessItemId.uuidString]
      )
    } else {
      DiagnosticLogger.shared.log(
        .info,
        .action,
        "Annotate window close request via Esc"
      )
    }

    if state.hasUnsavedChanges {
      showUnsavedChangesAlert(for: window)
    } else {
      forceClose()
    }
    return true
  }



  func showWindow() {
    window?.makeKeyAndOrderFront(nil)
    window?.makeMain()
    NSApp.activate(ignoringOtherApps: true)
  }

  func windowDidBecomeKey(_ notification: Notification) {
    (notification.object as? AnnotateWindow)?.syncLevelWithFocusState()
  }

  func windowDidResignKey(_ notification: Notification) {
    (notification.object as? AnnotateWindow)?.syncLevelWithFocusState()
  }

  func windowDidBecomeMain(_ notification: Notification) {
    (notification.object as? AnnotateWindow)?.syncLevelWithFocusState()
  }

  func windowDidResignMain(_ notification: Notification) {
    (notification.object as? AnnotateWindow)?.syncLevelWithFocusState()
  }

  // MARK: - Image Loading

  /// Load image and adjust size for the density recorded in the file
  /// (single source of truth lives on AnnotateState).
  private static func loadImageWithCorrectScale(from url: URL) -> NSImage? {
    AnnotateState.loadImageWithCorrectScale(from: url)
  }

  /// Restore a session source image in the exact logical coordinate space its
  /// annotations were authored in. Sidecars saved before `sourceLogicalSize`
  /// existed fall back to the legacy main-screen scale heuristic.
  static func restoredSessionImage(_ image: NSImage, sourceLogicalSize: CGSize?) -> NSImage {
    guard let sourceLogicalSize,
          sourceLogicalSize.width > 0,
          sourceLogicalSize.height > 0 else {
      return applyRetinaScaling(to: image)
    }
    image.size = sourceLogicalSize
    return image
  }

  /// Legacy fallback for pre-`sourceLogicalSize` sidecars: assumes the image is at
  /// the main display's density. Kept only for old session data — new restores use
  /// `restoredSessionImage(_:sourceLogicalSize:)`, and file opens use the file's
  /// own DPI metadata via `AnnotateState.loadImageWithCorrectScale(from:)`.
  private static func applyRetinaScaling(to image: NSImage) -> NSImage {
    let scaleFactor = NSScreen.main?.backingScaleFactor ?? 2.0
    if let normalizedSize = normalizedRetinaLogicalSizeIfNeeded(for: image, scaleFactor: scaleFactor) {
      image.size = normalizedSize
    }
    return image
  }

  private static func normalizedRetinaLogicalSizeIfNeeded(
    for image: NSImage,
    scaleFactor: CGFloat
  ) -> NSSize? {
    guard scaleFactor > 1 else { return nil }
    guard let rep = image.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 else {
      return nil
    }

    let pixelWidth = CGFloat(rep.pixelsWide)
    let pixelHeight = CGFloat(rep.pixelsHigh)
    let currentSize = image.size
    let expectedSize = NSSize(
      width: pixelWidth / scaleFactor,
      height: pixelHeight / scaleFactor
    )

    let isAlreadyScaled =
      abs(currentSize.width - expectedSize.width) < 0.5 &&
      abs(currentSize.height - expectedSize.height) < 0.5
    if isAlreadyScaled {
      return nil
    }

    let isUnscaledLogicalSize =
      abs(currentSize.width - pixelWidth) < 0.5 &&
      abs(currentSize.height - pixelHeight) < 0.5
    return isUnscaledLogicalSize ? expectedSize : nil
  }

  /// Read raw file bytes from disk (fast: no image decoding or re-encoding)
  private static func readFileData(from url: URL) -> Data? {
    SandboxFileAccessManager.shared.withScopedAccess(to: url) {
      try? Data(contentsOf: url)
    }
  }

  /// Эталон: открытие Background увеличивает высоту окна, закрытие её не возвращает.
  private func setupBackgroundPanelWindowGrowth() {
    state.$showSidebar
      .removeDuplicates()
      .filter { $0 }
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        self?.growWindowForBackgroundPanel()
      }
      .store(in: &cancellables)
  }

  private func growWindowForBackgroundPanel() {
    guard let window, state.editorMode != .preview, !window.styleMask.contains(.fullScreen),
          let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame,
          let frame = AnnotateBackgroundWindowSizing.grownFrame(current: window.frame, visibleFrame: visibleFrame)
    else { return }
    window.setFrame(frame, display: true, animate: window.isVisible)
  }

  private func setupSourceURLObservation() {
    state.$sourceURL
      .sink { [weak self] url in
        self?.refreshSourceAccess(for: url)
      }
      .store(in: &cancellables)
  }

  private func refreshSourceAccess(for url: URL?) {
    sourceFileAccess?.stop()
    sourceFileAccess = nil

    guard let url = url else { return }
    sourceFileAccess = fileAccessManager.beginAccessingURL(url)
  }

  private var requiresCloudOverwriteConfirmation: Bool {
    state.cloudURL != nil && (state.requiresRenderedOutputForSharing || state.isCloudStale)
  }

  private var shouldCloseAfterDrag: Bool {
    UserDefaults.standard.object(forKey: PreferencesKeys.annotateCloseAfterDrag) as? Bool ?? true
  }

  private var shouldBringForwardAfterDrag: Bool {
    UserDefaults.standard.object(forKey: PreferencesKeys.annotateBringForwardAfterDrag) as? Bool ?? false
  }

  private enum PasteboardImageCandidate {
    case file(URL)
    case data(NSImage, Data)
    case image(NSImage)
  }

  private static let pasteboardRawImageTypes: [NSPasteboard.PasteboardType] = [
    .png,
    .tiff,
    NSPasteboard.PasteboardType(UTType.jpeg.identifier),
    NSPasteboard.PasteboardType(UTType.gif.identifier),
    NSPasteboard.PasteboardType(UTType.bmp.identifier),
    NSPasteboard.PasteboardType(UTType.heic.identifier),
    NSPasteboard.PasteboardType(UTType.webP.identifier),
  ]

  private static func hasPasteboardImage(_ pasteboard: NSPasteboard) -> Bool {
    !pasteboardImageCandidates(from: pasteboard).isEmpty
  }

  private static func pasteboardImageCandidates(from pasteboard: NSPasteboard) -> [PasteboardImageCandidate] {
    if let firstItem = pasteboard.pasteboardItems?.first {
      let directCandidates = pasteboardImageCandidates(from: firstItem)
      if !directCandidates.isEmpty {
        return directCandidates
      }
    }

    var candidates: [PasteboardImageCandidate] = []
    let pastedURLs = pasteboard.readObjects(
      forClasses: [NSURL.self],
      options: [.urlReadingFileURLsOnly: true]
    )

    if let imageURLs = (pastedURLs as? [URL]) ?? (pastedURLs as? [NSURL])?.map({ $0 as URL }) {
      for imageURL in imageURLs where AnnotateCanvasView.isValidImageFile(url: imageURL) {
        candidates.append(.file(imageURL))
      }
    }

    if let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
       let image = images.first {
      candidates.append(.image(image))
    }

    return candidates
  }

  private static func pasteboardImageCandidates(from item: NSPasteboardItem) -> [PasteboardImageCandidate] {
    var candidates: [PasteboardImageCandidate] = []

    if let fileURL = fileURL(from: item),
       AnnotateCanvasView.isValidImageFile(url: fileURL) {
      candidates.append(.file(fileURL))
    }

    for rawType in pasteboardRawImageTypes {
      guard let data = item.data(forType: rawType),
            let image = NSImage(data: data) else { continue }
      candidates.append(.data(image, data))
    }

    return candidates
  }

  private static func fileURL(from item: NSPasteboardItem) -> URL? {
    guard let value = item.string(forType: .fileURL) else { return nil }
    if let url = URL(string: value), url.isFileURL {
      return url
    }
    guard value.hasPrefix("/") else { return nil }
    return URL(fileURLWithPath: value)
  }

  // MARK: - Manual Open Clipboard Import

  func handleManualOpenClipboardImageBehavior() {
    let behavior = AnnotateClipboardImageBehavior.stored()
    guard behavior != .doNothing else { return }
    guard Self.hasPasteboardImage(NSPasteboard.general) else { return }

    switch behavior {
    case .ask:
      showClipboardImagePrompt()
    case .loadAutomatically:
      performPasteImage(beepOnFailure: false)
    case .doNothing:
      break
    }
  }

  private func showClipboardImagePrompt() {
    guard let window = self.window else { return }

    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = L10n.AnnotateUI.clipboardImagePromptTitle
    alert.informativeText = L10n.AnnotateUI.clipboardImagePromptMessage

    let loadButton = alert.addButton(withTitle: L10n.AnnotateUI.loadImageButton)
    loadButton.keyEquivalent = "\r"

    let notNowButton = alert.addButton(withTitle: L10n.AnnotateUI.notNowButton)
    notNowButton.keyEquivalent = "\u{1B}"

    alert.showsSuppressionButton = true
    alert.suppressionButton?.title = L10n.AnnotateUI.dontAskAgain

    alert.beginSheetModal(for: window) { [weak self] response in
      guard let self else { return }

      let shouldRemember = alert.suppressionButton?.state == .on
      switch response {
      case .alertFirstButtonReturn:
        if shouldRemember {
          AnnotateClipboardImageBehavior.loadAutomatically.persist()
        }
        self.performPasteImage()
      case .alertSecondButtonReturn:
        if shouldRemember {
          AnnotateClipboardImageBehavior.doNothing.persist()
        }
      default:
        break
      }
    }
  }

  // MARK: - NSWindowDelegate

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    guard !isSavingImage else { return false }
    guard state.hasUnsavedChanges else {
      forceClose()
      return false
    }

    showUnsavedChangesAlert(for: sender)
    return false
  }

  private func showUnsavedChangesAlert(for window: NSWindow) {
    let alert = NSAlert()
    // Тексты как у alert эталона (evidence/spec-055-live/editor-unsaved-close-alert.txt).
    alert.messageText = L10n.AnnotateUI.saveChangesQuestion
    alert.informativeText = L10n.AnnotateUI.changesWillBeLost
    alert.alertStyle = .warning

    alert.addButton(withTitle: L10n.VideoEditor.save)
    alert.addButton(withTitle: L10n.AnnotateUI.dontSave)
    alert.addButton(withTitle: L10n.Common.cancel)

    alert.beginSheetModal(for: window) { [weak self] response in
      guard let self = self else { return }

      switch response {
      case .alertFirstButtonReturn:
        self.performSaveAndClose()

      case .alertSecondButtonReturn:
        self.forceClose()

      default:
        break
      }
    }
  }

  private func performSaveAndClose() {
    guard !isSavingImage else { return }

    // Combine coherence: if a ⌘S would show the "Save Combined Image" dialog (pref OFF or
    // manual session), the close-save path must show it too instead of silently overwriting.
    if combineSaveNeedsDialog {
      performCombineSave()
      return
    }

    // Cloud gate: if the rendered output differs from the uploaded file, require overwrite confirmation.
    if requiresCloudOverwriteConfirmation {
      showCloudOverwriteAlert { [weak self] in
        self?.performCloudReUploadAndClose()
      }
      return
    }
    executeSaveAndClose()
  }

  private func executeSaveAndClose() {
    if isEditingProjectDocument {
      if saveProjectDocumentInPlace() { forceClose() }
    } else if let sourceURL = state.sourceURL {
      saveRasterInPlace(to: sourceURL)
    } else {
      performSaveAs()
    }
  }

  private func forceClose(perfInterval: Any? = nil) {
    state.hasUnsavedChanges = false
    guard let window = self.window else {
      PerfSignpost.endInterval(perfInterval)
      return
    }

    // Hide window instantly
    window.alphaValue = 0

    if let itemId = quickAccessItemId {
      QuickAccessManager.shared.setWindowOpen(id: itemId, isOpen: false)
    }

    PerfSignpost.measure("windowClose") {
      window.close()
    }

    if let perfInterval = perfInterval {
      DispatchQueue.main.async {
        PerfSignpost.endInterval(perfInterval)
      }
    }
  }

  // MARK: - Keyboard Shortcuts

  private func setupKeyboardShortcutObservers() {
    guard let window = self.window else { return }

    NotificationCenter.default.addObserver(
      forName: .annotateSave,
      object: window,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.performSave()
      }
    }

    NotificationCenter.default.addObserver(
      forName: .annotateSaveAs,
      object: window,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.performSaveAs()
      }
    }

    NotificationCenter.default.addObserver(
      forName: .annotatePrint,
      object: window,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.performPrint()
      }
    }

    NotificationCenter.default.addObserver(
      forName: .annotateCopyAndClose,
      object: window,
      queue: .main
    ) { [weak self] notification in
      MainActor.assumeIsolated {
        let closeAfterCopy = AnnotateCopyCompletionPolicy.shouldClose(userInfo: notification.userInfo)
        self?.performCopy(closeAfterCopy: closeAfterCopy)
      }
    }

    NotificationCenter.default.addObserver(
      forName: .annotateTogglePin,
      object: window,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.togglePin()
      }
    }

    NotificationCenter.default.addObserver(
      forName: .annotatePasteImage,
      object: window,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        _ = self?.performPasteImage()
      }
    }

    NotificationCenter.default.addObserver(
      forName: .annotateAddImage,
      object: window,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.performAddImages()
      }
    }

    NotificationCenter.default.addObserver(
      forName: .annotateAddNewScreenshot,
      object: window,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.performAddNewScreenshot()
      }
    }

    NotificationCenter.default.addObserver(
      forName: .annotateAutoRedactSensitiveData,
      object: window,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.state.autoRedactSensitiveData()
      }
    }

    // Drag-to-app: hide window when drag starts
    NotificationCenter.default.addObserver(
      forName: .annotateDragStarted,
      object: window,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.handleDragStarted()
      }
    }

    // Drag-to-app: restore or close window when drag ends
    NotificationCenter.default.addObserver(
      forName: .annotateDragEnded,
      object: window,
      queue: .main
    ) { [weak self] notification in
      MainActor.assumeIsolated {
        let success = (notification.userInfo?["success"] as? Bool) ?? false
        self?.handleDragEnded(success: success)
      }
    }
  }

  // MARK: - Drag-to-App Window Management

  private var savedWindowFrame: NSRect?

  private func handleDragStarted() {
    guard let window = self.window else { return }
    savedWindowFrame = window.frame
    window.orderOut(nil) // Hide without closing
    print("[AnnotateDrag] Window hidden for drag session")
  }

  private func handleDragEnded(success: Bool) {
    switch AnnotateDragCompletionPolicy.action(
      success: success,
      closeAfterDrag: shouldCloseAfterDrag,
      bringForwardAfterDrag: shouldBringForwardAfterDrag
    ) {
    case .closeAndDismiss:
      commitDragSuccessChangesIfNeeded()
      forceClose()
      // Also dismiss the Quick Access card (without deleting the file)
      if let itemId = quickAccessItemId {
        QuickAccessManager.shared.dismissCard(id: itemId)
      }
      print("[AnnotateDrag] Drag succeeded — window + QA card dismissed")

    case .restore(let presentation):
      restoreWindowAfterDrag(presentation: presentation)
      if success {
        print("[AnnotateDrag] Drag succeeded — editor preserved")
      } else {
        print("[AnnotateDrag] Drag cancelled — window restored")
      }
    }
    savedWindowFrame = nil
  }

  private func restoreWindowAfterDrag(presentation: AnnotateDragRestorePresentation) {
    guard let window = self.window else { return }
    if let frame = savedWindowFrame {
      window.setFrame(frame, display: true)
    }

    switch presentation {
    case .foreground:
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
    case .background:
      window.orderBack(nil)
    }
  }

  private func commitDragSuccessChangesIfNeeded() {
    guard state.requiresRenderedOutputForSharing else {
      state.markAsSaved()
      return
    }

    // Manual combine session: the drag already delivered the rendered payload to the target
    // app; do not overwrite the user's picked source file with the stitched result.
    if protectsSourceFromImplicitCombineWrite {
      state.markAsSaved()
      return
    }

    guard let sourceURL = state.sourceURL else {
      state.markAsSaved()
      return
    }

    let renderedImage = AnnotateExporter.renderFinalImage(state: state)
    guard let renderedImage else {
      DiagnosticLogger.shared.log(
        .error,
        .annotate,
        "Annotate drag success save skipped; render returned nil",
        context: ["fileName": sourceURL.lastPathComponent]
      )
      state.markAsSaved()
      return
    }

    let sessionSnapshot = makeSessionSnapshot()
    state.markAsSaved()
    saveSessionCache(sessionSnapshot)
    if let itemId = quickAccessItemId {
      QuickAccessManager.shared.updateItemThumbnail(id: itemId, image: renderedImage)
      QuickAccessManager.shared.markCloudStale(id: itemId)
    }

    let capturedState = state
    Task.detached(priority: .userInitiated) {
      guard await AnnotateExporter.saveToFile(image: renderedImage, state: capturedState) else {
        DiagnosticLogger.shared.log(
          .error,
          .annotate,
          "Annotate drag success save failed",
          context: ["fileName": sourceURL.lastPathComponent]
        )
        return
      }
      await Self.persistCommittedSessionOffMain(sessionSnapshot, for: sourceURL)
      await PostCaptureActionHandler.shared.copyEditedCaptureToClipboardIfEnabled(
        for: .screenshot,
        url: sourceURL
      )
    }
  }

  /// Pin to the screen эталона (pinAndClose): текущий рендер становится закреплённым
  /// скриншотом, затем редактор закрывается обычным путём. При несохранённых
  /// изменениях закрытие спросит про сохранение, сам pin уже на экране.
  private func togglePin() {
    guard let window = self.window, state.hasImage,
          let renderedImage = AnnotateExporter.renderFinalImage(state: state),
          let url = Self.writePinImage(renderedImage) else {
      NSSound.beep()
      return
    }
    let item = QuickAccessItem(url: url, thumbnail: renderedImage)
    QuickAccessPinWindowManager.shared.show(item: item) { _ in
      try? FileManager.default.removeItem(at: url)
    }
    window.performClose(nil)
  }

  /// PNG для закреплённого скриншота во временной папке: исходный файл не трогаем.
  private static func writePinImage(_ image: NSImage) -> URL? {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let data = bitmap.representation(using: .png, properties: [:]) else { return nil }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OwnShot-Pins", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let url = directory.appendingPathComponent("Pin-\(UUID().uuidString).png")
      try data.write(to: url, options: .atomic)
      return url
    } catch {
      return nil
    }
  }

  @discardableResult
  private func performPasteImage(beepOnFailure: Bool = true) -> Bool {
    for candidate in Self.pasteboardImageCandidates(from: NSPasteboard.general) {
      if importPasteboardImage(candidate) {
        return true
      }
    }

    if beepOnFailure {
      NSSound.beep()
    }
    return false
  }

  private func performAddImages() {
    guard let window else { return }
    let panel = NSOpenPanel()
    panel.title = L10n.Combine.pickerTitle
    panel.prompt = L10n.Combine.pickerConfirm
    panel.allowedContentTypes = [.png, .jpeg, .webP, .gif, .tiff, .heic]
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK, let self else { return }
      for url in panel.urls {
        _ = self.state.importImage(from: url)
      }
    }
  }

  /// Add New Screenshot: прячет редактор, даёт выделить область и добавляет снимок на холст.
  private func performAddNewScreenshot() {
    guard let window, state.hasImage else { return }
    window.orderOut(nil)
    AreaSelectionController.shared.startSelection(mode: .screenshot) { [weak self, weak window] rect, _ in
      MainActor.assumeIsolated {
        guard let self, let window else { return }
        guard let rect, rect.width > 0, rect.height > 0 else {
          window.makeKeyAndOrderFront(nil)
          return
        }
        Task { @MainActor in
          defer { window.makeKeyAndOrderFront(nil) }
          do {
            guard let image = try await ScreenCaptureManager.shared.captureAreaAsImage(
              rect: rect,
              excludeOwnApplication: true
            ) else {
              NSSound.beep()
              return
            }
            let nsImage = NSImage(cgImage: image, size: rect.size)
            if !self.state.importImage(nsImage, sourceURL: nil) {
              NSSound.beep()
            }
          } catch {
            DiagnosticLogger.shared.logError(.capture, error, "Annotate add new screenshot failed")
            NSSound.beep()
          }
        }
      }
    }
  }

  /// Вставленная картинка встаёт под исходный снимок, как у эталона (ANN-347).
  private func importPasteboardImage(_ candidate: PasteboardImageCandidate) -> Bool {
    switch candidate {
    case .file(let url):
      return state.pasteImage(from: url)
    case .data(let image, let data):
      return state.pasteImage(image, sourceData: data)
    case .image(let image):
      return state.pasteImage(image)
    }
  }

  /// True when an active combine session must show the "Save Combined Image" confirmation
  /// dialog instead of saving silently as an edit of the current image.
  ///
  /// Dialog is required when either:
  /// - the save-as-edit preference is OFF, or
  /// - this is a manual import session (empty window / Combine picker), whose sourceURL is
  ///   a user-picked file we must never silently overwrite, or
  /// - there is no sourceURL to save into.
  private var combineSaveNeedsDialog: Bool {
    guard state.isCombineMode else { return false }
    return !CombineSaveAsEditPreference.isEnabled()
      || state.isManualImportSession
      || state.sourceURL == nil
  }

  /// Manual combine sessions have `sourceURL` pointing at the first user-picked file.
  /// Implicit-write paths (copy, drag-out, cloud) must never silently overwrite it with the
  /// stitched render — they route to explicit or no-write alternatives instead. Scoped to
  /// combine mode so ordinary single-image manual annotate saves still overwrite as expected.
  private var protectsSourceFromImplicitCombineWrite: Bool {
    state.isCombineMode && state.isManualImportSession
  }

  /// Silent save — renders once, updates thumbnail instantly, closes window, saves in background
  /// If previously uploaded to cloud, gate behind overwrite confirmation.
  private func performSave() {
    guard state.hasImage, !isSavingImage else { return }

    if combineSaveNeedsDialog {
      performCombineSave()
      return
    }
    // Capture-origin Combine can save to its existing source when enabled.

    // Cloud gate: if the rendered output differs from the uploaded file, require overwrite confirmation.
    if requiresCloudOverwriteConfirmation {
      showCloudOverwriteAlert { [weak self] in
        self?.performCloudReUploadAndClose()
      }
      return
    }
    executeSave()
  }

  private func executeSave() {
    guard state.hasImage else { return }

    if isEditingProjectDocument {
      if saveProjectDocumentInPlace() { forceClose() }
      return
    }

    guard let sourceURL = state.sourceURL else {
      performSaveAs()
      return
    }
    guard AnnotateExporter.confirmTransparencyLossIfNeeded(state: state, targetURL: sourceURL) else {
      return
    }
    saveRasterInPlace(to: sourceURL)
  }

  private func saveRasterInPlace(to sourceURL: URL) {
    guard let window, !isSavingImage else { return }
    guard !state.isSensitiveRedactionScanning else {
      showSaveErrorAlert(informativeText: L10n.AnnotateUI.autoRedactionScanning)
      return
    }
    guard let renderSnapshot = state.makeRenderSnapshot() else {
      showSaveErrorAlert()
      return
    }

    let itemId = quickAccessItemId
    if let itemId, !QuickAccessManager.shared.beginSavingItem(id: itemId) {
      showSaveErrorAlert()
      return
    }

    let returnInterval = PerfSignpost.beginInterval("AnnotateReturn")
    let sessionSnapshot = makeSessionSnapshot()
    let generation = itemId.map { QuickAccessManager.shared.nextThumbnailGeneration(for: $0) }
    isSavingRasterInPlace = true
    var didEditDuringSave = false
    let editObservation = state.$hasUnsavedChanges.dropFirst().sink { isDirty in
      if isDirty { didEditDuringSave = true }
    }
    let progress = beginSaveProgress(in: window)

    Task {
      defer {
        if let itemId { QuickAccessManager.shared.finishSavingItem(id: itemId) }
      }
      let result = await Task.detached(priority: .userInitiated) { () -> (image: NSImage, thumbnail: NSImage?)? in
        let renderInterval = PerfSignpost.beginInterval("render")
        let rendered = await AnnotateExporter.renderFinalImage(snapshot: renderSnapshot)
        PerfSignpost.endInterval(renderInterval)
        guard let rendered, await AnnotateExporter.saveToFileOffMain(image: rendered, sourceURL: sourceURL) else {
          return nil
        }

        let thumbnail = itemId.map { _ in
          PerfSignpost.measure("thumbnailScale") {
            QuickAccessManager.cgScaleThumbnail(rendered, maxSize: 200)
          }
        }
        return (rendered, thumbnail)
      }.value

      if let result {
        await Self.persistCommittedSessionOffMain(sessionSnapshot, for: sourceURL)
        if state.sourceURL == sourceURL {
          saveSessionCache(sessionSnapshot)
          if let itemId, let thumbnail = result.thumbnail {
            QuickAccessManager.shared.updateItemThumbnail(
              id: itemId, thumbnail: thumbnail, fullResImage: result.image, generation: generation
            )
            QuickAccessManager.shared.markCloudStale(id: itemId)
          }
        }
      }

      endSaveProgress(progress, in: window)
      editObservation.cancel()
      isSavingRasterInPlace = false
      guard self.window === window, window.isVisible, state.sourceURL == sourceURL else {
        PerfSignpost.endInterval(returnInterval)
        return
      }
      guard result != nil else {
        PerfSignpost.endInterval(returnInterval)
        showSaveErrorAlert()
        return
      }
      guard !didEditDuringSave else {
        PerfSignpost.endInterval(returnInterval)
        return
      }

      state.markAsSaved()
      PostCaptureActionHandler.shared.copyEditedCaptureToClipboardIfEnabled(for: .screenshot, url: sourceURL)
      forceClose(perfInterval: returnInterval)
    }
  }

  private func performSaveAs() {
    guard state.hasImage, !isSavingImage else { return }

    // Дефолты эталона: имя и папка исходника, формат PNG.
    let savePanel = AnnotateSavePanelController(
      baseFileName: AnnotateSavePanelController.baseFileName(for: state.sourceURL, isCombine: state.isCombineMode),
      directoryURL: AnnotateSavePanelController.directoryURL(for: state.sourceURL)
    )
    let panel = savePanel.panel
    // Редактор проекта после Save As остаётся открытым (так ведёт себя эталон),
    // остальные контексты закрываются, как раньше.
    let keepsWindowOpen = isEditingProjectDocument

    guard let window = self.window else { return }

    panel.beginSheetModal(for: window) { [weak self] response in
      // Контроллер меню формата должен жить, пока открыта панель.
      withExtendedLifetime(savePanel) {}
      guard let self = self, response == .OK, let url = savePanel.destinationURL else { return }
      self.saveAs(to: url, keepsWindowOpen: keepsWindowOpen)
    }
  }

  func saveAs(to url: URL, keepsWindowOpen: Bool) {
    guard AnnotateExporter.confirmTransparencyLossIfNeeded(state: state, targetURL: url) else {
      return
    }
    if AnnotateSaveFormat(fileExtension: url.pathExtension) == .heic {
      exportHEIC(to: url)
    } else {
      let didSave = AnnotateExporter.save(state: state, to: url, originalImageData: originalImageData)
      if didSave, !OwnShotProjectFormat.isProjectURL(url) {
        Self.persistCommittedSession(makeSessionSnapshot(), for: url)
      }
      finishSaveAs(didSave: didSave, keepsWindowOpen: keepsWindowOpen, destinationURL: url)
    }
  }

  func exportHEIC(to url: URL) {
    guard let window, !isSavingImage else { return }
    let keepsWindowOpen = isEditingProjectDocument
    guard !state.isSensitiveRedactionScanning else {
      showSaveErrorAlert(informativeText: L10n.AnnotateUI.autoRedactionScanning)
      return
    }
    let directory = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
    let destination = directory.appendingPathComponent(url.lastPathComponent)
    let path = destination.path.precomposedStringWithCanonicalMapping
    let volume = try? directory.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
    let destinationKey = volume?.volumeSupportsCaseSensitiveNames == true ? path : path.lowercased()
    guard !Self.activeHEICDestinations.contains(destinationKey),
          let snapshot = state.makeRenderSnapshot() else {
      showSaveErrorAlert()
      return
    }
    Self.activeHEICDestinations.insert(destinationKey)
    let sessionSnapshot = AnnotationSessionStore.shared.shouldPersist(for: url) ? makeSessionSnapshot() : nil
    isExportingHEIC = true
    var didEditDuringExport = false
    let editObservation = state.$hasUnsavedChanges.dropFirst().sink { isDirty in
      if isDirty { didEditDuringExport = true }
    }

    // Лист блокирует ввод. Уже запущенные фоновые инструменты могут завершить правки.
    let progress = beginSaveProgress(in: window)

    Task {
      defer {
        editObservation.cancel()
        Self.activeHEICDestinations.remove(destinationKey)
      }
      let savedRevision = await AnnotateExporter.saveRasterOffMain(snapshot: snapshot, to: url)
      if let savedRevision {
        await Self.persistCommittedSessionOffMain(sessionSnapshot, for: url, expecting: savedRevision)
      }
      endSaveProgress(progress, in: window)
      isExportingHEIC = false
      guard self.window === window else { return }
      let didSave = savedRevision.map { revision in
        SandboxFileAccessManager.shared.withScopedAccess(to: directory) {
          CaptureFilePublication.FileRevision(at: url) == revision
        }
      } ?? false
      if didSave, didEditDuringExport { return }
      finishSaveAs(didSave: didSave, keepsWindowOpen: keepsWindowOpen, destinationURL: url)
    }
  }

  private func beginSaveProgress(in window: NSWindow) -> NSPanel {
    let progress = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 280, height: 72),
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )
    let indicator = NSProgressIndicator()
    indicator.style = .spinning
    indicator.isIndeterminate = true
    let label = NSTextField(wrappingLabelWithString: L10n.VideoEditor.preparingSave)
    let stack = NSStackView(views: [indicator, label])
    stack.alignment = .centerY
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false
    if let content = progress.contentView {
      content.addSubview(stack)
      NSLayoutConstraint.activate([
        stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
        stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        stack.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 16)
      ])
    }
    window.beginSheet(progress)
    indicator.startAnimation(nil)
    return progress
  }

  private func endSaveProgress(_ progress: NSPanel, in window: NSWindow) {
    if progress.sheetParent === window {
      window.endSheet(progress)
    }
    progress.orderOut(nil)
  }

  private func finishSaveAs(didSave: Bool, keepsWindowOpen: Bool, destinationURL: URL) {
    guard didSave else {
      showSaveErrorAlert()
      return
    }
    if !keepsWindowOpen || overwritesOpenProject(at: destinationURL) {
      state.markAsSaved()
    }
    SoundManager.play("Pop")
    guard !keepsWindowOpen else { return }
    if let itemId = quickAccessItemId {
      QuickAccessManager.shared.dismissCard(id: itemId)
    }
    forceClose()
  }

  private func overwritesOpenProject(at destinationURL: URL) -> Bool {
    guard OwnShotProjectFormat.isProjectURL(destinationURL),
          let sourceURL = state.sourceURL,
          OwnShotProjectFormat.isProjectURL(sourceURL) else { return false }

    func canonicalPath(_ url: URL) -> String {
      let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
      return (try? resolved.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath) ?? resolved.path
    }

    return canonicalPath(sourceURL) == canonicalPath(destinationURL)
  }

  // MARK: - Project

  /// Редактор открыт из проекта OwnShot: Done пишет проект, а не растр.
  private var isEditingProjectDocument: Bool {
    state.sourceURL.map(OwnShotProjectFormat.isProjectURL) ?? false
  }

  /// Сохраняет открытый проект на место. false — проекта нет или запись не удалась.
  private func saveProjectDocumentInPlace() -> Bool {
    guard let projectURL = state.sourceURL, OwnShotProjectFormat.isProjectURL(projectURL) else { return false }
    guard AnnotateExporter.saveProject(state: state, to: projectURL, originalImageData: originalImageData) else {
      showSaveErrorAlert()
      return false
    }
    state.markAsSaved()
    return true
  }

  private func performPrint() {
    AnnotateExporter.printImage(state: state, in: window)
  }

  private func showSaveErrorAlert(informativeText: String? = nil) {
    guard let window = self.window else { return }

    let alert = NSAlert()
    alert.messageText = L10n.AnnotateUI.saveFailedTitle
    alert.informativeText = informativeText ?? L10n.AnnotateUI.saveFailedMessage
    alert.alertStyle = .warning
    alert.addButton(withTitle: L10n.Common.ok)
    alert.beginSheetModal(for: window)
  }

  private func performCombineSave() {
    guard let window else { return }
    let alert = NSAlert()
    alert.messageText = L10n.Combine.saveTitle
    alert.informativeText = L10n.Combine.saveMessage
    alert.alertStyle = .informational
    alert.addButton(withTitle: L10n.Combine.saveToFile)
    alert.addButton(withTitle: L10n.Combine.copyToClipboard)
    alert.addButton(withTitle: L10n.Common.cancel)
    alert.beginSheetModal(for: window) { [weak self] response in
      guard let self else { return }
      switch response {
      case .alertFirstButtonReturn:
        self.performSaveAs()
      case .alertSecondButtonReturn:
        // "Copy to Clipboard" must copy only — the user declined "Save to File", so never
        // write over the source. (Previously this silently overwrote the file via executeCopy.)
        if let rendered = AnnotateExporter.renderFinalImage(state: self.state) {
          ClipboardHelper.copyImage(rendered)
          SoundManager.play("Pop")
        }
        self.forceClose()
      default:
        break
      }
    }
  }

  /// Copy = render once, copy to clipboard, update thumbnail, close, save in background.
  /// If previously uploaded to cloud and output changed, gate behind overwrite confirmation.
  /// closeAfterCopy = false — копируем и оставляем редактор открытым (сочетание ⇧⌘C).
  private func performCopy(closeAfterCopy: Bool = true) {
    guard state.hasImage, !isSavingRasterInPlace else { return }

    // Manual combine session: copy only. Skip the cloud-overwrite gate — its re-upload
    // path writes the stitched render to sourceURL (the user's picked file). executeCopy()
    // enforces the same protection (clipboard + close, no write).
    if protectsSourceFromImplicitCombineWrite {
      executeCopy(closeAfterCopy: closeAfterCopy)
      return
    }

    // Cloud gate: if the rendered output differs from the uploaded file, require overwrite confirmation.
    if requiresCloudOverwriteConfirmation {
      showCloudOverwriteAlert { [weak self] in
        self?.performCloudReUploadCopyAndClose(closeAfterCopy: closeAfterCopy)
      }
      return
    }
    executeCopy(closeAfterCopy: closeAfterCopy)
  }

  private func executeCopy(closeAfterCopy: Bool = true) {
    guard state.hasImage else { return }

    // Render once, use for everything
    let renderedImage = AnnotateExporter.renderFinalImage(state: state)

    // Manual combine sessions upload a temporary render, so any existing cloud URL may
    // point at an older stitch. Copy the current render and close without touching source.
    if protectsSourceFromImplicitCombineWrite {
      if let renderedImage = renderedImage {
        ClipboardHelper.copyImage(renderedImage)
        SoundManager.play("Pop")
      }
      if closeAfterCopy { forceClose() }
      return
    }

    // Проект: копируем рендер и сохраняем документ на место, растр в ZIP не пишем.
    if isEditingProjectDocument {
      if let renderedImage = renderedImage {
        ClipboardHelper.copyImage(renderedImage)
        SoundManager.play("Pop")
      }
      if saveProjectDocumentInPlace(), closeAfterCopy { forceClose() }
      return
    }

    // Copy to clipboard — cloud link (text) if available, otherwise image
    if let cloudURL = state.cloudURL {
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      pasteboard.setString(cloudURL.absoluteString, forType: .string)
      SoundManager.play("Pop")
    } else if let renderedImage = renderedImage {
      ClipboardHelper.copyImage(renderedImage)
      SoundManager.play("Pop")
    }

    // Update QA thumbnail instantly + cache
    let sessionSnapshot = makeSessionSnapshot()
    if let _ = state.sourceURL {
      state.markAsSaved()
      saveSessionCache(sessionSnapshot)
    }
    if let renderedImage = renderedImage, let itemId = quickAccessItemId {
      QuickAccessManager.shared.updateItemThumbnail(id: itemId, image: renderedImage)
      QuickAccessManager.shared.markCloudStale(id: itemId)
    }

    // Close instantly, save in background
    let capturedState = state
    let sourceURL = state.sourceURL
    let writesSourceFile = Self.copyWritesSourceFile(quickAccessItemId: quickAccessItemId)
    if closeAfterCopy { forceClose() }
    Task.detached(priority: .userInitiated) {
      guard let sourceURL else { return }
      // Чужой файл копирование не меняет: правки остаются только в сессии.
      if writesSourceFile {
        guard await AnnotateExporter.saveToFile(image: renderedImage, state: capturedState) else { return }
      }
      await Self.persistCommittedSessionOffMain(sessionSnapshot, for: sourceURL)
    }
  }

  /// Copy пишет рендер на место только в снимок OwnShot с карточкой Quick Access.
  /// Файлы из open-annotate, History и Open With эталон при копировании не трогает.
  nonisolated static func copyWritesSourceFile(quickAccessItemId: UUID?) -> Bool {
    quickAccessItemId != nil
  }

  // MARK: - Cloud Overwrite

  /// Show alert asking user to confirm overwrite of cloud file.
  /// "Overwrite" → executes onOverwrite closure. "Cancel" → does nothing (window stays open).
  private func showCloudOverwriteAlert(onOverwrite: @escaping () -> Void) {
    guard let window = self.window else {
      onOverwrite()
      return
    }

    let alert = NSAlert()
    alert.messageText = L10n.AnnotateUI.overwriteCloudFileTitle
    alert.informativeText = L10n.AnnotateUI.overwriteCloudFileOnSaveMessage
    alert.alertStyle = .warning
    alert.addButton(withTitle: L10n.Common.overwrite)
    alert.addButton(withTitle: L10n.Common.cancel)

    alert.beginSheetModal(for: window) { response in
      if response == .alertFirstButtonReturn {
        onOverwrite()
      }
      // Cancel: do nothing — window stays open, changes preserved but not committed
    }
  }

  /// Save locally + re-upload to cloud + update QA card + close window.
  /// Used when user confirms overwrite on Save or Close-Save.
  private func performCloudReUploadAndClose() {
    guard let sourceURL = state.sourceURL else { return }

    // Render once
    let sessionSnapshot = makeSessionSnapshot()
    let renderedImage = AnnotateExporter.renderFinalImage(state: state)

    // Save to disk first (so cloud upload reads the updated file)
    if let renderedImage = renderedImage {
      let didSaveRenderedImage = AnnotateExporter.saveToFile(image: renderedImage, state: state)
      if didSaveRenderedImage {
        Self.persistCommittedSession(sessionSnapshot, for: sourceURL)
      }
    }

    let oldCloudKey = state.cloudKey
    let capturedState = state
    let itemId = quickAccessItemId

    // Re-upload to cloud
    Task {
      do {
        let fileAccess = SandboxFileAccessManager.shared.beginAccessingURL(sourceURL)
        defer { fileAccess.stop() }
        DiagnosticLogger.shared.log(
          .info,
          .cloud,
          "Annotate cloud re-upload started",
          context: ["fileName": sourceURL.lastPathComponent, "mode": "save"]
        )

        let result = try await CloudManager.shared.upload(fileURL: sourceURL)

        // Delete old cloud file in background
        if let oldKey = oldCloudKey {
          Task.detached(priority: .utility) {
            do {
              try await CloudManager.shared.deleteByKey(key: oldKey)
            } catch {
              DiagnosticLogger.shared.logError(.cloud, error, "Annotate old cloud object cleanup failed")
            }
          }
        }

        // Update state
        capturedState.cloudURL = result.publicURL
        capturedState.cloudKey = result.key
        capturedState.markAsSaved()
        capturedState.isCloudStale = false

        // Update QuickAccess item: thumbnail first, then setCloudURL to reset stale
        if let itemId = itemId {
          if let renderedImage = renderedImage {
            QuickAccessManager.shared.updateItemThumbnail(id: itemId, image: renderedImage)
          }
          QuickAccessManager.shared.setCloudURL(id: itemId, url: result.publicURL, key: result.key)
        }

        // Auto-copy cloud link
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(result.publicURL.absoluteString, forType: .string)

        SoundManager.play("Pop")
        DiagnosticLogger.shared.log(
          .info,
          .cloud,
          "Annotate cloud re-upload completed",
          context: ["fileName": sourceURL.lastPathComponent, "mode": "save"]
        )
        self.forceClose()
      } catch {
        DiagnosticLogger.shared.logError(
          .cloud,
          error,
          "Annotate cloud re-upload failed; falling back to local save",
          context: ["fileName": sourceURL.lastPathComponent, "mode": "save"]
        )
        // Fall back to local save only
        capturedState.markAsSaved()
        if let renderedImage = renderedImage, let itemId = itemId {
          QuickAccessManager.shared.updateItemThumbnail(id: itemId, image: renderedImage)
        }
        PostCaptureActionHandler.shared.copyEditedCaptureToClipboardIfEnabled(
          for: .screenshot,
          url: sourceURL
        )
        self.forceClose()
      }
    }
  }

  /// Save locally + re-upload to cloud + copy cloud URL + close window.
  /// Used when user confirms overwrite on Copy (⌘⇧C).
  private func performCloudReUploadCopyAndClose(closeAfterCopy: Bool = true) {
    guard let sourceURL = state.sourceURL else { return }

    // Render once
    let sessionSnapshot = makeSessionSnapshot()
    let renderedImage = AnnotateExporter.renderFinalImage(state: state)

    // Save to disk first
    if let renderedImage = renderedImage {
      let didSaveRenderedImage = AnnotateExporter.saveToFile(image: renderedImage, state: state)
      if didSaveRenderedImage {
        Self.persistCommittedSession(sessionSnapshot, for: sourceURL)
      }
    }

    let oldCloudKey = state.cloudKey
    let capturedState = state
    let itemId = quickAccessItemId

    // Re-upload to cloud
    Task {
      do {
        let fileAccess = SandboxFileAccessManager.shared.beginAccessingURL(sourceURL)
        defer { fileAccess.stop() }
        DiagnosticLogger.shared.log(
          .info,
          .cloud,
          "Annotate cloud re-upload started",
          context: ["fileName": sourceURL.lastPathComponent, "mode": "copy"]
        )

        let result = try await CloudManager.shared.upload(fileURL: sourceURL)

        // Delete old cloud file
        if let oldKey = oldCloudKey {
          Task.detached(priority: .utility) {
            do {
              try await CloudManager.shared.deleteByKey(key: oldKey)
            } catch {
              DiagnosticLogger.shared.logError(.cloud, error, "Annotate old cloud object cleanup failed")
            }
          }
        }

        // Update state
        capturedState.cloudURL = result.publicURL
        capturedState.cloudKey = result.key
        capturedState.markAsSaved()
        capturedState.isCloudStale = false

        // Update QuickAccess item: thumbnail first, then setCloudURL to reset stale
        if let itemId = itemId {
          if let renderedImage = renderedImage {
            QuickAccessManager.shared.updateItemThumbnail(id: itemId, image: renderedImage)
          }
          QuickAccessManager.shared.setCloudURL(id: itemId, url: result.publicURL, key: result.key)
        }

        // Copy cloud link to clipboard
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(result.publicURL.absoluteString, forType: .string)

        SoundManager.play("Pop")
        DiagnosticLogger.shared.log(
          .info,
          .cloud,
          "Annotate cloud re-upload completed",
          context: ["fileName": sourceURL.lastPathComponent, "mode": "copy"]
        )
        if closeAfterCopy { self.forceClose() }
      } catch {
        DiagnosticLogger.shared.logError(
          .cloud,
          error,
          "Annotate cloud re-upload failed; falling back to image clipboard",
          context: ["fileName": sourceURL.lastPathComponent, "mode": "copy"]
        )
        // Fall back: copy image to clipboard, close
        if let renderedImage = renderedImage {
          ClipboardHelper.copyImage(renderedImage)
        }
        capturedState.markAsSaved()
        if let renderedImage = renderedImage, let itemId = itemId {
          QuickAccessManager.shared.updateItemThumbnail(id: itemId, image: renderedImage)
        }
        SoundManager.play("Pop")
        if closeAfterCopy { self.forceClose() }
      }
    }
  }

  // MARK: - Session Cache

  private func makeSessionSnapshot() -> AnnotationSessionData? {
    AnnotateManager.shared.makeSessionData(for: state, originalImageData: originalImageData)
  }

  /// Save current annotation state to session cache for re-editing
  private func saveSessionCache(_ snapshot: AnnotationSessionData?) {
    guard let itemId = quickAccessItemId,
          let snapshot else { return }
    let startedAt = CFAbsoluteTimeGetCurrent()
    let snapshotDurationMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1_000)
    let embeddedBytes = snapshot.embeddedImageAssetsData.values.reduce(0) { $0 + $1.count }

    AnnotateManager.shared.saveSessionData(snapshot, for: itemId)

    let totalDurationMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1_000)
    DiagnosticLogger.shared.log(.debug, .annotate, "Session cache updated", context: [
      "itemId": itemId.uuidString,
      "annotations": "\(snapshot.annotations.count)",
      "embeddedAssets": "\(snapshot.embeddedImageAssetsData.count)",
      "embeddedBytes": "\(embeddedBytes)",
      "snapshotMs": "\(snapshotDurationMs)",
      "totalMs": "\(totalDurationMs)"
    ])
  }

  @MainActor
  private static func persistCommittedSession(_ snapshot: AnnotationSessionData?, for sourceURL: URL) {
    guard let snapshot,
          AnnotationSessionStore.shared.shouldPersist(for: sourceURL) else { return }
    AnnotationSessionStore.shared.persist(snapshot, for: sourceURL)
  }

  /// Off-main variant for background save flows: the multi-MB sidecar package write
  /// runs on the calling queue; only the cheap shouldPersist check hops to main.
  @concurrent nonisolated private static func persistCommittedSessionOffMain(
    _ snapshot: AnnotationSessionData?,
    for sourceURL: URL,
    expecting expectedSourceRevision: CaptureFilePublication.FileRevision? = nil
  ) async {
    guard let snapshot else { return }
    let shouldPersist = await MainActor.run { AnnotationSessionStore.shared.shouldPersist(for: sourceURL) }
    guard shouldPersist else { return }
    _ = await AnnotationSessionStore.shared.persistOffMain(snapshot, for: sourceURL, expecting: expectedSourceRevision)
  }
}
