//
//  RecordingCoordinator.swift
//  Snapzy
//
//  Coordinates the recording flow between UI components and recording manager
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class RecordingCoordinator: ObservableObject {
  static let shared = RecordingCoordinator()

  @Published private(set) var isActive = false

  private(set) var toolbarWindow: RecordingToolbarWindow?
  private var regionOverlayWindows: [RecordingRegionOverlayWindow] = []
  private var selectionAspectRatio: CGFloat?
  private var selectedRect: CGRect?
  private var selectedWindowTarget: WindowCaptureTarget?
  private let captureManager = ScreenCaptureManager.shared
  private let recorder = ScreenRecordingManager.shared
  private var isStartingRecording = false
  // Invalidated before Stop/Cancel/Restart suspends, even while the toolbar survives.
  private var recordingGeneration = UUID()
  private var localEscapeMonitor: Any?
  private var globalEscapeMonitor: Any?
  private var onSessionEnded: (@MainActor () -> Void)?
  private let focusLifecycle = RecordingFocusLifecycle(
    session: RecordingFocusSession(runner: ShortcutsRecordingFocusRunner())
  )
  private var focusRenewal: Task<Void, Never>?
  private var recorderStateObservation: AnyCancellable?
  private var isRestartingRecording = false

  // Annotation overlay
  private var annotationToolbarWindow: RecordingAnnotationToolbarWindow?
  private var annotationOverlayWindow: RecordingAnnotationOverlayWindow?

  // Click highlight overlay
  private var clickHighlightWindow: MouseClickHighlightWindow?
  private var clickHighlightService: MouseClickHighlightService?

  // Keystroke overlay
  private var keystrokeOverlayWindow: KeystrokeOverlayWindow?
  private var keystrokeMonitorService: KeystrokeMonitorService?

  private var cameraOverlayWindow: RecordingCameraOverlayWindow?

  // Охрана записи по образцу эталона: сон дисплея, место на диске, отключение микрофона.
  private let displaySleepAssertion = RecordingDisplaySleepAssertion()
  private let diskSpaceMonitor = RecordingDiskSpaceMonitor()
  private let microphoneDisconnectMonitor = RecordingMicrophoneDisconnectMonitor()
  /// Audio Recording Failed: системный звук перестал приходить.
  private var systemAudioWatchdog = RecordingSystemAudioWatchdog()
  private var systemAudioWatchdogTimer: Timer?
  /// Merging audio... на время сведения дорожек после остановки.
  private let audioMergeProgressPanel = RecordingAudioMergeProgressPanel()
  /// Идущая конвертация в GIF, которую можно остановить из Quick Access.
  private var gifConversions = RecordingGIFConversions()
  private var activeSaveDirectory: URL?
  typealias StopNotice = (title: String, message: String)
  private var isStopPending = false

  private struct ToolbarConfiguration {
    let format: VideoFormat
    let quality: VideoQuality
    let maxResolution: RecordingMaxResolution
    let captureAudio: Bool
    let captureMicrophone: Bool
    let microphoneDeviceID: String
    let captureCamera: Bool
    let cameraDeviceID: String
    let outputMode: RecordingOutputMode
    let showCursor: Bool
    let highlightClicks: Bool
    let showKeystrokes: Bool
    let dimNonSelectedArea: Bool
  }

  init() {
    // Live-apply the dim preference while recording so toggling it in Settings (or the
    // toolbar options) takes effect immediately, mirroring the hover-bar live toggle.
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(dimPreferenceDidChange),
      name: UserDefaults.didChangeNotification,
      object: nil
    )
    recorder.onAudioMergeWillBegin = { [weak self] cancellation in
      self?.audioMergeProgressPanel.begin(cancellation: cancellation)
    }
    recorder.onAudioMergeDidEnd = { [weak self] in
      self?.audioMergeProgressPanel.end()
    }
    recorder.onStreamStoppedUnexpectedly = { [weak self] in
      self?.stopRecording(notice: (L10n.RecordingParity.stoppedTitle, L10n.RecordingParity.stoppedUnexpectedly))
    }
    recorderStateObservation = recorder.$state.sink { [weak self] state in
      guard let self, !self.isRestartingRecording else { return }
      if state == .stopping || (state == .idle && !self.isStartingRecording) {
        self.releaseRecordingFocus()
      }
    }
  }

  private let tempCaptureManager = TempCaptureManager.shared

  private var includeOwnAppInScreenshots: Bool {
    UserDefaults.standard.bool(forKey: PreferencesKeys.screenshotIncludeOwnApp)
  }

  private var showsCursorInScreenshots: Bool {
    UserDefaults.standard.object(forKey: PreferencesKeys.screenshotShowCursor) as? Bool ?? false
  }

  private var includeOwnAppInRecordings: Bool {
    UserDefaults.standard.bool(forKey: PreferencesKeys.recordingIncludeOwnApp)
  }

  private func recordingCaptureExclusionConfiguration()
    -> (excludeOwnApplication: Bool, excludedWindowIDs: [CGWindowID]) {
    let excludeOwnApplication = !includeOwnAppInRecordings
    if excludeOwnApplication {
      return (true, [])
    }

    // Toolbar and region overlays register as `.recordingControls`.
    let windowIDs = CaptureChromeWindowRegistry.shared.windowIDs(roles: [.recordingControls])
    return (false, windowIDs.sorted())
  }

  // MARK: - Recording Area Persistence

  /// Save recording area rect to UserDefaults
  private func saveLastAreaRect(_ rect: CGRect) {
    let rectDict: [String: CGFloat] = [
      "x": rect.origin.x,
      "y": rect.origin.y,
      "width": rect.width,
      "height": rect.height,
    ]
    UserDefaults.standard.set(rectDict, forKey: PreferencesKeys.recordingLastAreaRect)
  }

  /// Load last recording area rect from UserDefaults
  func loadLastAreaRect() -> CGRect? {
    guard let rectDict = UserDefaults.standard.dictionary(forKey: PreferencesKeys.recordingLastAreaRect),
          let x = rectDict["x"] as? CGFloat,
          let y = rectDict["y"] as? CGFloat,
          let width = rectDict["width"] as? CGFloat,
          let height = rectDict["height"] as? CGFloat else {
      return nil
    }

    let rect = CGRect(x: x, y: y, width: width, height: height)

    // Validate rect is still visible on current screens
    guard isRectVisibleOnScreen(rect) else {
      return nil
    }

    return rect
  }

  /// Check if rect is visible on any connected screen
  private func isRectVisibleOnScreen(_ rect: CGRect) -> Bool {
    for screen in NSScreen.screens {
      if screen.frame.intersects(rect) {
        return true
      }
    }
    return false
  }

  /// Whether the floating recording controls bar should be shown during recording.
  /// Shared source of truth with `AppStatusBarController` via `RecordingToolbarPreferences`.
  private var isHoverBarVisiblePreference: Bool {
    RecordingToolbarPreferences.hoverBarVisible()
  }

  // MARK: - Public API

  func stopFromStatusItem() {
    DiagnosticLogger.shared.log(.debug, .recording, "Stop requested from status item", context: [
      "recorderState": "\(recorder.state)",
    ])
    switch recorder.state {
    case .recording, .paused:
      stopRecording()
    case .preparing:
      cancel()
    case .idle, .stopping:
      break
    }
  }

  /// Toggle pen/annotations overlay from global shortcut.
  func togglePenFromShortcut() {
    guard isActive, let toolbarWindow else { return }
    toolbarWindow.annotationState.isAnnotationEnabled.toggle()
  }

  /// «Toggle Camera Fullscreen»: камера на весь записываемый дисплей и обратно.
  /// false — сессия не идёт или камера выключена.
  @discardableResult
  func toggleCameraFullscreenFromShortcut() -> Bool {
    guard isActive, let cameraOverlayWindow else { return false }
    cameraOverlayWindow.toggleFullscreen()
    return true
  }

  /// Restart/Re-record from global shortcut.
  func restartFromShortcut() {
    guard isActive else { return }
    requestRestartRecording()
  }

  /// Cancel/Delete current recording from global shortcut.
  func deleteFromShortcut() {
    guard isActive else { return }
    requestDeleteRecording()
  }

  /// Start recording flow after area selection
  func showToolbar(
    for rect: CGRect,
    captureMode: RecordingCaptureMode = .area,
    windowTarget: WindowCaptureTarget? = nil,
    onSessionEnded: (@MainActor () -> Void)? = nil
  ) {
    guard !isActive else {
      DiagnosticLogger.shared.log(.debug, .recording, "Recording toolbar request ignored: coordinator active")
      onSessionEnded?()
      return
    }
    isActive = true
    self.onSessionEnded = onSessionEnded
    presentToolbar(
      for: rect,
      captureMode: captureMode,
      windowTarget: windowTarget,
      configuration: nil
    )
  }

  private func setupEscapeMonitors() {
    removeEscapeMonitors()

    localEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      if self?.handlePreRecordKeyEvent(event) == true {
        return nil
      }
      return event
    }

    globalEscapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard self?.isPreRecordKeyEvent(event) == true else { return }
      DispatchQueue.main.async {
        _ = self?.handlePreRecordKeyEvent(event)
      }
    }
  }

  /// A capture-area selection overlay (⇧⌘4) can be presented ON TOP of the pre-record toolbar.
  /// It is the topmost overlay, so it must win Escape (LIFO dismissal). Our app-level `NSEvent`
  /// monitor fires before the overlay's key-window `keyDown`, so we must explicitly yield Escape
  /// to it while it is presenting instead of consuming the event ourselves.
  private var isCaptureAreaOverlayPresenting: Bool {
    AreaSelectionController.shared.isPresenting
  }

  private func isPreRecordKeyEvent(_ event: NSEvent) -> Bool {
    if event.keyCode == 53 { // Escape key — yield to a topmost capture-area overlay
      return !isCaptureAreaOverlayPresenting
    }
    return recordStartMode(for: event) != nil || isApplicationToggleEvent(event)
  }

  private func recordStartMode(for event: NSEvent) -> RecordingOutputMode? {
    guard recorder.state == .idle, !isStartingRecording,
          let toolbarWindow, toolbarWindow.isVisible,
          !toolbarWindow.state.isPreparingToRecord, !isCaptureAreaOverlayPresenting,
          RunLoop.current.currentMode != .eventTracking,
          // Return в поле размера применяет значение, а не запускает запись.
          !(NSApp.keyWindow?.firstResponder is NSText) else { return nil }
    return RecordingPreRecordShortcut.outputMode(keyCode: event.keyCode, modifiers: event.modifierFlags, isRepeat: event.isARepeat)
  }

  @discardableResult
  private func handlePreRecordKeyEvent(_ event: NSEvent) -> Bool {
    if event.keyCode == 53 { // Escape key
      // LIFO: let a topmost capture-area overlay handle Escape first. Do not consume it here.
      if isCaptureAreaOverlayPresenting { return false }
      handleEscapeKey()
      return true
    }

    if nudgeSelection(with: event) { return true }

    if let mode = recordStartMode(for: event), let toolbarWindow {
      toolbarWindow.state.outputMode = mode
      UserDefaults.standard.set(mode.rawValue, forKey: PreferencesKeys.recordingOutputMode)
      startRecording()
      return true
    }

    guard isApplicationToggleEvent(event) else { return false }
    // LIFO: a topmost capture overlay we do not own (e.g. a ⇧⌘4 screenshot selection
    // presenting over the pre-record toolbar) keeps its session — replacing it here would
    // strand the screenshot flow. Mirrors the Escape yield above.
    if isCaptureAreaOverlayPresenting,
       AreaSelectionController.shared.selectionMode != .recording {
      return false
    }
    toggleApplicationCaptureMode()
    return true
  }

  /// Стрелки двигают область до старта, ⌘ со стрелками меняет размер, ⇧ – шаг 10 pt.
  /// Только в своём приложении и не во время ввода текста в полях панели.
  private func nudgeSelection(with event: NSEvent) -> Bool {
    guard recorder.state == .idle, !isStartingRecording, !isCaptureAreaOverlayPresenting,
          let toolbarWindow, toolbarWindow.isVisible, !toolbarWindow.state.isPreparingToRecord,
          toolbarWindow.captureMode != .application, selectedWindowTarget == nil,
          let rect = selectedRect,
          !(NSApp.keyWindow?.firstResponder is NSText) else { return false }
    let bounds = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
    guard let nudged = RecordingRegionGeometry.nudged(
      rect, keyCode: event.keyCode, modifiers: event.modifierFlags, minimumSize: 50, bounds: bounds
    ) else { return false }
    updateSelectedRect(nudged)
    return true
  }

  private func isApplicationToggleEvent(_ event: NSEvent) -> Bool {
    guard recorder.state == .idle, !isStartingRecording else { return false }
    guard toolbarWindow != nil else { return false }
    return CaptureOverlayShortcutSettings.matchesRecordingApplicationCaptureShortcut(event)
  }

  private func toggleApplicationCaptureMode() {
    guard let toolbarWindow else { return }
    let nextMode: RecordingCaptureMode = toolbarWindow.captureMode == .application ? .area : .application
    toolbarWindow.captureMode = nextMode
    handleCaptureModeChange(nextMode)
  }

  /// Handle ESC key before recording starts.
  private func handleEscapeKey() {
    cancel()
  }

  private func removeEscapeMonitors() {
    if let monitor = localEscapeMonitor {
      NSEvent.removeMonitor(monitor)
      localEscapeMonitor = nil
    }
    if let monitor = globalEscapeMonitor {
      NSEvent.removeMonitor(monitor)
      globalEscapeMonitor = nil
    }
  }

  @discardableResult
  func cancel() -> Task<Void, Never>? {
    guard canDiscardRecording(in: recorder.state) else { return nil }
    recordingGeneration = UUID()
    let generation = recordingGeneration
    releaseRecordingFocus()
    DiagnosticLogger.shared.log(.info, .recording, "Recording coordinator cancel requested", context: [
      "isActive": "\(isActive)",
      "recorderState": "\(recorder.state)",
    ])
    return Task {
      guard recordingGeneration == generation, canDiscardRecording(in: recorder.state) else { return }
      await recorder.cancelRecording()
      guard recordingGeneration == generation else { return }
      cleanup()
    }
  }

  private func presentToolbar(
    for rect: CGRect,
    captureMode: RecordingCaptureMode,
    windowTarget: WindowCaptureTarget?,
    configuration: ToolbarConfiguration?
  ) {
    DiagnosticLogger.shared.log(.info, .recording, "Recording toolbar shown", context: [
      "mode": captureMode.rawValue,
      "rect": "\(Int(rect.width))x\(Int(rect.height))",
      "origin": "\(Int(rect.origin.x)),\(Int(rect.origin.y))",
      "windowTarget": windowTarget == nil ? "false" : "true",
    ])

    updateSelectedTarget(
      rect: rect,
      captureMode: captureMode,
      windowTarget: windowTarget,
      syncToolbarMode: false
    )

    let toolbar = RecordingToolbarWindow(anchorRect: rect)
    selectionAspectRatio = nil
    toolbar.state.selectionRect = rect
    toolbar.state.onResizeSelection = { [weak self] width, height, locked in
      guard let self, let current = self.selectedRect, let screen = NSScreen.screens.first(where: { $0.frame.intersects(current) }) else { return }
      self.updateSelectedRect(OwnShotCaptureGeometry.resized(current, width: width, height: height, locked: locked, within: screen.frame, keepingCenter: true))
    }
    toolbar.state.onAspectRatioChanged = { [weak self] ratio in
      guard let self else { return }
      self.selectionAspectRatio = ratio
      self.regionOverlayWindows.forEach { $0.setAspectRatio(ratio) }
      guard let ratio, let current = self.selectedRect,
            let screen = NSScreen.screens.first(where: { $0.frame.intersects(current) }) else { return }
      self.updateSelectedRect(OwnShotCaptureGeometry.applyingAspectRatio(ratio, to: current, within: screen.frame))
    }
    configureToolbarCallbacks(toolbar)
    applyToolbarConfiguration(configuration, to: toolbar)
    toolbar.captureMode = captureMode
    toolbarWindow = toolbar

    showRegionOverlay(for: rect, interactionEnabled: captureMode != .application)
    setupEscapeMonitors()
  }

  private func configureToolbarCallbacks(_ toolbar: RecordingToolbarWindow) {
    toolbar.onRecord = { [weak self] in
      self?.startRecording()
    }
    toolbar.onCapture = { [weak self] in
      self?.captureScreenshot()
    }
    toolbar.onCancel = { [weak self] in
      self?.cancel()
    }
    toolbar.onDelete = { [weak self] in
      self?.requestDeleteRecording()
    }
    toolbar.onRestart = { [weak self] in
      self?.requestRestartRecording()
    }
    toolbar.onStop = { [weak self] in
      self?.stopRecording()
    }
    toolbar.onCaptureModeChanged = { [weak self] mode in
      self?.handleCaptureModeChange(mode)
    }
  }

  private func currentToolbarConfiguration() -> ToolbarConfiguration? {
    guard let toolbarWindow else { return nil }
    return ToolbarConfiguration(
      format: toolbarWindow.selectedFormat,
      quality: toolbarWindow.selectedQuality,
      maxResolution: toolbarWindow.selectedMaxResolution,
      captureAudio: toolbarWindow.captureAudio,
      captureMicrophone: toolbarWindow.captureMicrophone,
      microphoneDeviceID: toolbarWindow.microphoneDeviceID,
      captureCamera: toolbarWindow.captureCamera,
      cameraDeviceID: toolbarWindow.cameraDeviceID,
      outputMode: toolbarWindow.outputMode,
      showCursor: toolbarWindow.state.showCursor,
      highlightClicks: toolbarWindow.state.highlightClicks,
      showKeystrokes: toolbarWindow.state.showKeystrokes,
      dimNonSelectedArea: toolbarWindow.state.dimNonSelectedArea
    )
  }

  private func applyToolbarConfiguration(
    _ configuration: ToolbarConfiguration?,
    to toolbar: RecordingToolbarWindow
  ) {
    if let configuration {
      toolbar.selectedFormat = configuration.format
      toolbar.selectedQuality = configuration.quality
      toolbar.selectedMaxResolution = configuration.maxResolution
      toolbar.captureAudio = configuration.captureAudio
      toolbar.captureMicrophone = configuration.captureMicrophone
      toolbar.microphoneDeviceID = configuration.microphoneDeviceID
      toolbar.captureCamera = configuration.captureCamera
      toolbar.cameraDeviceID = configuration.cameraDeviceID
      toolbar.outputMode = configuration.outputMode
      toolbar.state.showCursor = configuration.showCursor
      toolbar.state.highlightClicks = configuration.highlightClicks
      toolbar.state.showKeystrokes = configuration.showKeystrokes
      toolbar.state.dimNonSelectedArea = configuration.dimNonSelectedArea
      return
    }

    if let formatString = UserDefaults.standard.string(forKey: PreferencesKeys.recordingFormat),
       let format = VideoFormat(rawValue: formatString) {
      toolbar.selectedFormat = format
    }
  }

  private func updateSelectedTarget(
    rect: CGRect,
    captureMode: RecordingCaptureMode,
    windowTarget: WindowCaptureTarget?,
    syncToolbarMode: Bool = true
  ) {
    selectedRect = rect
    toolbarWindow?.state.selectionRect = rect
    selectedWindowTarget = windowTarget
    if RecordingDisplaySelectionLogic.shouldSaveLastArea(for: captureMode) {
      saveLastAreaRect(rect)
    }

    let interactionEnabled = captureMode != .application
    for overlay in regionOverlayWindows {
      overlay.updateHighlightRect(rect)
      overlay.setInteractionEnabledIfNeeded(interactionEnabled)
    }

    if syncToolbarMode {
      if toolbarWindow?.captureMode != captureMode {
        toolbarWindow?.captureMode = captureMode
      }
      toolbarWindow?.updateAnchorRect(rect)
    }
  }

  /// Lightweight path for drag/resize events — updates overlay visuals and
  /// toolbar position without the expensive work (UserDefaults persistence,
  /// @Published setters, cursor rect invalidation).
  /// Toolbar repositioning is cheap here because fixes 5+6 removed
  /// orderFrontRegardless() and cached fittingSize.
  private func updateOverlayHighlightsOnly(_ rect: CGRect) {
    selectedRect = rect
    toolbarWindow?.state.selectionRect = rect
    for overlay in regionOverlayWindows {
      overlay.updateHighlightRect(rect)
    }
    toolbarWindow?.updateAnchorRect(rect)
  }

  /// Finalize a drag/resize: persist the rect and reposition the toolbar.
  private func finalizeDragOrResize() {
    guard let rect = selectedRect else { return }
    if RecordingDisplaySelectionLogic.shouldSaveLastArea(for: toolbarWindow?.captureMode ?? .area) {
      saveLastAreaRect(rect)
    }
    toolbarWindow?.updateAnchorRect(rect)
  }

  private func handleSelectionResult(
    _ selection: AreaSelectionResult?,
    configuration: ToolbarConfiguration?,
    cancellationLog: String
  ) {
    guard let selection else {
      DiagnosticLogger.shared.log(.info, .recording, cancellationLog)
      cleanup()
      return
    }

    let captureMode: RecordingCaptureMode
    let windowTarget: WindowCaptureTarget?
    switch selection.target {
    case .rect:
      captureMode = .area
      windowTarget = nil
    case .display:
      captureMode = .fullscreen
      windowTarget = nil
    case .window(let target):
      captureMode = .application
      windowTarget = target
    }

    presentToolbar(
      for: selection.rect,
      captureMode: captureMode,
      windowTarget: windowTarget,
      configuration: configuration
    )
  }

  private func restartSelection(for mode: RecordingCaptureMode) {
    let configuration = currentToolbarConfiguration()
    DiagnosticLogger.shared.log(.info, .recording, "Recording selection restart requested", context: [
      "mode": mode.rawValue,
      "hasToolbar": "\(toolbarWindow != nil)",
    ])

    removeEscapeMonitors()
    closePreRecordUI()

    let applicationConfiguration = AreaSelectionApplicationConfiguration(
      prefetchedContentTask: captureManager.prefetchShareableContent(),
      excludeOwnApplication: !includeOwnAppInRecordings
    )

    if mode == .fullscreen {
      // Stay on the display the user already picked (a display click, or an area mostly on
      // it); fall back to the active screen only when nothing is selected yet.
      let fullscreenRect = RecordingDisplaySelectionLogic.displayFrame(
        bestMatching: selectedRect,
        screenFrames: NSScreen.screens.map(\.frame)
      ) ?? ScreenUtility.activeScreen().frame
      presentToolbar(
        for: fullscreenRect,
        captureMode: .fullscreen,
        windowTarget: nil,
        configuration: configuration
      )
      return
    }

    AreaSelectionController.shared.startSelection(
      mode: .recording,
      backdrops: [:],
      applicationConfiguration: applicationConfiguration,
      initialInteractionMode: mode == .application ? .applicationWindow : .manualRegion
    ) { [weak self] selection in
      guard let self else { return }
      handleSelectionResult(
        selection,
        configuration: configuration,
        cancellationLog: "Recording reselection cancelled"
      )
    }
  }

  private func closePreRecordUI() {
    for overlay in regionOverlayWindows {
      overlay.close()
    }
    regionOverlayWindows.removeAll()

    toolbarWindow?.onRecord = nil
    toolbarWindow?.onCapture = nil
    toolbarWindow?.onCancel = nil
    toolbarWindow?.onDelete = nil
    toolbarWindow?.onRestart = nil
    toolbarWindow?.onStop = nil
    toolbarWindow?.onCaptureModeChanged = nil
    toolbarWindow?.onAnnotateButtonOffsetChanged = nil
    toolbarWindow?.state.onResizeSelection = nil
    toolbarWindow?.state.onAspectRatioChanged = nil
    toolbarWindow?.close()
    toolbarWindow = nil
  }

  /// Handle capture mode toggle between area and fullscreen
  private func handleCaptureModeChange(_ mode: RecordingCaptureMode) {
    DiagnosticLogger.shared.log(.info, .recording, "Recording capture mode changed", context: [
      "mode": "\(mode)",
    ])

    switch mode {
    case .fullscreen:
      restartSelection(for: .fullscreen)
    case .area:
      restartSelection(for: .area)
    case .application:
      restartSelection(for: .application)
    }
  }

  // MARK: - Discard Confirmation

  nonisolated enum DiscardAction: String {
    case restart
    case delete
  }

  /// Recordings shorter than this are discarded without asking, so a quick retake stays one click.
  private static let discardConfirmationMinimumSeconds = 3

  /// Guards against stacking alerts when the button or shortcut is triggered again while one is open.
  private var isConfirmingDiscard = false

  private func canDiscardRecording(in state: RecordingState) -> Bool {
    !isStopPending && state != .stopping
  }

  private func requestRestartRecording() {
    guard confirmDiscardIfNeeded(.restart) else { return }
    restartRecording()
  }

  private func requestDeleteRecording() {
    guard confirmDiscardIfNeeded(.delete) else { return }
    deleteRecording()
  }

  /// Asks the user before throwing away a recording in progress.
  /// The recording is paused while the alert is up so the wait doesn't end up in the video.
  /// Returns `true` when the caller may go ahead and discard.
  func confirmDiscardIfNeeded(
    _ action: DiscardAction,
    recording: (state: RecordingState, elapsedSeconds: Int)? = nil,
    present: (() -> Bool)? = nil
  ) -> Bool {
    let state = recording?.state ?? recorder.state
    guard !isConfirmingDiscard, canDiscardRecording(in: state) else { return false }
    let elapsedSeconds = recording?.elapsedSeconds ?? recorder.elapsedSeconds
    guard state.isPauseResumeEligible, elapsedSeconds >= Self.discardConfirmationMinimumSeconds else {
      return true
    }

    isConfirmingDiscard = true
    defer { isConfirmingDiscard = false }
    let generation = recordingGeneration

    let pausedForAlert = state == .recording
    if pausedForAlert {
      recorder.pauseRecording()
    }

    let confirmed = present?() ?? presentDiscardConfirmation(action)
    DiagnosticLogger.shared.log(.info, .recording, "Recording discard confirmation answered", context: [
      "action": action.rawValue,
      "confirmed": "\(confirmed)",
      "elapsedSeconds": "\(recorder.elapsedSeconds)",
    ])

    guard isActive, generation == recordingGeneration, canDiscardRecording(in: recorder.state) else { return false }
    if !confirmed, pausedForAlert, recorder.state == .paused {
      recorder.resumeRecording()
    }
    return confirmed
  }

  private func presentDiscardConfirmation(_ action: DiscardAction) -> Bool {
    let alert = NSAlert()
    alert.alertStyle = .warning
    switch action {
    case .restart:
      alert.messageText = L10n.Recording.restartConfirmTitle
      alert.informativeText = L10n.Recording.restartConfirmMessage
    case .delete:
      alert.messageText = L10n.Recording.deleteConfirmTitle
      alert.informativeText = L10n.Recording.deleteConfirmMessage
    }
    // Safe choice first so Return keeps the recording; Escape also maps to it.
    let keepButton = alert.addButton(withTitle: L10n.Recording.keepRecordingButton)
    keepButton.keyEquivalent = "\r"
    let discardButton = alert.addButton(
      withTitle: action == .restart ? L10n.Recording.restartConfirmButton : L10n.Recording.deleteConfirmButton
    )
    discardButton.keyEquivalent = ""
    discardButton.hasDestructiveAction = true
    // The toolbar floats at pop-up-menu level; keep the alert above it.
    alert.window.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
    NSApp.activate(ignoringOtherApps: true)

    return alert.runModal() == .alertSecondButtonReturn
  }

  /// Delete current recording and close
  private func deleteRecording() {
    recordingGeneration = UUID()
    let generation = recordingGeneration
    releaseRecordingFocus()
    DiagnosticLogger.shared.log(.info, .recording, "Recording delete requested", context: [
      "recorderState": "\(recorder.state)",
    ])
    Task {
      guard recordingGeneration == generation, canDiscardRecording(in: recorder.state) else { return }
      await recorder.cancelRecording()
      guard recordingGeneration == generation else { return }
      SoundManager.play("Funk")
      cleanup()
    }
  }

  /// Restart recording from scratch (cancel current and start new)
  private func restartRecording() {
    guard let rect = selectedRect, let window = toolbarWindow else {
      DiagnosticLogger.shared.log(.warning, .recording, "Recording restart ignored: missing selection or toolbar")
      return
    }

    recordingGeneration = UUID()
    let generation = recordingGeneration
    isRestartingRecording = true
    let savedFormat = window.selectedFormat
    let savedQuality = window.selectedQuality
    let maxResolution = window.selectedMaxResolution
    let savedCaptureAudio = window.captureAudio
    let savedCaptureMicrophone = window.captureMicrophone
    let savedMicrophoneDeviceID = window.microphoneDeviceID
    let savedCaptureCamera = window.captureCamera
    let savedCameraDeviceID = window.cameraDeviceID
    let savedShowCursor = window.state.showCursor
    DiagnosticLogger.shared.log(.info, .recording, "Recording restart requested", context: [
      "format": savedFormat.rawValue,
      "quality": savedQuality.rawValue,
      "systemAudio": "\(savedCaptureAudio)",
      "microphone": "\(savedCaptureMicrophone)",
      "microphoneDevice": savedMicrophoneDeviceID,
      "camera": "\(savedCaptureCamera)",
      "cameraDevice": savedCameraDeviceID,
      "showCursor": "\(savedShowCursor)",
      "rect": "\(Int(rect.width))x\(Int(rect.height))",
    ])

    Task {
      defer {
        if recordingGeneration == generation { isRestartingRecording = false }
      }
      guard isCurrentRecordingStart(generation, window: window) else { return }
      // Cancel current recording
      await recorder.cancelRecording()
      guard isCurrentRecordingStart(generation, window: window) else { return }

      // Small delay to ensure cleanup completes
      try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
      guard isCurrentRecordingStart(generation, window: window) else { return }

      // Re-prepare and start recording with same settings
      do {
        var fps = UserDefaults.standard.integer(forKey: PreferencesKeys.recordingFPS)
        if fps == 0 { fps = 30 }

        guard let saveDirectory = self.resolveSaveDirectoryForOperation() else {
          DiagnosticLogger.shared.log(.warning, .recording, "Recording restart blocked: no save directory access")
          self.releaseRecordingFocus()
          self.showSaveLocationPermissionAlert()
          return
        }
        self.activeSaveDirectory = saveDirectory

        let exclusionConfig = self.recordingCaptureExclusionConfiguration()

        guard await OwnShotRecordingCountdown.wait(
          seconds: UserDefaults.standard.bool(forKey: OwnShotRecordingPreferenceKeys.showCountdown) ? 3 : 0,
          isCurrent: { self.isCurrentRecordingStart(generation, window: window) },
          onCancel: { self.cancel() }
        ) else { return }

        let savePlan = try self.tempCaptureManager.makeRecordingSavePlan(
          exportDirectory: saveDirectory
        )

        try await recorder.prepareRecording(
          rect: rect,
          windowTarget: self.selectedWindowTarget,
          format: savedFormat,
          quality: savedQuality,
          fps: fps,
          maxResolution: maxResolution,
          captureSystemAudio: savedCaptureAudio,
          captureMicrophone: savedCaptureMicrophone,
          microphoneDeviceID: savedMicrophoneDeviceID,
          showCursor: savedShowCursor,
          saveDirectory: savePlan.finalDirectory,
          processingSession: savePlan.processingSession,
          excludeDesktopIcons: DesktopIconManager.shared.isIconHidingEnabled,
          excludeDesktopWidgets: DesktopIconManager.shared.isWidgetHidingEnabled,
          excludeOwnApplication: exclusionConfig.excludeOwnApplication,
          excludedWindowIDs: exclusionConfig.excludedWindowIDs,
          context: self.selectedWindowTarget
            .map { CaptureContext.fromPID($0.ownerPID, windowTitle: $0.title) } ?? CaptureContext.fromFrontmostApp()
        )

        guard isCurrentRecordingStart(generation, window: window) else { return }
        try await self.setupCameraOverlay(
          for: rect,
          enabled: savedCaptureCamera,
          deviceID: savedCameraDeviceID
        )
        guard isCurrentRecordingStart(generation, window: window) else { return }
        guard try await acquireRecordingFocus(generation: generation, window: window) else { return }
        try await recorder.startRecording()
        guard isCurrentRecordingStart(generation, window: window) else { return }
        removeEscapeMonitors()
        guard await completeRecordingStart(for: rect) else { return }
        DiagnosticLogger.shared.log(.info, .recording, "Recording restart completed")

        // Play sound to indicate restart
        SoundManager.play("Purr")

      } catch let error as RecordingError {
        guard isCurrentRecordingStart(generation, window: window) else { return }
        releaseRecordingFocus()
        DiagnosticLogger.shared.logError(.recording, error, "Recording restart failed")
        if !showErrorAlert(error) {
          cancel()
        }
      } catch {
        guard isCurrentRecordingStart(generation, window: window) else { return }
        releaseRecordingFocus()
        DiagnosticLogger.shared.logError(.recording, error, "Recording restart failed (generic)")
        if !showErrorAlert(.setupFailed(error.localizedDescription)) {
          cancel()
        }
      }
    }
  }

  // MARK: - Private

  private func showRegionOverlay(for rect: CGRect, interactionEnabled: Bool) {
    for screen in NSScreen.screens {
      let overlay = RecordingRegionOverlayWindow(screen: screen, highlightRect: rect)
      overlay.interactionDelegate = self
      overlay.setAspectRatio(selectionAspectRatio)
      overlay.setInteractionEnabled(interactionEnabled)
      overlay.orderFrontRegardless()
      regionOverlayWindows.append(overlay)
    }
  }

  /// Re-applies the dim preference to the live region overlays when it changes.
  /// Only acts while actively recording — the pre-record selection always keeps
  /// its dim for selection feedback, regardless of the preference.
  @objc private func dimPreferenceDidChange() {
    guard recorder.state.isPauseResumeEligible, !regionOverlayWindows.isEmpty else { return }
    let dimNonSelectedArea = RecordingToolbarPreferences.dimNonSelectedArea()
    for overlay in regionOverlayWindows {
      overlay.setDimEnabled(dimNonSelectedArea)
    }
  }

  private func startRecording() {
    guard let rect = selectedRect, let window = toolbarWindow else {
      DiagnosticLogger.shared.log(.warning, .recording, "Start recording ignored: missing selection or toolbar")
      return
    }
    guard beginRecordingStartAttempt(source: "toolbar") else { return }
    let generation = recordingGeneration

    let format = window.selectedFormat
    DiagnosticLogger.shared.log(.info, .recording, "Start recording", context: [
      "format": format.rawValue,
      "rect": "\(Int(rect.width))x\(Int(rect.height))",
    ])

    // Get FPS from preferences (default 30)
    var fps = UserDefaults.standard.integer(forKey: PreferencesKeys.recordingFPS)
    if fps == 0 { fps = 30 }

    // Get quality from preferences (default high)
    let qualityString = UserDefaults.standard.string(forKey: PreferencesKeys.recordingQuality) ?? "high"
    let quality = VideoQuality(rawValue: qualityString) ?? .high
    let maxResolution = window.selectedMaxResolution

    let captureSystemAudio = window.captureAudio
    let showCursor = window.state.showCursor

    // Get microphone setting from toolbar
    var captureMicrophone = window.captureMicrophone
    let microphoneDeviceID = window.microphoneDeviceID
    let captureCamera = window.captureCamera
    let cameraDeviceID = window.cameraDeviceID
    DiagnosticLogger.shared.log(.debug, .recording, "Recording options resolved", context: [
      "quality": quality.rawValue,
      "fps": "\(fps)",
      "systemAudio": "\(captureSystemAudio)",
      "microphone": "\(captureMicrophone)",
      "microphoneDevice": microphoneDeviceID,
      "camera": "\(captureCamera)",
      "cameraDevice": cameraDeviceID,
      "showCursor": "\(showCursor)",
    ])

    guard let saveDirectory = resolveSaveDirectoryForOperation() else {
      DiagnosticLogger.shared.log(.warning, .recording, "Recording start blocked: no save directory access")
      finishRecordingStartAttempt()
      showSaveLocationPermissionAlert()
      return
    }

    // Предупреждения эталона до старта: диск, камера без микрофона, крышка, заглушённый микрофон.
    let startWarnings = RecordingStartWarnings.warnings(for: RecordingStartWarningPresenter.conditions(
      saveDirectory: saveDirectory,
      captureCamera: captureCamera,
      captureMicrophone: captureMicrophone,
      microphoneDeviceID: microphoneDeviceID
    ))
    switch RecordingStartWarningPresenter.present(startWarnings) {
    case .cancel:
      DiagnosticLogger.shared.log(.info, .recording, "Recording start cancelled from warning")
      finishRecordingStartAttempt()
      return
    case .proceedWithoutMicrophone:
      captureMicrophone = false
      window.captureMicrophone = false
    case .proceed:
      break
    }
    guard isCurrentRecordingStart(generation, window: window) else { return }
    activeSaveDirectory = saveDirectory

    // Save selected format to preferences
    UserDefaults.standard.set(format.rawValue, forKey: PreferencesKeys.recordingFormat)

    Task {
      guard isCurrentRecordingStart(generation, window: window) else { return }
      do {
        let exclusionConfig = self.recordingCaptureExclusionConfiguration()
        DiagnosticLogger.shared.log(.debug, .recording, "Recording capture exclusion resolved", context: [
          "excludeOwnApp": "\(exclusionConfig.excludeOwnApplication)",
          "excludedWindows": "\(exclusionConfig.excludedWindowIDs.count)",
        ])

        guard await OwnShotRecordingCountdown.wait(
          seconds: UserDefaults.standard.bool(forKey: OwnShotRecordingPreferenceKeys.showCountdown) ? 3 : 0,
          isCurrent: { self.isCurrentRecordingStart(generation, window: window) },
          onCancel: { self.cancel() }
        ) else { return }

        let savePlan = try self.tempCaptureManager.makeRecordingSavePlan(
          exportDirectory: saveDirectory
        )

        try await recorder.prepareRecording(
          rect: rect,
          windowTarget: self.selectedWindowTarget,
          format: format,
          quality: quality,
          fps: fps,
          maxResolution: maxResolution,
          captureSystemAudio: captureSystemAudio,
          captureMicrophone: captureMicrophone,
          microphoneDeviceID: microphoneDeviceID,
          showCursor: showCursor,
          saveDirectory: savePlan.finalDirectory,
          processingSession: savePlan.processingSession,
          excludeDesktopIcons: DesktopIconManager.shared.isIconHidingEnabled,
          excludeDesktopWidgets: DesktopIconManager.shared.isWidgetHidingEnabled,
          excludeOwnApplication: exclusionConfig.excludeOwnApplication,
          excludedWindowIDs: exclusionConfig.excludedWindowIDs,
          context: self.selectedWindowTarget
            .map { CaptureContext.fromPID($0.ownerPID, windowTitle: $0.title) } ?? CaptureContext.fromFrontmostApp()
        )

        guard isCurrentRecordingStart(generation, window: window) else { return }
        try await self.setupCameraOverlay(
          for: rect,
          enabled: captureCamera,
          deviceID: cameraDeviceID
        )
        guard isCurrentRecordingStart(generation, window: window) else { return }
        guard try await acquireRecordingFocus(generation: generation, window: window) else { return }
        try await recorder.startRecording()
        guard isCurrentRecordingStart(generation, window: window) else { return }
        removeEscapeMonitors()

        // Hide border on overlay (would appear in video), disable interaction, and
        // apply the dim preference — off keeps non-selected windows fully visible.
        let dimNonSelectedArea = RecordingToolbarPreferences.dimNonSelectedArea()
        for overlay in regionOverlayWindows {
          overlay.hideBorder()
          overlay.setInteractionEnabled(false)
          overlay.setDimEnabled(dimNonSelectedArea)
        }

        guard await completeRecordingStart(for: rect) else { return }

      } catch let error as RecordingError {
        guard isCurrentRecordingStart(generation, window: window) else { return }
        releaseRecordingFocus()
        DiagnosticLogger.shared.logError(.recording, error, "Recording setup failed")
        finishRecordingStartAttempt()
        if case .alreadyActive = error { return }
        if !showErrorAlert(error) {
          cancel()
        }
      } catch {
        guard isCurrentRecordingStart(generation, window: window) else { return }
        releaseRecordingFocus()
        DiagnosticLogger.shared.logError(.recording, error, "Recording setup failed (generic)")
        finishRecordingStartAttempt()
        if !showErrorAlert(.setupFailed(error.localizedDescription)) {
          cancel()
        }
      }
    }
  }

  @discardableResult
  private func showErrorAlert(_ error: RecordingError) -> Bool {
    DiagnosticLogger.shared.log(.error, .recording, "Error alert shown", context: ["error": error.localizedDescription])
    let alert = NSAlert()
    alert.messageText = L10n.Recording.failedTitle
    alert.informativeText = error.localizedDescription
    alert.alertStyle = .warning

    if case .cameraPermissionDenied = error {
      alert.messageText = L10n.RecordingParity.cameraNoAccessTitle
      alert.informativeText = L10n.RecordingParity.cameraNoAccessMessage
      alert.addButton(withTitle: L10n.Common.openSystemSettings)
      alert.addButton(withTitle: L10n.Common.cancel)

      if alert.runModal() == .alertFirstButtonReturn,
         let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
        NSWorkspace.shared.open(url)
      }
      return false
    } else if case .microphonePermissionDenied = error {
      alert.messageText = L10n.RecordingParity.microphoneNoAccessTitle
      alert.informativeText = L10n.RecordingParity.microphoneNoAccessMessage
      alert.addButton(withTitle: L10n.Common.openSystemSettings)
      alert.addButton(withTitle: L10n.Microphone.continueWithoutMic)
      alert.addButton(withTitle: L10n.Common.cancel)

      let response = alert.runModal()
      switch response {
      case .alertFirstButtonReturn:
        // Open System Settings > Privacy & Security > Microphone
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
          NSWorkspace.shared.open(url)
        }
        return false
      case .alertSecondButtonReturn:
        // Continue recording without microphone
        startRecordingWithoutMicrophone()
        return true
      default:
        return false
      }
    } else {
      // Текст эталона про старт записи, исходная ошибка остаётся последней строкой.
      alert.messageText = L10n.RecordingParity.startErrorTitle
      alert.informativeText = RecordingLifecycleText.startErrorMessage(underlying: error.localizedDescription)
      alert.addButton(withTitle: L10n.Common.ok)
      alert.runModal()
      return false
    }
  }

  private func startRecordingWithoutMicrophone() {
    guard let rect = selectedRect, let window = toolbarWindow else {
      DiagnosticLogger.shared.log(.warning, .recording, "Microphone retry ignored: missing selection or toolbar")
      return
    }
    guard beginRecordingStartAttempt(source: "microphone-retry") else { return }
    let generation = recordingGeneration

    // Disable microphone and retry
    window.captureMicrophone = false
    DiagnosticLogger.shared.log(.info, .recording, "Retrying recording without microphone")

    let format = window.selectedFormat
    var fps = UserDefaults.standard.integer(forKey: PreferencesKeys.recordingFPS)
    if fps == 0 { fps = 30 }
    let qualityString = UserDefaults.standard.string(forKey: PreferencesKeys.recordingQuality) ?? "high"
    let quality = VideoQuality(rawValue: qualityString) ?? .high
    let maxResolution = window.selectedMaxResolution
    let captureSystemAudio = window.captureAudio
    let showCursor = window.state.showCursor
    let captureCamera = window.captureCamera
    let cameraDeviceID = window.cameraDeviceID

    guard let saveDirectory = resolveSaveDirectoryForOperation() else {
      DiagnosticLogger.shared.log(.warning, .recording, "Microphone retry blocked: no save directory access")
      finishRecordingStartAttempt()
      showSaveLocationPermissionAlert()
      return
    }
    activeSaveDirectory = saveDirectory

    Task {
      guard isCurrentRecordingStart(generation, window: window) else { return }
      do {
        let exclusionConfig = self.recordingCaptureExclusionConfiguration()

        guard await OwnShotRecordingCountdown.wait(
          seconds: UserDefaults.standard.bool(forKey: OwnShotRecordingPreferenceKeys.showCountdown) ? 3 : 0,
          isCurrent: { self.isCurrentRecordingStart(generation, window: window) },
          onCancel: { self.cancel() }
        ) else { return }

        let savePlan = try self.tempCaptureManager.makeRecordingSavePlan(
          exportDirectory: saveDirectory
        )

        try await recorder.prepareRecording(
          rect: rect,
          windowTarget: self.selectedWindowTarget,
          format: format,
          quality: quality,
          fps: fps,
          maxResolution: maxResolution,
          captureSystemAudio: captureSystemAudio,
          captureMicrophone: false,
          showCursor: showCursor,
          saveDirectory: savePlan.finalDirectory,
          processingSession: savePlan.processingSession,
          excludeDesktopIcons: DesktopIconManager.shared.isIconHidingEnabled,
          excludeDesktopWidgets: DesktopIconManager.shared.isWidgetHidingEnabled,
          excludeOwnApplication: exclusionConfig.excludeOwnApplication,
          excludedWindowIDs: exclusionConfig.excludedWindowIDs,
          context: self.selectedWindowTarget
            .map { CaptureContext.fromPID($0.ownerPID, windowTitle: $0.title) } ?? CaptureContext.fromFrontmostApp()
        )
        try await self.setupCameraOverlay(
          for: rect,
          enabled: captureCamera,
          deviceID: cameraDeviceID
        )
        guard isCurrentRecordingStart(generation, window: window) else { return }
        guard try await acquireRecordingFocus(generation: generation, window: window) else { return }
        try await recorder.startRecording()
        guard isCurrentRecordingStart(generation, window: window) else { return }
        removeEscapeMonitors()

        let dimNonSelectedArea = RecordingToolbarPreferences.dimNonSelectedArea()
        for overlay in regionOverlayWindows {
          overlay.hideBorder()
          overlay.setInteractionEnabled(false)
          overlay.setDimEnabled(dimNonSelectedArea)
        }
        guard await completeRecordingStart(for: rect) else { return }
        DiagnosticLogger.shared.log(.info, .recording, "Microphone retry recording started")
      } catch let error as RecordingError {
        guard isCurrentRecordingStart(generation, window: window) else { return }
        releaseRecordingFocus()
        DiagnosticLogger.shared.logError(.recording, error, "Microphone retry recording failed")
        finishRecordingStartAttempt()
        if case .alreadyActive = error { return }
        if !showErrorAlert(error) {
          cancel()
        }
      } catch {
        guard isCurrentRecordingStart(generation, window: window) else { return }
        releaseRecordingFocus()
        DiagnosticLogger.shared.logError(.recording, error, "Microphone retry recording failed (generic)")
        finishRecordingStartAttempt()
        if !showErrorAlert(.setupFailed(error.localizedDescription)) {
          cancel()
        }
      }
    }
  }

  @discardableResult
  func stopRecording(
    notice: StopNotice? = nil,
    using finish: @escaping @MainActor () async -> URL? = { await ScreenRecordingManager.shared.stopRecording() },
    presentNotice: (@MainActor (StopNotice) -> Void)? = nil,
    deliverOutput: (@MainActor (URL) async -> Void)? = nil
  ) -> Task<Void, Never>? {
    guard !isStopPending else { return nil }
    isStopPending = true
    recordingGeneration = UUID()
    releaseRecordingFocus()
    // Capture output mode before cleanup closes the toolbar
    let outputMode = toolbarWindow?.state.outputMode ?? .video
    // Stop во время подготовки: записывать было нечего, это не сбой сохранения.
    let wasRecording = recorder.state.isPauseResumeEligible

    return Task {
      let url = await finish()
      let audioMergeIssue = recorder.lastAudioMergeIssue
      DiagnosticLogger.shared.log(.info, .recording, "Recording stopped", context: [
        "hasOutput": "\(url != nil)",
        "outputMode": "\(outputMode)",
      ])
      if url == nil {
        DiagnosticLogger.shared.log(.warning, .recording, "Recording stop completed without output URL")
      }

      // Dismiss recording UI immediately (status bar, area overlay, etc.)
      cleanup()
      isStopPending = false

      // Остановка не по кнопке: эталон объясняет причину после сохранения файла.
      if let stopNotice = notice {
        if let presentNotice {
          presentNotice(stopNotice)
        } else {
          RecordingStartWarningPresenter.presentStopped(title: stopNotice.title, message: stopNotice.message)
        }
      }

      if RecordingSaveFailurePolicy.shouldReportSaveFailure(outputURL: url, wasRecording: wasRecording) {
        // Эталон: Something went wrong saving your file.
        RecordingStartWarningPresenter.presentSaveFailed(detail: nil)
      } else if url != nil, let audioMergeIssue {
        // Дорожки не свели (сбой или мало места), запись при этом сохранена.
        RecordingStartWarningPresenter.presentAudioMergeIssue(audioMergeIssue)
      }

      if let url {
        if let deliverOutput {
          await deliverOutput(url)
          return
        }
        // Звук остановки эталона (stopRecording.aif)
        SoundManager.play(.stop)

        if outputMode == .gif {
          // GIF mode: add to QuickAccess immediately with processing state
          await handleGIFConversion(videoURL: url)
        } else {
          // Video mode: normal post-capture flow
          await PostCaptureActionHandler.shared.handleVideoCapture(url: url)
        }
      }
    }
  }

  /// Handle GIF conversion: add to QuickAccess with progress, convert, and update
  private func handleGIFConversion(videoURL: URL) async {
    DiagnosticLogger.shared.log(
      .info,
      .recording,
      "GIF conversion started",
      context: ["file": videoURL.lastPathComponent]
    )
    let quickAccess = QuickAccessManager.shared
    let sourceAccess = SandboxFileAccessManager.shared.beginAccessingURL(videoURL)
    let outputDirectoryAccess = SandboxFileAccessManager.shared.beginAccessingURL(
      videoURL.deletingLastPathComponent()
    )
    defer {
      sourceAccess.stop()
      outputDirectoryAccess.stop()
    }

    // Conversion still runs when the user has turned off the recording card.
    let itemId = PreferencesManager.shared.isActionEnabled(.showQuickAccess, for: .recording)
      ? await quickAccess.addVideo(url: videoURL)?.id
      : nil

    let conversionID = UUID()
    let conversion = Task { @MainActor [weak self] in
      try await GIFConverter.convert(
        videoURL: videoURL,
        options: OwnShotRecordingPreferences.gifOptions(),
        onProgress: { [weak self] progress in
          guard let itemId, self?.gifConversions.acceptsProgress(for: conversionID) == true else { return }
          quickAccess.updateProcessingState(id: itemId, state: .processing(progress: progress))
        }
      )
    }
    gifConversions.start(conversion, id: conversionID, itemID: itemId)
    if let itemId {
      quickAccess.updateProcessingState(id: itemId, state: .processing(progress: 0))
    }
    let result = await conversion.result
    let cancelChoice = gifConversions.finish(conversion)

    do {
      let gifURL = try result.get()

      if let itemId {
        // Generate thumbnail from GIF
        let thumbnail = SandboxFileAccessManager.shared.withScopedAccess(to: gifURL) {
          NSImage(contentsOf: gifURL)
        }

        // Update the QuickAccess item with GIF URL
        quickAccess.updateItemURL(id: itemId, newURL: gifURL, newThumbnail: thumbnail)
        quickAccess.updateProcessingState(id: itemId, state: .idle)
      }

      // Run remaining post-capture actions (clipboard copy, etc.) on the final GIF
      // skipQuickAccess: item is already in QuickAccess from addVideo() above
      await PostCaptureActionHandler.shared.handleVideoCapture(url: gifURL, skipQuickAccess: true)

      // Delete the original video file
      SandboxFileAccessManager.shared.withScopedAccess(to: videoURL.deletingLastPathComponent()) {
        do {
          try FileManager.default.removeItem(at: videoURL)
          DiagnosticLogger.shared.log(.debug, .recording, "GIF source video deleted", context: [
            "file": videoURL.lastPathComponent,
          ])
        } catch {
          DiagnosticLogger.shared.logError(.recording, error, "Failed to delete GIF source video", context: [
            "file": videoURL.lastPathComponent,
          ])
        }
        try? RecordingMetadataStore.delete(for: videoURL)
      }

    } catch is CancellationError {
      await finishCancelledGIFConversion(videoURL: videoURL, itemID: itemId, choice: cancelChoice ?? .saveAsVideo)
    } catch {
      DiagnosticLogger.shared.logError(.recording, error, "GIF conversion failed")
      // On failure, keep the video as-is and clear processing state
      guard let itemId else { return }
      quickAccess.updateProcessingState(id: itemId, state: .failed)

      // Auto-clear failure state after 2 seconds
      Task {
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        quickAccess.updateProcessingState(id: itemId, state: .idle)
      }
    }
  }

  // MARK: - Отмена GIF

  /// Есть ли конвертация, которую можно остановить (для кнопки отмены в карточке).
  func isConvertingGIF(itemID: UUID?) -> Bool {
    gifConversions.activeConversion(for: itemID) != nil
  }

  /// Отмена конвертации в GIF, как GIFProcessingPopup у эталона: вопрос
  /// Are you sure you want to stop the conversion? с выбором сохранить видео
  /// или удалить запись. Точка входа для кнопки отмены карточки Quick Access.
  func requestGIFConversionCancel(itemID: UUID? = nil) {
    guard let conversion = gifConversions.activeConversion(for: itemID),
          conversion.cancelChoice == nil else { return }
    let choice = RecordingStartWarningPresenter.confirmStopGIFConversion()
    // Пока висел вопрос, конвертация могла закончиться.
    gifConversions.cancel(conversion.task, choice: choice)
  }

  private func finishCancelledGIFConversion(
    videoURL: URL,
    itemID: UUID?,
    choice: RecordingGIFCancelChoice
  ) async {
    DiagnosticLogger.shared.log(.info, .recording, "GIF conversion cancelled", context: [
      "file": videoURL.lastPathComponent,
      "choice": "\(choice)",
    ])
    let quickAccess = QuickAccessManager.shared
    switch choice {
    case .deleteRecording:
      if let itemID { quickAccess.removeItem(id: itemID) }
      SandboxFileAccessManager.shared.withScopedAccess(to: videoURL.deletingLastPathComponent()) {
        try? FileManager.default.removeItem(at: videoURL)
        try? RecordingMetadataStore.delete(for: videoURL)
      }
    case .saveAsVideo, .continueConverting:
      // Карточка уже показывает видео: снимаем прогресс и запускаем обычные действия для видео.
      if let itemID { quickAccess.updateProcessingState(id: itemID, state: .idle) }
      await PostCaptureActionHandler.shared.handleVideoCapture(url: videoURL, skipQuickAccess: itemID != nil)
    }
  }

  /// Capture a screenshot of the selected area and close the toolbar
  private func captureScreenshot() {
    guard let rect = selectedRect else { return }
    DiagnosticLogger.shared.log(.info, .recording, "Screenshot during recording", context: [
      "rect": "\(Int(rect.width))x\(Int(rect.height))",
    ])

    guard let saveDirectory = resolveSaveDirectoryForOperation() else {
      DiagnosticLogger.shared.log(.warning, .recording, "Screenshot during recording blocked: no save directory access")
      showSaveLocationPermissionAlert()
      return
    }

    let selectedWindowTarget = self.selectedWindowTarget
    let sourceBundleID: String?
    if let selectedWindowTarget {
      sourceBundleID = selectedWindowTarget.ownerPID.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
    } else {
      sourceBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }
    let context = CaptureContext(
      appName: nil,
      windowTitle: nil,
      sourceAppBundleID: CaptureSourceApplication.externalBundleID(sourceBundleID, ownBundleID: Bundle.main.bundleIdentifier)
    )

    // Hide overlay windows and toolbar so they don't appear in the screenshot
    for overlay in regionOverlayWindows {
      overlay.orderOut(nil)
    }
    toolbarWindow?.orderOut(nil)

    let captureManager = ScreenCaptureManager.shared
    let excludeDesktopIcons = DesktopIconManager.shared.isIconHidingEnabled
    let excludeDesktopWidgets = DesktopIconManager.shared.isWidgetHidingEnabled
    let prefetchedContentTask = captureManager.prefetchShareableContent(
      includeDesktopWindows: excludeDesktopIcons || excludeDesktopWidgets
    )

    // Resolve save directory based on auto-save toggle
    let actualSaveDirectory = tempCaptureManager.resolveSaveDirectory(
      for: .screenshot,
      exportDirectory: saveDirectory
    )

    Task {
      await Task.yield()

      let result: CaptureResult = if let selectedWindowTarget {
        await captureManager.captureWindow(
          target: selectedWindowTarget,
          saveDirectory: actualSaveDirectory,
          showCursor: showsCursorInScreenshots,
          excludeDesktopIcons: excludeDesktopIcons,
          excludeDesktopWidgets: excludeDesktopWidgets,
          excludeOwnApplication: !includeOwnAppInScreenshots,
          prefetchedContentTask: prefetchedContentTask,
          context: context
        )
      } else {
        await captureManager.captureArea(
          rect: rect,
          saveDirectory: actualSaveDirectory,
          showCursor: showsCursorInScreenshots,
          excludeDesktopIcons: excludeDesktopIcons,
          excludeDesktopWidgets: excludeDesktopWidgets,
          excludeOwnApplication: !includeOwnAppInScreenshots,
          prefetchedContentTask: prefetchedContentTask,
          context: context
        )
      }

      switch result {
      case .success:
        DiagnosticLogger.shared.log(.info, .recording, "Screenshot during recording captured")
        SoundManager.playScreenshotCapture()
      // PostCaptureActionHandler is triggered automatically via
      // ScreenCaptureManager.captureCompletedPublisher → ScreenCaptureViewModel
      case .failure(let error):
        DiagnosticLogger.shared.logError(.recording, error, "Screenshot during recording failed")
        let alert = NSAlert()
        alert.messageText = L10n.Recording.screenshotFailedTitle
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.Common.ok)
        alert.runModal()
      }

      cleanup()
    }
  }

  private func cleanup() {
    recordingGeneration = UUID()
    isRestartingRecording = false
    releaseRecordingFocus()
    DiagnosticLogger.shared.log(.debug, .recording, "Recording cleanup", context: [
      "regionOverlays": "\(regionOverlayWindows.count)",
      "hasToolbar": "\(toolbarWindow != nil)",
      "hasAnnotationOverlay": "\(annotationOverlayWindow != nil)",
      "hasClickHighlight": "\(clickHighlightWindow != nil)",
      "hasKeystrokeOverlay": "\(keystrokeOverlayWindow != nil)",
      "hasCameraOverlay": "\(cameraOverlayWindow != nil)",
    ])
    finishRecordingStartAttempt()
    stopRecordingGuards()
    // Remove escape monitors
    removeEscapeMonitors()

    // Close click highlight overlay
    cleanupClickHighlightOverlay()

    // Close keystroke overlay
    cleanupKeystrokeOverlay()

    // Close annotation windows
    cleanupAnnotationOverlay()

    cleanupCameraOverlay()

    // Close region overlay windows
    closePreRecordUI()
    selectedRect = nil
    selectedWindowTarget = nil
    isActive = false
    let sessionEndHandler = onSessionEnded
    onSessionEnded = nil
    sessionEndHandler?()
  }

  private func setupCameraOverlay(
    for rect: CGRect,
    enabled: Bool,
    deviceID: String
  ) async throws {
    guard enabled else {
      cleanupCameraOverlay()
      return
    }

    guard await RecordingCameraDeviceProvider.requestAccessIfNeeded() else {
      throw RecordingError.cameraPermissionDenied
    }

    if let cameraOverlayWindow {
      await recorder.addExceptedWindow(windowID: cameraOverlayWindow.overlayWindowID)
      return
    }

    do {
      let shape = toolbarWindow?.cameraShape ?? RecordingCameraSettingsProvider.storedShape()
      let sizePreset = toolbarWindow?.cameraSize ?? RecordingCameraSettingsProvider.storedSize()
      let isMirrored = toolbarWindow?.cameraMirrored ?? RecordingCameraSettingsProvider.storedMirrored()

      let window = try RecordingCameraOverlayWindow(
        recordingRect: rect,
        deviceID: deviceID,
        shape: shape,
        sizePreset: sizePreset,
        isMirrored: isMirrored
      )
      window.onConfigurationChanged = { [weak self] newShape, newSize, newMirrored in
        self?.toolbarWindow?.cameraShape = newShape
        self?.toolbarWindow?.cameraSize = newSize
        self?.toolbarWindow?.cameraMirrored = newMirrored
      }
      window.onCloseRequested = { [weak self] in
        self?.toolbarWindow?.state.captureCamera = false
        UserDefaults.standard.set(false, forKey: PreferencesKeys.recordingCaptureCamera)
        self?.cleanupCameraOverlay()
      }

      cameraOverlayWindow = window
      window.startPreview()
      await recorder.addExceptedWindow(windowID: window.overlayWindowID)
    } catch {
      DiagnosticLogger.shared.logError(.recording, error, "Camera overlay setup failed")
      throw RecordingError.setupFailed(L10n.Camera.unavailable)
    }
  }

  private func cleanupCameraOverlay() {
    cameraOverlayWindow?.close()
    cameraOverlayWindow = nil
  }

  private func acquireRecordingFocus(generation: UUID, window: RecordingToolbarWindow) async throws -> Bool {
    do {
      try await focusLifecycle.begin(
        enabled: UserDefaults.standard.bool(forKey: OwnShotRecordingPreferenceKeys.doNotDisturb),
        preservingCurrentLease: isRestartingRecording,
        isCurrent: { self.isCurrentRecordingStart(generation, window: window) }
      )
    } catch {
      throw RecordingError.setupFailed(
        "Couldn’t enable Do Not Disturb. Add the Focus shortcuts in Settings → Recording → Set Up, then try again."
      )
    }
    return isCurrentRecordingStart(generation, window: window)
  }

  private func startFocusRenewalIfNeeded() {
    guard let token = focusLifecycle.token, focusRenewal == nil else { return }
    focusRenewal = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
        guard let self, self.focusLifecycle.token == token else { return }
        do {
          try await self.focusLifecycle.renew()
        } catch {
          guard !Task.isCancelled, self.focusLifecycle.token == token else { return }
          DiagnosticLogger.shared.log(.warning, .recording, "Recording Focus renewal failed")
          // Очистку только этого токена уже поставил в очередь FocusLifecycle.
          return
        }
      }
    }
  }

  private func releaseRecordingFocus() {
    focusRenewal?.cancel()
    focusRenewal = nil
    focusLifecycle.end()
  }

  private func beginRecordingStartAttempt(source: String) -> Bool {
    guard !isStartingRecording, recorder.state == .idle else {
      DiagnosticLogger.shared.log(.debug, .recording, "Recording start blocked: recorder busy", context: [
        "source": source,
        "state": "\(recorder.state)",
      ])
      return false
    }

    recordingGeneration = UUID()
    isStartingRecording = true
    toolbarWindow?.state.isPreparingToRecord = true
    return true
  }

  private func finishRecordingStartAttempt() {
    isStartingRecording = false
    toolbarWindow?.state.isPreparingToRecord = false
  }

  private func resolveSaveDirectoryForOperation() -> URL? {
    SandboxFileAccessManager.shared.ensureExportDirectoryForOperation(
      promptMessage: L10n.Recording.chooseSaveLocationMessage
    )
  }

  private func showSaveLocationPermissionAlert() {
    let alert = NSAlert()
    alert.messageText = L10n.Recording.saveLocationAccessRequiredTitle
    alert.informativeText = L10n.Recording.saveLocationAccessRequiredMessage
    alert.alertStyle = .warning
    alert.addButton(withTitle: L10n.Common.ok)
    alert.runModal()
  }

  // MARK: - Recording Overlays

  private func isCurrentRecordingStart(_ generation: UUID, window: RecordingToolbarWindow) -> Bool {
    isActive && recordingGeneration == generation && toolbarWindow === window
  }

  func completeRecordingStart(
    for rect: CGRect,
    registerWindow: (CGWindowID) async -> Void = {
      await ScreenRecordingManager.shared.addExceptedWindow(windowID: $0)
    }
  ) async -> Bool {
    guard isActive, let window = toolbarWindow else { return false }
    let generation = recordingGeneration
    if clickHighlightWindow == nil {
      setupClickHighlightOverlay(for: rect)
    }
    if keystrokeOverlayWindow == nil {
      setupKeystrokeOverlay(for: rect)
    }

    // Switch to status bar
    window.showRecordingStatusBar(recorder: recorder, visible: isHoverBarVisiblePreference)
    window.contentView?.layoutSubtreeIfNeeded()

    // Set up annotation after the status bar has a live hosting view. The anchor reporter can
    // then synchronously seed the current offset, while its later layout updates remain live.
    if annotationOverlayWindow == nil {
      setupAnnotationOverlay(for: rect)
    }

    // Each new recording stream resets its exceptions, even when the overlay
    // windows survive a restart. Register both new and retained overlays.
    for windowID in [
      annotationOverlayWindow?.overlayWindowID,
      clickHighlightWindow?.overlayWindowID,
      keystrokeOverlayWindow?.overlayWindowID,
    ].compactMap({ $0 }) {
      await registerWindow(windowID)
      guard isCurrentRecordingStart(generation, window: window) else { return false }
    }
    finishRecordingStartAttempt()
    startFocusRenewalIfNeeded()
    startRecordingGuards(window: window)
    return true
  }

  // MARK: - Recording Guards

  private func startRecordingGuards(window: RecordingToolbarWindow) {
    if !isRestartingRecording, !displaySleepAssertion.isActive {
      // Звук старта. Рестарт озвучивается отдельно.
      SoundManager.play(.start)
    }
    displaySleepAssertion.begin()
    if let activeSaveDirectory {
      diskSpaceMonitor.start(directory: activeSaveDirectory) { [weak self] in
        guard let self, self.recorder.state.isPauseResumeEligible else { return }
        DiagnosticLogger.shared.log(.warning, .recording, "Recording stopped: disk almost full")
        self.stopRecording(notice: (L10n.RecordingParity.diskFullTitle, L10n.RecordingParity.diskFullMessage))
      }
    }
    startSystemAudioWatchdogIfNeeded()
    if window.captureMicrophone {
      microphoneDisconnectMonitor.start(deviceID: window.microphoneDeviceID) { [weak self] in
        guard let self, self.recorder.state.isPauseResumeEligible else { return }
        DiagnosticLogger.shared.log(.warning, .recording, "Microphone disconnected during recording")
        if !RecordingStartWarningPresenter.presentMicrophoneDisconnected(),
           self.recorder.state.isPauseResumeEligible {
          self.stopFromStatusItem()
        }
      }
    }
  }

  private func stopRecordingGuards() {
    activeSaveDirectory = nil
    displaySleepAssertion.end()
    diskSpaceMonitor.stop()
    microphoneDisconnectMonitor.stop()
    systemAudioWatchdogTimer?.invalidate()
    systemAudioWatchdogTimer = nil
  }

  /// Раз в секунду сверяет поток системного звука. При сбое спрашивает,
  /// продолжить без звука или остановить, как Audio Recording Failed у эталона.
  private func startSystemAudioWatchdogIfNeeded() {
    systemAudioWatchdogTimer?.invalidate()
    systemAudioWatchdogTimer = nil
    systemAudioWatchdog = RecordingSystemAudioWatchdog()
    guard recorder.isCapturingSystemAudio else { return }
    systemAudioWatchdogTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.checkSystemAudio() }
    }
  }

  private func checkSystemAudio() {
    guard recorder.state.isPauseResumeEligible else { return }
    let health = recorder.systemAudioHealth()
    guard systemAudioWatchdog.observe(
      health, isPaused: recorder.isPaused, now: ProcessInfo.processInfo.systemUptime
    ) else { return }
    systemAudioWatchdogTimer?.invalidate()
    systemAudioWatchdogTimer = nil
    DiagnosticLogger.shared.log(.warning, .recording, "System audio capture failed during recording", context: [
      "samplesReceived": "\(health.samplesReceived)",
      "appendFailed": "\(health.appendFailed)",
    ])
    if !RecordingStartWarningPresenter.presentSystemAudioFailed(), recorder.state.isPauseResumeEligible {
      stopFromStatusItem()
    }
  }

  // MARK: - Annotation Overlay

  private func setupAnnotationOverlay(for rect: CGRect) {
    guard let window = toolbarWindow else {
      DiagnosticLogger.shared.log(.warning, .recording, "Annotation overlay setup skipped: toolbar missing")
      return
    }
    let annotationState = window.annotationState

    // Create overlay window covering recording rect
    let overlayWindow = RecordingAnnotationOverlayWindow(
      recordingRect: rect,
      annotationState: annotationState
    )
    overlayWindow.orderFrontRegardless()
    annotationOverlayWindow = overlayWindow
    DiagnosticLogger.shared.log(.info, .recording, "Annotation overlay created", context: [
      "windowID": "\(overlayWindow.overlayWindowID)",
      "rect": "\(Int(rect.width))x\(Int(rect.height))",
    ])

    // Create popover-style annotation toolbar anchored to the status bar
    let toolbarWin = RecordingAnnotationToolbarWindow(annotationState: annotationState)
    toolbarWin.anchorWindow = window
    toolbarWin.anchorButtonCenterXOffset = window.annotateButtonCenterXOffset
    annotationToolbarWindow = toolbarWin

    // Update popover anchor offset when the status-bar anchor reporter reports button position.
    window.onAnnotateButtonOffsetChanged = { [weak toolbarWin] offset in
      toolbarWin?.anchorButtonCenterXOffset = offset
      if annotationState.isAnnotationEnabled {
        if toolbarWin?.isVisible == true {
          toolbarWin?.positionRelativeToAnchor()
        } else {
          toolbarWin?.showPopover()
        }
      }
    }

    // Cover the narrow startup window where annotation was enabled before the popover received
    // its anchor callback (for example, a global shortcut arriving during recording startup).
    if annotationState.isAnnotationEnabled {
      toolbarWin.showPopover()
    }

    // Start auto-clear timer
    annotationState.startCleanupTimer()

  }

  private func cleanupAnnotationOverlay() {
    if annotationOverlayWindow != nil || annotationToolbarWindow != nil {
      DiagnosticLogger.shared.log(.debug, .recording, "Annotation overlay cleanup")
    }
    toolbarWindow?.annotationState.stopCleanupTimer()
    toolbarWindow?.annotationState.isAnnotationEnabled = false

    annotationToolbarWindow?.close()
    annotationToolbarWindow = nil

    annotationOverlayWindow?.close()
    annotationOverlayWindow = nil
  }

  // MARK: - Click Highlight Overlay

  private func setupClickHighlightOverlay(for rect: CGRect) {
    let isEnabled = UserDefaults.standard.object(forKey: PreferencesKeys.recordingHighlightClicks) as? Bool ?? false
    guard isEnabled else {
      DiagnosticLogger.shared.log(.debug, .recording, "Click highlight overlay disabled")
      return
    }

    let config = MouseHighlightConfiguration()
    let highlightWindow = MouseClickHighlightWindow(recordingRect: rect, configuration: config)
    highlightWindow.orderFrontRegardless()
    clickHighlightWindow = highlightWindow

    let service = MouseClickHighlightService()
    service.onMouseDown = { [weak highlightWindow] point in
      highlightWindow?.showClickEffect(at: point)
    }
    service.onMouseUp = { [weak highlightWindow] in
      highlightWindow?.dismissClickEffect()
    }
    service.onMouseDragged = { [weak highlightWindow] point in
      highlightWindow?.moveClickEffect(to: point)
    }
    service.start(recordingRect: rect)
    clickHighlightService = service
    DiagnosticLogger.shared.log(.info, .recording, "Click highlight overlay started", context: [
      "windowID": "\(highlightWindow.overlayWindowID)",
    ])

  }

  private func cleanupClickHighlightOverlay() {
    if clickHighlightWindow != nil || clickHighlightService != nil {
      DiagnosticLogger.shared.log(.debug, .recording, "Click highlight overlay cleanup")
    }
    clickHighlightService?.stop()
    clickHighlightService = nil
    clickHighlightWindow?.close()
    clickHighlightWindow = nil
  }

  // MARK: - Keystroke Overlay

  private func setupKeystrokeOverlay(for rect: CGRect) {
    let isEnabled = UserDefaults.standard.object(forKey: PreferencesKeys.recordingShowKeystrokes) as? Bool ?? false
    guard isEnabled else {
      DiagnosticLogger.shared.log(.debug, .recording, "Keystroke overlay disabled")
      return
    }

    let config = KeystrokeOverlayConfiguration()
    let overlayWindow = KeystrokeOverlayWindow(recordingRect: rect, configuration: config)
    overlayWindow.orderFrontRegardless()
    keystrokeOverlayWindow = overlayWindow

    let service = KeystrokeMonitorService()
    service.keysMode = config.keysMode
    service.onKeystroke = { [weak overlayWindow] text in
      overlayWindow?.showKeystroke(text)
    }
    service.start()
    keystrokeMonitorService = service
    DiagnosticLogger.shared.log(.info, .recording, "Keystroke overlay started", context: [
      "windowID": "\(overlayWindow.overlayWindowID)",
    ])

  }

  private func cleanupKeystrokeOverlay() {
    if keystrokeOverlayWindow != nil || keystrokeMonitorService != nil {
      DiagnosticLogger.shared.log(.debug, .recording, "Keystroke overlay cleanup")
    }
    keystrokeMonitorService?.stop()
    keystrokeMonitorService = nil
    keystrokeOverlayWindow?.close()
    keystrokeOverlayWindow = nil
  }

  /// Full update: selected rect + overlays + toolbar + persistence.
  /// Used for non-drag events (reselection, mode changes).
  private func updateSelectedRect(_ rect: CGRect) {
    let captureMode = toolbarWindow?.captureMode == .application ? RecordingCaptureMode
      .area : (toolbarWindow?.captureMode ?? .area)
    updateSelectedTarget(rect: rect, captureMode: captureMode, windowTarget: nil)
  }
}

// MARK: - RecordingRegionOverlayDelegate

extension RecordingCoordinator: RecordingRegionOverlayDelegate {
  func overlayDidRequestReselection(_: RecordingRegionOverlayWindow) {
    restartSelection(for: .area)
  }

  func overlay(_: RecordingRegionOverlayWindow, didMoveRegionTo rect: CGRect) {
    // Lightweight path: update overlay visuals only, skip persistence + toolbar reposition
    updateOverlayHighlightsOnly(rect)
  }

  func overlayDidFinishMoving(_: RecordingRegionOverlayWindow) {
    // Persist rect and reposition toolbar now that drag is complete
    finalizeDragOrResize()
  }

  func overlay(_: RecordingRegionOverlayWindow, didReselectWithRect rect: CGRect) {
    // Full update for reselection — not a continuous drag, so full sync is fine
    updateSelectedRect(rect)
  }

  func overlay(_: RecordingRegionOverlayWindow, didResizeRegionTo rect: CGRect) {
    // Lightweight path: update overlay visuals only, skip persistence + toolbar reposition
    updateOverlayHighlightsOnly(rect)
  }

  func overlayDidFinishResizing(_: RecordingRegionOverlayWindow) {
    // Persist rect and reposition toolbar now that resize is complete
    finalizeDragOrResize()
  }
}
