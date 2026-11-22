//
//  VideoEditorWindowController.swift
//  Snapzy
//
//  Controller managing video editor window lifecycle
//

import AppKit
import Combine
import CoreMedia
import Darwin
import SwiftUI
import UniformTypeIdentifiers

/// The file ownership boundary used by the Video Editor Save action.
///
/// A temporary Quick Access capture is committed at its current URL. A capture
/// that is already saved can be replaced at its existing destination or
/// explicitly exported as a copy through the existing confirmation flow.
enum VideoEditorSaveTarget: Equatable {
  case quickAccessTemp
  case standaloneTemp
  case destination

  static func resolve(isTempCapture: Bool, hasQuickAccessItem: Bool = true) -> Self {
    guard isTempCapture else { return .destination }
    return hasQuickAccessItem ? .quickAccessTemp : .standaloneTemp
  }
}

/// Manages video editor window lifecycle
@MainActor
final class VideoEditorWindowController: NSWindowController, NSWindowDelegate {
  private let fileAccessManager = SandboxFileAccessManager.shared
  private let tempCaptureManager = TempCaptureManager.shared
  private let quickAccessItemID: UUID?
  private var sourceFileAccess: SandboxFileAccessManager.ScopedAccess?
  private var originalFileAccess: SandboxFileAccessManager.ScopedAccess?
  private var sourceURL: URL?
  private var state: VideoEditorState?
  private var sessionData: VideoEditorSessionData?
  private var documentEditedCancellable: AnyCancellable?
  private var shortcutSettingsCancellable: AnyCancellable?
  private var isExportingFrame = false
  private var isEmptyState: Bool = false

  /// Callback when video is loaded in empty state - (workingURL, originalURL)
  var onVideoLoaded: ((URL, URL?) -> Void)?

  func ownsFile(atDirectoryEntryPath filePath: String) -> Bool {
    guard let state else { return false }
    return SandboxFileAccessManager.directoryEntryPath(for: state.sourceURL) == filePath
      || SandboxFileAccessManager.directoryEntryPath(for: state.originalURL) == filePath
  }

  /// Initialize with QuickAccessItem (existing behavior)
  init(item: QuickAccessItem, sessionData: VideoEditorSessionData? = nil) {
    quickAccessItemID = item.id
    sourceFileAccess = fileAccessManager.beginAccessingURL(item.url)
    sourceURL = item.url
    self.sessionData = sessionData
    let state = VideoEditorState(url: item.url, sessionData: sessionData)
    state.quickAccessItemId = item.id
    // A stale Quick Access cloud link must not make the edited file look
    // uploaded again when the editor is reopened. Keep the key so the next
    // upload can still overwrite the existing cloud object.
    state.cloudURL = item.isCloudStale ? nil : item.cloudURL
    state.cloudKey = item.cloudKey
    self.state = state
    isEmptyState = false

    super.init(window: Self.createWindow())
    window?.delegate = self
    setupContent()
  }

  /// Initialize with URL directly (for drag & drop from external sources)
  init(url: URL, sessionData: VideoEditorSessionData? = nil) {
    quickAccessItemID = nil
    sourceFileAccess = fileAccessManager.beginAccessingURL(url)
    sourceURL = url
    self.sessionData = sessionData
    state = VideoEditorState(url: url, sessionData: sessionData)
    isEmptyState = false

    super.init(window: Self.createWindow())
    window?.delegate = self
    setupContent()
  }

  /// Initialize with URL and optional original URL (for drag & drop with temp copy)
  init(
    url: URL,
    originalURL: URL?,
    sessionData: VideoEditorSessionData? = nil
  ) {
    quickAccessItemID = nil
    sourceFileAccess = fileAccessManager.beginAccessingURL(url)
    if let originalURL, originalURL != url {
      originalFileAccess = fileAccessManager.beginAccessingURL(originalURL)
    }
    sourceURL = url
    self.sessionData = sessionData
    state = VideoEditorState(
      url: url,
      originalURL: originalURL,
      sessionData: sessionData
    )
    isEmptyState = false

    super.init(window: Self.createWindow())
    window?.delegate = self
    setupContent()
  }

  /// Initialize with empty state (for drag & drop workflow)
  override init(window _: NSWindow?) {
    quickAccessItemID = nil
    sourceURL = nil
    state = nil
    sessionData = nil
    isEmptyState = true

    super.init(window: Self.createWindow())
    window?.delegate = self
    setupEmptyContent()
  }

  deinit {
    sourceFileAccess?.stop()
    originalFileAccess?.stop()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private static func createWindow() -> VideoEditorWindow {
    let screen = NSScreen.main ?? NSScreen.screens.first!
    let windowWidth: CGFloat = 1200
    let windowHeight: CGFloat = 800

    let origin = NSPoint(
      x: (screen.frame.width - windowWidth) / 2,
      y: (screen.frame.height - windowHeight) / 2
    )

    return VideoEditorWindow(
      contentRect: NSRect(origin: origin, size: NSSize(width: windowWidth, height: windowHeight))
    )
  }

  private func setupContent() {
    guard let state else {
      setupEmptyContent()
      return
    }

    let mainView = VideoEditorMainView(
      state: state,
      primaryActionTitle: primaryActionTitle,
      onSave: { [weak self] in self?.showSaveConfirmation() },
      onCancel: { [weak self] in self?.handleCancel() }
    )
    bindDocumentEditedState(to: state)
    if !state.isGIF {
      (window as? VideoEditorWindow)?.onTogglePlayback = { [weak state] in
        guard state?.isExporting != true else { return }
        state?.togglePlayback()
      }
    }
    if let videoWindow = window as? VideoEditorWindow {
      videoWindow.onEditorShortcut = { [weak self] action, repeating in
        self?.performShortcut(action, repeating: repeating) ?? false
      }
      videoWindow.editorShortcutOverrides = { [weak state] in
        guard let state else { return [] }
        let settings = VideoEditorShortcutSettings.shared
        if state.isGIF {
          return [settings.shortcut(for: .exportVideo), settings.shortcut(for: .toggleFullScreen)].compactMap { $0 }
        }
        return settings.activeShortcuts
      }
      shortcutSettingsCancellable = VideoEditorShortcutSettings.shared.objectWillChange
        .receive(on: RunLoop.main)
        .sink { [weak videoWindow] _ in
          guard let videoWindow, videoWindow.isKeyWindow else { return }
          KeyboardShortcutManager.shared.updateVideoEditorShortcutOverrides(for: videoWindow, isFocused: true)
        }
    }
    window?.contentView = NSHostingView(rootView: mainView)
  }

  private func setupEmptyContent() {
    bindDocumentEditedState(to: nil)
    (window as? VideoEditorWindow)?.onTogglePlayback = nil
    let emptyView = VideoEditorEmptyStateView { [weak self] url, originalURL in
      self?.onVideoLoaded?(url, originalURL)
    }
    window?.contentView = NSHostingView(rootView: emptyView)
  }

  private func bindDocumentEditedState(to state: VideoEditorState?) {
    documentEditedCancellable = nil
    window?.isDocumentEdited = state?.hasUnsavedChanges ?? false

    guard let state else { return }

    documentEditedCancellable = state.$hasUnsavedChanges
      .removeDuplicates()
      .receive(on: RunLoop.main)
      .sink { [weak self] hasUnsavedChanges in
        self?.window?.isDocumentEdited = hasUnsavedChanges
      }
  }

  func showWindow() {
    window?.makeKeyAndOrderFront(nil)
    window?.makeMain()
    NSApp.activate(ignoringOtherApps: true)
  }

  func windowDidBecomeKey(_ notification: Notification) {
    guard let videoWindow = notification.object as? VideoEditorWindow else { return }
    videoWindow.syncLevelWithFocusState()
    KeyboardShortcutManager.shared.updateVideoEditorShortcutOverrides(for: videoWindow, isFocused: true)
  }

  func windowDidResignKey(_ notification: Notification) {
    guard let videoWindow = notification.object as? VideoEditorWindow else { return }
    videoWindow.syncLevelWithFocusState()
    KeyboardShortcutManager.shared.updateVideoEditorShortcutOverrides(for: videoWindow, isFocused: false)
  }

  func windowDidBecomeMain(_ notification: Notification) {
    (notification.object as? VideoEditorWindow)?.syncLevelWithFocusState()
  }

  func windowDidResignMain(_ notification: Notification) {
    (notification.object as? VideoEditorWindow)?.syncLevelWithFocusState()
  }

  private var isTempCaptureSource: Bool {
    guard let state else { return false }
    return tempCaptureManager.isTempFile(state.originalURL)
  }

  private var saveTarget: VideoEditorSaveTarget {
    VideoEditorSaveTarget.resolve(isTempCapture: isTempCaptureSource, hasQuickAccessItem: quickAccessItemID != nil)
  }

  private var primaryActionTitle: String {
    state?.isGIF == true || saveTarget != .destination ? L10n.VideoEditor.save : L10n.VideoEditor.convert
  }

  // MARK: - NSWindowDelegate

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    // Empty state can always close
    guard let state else { return true }

    guard state.hasUnsavedChanges else {
      state.pause()
      return true
    }

    showUnsavedChangesAlert(for: sender)
    return false
  }

  func windowWillClose(_: Notification) {
    if let videoWindow = window as? VideoEditorWindow {
      KeyboardShortcutManager.shared.updateVideoEditorShortcutOverrides(for: videoWindow, isFocused: false)
    }
    state?.cancelPendingPerformanceWork()
    window?.alphaValue = 0
    if let itemId = quickAccessItemID {
      QuickAccessManager.shared.setWindowOpen(id: itemId, isOpen: false)
    }
  }

  private func performShortcut(_ action: VideoEditorShortcutAction, repeating: Bool) -> Bool {
    guard let state, let window, !state.isRenamingFile else { return false }
    guard !state.isExporting else { return true }

    switch action {
    case .exportVideo:
      if !repeating && !isExportingFrame { showSaveConfirmation() }
      return true
    case .toggleFullScreen:
      if !repeating { window.toggleFullScreen(nil) }
      return true
    default:
      guard !state.isGIF else { return false }
    }

    if repeating {
      switch action {
      case .zoomIn, .zoomOut, .previousFrame, .nextFrame, .backTenFrames, .forwardTenFrames,
           .previousClipEdge, .nextClipEdge:
        break
      default:
        return true
      }
    }

    switch action {
    case .selectionTool: state.selectTimelineTool(.selection)
    case .cutTool: state.selectTimelineTool(.cut)
    case .splitClip: state.splitAtPlayhead()
    case .splitZoom: state.splitZoomAtPlayhead()
    case .deselectAll: state.deselectAllTimelineItems()
    case .zoomIn: state.timelineViewport.zoomIn(anchorTime: state.currentTime.seconds)
    case .zoomOut: state.timelineViewport.zoomOut(anchorTime: state.currentTime.seconds)
    case .fitTimeline: state.timelineViewport.fit()
    case .exportVideoToCloud:
      NotificationCenter.default.post(name: .videoEditorCloudUpload, object: state)
    case .exportFrame: exportCurrentFrame()
    case .previousFrame: state.stepPlayhead(byFrames: -1)
    case .nextFrame: state.stepPlayhead(byFrames: 1)
    case .backTenFrames: state.stepPlayhead(byFrames: -10)
    case .forwardTenFrames: state.stepPlayhead(byFrames: 10)
    case .previousClipEdge: state.movePlayheadToClipEdge(forward: false)
    case .nextClipEdge: state.movePlayheadToClipEdge(forward: true)
    case .playheadStart: state.movePlayheadToBoundary(end: false)
    case .playheadEnd: state.movePlayheadToBoundary(end: true)
    case .exportVideo, .toggleFullScreen: break
    }
    return true
  }

  private func exportCurrentFrame() {
    guard let state, let window, !isExportingFrame else { return }
    state.pause()
    isExportingFrame = true

    Task {
      do {
        let frame = try await state.renderCurrentFrame()
        guard window.isVisible else {
          isExportingFrame = false
          return
        }

        let panel = NSSavePanel()
        panel.title = L10n.string(
          "video-editor.export-current-frame.title",
          defaultValue: "Export Current Frame",
          comment: "Save panel title when exporting a video frame as a PNG"
        )
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        let baseName = state.originalURL.deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = "\(baseName)-frame.png"
        panel.beginSheetModal(for: window) { [weak self] response in
          guard let self else { return }
          defer { self.isExportingFrame = false }
          guard response == .OK, let url = panel.url else { return }
          do {
            try VideoEditorFrameExport.writePNG(frame, to: url)
          } catch {
            self.showExportError(error)
          }
        }
      } catch {
        isExportingFrame = false
        if window.isVisible { showExportError(error) }
      }
    }
  }

  // MARK: - Unsaved Changes Alert

  private func showUnsavedChangesAlert(for window: NSWindow) {
    let alert = NSAlert()
    alert.messageText = L10n.VideoEditor.unsavedChangesTitle
    alert.informativeText = L10n.VideoEditor.unsavedChangesMessage
    alert.alertStyle = .warning

    alert.addButton(withTitle: L10n.VideoEditor.save)
    alert.addButton(withTitle: L10n.VideoEditor.dontSave)
    alert.addButton(withTitle: L10n.Common.cancel)

    alert.beginSheetModal(for: window) { [weak self] response in
      guard let self else { return }

      switch response {
      case .alertFirstButtonReturn:
        showSaveConfirmation()

      case .alertSecondButtonReturn:
        forceClose()

      default:
        break
      }
    }
  }

  // MARK: - Save Confirmation

  private func showSaveConfirmation() {
    guard let window, let state else { return }

    // A temporary capture stays under Quick Access ownership. Save commits
    // the edit to that same file; Quick Access Save handles promotion later.
    if saveTarget == .quickAccessTemp {
      if state.isGIF {
        showGIFSaveConfirmation()
      } else {
        performReplaceOriginal(offerPostExportUpload: false)
      }
      return
    }

    if saveTarget == .standaloneTemp {
      if state.isGIF {
        performGIFSaveAsCopy()
      } else {
        performSaveAsCopy()
      }
      return
    }

    if state.isGIF {
      showGIFSaveConfirmation()
      return
    }

    let alert = NSAlert()
    alert.messageText = L10n.VideoEditor.saveEditedVideoTitle
    alert.informativeText = L10n.VideoEditor.saveEditedVideoMessage(state.filename)
    alert.alertStyle = .informational

    alert.addButton(withTitle: L10n.VideoEditor.replaceOriginal)
    alert.addButton(withTitle: L10n.VideoEditor.saveAsCopy)
    alert.addButton(withTitle: L10n.Common.cancel)

    alert.beginSheetModal(for: window) { [weak self] response in
      guard let self else { return }

      switch response {
      case .alertFirstButtonReturn:
        performReplaceOriginal()

      case .alertSecondButtonReturn:
        performSaveAsCopy()

      default:
        break
      }
    }
  }

  // MARK: - GIF Export

  private func showGIFSaveConfirmation() {
    guard let window, let state else { return }

    let targetSize = state.exportSettings.exportSize(from: state.naturalSize)
    let isResizing = Int(targetSize.width) != Int(state.naturalSize.width)
      || Int(targetSize.height) != Int(state.naturalSize.height)

    let isTrimming = state.gifTrimRange != nil
    guard isResizing || isTrimming || state.hasUnsavedChanges else {
      let alert = NSAlert()
      alert.messageText = L10n.VideoEditor.noChangesTitle
      alert.informativeText = L10n.VideoEditor.gifDimensionsNotChanged
      alert.alertStyle = .informational
      alert.addButton(withTitle: L10n.Common.ok)
      alert.beginSheetModal(for: window)
      return
    }

    // Temporary GIF captures follow the same Quick Access session contract as
    // videos: render into staging, then replace the current temp file.
    if saveTarget == .quickAccessTemp {
      performGIFReplaceOriginal()
      return
    }

    let alert = NSAlert()
    if isTrimming {
      alert.messageText = L10n.VideoEditorGIFTrim.saveTitle
      alert.informativeText = L10n.VideoEditorGIFTrim.saveMessage(state.filename)
    } else if isResizing {
      alert.messageText = L10n.VideoEditor.saveResizedGIFTitle
      alert.informativeText = L10n.VideoEditor.resizeGifMessage(
        state.filename,
        Int(state.naturalSize.width),
        Int(state.naturalSize.height),
        Int(targetSize.width),
        Int(targetSize.height)
      )
    } else {
      alert.messageText = L10n.VideoEditorGIFTrim.saveEditsTitle
      alert.informativeText = L10n.VideoEditorGIFTrim.saveEditsMessage(state.filename)
    }
    alert.alertStyle = .informational

    alert.addButton(withTitle: L10n.VideoEditor.replaceOriginal)
    alert.addButton(withTitle: L10n.VideoEditor.saveAsCopy)
    alert.addButton(withTitle: L10n.Common.cancel)

    alert.beginSheetModal(for: window) { [weak self] response in
      guard let self else { return }
      switch response {
      case .alertFirstButtonReturn:
        performGIFReplaceOriginal()
      case .alertSecondButtonReturn:
        performGIFSaveAsCopy()
      default:
        break
      }
    }
  }

  private func performGIFReplaceOriginal() {
    guard let state else { return }

    let targetSize = state.exportSettings.exportSize(from: state.naturalSize)
    let trimRange = state.gifTrimRange
    let tempURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("GIFResize_\(UUID().uuidString)")
      .appendingPathComponent(state.sourceURL.lastPathComponent)

    let progressOperation: VideoEditorProgressOperation = .saveGIF
    state.progressOperation = progressOperation
    state.isExporting = true
    state.exportProgress = 0
    state.exportStatusMessage = progressOperation.initialStatusMessage

    Task {
      var preparedSource: VideoEditorSessionStore.PreparedSourceSnapshot?
      defer {
        try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent())
      }

      do {
        let originalAccess = SandboxFileAccessManager.shared.beginAccessingURL(state.originalURL)
        defer { originalAccess.stop() }
        let revision = try VideoEditorExporter.OriginalRevision.existing(at: originalAccess.url)
        preparedSource = try await prepareSessionSourceIfNeeded(for: state)
        try await GIFResizer.resize(
          sourceURL: state.editingSourceURL,
          targetSize: targetSize,
          outputURL: tempURL,
          trimRange: trimRange
        ) { progress in
          Task { @MainActor in
            state.exportProgress = Float(progress)
            state.exportStatusMessage = if progress >= 0.95 {
              L10n.VideoEditor.finalizing
            } else {
              trimRange == nil ? L10n.VideoEditor.resizingFrames : L10n.VideoEditorGIFTrim.exporting
            }
          }
        }

        try VideoEditorExporter.replaceExportedOriginal(
          at: originalAccess.url, expecting: revision, with: tempURL
        )

        invalidateEditedCloudState()
        guard await persistSessionAfterCommit(for: state, preparedSource: preparedSource) else {
          state.isExporting = false
          showExportError(VideoEditorSessionStore.StoreError.packageUnavailable)
          return
        }
        state.markAsSaved()
        state.isExporting = false
        if let quickAccessItemID {
          await QuickAccessManager.shared.refreshItemThumbnail(id: quickAccessItemID)
        }
        PostCaptureActionHandler.shared.copyEditedCaptureToClipboardIfEnabled(
          for: .recording,
          url: originalAccess.url
        )
        forceClose()
      } catch {
        if let preparedSource {
          VideoEditorSessionStore.shared.discardPreparedSourceSnapshot(preparedSource)
        }
        DiagnosticLogger.shared.logError(.export, error, "GIF replace original failed")
        state.isExporting = false
        showExportError(error)
      }
    }
  }

  private func performGIFSaveAsCopy() {
    guard let state, let window else { return }

    let savePanel = NSSavePanel()
    let baseName = state.originalURL.deletingPathExtension().lastPathComponent
    let targetSize = state.exportSettings.exportSize(from: state.naturalSize)
    if state.gifTrimRange != nil {
      savePanel.title = L10n.VideoEditorGIFTrim.saveTitle
      savePanel.nameFieldStringValue = "\(baseName)_trimmed.gif"
    } else if targetSize != state.naturalSize {
      savePanel.title = L10n.VideoEditor.saveResizedGIFTitle
      savePanel.nameFieldStringValue = "\(baseName)_resized.gif"
    } else {
      savePanel.title = L10n.VideoEditorGIFTrim.saveEditsTitle
      savePanel.nameFieldStringValue = "\(baseName).gif"
    }
    savePanel.message = L10n.VideoEditor.chooseWhereToSaveFile
    savePanel.nameFieldLabel = L10n.VideoEditor.fileNameLabel
    savePanel.allowedContentTypes = [.gif]
    savePanel.canCreateDirectories = true

    savePanel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK, let outputURL = savePanel.url else { return }
      self?.exportGIFToCopy(outputURL: outputURL)
    }
  }

  private func exportGIFToCopy(outputURL: URL) {
    guard let state else { return }
    if [state.originalURL, state.editingSourceURL].contains(where: {
      $0.resolvingSymlinksInPath().path == outputURL.resolvingSymlinksInPath().path
    }) {
      showExportError(CopyDestinationError.matchesSource)
      return
    }

    let targetSize = state.exportSettings.exportSize(from: state.naturalSize)
    let trimRange = state.gifTrimRange

    let progressOperation: VideoEditorProgressOperation = .exportGIF
    state.progressOperation = progressOperation
    state.isExporting = true
    state.exportProgress = 0
    state.exportStatusMessage = progressOperation.initialStatusMessage

    Task {
      do {
        try await GIFResizer.resize(
          sourceURL: state.editingSourceURL,
          targetSize: targetSize,
          outputURL: outputURL,
          trimRange: trimRange
        ) { progress in
          Task { @MainActor in
            state.exportProgress = Float(progress)
            state.exportStatusMessage = if progress >= 0.95 {
              L10n.VideoEditor.finalizing
            } else {
              trimRange == nil ? L10n.VideoEditor.resizingFrames : L10n.VideoEditorGIFTrim.exporting
            }
          }
        }

        state.isExporting = false
        state.markAsSaved()
        NSWorkspace.shared.activateFileViewerSelecting([outputURL])
      } catch {
        DiagnosticLogger.shared.logError(.export, error, "GIF save as copy failed")
        state.isExporting = false
        showExportError(error)
      }
    }
  }

  // MARK: - Export Actions

  private func performReplaceOriginal(offerPostExportUpload: Bool = true) {
    guard let state else { return }

    let progressOperation: VideoEditorProgressOperation = .saveVideo
    state.progressOperation = progressOperation
    state.isExporting = true
    state.exportProgress = 0
    state.exportStatusMessage = progressOperation.initialStatusMessage

    Task {
      var preparedSource: VideoEditorSessionStore.PreparedSourceSnapshot?
      do {
        let revision = try VideoEditorExporter.originalRevision(at: state.originalURL)
        preparedSource = try await prepareSessionSourceIfNeeded(for: state)
        try await VideoEditorExporter.replaceOriginal(state: state, expecting: revision) { [weak self] progress in
          Task { @MainActor in
            self?.state?.exportProgress = progress
            self?.state?.exportStatusMessage = self?.progressMessage(
              for: progress,
              operation: progressOperation
            ) ?? progressOperation.initialStatusMessage
          }
        }
        invalidateEditedCloudState()
        guard await persistSessionAfterCommit(for: state, preparedSource: preparedSource) else {
          state.isExporting = false
          showExportError(VideoEditorSessionStore.StoreError.packageUnavailable)
          return
        }
        state.markAsSaved()
        state.isExporting = false
        if let quickAccessItemID {
          await QuickAccessManager.shared.refreshItemThumbnail(id: quickAccessItemID)
        }
        PostCaptureActionHandler.shared.copyEditedCaptureToClipboardIfEnabled(
          for: .recording,
          url: state.originalURL
        )
        if offerPostExportUpload {
          self.offerPostExportUpload(for: state.originalURL) { [weak self] in
            self?.forceClose()
          }
        } else {
          self.forceClose()
        }
      } catch {
        if let preparedSource {
          VideoEditorSessionStore.shared.discardPreparedSourceSnapshot(preparedSource)
        }
        DiagnosticLogger.shared.logError(.export, error, "Video replace original failed")
        state.isExporting = false
        if error.isPermissionDenied {
          showReplaceOriginalPermissionFallback(error)
        } else {
          showExportError(error)
        }
      }
    }
  }

  private func performSaveAsCopy() {
    guard let state, let window else { return }

    // Show save panel to let user choose destination
    let savePanel = NSSavePanel()
    savePanel.title = L10n.VideoEditor.saveVideoCopyTitle
    savePanel.message = L10n.VideoEditor.chooseWhereToSaveEditedVideo
    savePanel.nameFieldLabel = L10n.VideoEditor.fileNameLabel
    savePanel.nameFieldStringValue = VideoEditorExporter.generateCopyFilename(from: state.sourceURL)
    savePanel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
    savePanel.canCreateDirectories = true

    savePanel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK, let outputURL = savePanel.url else { return }
      self?.exportToCopy(outputURL: outputURL)
    }
  }

  private func exportToCopy(outputURL: URL) {
    guard let state else { return }
    if [state.originalURL, state.editingSourceURL].contains(where: {
      $0.resolvingSymlinksInPath().path == outputURL.resolvingSymlinksInPath().path
    }) {
      showExportError(CopyDestinationError.matchesSource)
      return
    }

    let progressOperation: VideoEditorProgressOperation = .exportVideo
    state.progressOperation = progressOperation
    state.isExporting = true
    state.exportProgress = 0
    state.exportStatusMessage = progressOperation.initialStatusMessage

    Task {
      do {
        try await VideoEditorExporter.exportTrimmed(state: state, to: outputURL) { [weak self] progress in
          Task { @MainActor in
            self?.state?.exportProgress = progress
            self?.state?.exportStatusMessage = self?.progressMessage(
              for: progress,
              operation: progressOperation
            ) ?? progressOperation.initialStatusMessage
          }
        }
        state.isExporting = false
        state.cloudURL = nil
        state.cloudKey = nil
        state.markAsSaved()

        // Show exported file in Finder
        NSWorkspace.shared.activateFileViewerSelecting([outputURL])
        self.offerPostExportUpload(for: outputURL) {}
      } catch {
        DiagnosticLogger.shared.logError(.export, error, "Video save as copy failed")
        state.isExporting = false
        showExportError(error)
      }
    }
  }

  private enum CopyDestinationError: LocalizedError {
    case matchesSource

    var errorDescription: String? {
      L10n.string(
        "video-editor.copy.destination-matches-source",
        defaultValue: "Choose a different name or folder to save a copy.",
        comment: "A video or GIF copy must not replace its source file"
      )
    }
  }

  private func prepareSessionSourceIfNeeded(
    for state: VideoEditorState
  ) async throws -> VideoEditorSessionStore.PreparedSourceSnapshot? {
    // A restored session already owns an immutable master source. Reuse it for
    // every later save so the recipe is never applied to a rendered output.
    guard sessionData == nil else { return nil }

    return try await VideoEditorSessionStore.shared.prepareSourceSnapshot(
      from: state.editingSourceURL,
      for: state.originalURL
    )
  }

  /// Cache and persist the recipe after the rendered file has been replaced.
  /// Caching happens even if the disk manifest fails, so the current Quick Access
  /// session can still be reopened and promoted in this app process.
  @discardableResult
  private func persistSessionAfterCommit(
    for state: VideoEditorState,
    preparedSource: VideoEditorSessionStore.PreparedSourceSnapshot?
  ) async -> Bool {
    guard let sourceSnapshotURL = sessionData?.sourceSnapshotURL ?? preparedSource?.sourceURL else {
      DiagnosticLogger.shared.log(
        .warning,
        .editor,
        "Video Editor session cache skipped; source snapshot missing"
      )
      return false
    }

    let snapshot = VideoEditorSessionData.snapshot(
      from: state,
      sourceSnapshotURL: sourceSnapshotURL
    )
    if let quickAccessItemID {
      VideoEditorManager.shared.saveSessionData(snapshot, for: quickAccessItemID)
    } else {
      VideoEditorManager.shared.saveSessionData(snapshot, for: state.originalURL)
    }
    sessionData = snapshot

    let didPersist = await VideoEditorSessionStore.shared.persistOffMain(
      snapshot,
      for: state.originalURL,
      preparedSourceDirectory: preparedSource?.directoryURL
    )
    guard didPersist else {
      DiagnosticLogger.shared.log(
        .warning,
        .editor,
        "Video Editor session disk persistence failed; in-memory session retained",
        context: ["fileName": state.originalURL.lastPathComponent]
      )
      return false
    }

    if let reloaded = VideoEditorSessionStore.shared.load(for: state.originalURL) {
      sessionData = reloaded
      if let quickAccessItemID {
        VideoEditorManager.shared.saveSessionData(reloaded, for: quickAccessItemID)
      } else {
        VideoEditorManager.shared.saveSessionData(reloaded, for: state.originalURL)
      }
    } else if preparedSource != nil {
      // The pending source directory has been moved into its stable package.
      // Keep the in-memory fallback usable even if the immediate signature
      // re-read races with a filesystem timestamp update.
      let committedSourceURL = VideoEditorSessionStore.shared.committedSourceSnapshotURL(
        for: state.originalURL,
        fileName: sourceSnapshotURL.lastPathComponent
      )
      let committedSnapshot = VideoEditorSessionData.snapshot(
        from: state,
        sourceSnapshotURL: committedSourceURL
      )
      sessionData = committedSnapshot
      if let quickAccessItemID {
        VideoEditorManager.shared.saveSessionData(committedSnapshot, for: quickAccessItemID)
      } else {
        VideoEditorManager.shared.saveSessionData(committedSnapshot, for: state.originalURL)
      }
    }
    return true
  }

  private func progressMessage(
    for progress: Float,
    operation: VideoEditorProgressOperation = .exportVideo
  ) -> String {
    switch progress {
    case 0 ..< 0.1:
      operation.initialStatusMessage
    case 0.1 ..< 0.3:
      L10n.VideoEditor.processingVideo
    case 0.3 ..< 0.7:
      L10n.VideoEditor.applyingEffects
    case 0.7 ..< 0.9:
      L10n.VideoEditor.encodingFrames
    case 0.9 ..< 1.0:
      L10n.VideoEditor.finalizing
    default:
      L10n.VideoEditor.completing
    }
  }

  private func showExportError(_ error: Error) {
    DiagnosticLogger.shared.logError(.export, error, "Export error shown to user")
    guard let window else { return }

    let alert = NSAlert()
    alert.messageText = L10n.VideoEditor.exportFailedTitle
    alert.informativeText = error.localizedDescription
    alert.alertStyle = .critical
    alert.addButton(withTitle: L10n.Common.ok)
    alert.beginSheetModal(for: window)
  }

  private func showReplaceOriginalPermissionFallback(_ error: Error) {
    guard let window else { return }

    let alert = NSAlert()
    alert.messageText = L10n.VideoEditor.cannotReplaceOriginalTitle
    alert.informativeText = L10n.VideoEditor.cannotReplaceOriginalMessage(error.localizedDescription)
    alert.alertStyle = .warning
    alert.addButton(withTitle: L10n.VideoEditor.saveAsCopy)
    alert.addButton(withTitle: L10n.Common.cancel)

    alert.beginSheetModal(for: window) { [weak self] response in
      guard let self else { return }
      if response == .alertFirstButtonReturn {
        performSaveAsCopy()
      }
    }
  }

  // MARK: - Post-Export Cloud Upload Offer

  private func offerPostExportUpload(for fileURL: URL, completion: @escaping () -> Void) {
    guard CloudManager.shared.isConfigured,
          QuickAccessActionConfigurationStore.shared.isEnabled(.uploadToCloud),
          let window
    else {
      completion()
      return
    }

    let alert = NSAlert()
    alert.messageText = L10n.AnnotateUI.uploadToCloud
    alert.informativeText = L10n.VideoEditor.uploadToCloudMessage
    alert.alertStyle = .informational
    alert.addButton(withTitle: L10n.AnnotateUI.uploadToCloud)
    alert.addButton(withTitle: L10n.Common.cancel)

    alert.beginSheetModal(for: window) { [weak self] response in
      guard let self else {
        completion()
        return
      }

      if response == .alertFirstButtonReturn {
        performPostExportUpload(fileURL: fileURL, completion: completion)
      } else {
        completion()
      }
    }
  }

  private func performPostExportUpload(fileURL: URL, completion: @escaping () -> Void) {
    guard let state else {
      completion()
      return
    }

    let progressOperation: VideoEditorProgressOperation = .uploadToCloud
    state.progressOperation = progressOperation
    state.isExporting = true
    state.exportProgress = 0.8
    state.exportStatusMessage = progressOperation.initialStatusMessage

    Task {
      do {
        let fileAccess = SandboxFileAccessManager.shared.beginAccessingURL(fileURL)
        defer { fileAccess.stop() }

        let result = try await CloudManager.shared.upload(fileURL: fileURL)

        // Store cloud link on pasteboard
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(result.publicURL.absoluteString, forType: .string)

        SoundManager.play("Pop")

        // Sync with Quick Access item if linked
        if let itemId = self.quickAccessItemID {
          QuickAccessManager.shared.setCloudURL(id: itemId, url: result.publicURL, key: result.key)
        }

        state.isExporting = false
        completion()
      } catch {
        state.isExporting = false
        self.showExportError(error)
        completion()
      }
    }
  }

  private func forceClose() {
    state?.pause()
    state?.hasUnsavedChanges = false
    window?.close()
  }

  private func invalidateEditedCloudState() {
    state?.cloudURL = nil
    if let quickAccessItemID {
      QuickAccessManager.shared.markCloudStale(id: quickAccessItemID)
    }
  }

  // MARK: - Cancel Action

  private func handleCancel() {
    guard let window else { return }

    if let state, state.hasUnsavedChanges {
      showUnsavedChangesAlert(for: window)
    } else {
      forceClose()
    }
  }
}
