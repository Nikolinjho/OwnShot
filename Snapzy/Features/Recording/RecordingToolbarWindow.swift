//
//  RecordingToolbarWindow.swift
//  Snapzy
//
//  Floating window container for recording toolbar and status bar
//

import AppKit
import Combine
import SwiftUI

enum RecordingToolbarMode {
  case preRecord
  case recording
}

// MARK: - Recording Output Mode

enum RecordingOutputMode: String, CaseIterable {
  case video
  case gif

  var displayName: String {
    switch self {
    case .video: L10n.RecordingToolbar.outputVideo
    case .gif: L10n.RecordingToolbar.outputGIF
    }
  }

  var iconName: String {
    switch self {
    case .video: "video"
    case .gif: "photo.on.rectangle"
    }
  }
}

enum RecordingPreRecordShortcut {
  /// Клавиши настраиваются в Settings → Shortcuts (Start Video / Start GIF Recording).
  static func outputMode(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, isRepeat: Bool) -> RecordingOutputMode? {
    guard !isRepeat else { return nil }
    return RecordingStartShortcutSettings.outputMode(keyCode: keyCode, modifiers: modifiers)
  }
}

enum RecordingToolbarPreferences {
  static func selectedFormat(defaults: UserDefaults = .standard) -> VideoFormat {
    guard let formatString = defaults.string(forKey: PreferencesKeys.recordingFormat),
          let format = VideoFormat(rawValue: formatString)
    else {
      return .mov
    }
    return format
  }

  static func selectedQuality(defaults: UserDefaults = .standard) -> VideoQuality {
    guard let qualityString = defaults.string(forKey: PreferencesKeys.recordingQuality),
          let quality = VideoQuality(rawValue: qualityString)
    else {
      return .high
    }
    return quality
  }

  static func selectedMaxResolution(defaults: UserDefaults = .standard) -> RecordingMaxResolution {
    guard let raw = defaults.string(forKey: PreferencesKeys.recordingMaxResolution),
          let resolution = RecordingMaxResolution(rawValue: raw)
    else {
      return .auto
    }
    return resolution
  }

  static func captureAudio(defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: PreferencesKeys.recordingCaptureAudio) as? Bool ?? true
  }

  static func captureMicrophone(defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: PreferencesKeys.recordingCaptureMicrophone) as? Bool ?? false
  }

  static func microphoneDeviceID(defaults: UserDefaults = .standard) -> String {
    RecordingMicrophoneDeviceProvider.storedDeviceID(defaults: defaults)
  }

  static func captureCamera(defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: PreferencesKeys.recordingCaptureCamera) as? Bool ?? false
  }

  static func cameraDeviceID(defaults: UserDefaults = .standard) -> String {
    RecordingCameraDeviceProvider.storedDeviceID(defaults: defaults)
  }

  static func cameraShape(defaults: UserDefaults = .standard) -> RecordingCameraShape {
    RecordingCameraSettingsProvider.storedShape(defaults: defaults)
  }

  static func cameraSize(defaults: UserDefaults = .standard) -> RecordingCameraSize {
    RecordingCameraSettingsProvider.storedSize(defaults: defaults)
  }

  static func cameraMirrored(defaults: UserDefaults = .standard) -> Bool {
    RecordingCameraSettingsProvider.storedMirrored(defaults: defaults)
  }

  static func outputMode(defaults: UserDefaults = .standard) -> RecordingOutputMode {
    guard let modeString = defaults.string(forKey: PreferencesKeys.recordingOutputMode),
          let mode = RecordingOutputMode(rawValue: modeString)
    else {
      return .video
    }
    return mode
  }

  static func highlightClicks(defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: PreferencesKeys.recordingHighlightClicks) as? Bool ?? false
  }

  static func showKeystrokes(defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: PreferencesKeys.recordingShowKeystrokes) as? Bool ?? false
  }

  static func showCursor(defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: PreferencesKeys.recordingShowCursor) as? Bool ?? true
  }

  /// Whether the area outside the recording region is dimmed during recording.
  /// Defaults to `true` (dimmed) to preserve prior behavior when unset.
  static func dimNonSelectedArea(defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: PreferencesKeys.recordingDimNonSelectedArea) as? Bool ?? true
  }

  /// Whether the floating recording controls bar is shown during recording.
  /// Defaults to `true` (visible) to preserve prior behavior when unset.
  static func hoverBarVisible(defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: PreferencesKeys.recordingHoverBarVisible) as? Bool ?? true
  }

  /// Whether the elapsed recording time is shown next to the menu bar icon. Defaults to `true`.
  static func showTimeOnMenuBar(defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: PreferencesKeys.recordingShowTimeOnMenuBar) as? Bool ?? true
  }
}

enum RecordingToolbarPlacement {
  static let screenEdgeInset: CGFloat = 10
  static let outsideSelectionGap: CGFloat = 20
  static let insideSelectionBottomInset: CGFloat = 24

  static func frameOrigin(
    toolbarSize: CGSize,
    anchorRect rect: CGRect,
    screenFrame: CGRect
  ) -> CGPoint {
    let x = rect.midX - toolbarSize.width / 2
    let minX = screenFrame.minX + screenEdgeInset
    let maxX = screenFrame.maxX - toolbarSize.width - screenEdgeInset
    let safeX = max(minX, min(x, maxX))

    let minY = screenFrame.minY + screenEdgeInset
    let maxY = screenFrame.maxY - toolbarSize.height - screenEdgeInset
    let belowSelectionY = rect.minY - toolbarSize.height - outsideSelectionGap
    let aboveSelectionY = rect.maxY + outsideSelectionGap
    let preferredY: CGFloat
    if belowSelectionY >= minY {
      preferredY = belowSelectionY
    } else if aboveSelectionY <= maxY {
      preferredY = aboveSelectionY
    } else {
      preferredY = rect.minY + insideSelectionBottomInset
    }
    let safeY = max(minY, min(preferredY, maxY))

    return CGPoint(x: safeX, y: safeY)
  }
}

// MARK: - Observable State

@MainActor
final class RecordingToolbarState: ObservableObject {
  @Published var selectedFormat: VideoFormat
  @Published var selectedQuality: VideoQuality
  @Published var selectedMaxResolution: RecordingMaxResolution
  @Published var captureAudio: Bool
  @Published var captureMicrophone: Bool
  @Published var microphoneDeviceID: String
  @Published var captureCamera: Bool
  @Published var cameraDeviceID: String
  @Published var cameraShape: RecordingCameraShape
  @Published var cameraSize: RecordingCameraSize
  @Published var cameraMirrored: Bool
  @Published var captureMode: RecordingCaptureMode
  @Published var outputMode: RecordingOutputMode
  @Published var showCursor: Bool
  @Published var highlightClicks: Bool
  @Published var showKeystrokes: Bool
  @Published var dimNonSelectedArea: Bool
  @Published var selectionRect: CGRect
  var onResizeSelection: ((CGFloat?, CGFloat?, Bool) -> Void)?
  var onAspectRatioChanged: ((CGFloat?) -> Void)?
  @Published var isPreparingToRecord: Bool = false
  /// VU-метр кнопок звука до старта записи.
  let audioMonitor: RecordingSetupAudioMonitor

  var onCaptureModeChanged: ((RecordingCaptureMode) -> Void)?

  init(selectionRect: CGRect = .zero, audioMonitor: RecordingSetupAudioMonitor? = nil) {
    self.selectionRect = selectionRect
    self.audioMonitor = audioMonitor ?? RecordingSetupAudioMonitor()
    self.selectedFormat = RecordingToolbarPreferences.selectedFormat()
    self.selectedQuality = RecordingToolbarPreferences.selectedQuality()
    self.selectedMaxResolution = RecordingToolbarPreferences.selectedMaxResolution()
    self.captureAudio = RecordingToolbarPreferences.captureAudio()
    self.captureMicrophone = RecordingToolbarPreferences.captureMicrophone()
    self.microphoneDeviceID = RecordingToolbarPreferences.microphoneDeviceID()
    self.captureCamera = RecordingToolbarPreferences.captureCamera()
    self.cameraDeviceID = RecordingToolbarPreferences.cameraDeviceID()
    self.cameraShape = RecordingToolbarPreferences.cameraShape()
    self.cameraSize = RecordingToolbarPreferences.cameraSize()
    self.cameraMirrored = RecordingToolbarPreferences.cameraMirrored()
    self.captureMode = .area
    self.outputMode = RecordingToolbarPreferences.outputMode()
    self.showCursor = RecordingToolbarPreferences.showCursor()
    self.highlightClicks = RecordingToolbarPreferences.highlightClicks()
    self.showKeystrokes = RecordingToolbarPreferences.showKeystrokes()
    self.dimNonSelectedArea = RecordingToolbarPreferences.dimNonSelectedArea()
  }
}

// MARK: - Toolbar Window

@MainActor
final class RecordingToolbarWindow: NSWindow {
  private var anchorRect: CGRect
  private var mode: RecordingToolbarMode = .preRecord
  private var hostingView: NSHostingView<AnyView>?
  private var effectView: NSVisualEffectView?
  private var cachedContentSize: CGSize?

  // Callbacks
  var onRecord: (() -> Void)?
  var onCapture: (() -> Void)?
  var onCancel: (() -> Void)?
  var onDelete: (() -> Void)?
  var onRestart: (() -> Void)?
  var onStop: (() -> Void)?

  /// Called when annotate button layout position is determined
  var onAnnotateButtonOffsetChanged: ((CGFloat) -> Void)?

  /// Center X offset of the annotate button relative to this window's left edge
  private(set) var annotateButtonCenterXOffset: CGFloat = 0

  // Observable state for SwiftUI
  let state: RecordingToolbarState
  let annotationState = RecordingAnnotationState()

  /// Expose state properties for external access (read/write)
  var selectedFormat: VideoFormat {
    get { state.selectedFormat }
    set { state.selectedFormat = newValue }
  }

  var selectedQuality: VideoQuality {
    get { state.selectedQuality }
    set { state.selectedQuality = newValue }
  }

  var selectedMaxResolution: RecordingMaxResolution {
    get { state.selectedMaxResolution }
    set { state.selectedMaxResolution = newValue }
  }

  var captureAudio: Bool {
    get { state.captureAudio }
    set { state.captureAudio = newValue }
  }

  var captureMicrophone: Bool {
    get { state.captureMicrophone }
    set { state.captureMicrophone = newValue }
  }

  var microphoneDeviceID: String {
    get { state.microphoneDeviceID }
    set { state.microphoneDeviceID = newValue }
  }

  var captureCamera: Bool {
    get { state.captureCamera }
    set { state.captureCamera = newValue }
  }

  var cameraDeviceID: String {
    get { state.cameraDeviceID }
    set { state.cameraDeviceID = newValue }
  }

  var cameraShape: RecordingCameraShape {
    get { state.cameraShape }
    set { state.cameraShape = newValue }
  }

  var cameraSize: RecordingCameraSize {
    get { state.cameraSize }
    set { state.cameraSize = newValue }
  }

  var cameraMirrored: Bool {
    get { state.cameraMirrored }
    set { state.cameraMirrored = newValue }
  }

  var captureMode: RecordingCaptureMode {
    get { state.captureMode }
    set { state.captureMode = newValue }
  }

  var outputMode: RecordingOutputMode {
    get { state.outputMode }
    set { state.outputMode = newValue }
  }

  /// Callback for capture mode changes
  var onCaptureModeChanged: ((RecordingCaptureMode) -> Void)? {
    get { state.onCaptureModeChanged }
    set { state.onCaptureModeChanged = newValue }
  }

  init(anchorRect: CGRect) {
    self.anchorRect = anchorRect
    self.state = RecordingToolbarState(selectionRect: anchorRect)

    super.init(
      contentRect: .zero,
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )

    configureWindow()
    showPreRecordToolbar()
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  override func close() {
    // A closed bar may outlive its session in a suspended start task. Stop observing so a later
    // preference write cannot order it back on screen.
    NotificationCenter.default.removeObserver(self)
    state.audioMonitor.stop()
    super.close()
  }

  private func configureWindow() {
    isOpaque = false
    backgroundColor = .clear
    CaptureChromeWindowRegistry.configure(self, role: .recordingControls)
    // Use popUpMenu level to ensure toolbar is above the region overlay (.floating)
    level = .popUpMenu
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    hasShadow = true
    isReleasedWhenClosed = false

    // Apply theme appearance at window level (mirrors AnnotateWindow.applyTheme)
    appearance = ThemeManager.shared.nsAppearance
  }

  func showPreRecordToolbar() {
    mode = .preRecord
    level = NSWindow.Level(rawValue: 103)

    let view = RecordingToolbarView(
      state: state,
      onRecord: { [weak self] in self?.onRecord?() },
      onCapture: { [weak self] in self?.onCapture?() },
      onCancel: { [weak self] in self?.onCancel?() }
    )

    setContent(AnyView(view))
    showBelowRect(anchorRect)
    // Уровень слушается только пока открыта панель настройки.
    state.audioMonitor.observe(state)
  }

  /// Present the recording status bar.
  /// - Parameter visible: initial visibility. When `false`, the bar's content/state/callbacks stay
  ///   wired but the window is not displayed (hover bar hidden — stop/pause/annotate remain reachable
  ///   from the menu bar and global shortcuts). Visibility also tracks the preference live so toggling
  ///   it mid-recording stays in sync with the menu bar stop control.
  func showRecordingStatusBar(recorder: ScreenRecordingManager, visible: Bool = true) {
    let startsNewRecording = mode != .recording
    mode = .recording
    level = .popUpMenu
    annotateButtonCenterXOffset = 0
    // Захват записи забирает микрофон и звук, пробы панели настройки больше не нужны.
    state.audioMonitor.stop()

    let view = RecordingStatusBarView(
      recorder: recorder,
      audioLevelMeter: recorder.audioLevelMeter,
      annotationState: annotationState,
      state: state,
      onDelete: { [weak self] in self?.onDelete?() },
      onRestart: { [weak self] in self?.onRestart?() },
      onStop: { [weak self] in self?.onStop?() },
      onAnnotateButtonLayout: { [weak self] centerX in
        // The reporter converts the actual trigger frame into the hosting content view, whose
        // origin is the same as this borderless window's content origin.
        self?.annotateButtonCenterXOffset = centerX
        self?.onAnnotateButtonOffsetChanged?(centerX)
      }
    )

    setContent(AnyView(view))
    // Размер компактной плашки отличается от панели настройки: пересчитываем начальную позицию.
    if startsNewRecording { positionBelowRect(anchorRect) }
    applyRecordingBarVisibility(visible)

    // Track live preference toggles during recording so the on-screen bar and the menu bar stop
    // control never disagree (both derive from `recording.hoverBarVisible`).
    NotificationCenter.default.removeObserver(self, name: UserDefaults.didChangeNotification, object: nil)
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(hoverBarVisibilityPreferenceChanged),
      name: UserDefaults.didChangeNotification,
      object: nil
    )
  }

  // MARK: - Visibility

  @objc private func hoverBarVisibilityPreferenceChanged() {
    guard mode == .recording else { return }
    applyRecordingBarVisibility(RecordingToolbarPreferences.hoverBarVisible())
  }

  /// Show or hide the recording bar without rebuilding content. Idempotent so repeated
  /// `UserDefaults.didChangeNotification` ticks don't reposition an already-visible bar.
  private func applyRecordingBarVisibility(_ visible: Bool) {
    guard visible else {
      orderOut(nil)
      return
    }

    isMovableByWindowBackground = true
    guard !isVisible else { return }

    if let size = cachedContentSize {
      // В текущем сеансе сохраняем ручной перенос, но не восстанавливаем чужую область из прошлой записи.
      setFrameOrigin(clampOriginToVisibleScreens(frame.origin, size: size))
    }
    orderFrontRegardless()
  }

  /// Keep the given origin on a real screen. Picks the screen that contains the origin (or overlaps
  /// the window most, else the first) and clamps within *that* screen's visible frame — avoids the
  /// dead zones that a bounding-box union produces on non-aligned multi-monitor layouts.
  private func clampOriginToVisibleScreens(_ origin: CGPoint, size: CGSize) -> CGPoint {
    let screens = NSScreen.screens
    guard !screens.isEmpty else { return origin }

    let windowRect = CGRect(origin: origin, size: size)
    let target = screens.first(where: { $0.visibleFrame.contains(origin) })
      ?? screens.max(by: { overlapArea($0.visibleFrame, windowRect) < overlapArea($1.visibleFrame, windowRect) })
      ?? screens[0]

    return Self.clampedOrigin(origin, size: size, within: target.visibleFrame)
  }

  private func overlapArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
    let intersection = a.intersection(b)
    return intersection.isNull ? 0 : intersection.width * intersection.height
  }

  /// Pure clamp of a window origin so a `size`-sized window stays fully inside `bounds`.
  /// Returns `origin` unchanged when `bounds` is null. Extracted for deterministic testing.
  nonisolated static func clampedOrigin(_ origin: CGPoint, size: CGSize, within bounds: CGRect) -> CGPoint {
    guard !bounds.isNull else { return origin }
    let maxX = max(bounds.minX, bounds.maxX - size.width)
    let maxY = max(bounds.minY, bounds.maxY - size.height)
    return CGPoint(
      x: min(max(origin.x, bounds.minX), maxX),
      y: min(max(origin.y, bounds.minY), maxY)
    )
  }

  private func setContent(_ view: AnyView) {
    let themedView = view.preferredColorScheme(mode == .recording ? .dark : ThemeManager.shared.systemAppearance)
    let hosting = NSHostingView(rootView: AnyView(themedView))
    hosting.translatesAutoresizingMaskIntoConstraints = false

    if mode == .preRecord {
      // Между тремя отдельными группами остаётся прозрачное пространство.
      let size = hosting.fittingSize
      hosting.translatesAutoresizingMaskIntoConstraints = true
      hosting.frame = CGRect(origin: .zero, size: size)
      contentView = hosting
      hostingView = hosting
      effectView = nil
      setContentSize(size)
      cachedContentSize = size
      invalidateShadow()
      return
    }

    // NSVisualEffectView provides native wallpaper-tinted material backing,
    // matching AnnotateWindow's adaptive background behavior.
    let effect = NSVisualEffectView()
    effect.appearance = NSAppearance(named: .darkAqua)
    effect.material = .hudWindow
    effect.state = .active
    effect.blendingMode = .behindWindow
    effect.wantsLayer = true
    effect.layer?.cornerRadius = ToolbarConstants.toolbarCornerRadius
    effect.layer?.cornerCurve = .continuous
    effect.layer?.masksToBounds = true

    // Make hosting view transparent so material shows through
    hosting.layer?.backgroundColor = .clear

    effect.addSubview(hosting)
    NSLayoutConstraint.activate([
      hosting.topAnchor.constraint(equalTo: effect.topAnchor),
      hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
      hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
      hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
    ])

    // Size the effect view to match hosting content
    let fittingSize = hosting.fittingSize
    effect.frame = CGRect(origin: .zero, size: fittingSize)

    contentView = effect
    hostingView = hosting
    effectView = effect

    setContentSize(fittingSize)
    cachedContentSize = fittingSize
    invalidateShadow()
  }

  private func positionBelowRect(_ rect: CGRect) {
    guard let size = cachedContentSize ?? contentView?.fittingSize else { return }

    // Find the screen containing the anchor rect (not NSScreen.main which is always primary)
    let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) })
      ?? ScreenUtility.activeScreen()
    let screenFrame = screen.visibleFrame

    let origin = RecordingToolbarPlacement.frameOrigin(
      toolbarSize: size,
      anchorRect: rect,
      screenFrame: screenFrame
    )

    setFrameOrigin(origin)
  }

  /// Position and order the window to the front (initial show only).
  private func showBelowRect(_ rect: CGRect) {
    positionBelowRect(rect)
    orderFrontRegardless()
  }

  override var canBecomeKey: Bool {
    true
  }

  /// Поля размера принимают цифры только в key-окне: по клику в поле панель настройки
  /// становится key (с активацией приложения), как у эталона. Клики по кнопкам фокус не трогают.
  override func sendEvent(_ event: NSEvent) {
    if event.type == .leftMouseDown, mode == .preRecord, !isKeyWindow,
       Self.isTextInput(contentView?.hitTest(event.locationInWindow)) {
      NSApp.activate(ignoringOtherApps: true)
      makeKey()
    }
    super.sendEvent(event)
  }

  static func isTextInput(_ view: NSView?) -> Bool {
    var current = view
    while let candidate = current {
      if candidate is NSTextField || candidate is NSText { return true }
      current = candidate.superview
    }
    return false
  }

  func updateAnchorRect(_ rect: CGRect) {
    state.selectionRect = rect
    anchorRect = rect
    positionBelowRect(rect)
  }
}
