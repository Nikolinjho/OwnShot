//
//  AppStatusBarController.swift
//  Snapzy
//
//  Manages the NSStatusItem for menu-driven capture actions and live recording status.
//

import AppKit
import Carbon
import Combine
import Sparkle
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppStatusBarController: ObservableObject {

  static let shared = AppStatusBarController()

  // MARK: - Properties

  private var statusItem: NSStatusItem?
  private var cancellables = Set<AnyCancellable>()
  private let recorder = ScreenRecordingManager.shared
  private let menuBarCustomizationStore = MenuBarCustomizationStore.shared
  private let menuBarIconRenderer = MenuBarIconRenderer.shared
  private var isShowingCLIActivity = false
  private var cachedIdleStatusImage: NSImage?
  private var cachedIdleStatusStyle: MenuBarIconStyle?
  private var cachedCustomIconDate: Date?
  private lazy var recordingStopImage = makeRecordingStopImage()
  private var menu: NSMenu?
  private var didDetectCrash = false

  // Dependencies injected after setup
  private var viewModel: ScreenCaptureViewModel?
  private var updater: SPUUpdater?

  var screenCaptureViewModel: ScreenCaptureViewModel? {
    viewModel
  }

  // Track if we elevated activation policy for Settings window
  private var didElevateForSettings = false
  private weak var trackedPreferencesWindow: NSWindow?
  private var trackedPreferencesExcludedWindowID: CGWindowID?
  private var pendingPreferencesWindowTrackingWorkItem: DispatchWorkItem?

  // Processing indicator (OCR, etc.)
  private var processingSpinner: NSProgressIndicator?
  private(set) var isProcessing = false

  private init() {}

  // MARK: - Public API

  /// Setup the status bar item with required dependencies
  func setup(viewModel: ScreenCaptureViewModel, updater: SPUUpdater, didCrash: Bool = false) {
    self.viewModel = viewModel
    self.updater = updater
    self.didDetectCrash = didCrash

    syncStatusItemVisibility()
    buildMenu()
    observeRecordingState()

    // Pre-allocate area selection windows for instant activation (<150ms)
    AreaSelectionController.shared.prepareWindowPool()
    DiagnosticLogger.shared.log(
      .info,
      .ui,
      "Status bar item initialized",
      context: ["previousCrashPrompt": didCrash ? "true" : "false"]
    )
  }

  func stopRecording() {
    RecordingCoordinator.shared.stopFromStatusItem()
  }

  /// Show or hide a processing spinner on the menu bar icon (e.g. during OCR).
  /// The spinner runs on Core Animation so it stays animated even when the main thread is briefly busy.
  func setProcessing(_ active: Bool) {
    guard active != isProcessing else { return }
    isProcessing = active

    guard let button = statusItem?.button else { return }

    if active {
      // Swap to a transparent placeholder of the same size to preserve layout
      if let icon = button.image {
        let placeholder = NSImage(size: icon.size)
        placeholder.isTemplate = true
        button.image = placeholder
      }

      // Create a spinning indicator sized to match the icon
      let size: CGFloat = 16
      let spinner = NSProgressIndicator()
      spinner.style = .spinning
      spinner.controlSize = .small
      spinner.isIndeterminate = true
      spinner.isDisplayedWhenStopped = false
      spinner.frame = CGRect(
        x: (button.bounds.width - size) / 2,
        y: (button.bounds.height - size) / 2,
        width: size,
        height: size
      )
      spinner.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
      button.addSubview(spinner)
      spinner.startAnimation(nil)
      processingSpinner = spinner

      DiagnosticLogger.shared.log(.debug, .ui, "Status bar processing indicator started")
    } else {
      processingSpinner?.stopAnimation(nil)
      processingSpinner?.removeFromSuperview()
      processingSpinner = nil

      // Restore original icon
      button.image = idleStatusImage
      DiagnosticLogger.shared.log(.debug, .ui, "Status bar processing indicator stopped")
    }
  }

  // MARK: - Private Setup

  func setMenuBarIconVisible(_ visible: Bool) {
    UserDefaults.standard.set(visible, forKey: PreferencesKeys.showMenuBarIcon)
    syncStatusItemVisibility()
  }

  var isMenuBarIconVisible: Bool {
    statusItem != nil
  }

  private func syncStatusItemVisibility() {
    let shouldShow = UserDefaults.standard.object(forKey: PreferencesKeys.showMenuBarIcon) as? Bool ?? true

    if shouldShow {
      setupStatusItem()
    } else {
      removeStatusItem()
    }
  }

  private func setupStatusItem() {
    guard statusItem == nil else {
      renderStatusItem()
      return
    }

    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    // macOS persists a ⌘-drag removal per item; the Snapzy preference is the source of truth.
    statusItem?.isVisible = true

    if let button = statusItem?.button {
      button.imagePosition = .imageLeading
      button.target = self
      button.action = #selector(statusBarButtonClicked(_:))
      button.sendAction(on: [.leftMouseUp, .rightMouseUp])
      renderStatusItem()
    }

    // Occlusion is only known once the status bar window is on screen (see issue #587).
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
      self?.observeStatusItemOcclusion()
      self?.logStatusItemVisibilityIfChanged(trigger: "setup")
    }
  }

  // MARK: - Hidden Status Item Detection

  /// True when the icon is enabled but macOS is not drawing it, e.g. it was pushed behind the
  /// notch or under the active app's menus on a crowded menu bar (issue #587).
  var isMenuBarIconObscured: Bool {
    guard let statusItem else { return false }
    guard statusItem.isVisible, let window = statusItem.button?.window else { return true }
    let screen = window.screen
    return Self.isStatusItemObscured(
      itemFrame: window.frame,
      screenFrame: screen?.frame,
      notchGap: screen.flatMap { Self.notchGap(of: $0) },
      isOcclusionVisible: window.occlusionState.contains(.visible)
    )
  }

  /// Pure decision for whether a status item window is actually visible to the user.
  /// Extracted for deterministic testing; AppKit reports `isVisible == true` for hidden items.
  nonisolated static func isStatusItemObscured(
    itemFrame: CGRect,
    screenFrame: CGRect?,
    notchGap: ClosedRange<CGFloat>?,
    isOcclusionVisible: Bool
  ) -> Bool {
    guard isOcclusionVisible, let screenFrame else { return true }
    if itemFrame.minX < screenFrame.minX || itemFrame.maxX > screenFrame.maxX {
      return true
    }
    if let notchGap, itemFrame.minX < notchGap.upperBound, itemFrame.maxX > notchGap.lowerBound {
      return true
    }
    return false
  }

  /// Horizontal span covered by the camera housing, or nil on screens without a notch.
  private static func notchGap(of screen: NSScreen) -> ClosedRange<CGFloat>? {
    guard let left = screen.auxiliaryTopLeftArea,
          let right = screen.auxiliaryTopRightArea,
          left.maxX < right.minX else { return nil }
    return left.maxX...right.minX
  }

  private var statusItemOcclusionObserver: NSObjectProtocol?
  private var lastLoggedStatusItemObscured: Bool?
  private var didWarnStatusItemObscured = false

  private func observeStatusItemOcclusion() {
    removeStatusItemOcclusionObserver()
    guard let window = statusItem?.button?.window else { return }
    statusItemOcclusionObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didChangeOcclusionStateNotification,
      object: window,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.logStatusItemVisibilityIfChanged(trigger: "occlusionChange")
      }
    }
  }

  private func removeStatusItemOcclusionObserver() {
    if let statusItemOcclusionObserver {
      NotificationCenter.default.removeObserver(statusItemOcclusionObserver)
    }
    statusItemOcclusionObserver = nil
    lastLoggedStatusItemObscured = nil
    didWarnStatusItemObscured = false
  }

  private func logStatusItemVisibilityIfChanged(trigger: String) {
    guard let statusItem else { return }
    let obscured = isMenuBarIconObscured
    guard obscured != lastLoggedStatusItemObscured else { return }
    lastLoggedStatusItemObscured = obscured

    let window = statusItem.button?.window
    let context = [
      "trigger": trigger,
      "isVisible": statusItem.isVisible ? "true" : "false",
      "frame": window.map { NSStringFromRect($0.frame) } ?? "none",
      "occlusionVisible": (window?.occlusionState.contains(.visible) ?? false) ? "true" : "false",
      "hasNotch": (window?.screen.flatMap { Self.notchGap(of: $0) } != nil) ? "true" : "false",
    ]
    if obscured {
      // An auto-hiding menu bar flips occlusion on every reveal, so warn once per item.
      DiagnosticLogger.shared.log(
        didWarnStatusItemObscured ? .debug : .warning,
        .ui,
        "Menu bar icon is enabled but hidden by the system",
        context: context
      )
      didWarnStatusItemObscured = true
    } else {
      DiagnosticLogger.shared.log(.debug, .ui, "Menu bar icon is visible", context: context)
    }
  }

  private func removeStatusItem() {
    guard let statusItem else { return }
    removeStatusItemOcclusionObserver()
    processingSpinner?.stopAnimation(nil)
    processingSpinner?.removeFromSuperview()
    processingSpinner = nil
    isProcessing = false
    NSStatusBar.system.removeStatusItem(statusItem)
    self.statusItem = nil
  }

  @objc private func statusBarButtonClicked(_ sender: NSStatusBarButton) {
    guard let event = NSApp.currentEvent else { return }
    switch event.type {
    case .leftMouseUp:
      // With the hover bar hidden during recording, a left-click stops immediately
      // (macOS ⌘⇧5 parity). Right-click still opens the full menu.
      if isMenuBarActingAsStopControl {
        DiagnosticLogger.shared.log(.debug, .ui, "Status bar direct stop (hover bar hidden)")
        stopRecording()
        return
      }
      DiagnosticLogger.shared.log(.debug, .ui, "Status bar menu opened", context: ["event": "leftMouseUp"])
      showMenu()
    case .rightMouseUp:
      DiagnosticLogger.shared.log(.debug, .ui, "Status bar menu opened", context: ["event": "rightMouseUp"])
      showMenu()
    default:
      break
    }
  }

  private func showMenu() {
    guard let button = statusItem?.button else { return }
    buildMenu()  // Rebuild to update state
    statusItem?.menu = menu
    button.performClick(nil)
    statusItem?.menu = nil  // Reset to allow custom click handling
  }

  // MARK: - Recording UI Preferences

  /// Whether the floating recording controls bar is shown during recording.
  /// When hidden, the menu bar becomes the primary stop control (macOS ⌘⇧5 parity).
  /// Shared source of truth with `RecordingCoordinator` via `RecordingToolbarPreferences`.
  private var isHoverBarVisible: Bool {
    RecordingToolbarPreferences.hoverBarVisible()
  }

  /// Whether the elapsed recording time is shown next to the menu bar icon. Defaults to `true`.
  private var showsRecordingTimeOnMenuBar: Bool {
    RecordingToolbarPreferences.showTimeOnMenuBar()
  }

  /// True while the menu bar item acts as the direct stop control
  /// (recording/paused AND the hover bar is hidden).
  private var isMenuBarActingAsStopControl: Bool {
    (recorder.state == .recording || recorder.state == .paused) && !isHoverBarVisible
  }

  // MARK: - State Observation

  private func observeRecordingState() {
    recorder.$state
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        self?.renderStatusItem()
        self?.syncTrackedPreferencesWindowExclusion()
      }
      .store(in: &cancellables)

    recorder.$elapsedSeconds
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        self?.renderStatusItem()
      }
      .store(in: &cancellables)

    // Re-render when recording UI preferences change (e.g. toggled in Settings mid-recording).
    NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        self?.scheduleRenderStatusItem()
      }
      .store(in: &cancellables)
  }

  private var isStatusItemRenderScheduled = false

  /// Coalesce bursts of UserDefaults changes (e.g. slider drags) into one
  /// status-item render per runloop (see issue #335).
  private func scheduleRenderStatusItem() {
    guard !isStatusItemRenderScheduled else { return }
    isStatusItemRenderScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      isStatusItemRenderScheduled = false
      renderStatusItem()
    }
  }

  /// Tints the menu bar icon while the `snapzy` command is capturing, so a
  /// capture started by another app is never invisible.
  func setCLIActivity(_ active: Bool) {
    guard isShowingCLIActivity != active else { return }
    isShowingCLIActivity = active
    // Tint only: re-rendering would replace a running OCR spinner's image.
    statusItem?.button?.contentTintColor = active ? .controlAccentColor : nil
  }

  /// False when the icon is turned off or macOS hides it (notch, crowded menu bar).
  var isStatusItemVisibleToUser: Bool {
    statusItem != nil && !isMenuBarIconObscured
  }

  private func renderStatusItem() {
    guard let button = statusItem?.button else { return }
    // When the hover bar is hidden during recording, the menu bar item becomes the stop
    // control and shows a distinct stop glyph (macOS ⌘⇧5 parity). Otherwise use the app icon.
    button.image = isMenuBarActingAsStopControl ? (recordingStopImage ?? idleStatusImage) : idleStatusImage
    button.contentTintColor = isShowingCLIActivity ? .controlAccentColor : nil
    button.attributedTitle = statusItemAttributedTitle(for: recorder.state)
    button.toolTip = statusItemTooltip(for: recorder.state)
    button.setAccessibilityLabel(statusItemTooltip(for: recorder.state))
  }

  /// Pure decision for the menu bar title text. Empty when the time display is off or there is
  /// nothing to show. Extracted for deterministic testing of the optional-time gating.
  nonisolated static func menuBarTitleString(
    for state: RecordingState,
    duration: String,
    showTime: Bool
  ) -> String {
    guard showTime else { return "" }
    switch state {
    case .recording:
      return duration
    case .paused:
      return "|| \(duration)"
    case .idle, .preparing, .stopping:
      return ""
    }
  }

  private func statusItemAttributedTitle(for state: RecordingState) -> NSAttributedString {
    let title = Self.menuBarTitleString(
      for: state,
      duration: recorder.formattedDuration,
      showTime: showsRecordingTimeOnMenuBar
    )

    guard !title.isEmpty else {
      return NSAttributedString(string: "")
    }

    let menuBarFont = NSFont.menuBarFont(ofSize: 0)
    let monospacedDigitsFont = NSFont.monospacedDigitSystemFont(
      ofSize: menuBarFont.pointSize,
      weight: .regular
    )

    return NSAttributedString(
      string: title,
      attributes: [
        .font: monospacedDigitsFont,
        .foregroundColor: NSColor.labelColor,
      ]
    )
  }

  private func statusItemTooltip(for state: RecordingState) -> String {
    // When the menu bar is the stop control, tell the user a click stops the recording.
    if isMenuBarActingAsStopControl {
      return L10n.RecordingToolbar.clickToStop(recorder.formattedDuration)
    }
    switch state {
    case .recording:
      return "\(L10n.RecordingToolbar.recordingInProgress) (\(recorder.formattedDuration))"
    case .paused:
      return "\(L10n.RecordingToolbar.recordingPaused) (\(recorder.formattedDuration))"
    case .preparing:
      return "OwnShot"
    case .stopping:
      return "OwnShot"
    case .idle:
      return "OwnShot"
    }
  }

  /// Idle menu bar icon for the configured style. Cached per style + custom
  /// icon file date; recomputed when the user changes icon preferences.
  private var idleStatusImage: NSImage? {
    let style = menuBarCustomizationStore.iconStyle
    let customDate = style == .custom ? menuBarIconRenderer.customIconModificationDate : nil

    if let cachedIdleStatusImage,
       cachedIdleStatusStyle == style,
       cachedCustomIconDate == customDate {
      return cachedIdleStatusImage
    }

    let image = menuBarIconRenderer.statusImage(for: style)
    cachedIdleStatusImage = image
    cachedIdleStatusStyle = style
    cachedCustomIconDate = customDate
    return image
  }

  /// Distinct "stop" glyph shown on the menu bar item while recording with the hover bar hidden.
  /// Signals that a click stops the recording (macOS ⌘⇧5 parity).
  private func makeRecordingStopImage() -> NSImage? {
    let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
    // Actionable a11y cue matching the icon's behavior (a click stops the recording).
    let image = NSImage(
      systemSymbolName: "stop.circle.fill",
      accessibilityDescription: L10n.RecordingToolbar.stopRecordingHint
    )?.withSymbolConfiguration(config)
    image?.isTemplate = true
    return image
  }

  // MARK: - Menu Building

  private func buildMenu() {
    menu = NSMenu()
    menu?.autoenablesItems = false

    guard let viewModel = viewModel else {
      DiagnosticLogger.shared.log(.warning, .ui, "Status bar menu requested before view model setup")
      return
    }
    let shortcutManager = KeyboardShortcutManager.shared

    // Recording status indicator (when recording)
    if recorder.state == .recording || recorder.state == .paused {
      let stopItem = NSMenuItem(
        title: L10n.Menu.stopRecording(recorder.formattedDuration),
        action: #selector(stopRecordingAction),
        keyEquivalent: ""
      )
      stopItem.target = self
      stopItem.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: nil)
      stopItem.isEnabled = true
      menu?.addItem(stopItem)

      let pauseResumeItem = NSMenuItem(
        title: recorder.isPaused ? L10n.RecordingToolbar.resumeRecording : L10n.RecordingToolbar.pauseRecording,
        action: #selector(togglePauseRecordingAction),
        keyEquivalent: ""
      )
      pauseResumeItem.target = self
      pauseResumeItem.image = NSImage(
        systemSymbolName: recorder.isPaused ? "play.fill" : "pause.fill",
        accessibilityDescription: nil
      )
      pauseResumeItem.isEnabled = recorder.state == .recording || recorder.state == .paused
      menu?.addItem(pauseResumeItem)

      menu?.addItem(NSMenuItem.separator())
    }

    // Activate... эталона виден только без лицензии. OwnShot всегда лицензирован,
    // поэтому пункт появляется лишь с Option.
    if OwnShotLicense.showsActivateMenuItem(optionPressed: NSEvent.modifierFlags.contains(.option)) {
      let activate = NSMenuItem(title: L10n.License.activateMenuItem, action: #selector(activateLicenseAction), keyEquivalent: "")
      activate.target = self
      menu?.addItem(activate)
      menu?.addItem(.separator())
    }

    let allInOne = NSMenuItem(title: "All-In-One", action: #selector(captureAllInOneAction), keyEquivalent: "")
    allInOne.target = self
    allInOne.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: nil)
    allInOne.isEnabled = viewModel.hasPermission
    menu?.addItem(allInOne)
    let captureOrder: [MenuBarItemKind] = [.captureArea, .captureFullscreen, .captureApplication, .scrollingCapture, .captureDelayed, .captureOCR, .recordScreen]
    for kind in captureOrder {
      let item = makeMenuItem(for: kind, viewModel: viewModel, shortcutManager: shortcutManager)
      switch kind {
      case .captureApplication: item.title = "Capture Window"
      case .captureDelayed: item.title = "Self-Timer"
      default: break
      }
      menu?.addItem(item)
      if kind == .captureArea {
        let previous = NSMenuItem(title: "Capture Previous Area", action: #selector(capturePreviousAreaAction), keyEquivalent: "")
        previous.target = self
        previous.image = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: nil)
        previous.isEnabled = viewModel.hasPermission
        applyConfiguredShortcut(previous, for: .repeatArea, using: shortcutManager)
        menu?.addItem(previous)
      }
    }
    menu?.addItem(.separator())
    let hideIcons = NSMenuItem(title: "Hide Desktop Icons", action: #selector(toggleCaptureDesktopIconsAction), keyEquivalent: "")
    hideIcons.target = self
    hideIcons.state = OwnShotDesktopIconsController.shared.isHidden ? .on : .off
    // У эталона монохромная иконка у всех 13 пунктов от All-In-One до Capture History.
    hideIcons.image = NSImage(systemSymbolName: Self.hideDesktopIconsSymbol, accessibilityDescription: nil)
    menu?.addItem(hideIcons)
    menu?.addItem(.separator())
    let open = NSMenuItem(title: "Open…", action: #selector(openImageAction), keyEquivalent: "")
    open.target = self
    open.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
    menu?.addItem(open)
    let pin = NSMenuItem(title: "Pin to the Screen…", action: #selector(pinImageAction), keyEquivalent: "")
    pin.target = self
    pin.image = NSImage(systemSymbolName: "pin", accessibilityDescription: nil)
    menu?.addItem(pin)
    let optionPressed = NSEvent.modifierFlags.contains(.option)
    // Open from Clipboard в эталоне скрыт в покое. У OwnShot он виден с Option.
    if optionPressed {
      let openFromClipboard = NSMenuItem(title: "Open from Clipboard", action: #selector(openFromClipboardAction), keyEquivalent: "")
      openFromClipboard.target = self
      openFromClipboard.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
      openFromClipboard.isEnabled = NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil)
      menu?.addItem(openFromClipboard)
    }
    menu?.addItem(.separator())
    let history = makeMenuItem(for: .openHistory, viewModel: viewModel, shortcutManager: shortcutManager)
    history.title = "Capture History…"
    menu?.addItem(history)

    let extras = MenuBarItemGroup.allCases.flatMap { menuBarCustomizationStore.orderedVisibleItems(for: $0) }
      .filter { !captureOrder.contains($0) && $0 != .openHistory && $0 != .checkForUpdates }
    if Self.showsMoreSubmenu(extras: extras, optionPressed: optionPressed, hasCustomizedMenu: hasCustomizedMenuBar) {
      let more = NSMenuItem(title: "More", action: nil, keyEquivalent: "")
      let submenu = NSMenu()
      submenu.autoenablesItems = false
      extras.forEach { submenu.addItem(makeMenuItem(for: $0, viewModel: viewModel, shortcutManager: shortcutManager)) }
      more.submenu = submenu
      menu?.addItem(more)
    }
    menu?.addItem(.separator())
    let about = NSMenuItem(title: "About OwnShot…", action: #selector(openAboutAction), keyEquivalent: "")
    about.target = self
    menu?.addItem(about)

    // Permission (if not granted)
    if !viewModel.hasPermission {
      let permissionItem = NSMenuItem(
        title: L10n.Menu.grantPermission,
        action: #selector(grantPermissionAction),
        keyEquivalent: ""
      )
      permissionItem.target = self
      permissionItem.image = NSImage(
        systemSymbolName: "lock.shield", accessibilityDescription: nil)
      permissionItem.isEnabled = true
      menu?.addItem(permissionItem)
      menu?.addItem(NSMenuItem.separator())
    }

    let updates = NSMenuItem(title: "Check for Updates…", action: nil, keyEquivalent: "")
    updates.isEnabled = false
    updates.toolTip = "OwnShot is a local build. Automatic updates are not configured."
    menu?.addItem(updates)

    // Settings… отдельной группой, как в эталоне.
    menu?.addItem(NSMenuItem.separator())
    let prefsItem = NSMenuItem(
      title: "Settings…",
      action: #selector(openPreferencesAction),
      keyEquivalent: ","
    )
    prefsItem.keyEquivalentModifierMask = .command
    prefsItem.target = self
    // У Settings… и Quit эталона иконок нет.
    prefsItem.isEnabled = true
    menu?.addItem(prefsItem)

    menu?.addItem(NSMenuItem.separator())

    // Quit: в эталоне подпись «Quit» без сочетания клавиш.
    let quitItem = NSMenuItem(
      title: "Quit",
      action: #selector(quitAction),
      keyEquivalent: ""
    )
    quitItem.target = self
    quitItem.isEnabled = true
    menu?.addItem(quitItem)

    // Строки с иконкой 30 pt, как у эталона, без своих view и с системной подсветкой.
    if let menu { StatusMenuRowMetrics.applyIconRowHeight(to: menu) }
  }

  // MARK: - Menu Item Factory

  /// Builds a configured menu entry for a customizable item. Titles, icons,
  /// actions, shortcuts, and enabled states are identical to the original
  /// fixed menu regardless of user ordering or visibility.
  private func makeMenuItem(
    for kind: MenuBarItemKind,
    viewModel: ScreenCaptureViewModel,
    shortcutManager: KeyboardShortcutManager
  ) -> NSMenuItem {
    switch kind {
    case .captureArea:
      let item = NSMenuItem(
        title: L10n.Actions.captureArea,
        action: #selector(captureAreaAction),
        keyEquivalent: ""
      )
      applyConfiguredShortcut(item, for: .area, using: shortcutManager)
      item.target = self
      item.image = NSImage(systemSymbolName: "crop", accessibilityDescription: nil)
      item.isEnabled = viewModel.hasPermission
      return item

    case .captureAreaAnnotate:
      let item = NSMenuItem(
        title: L10n.Actions.captureAreaAnnotate,
        action: #selector(captureAreaAnnotateAction),
        keyEquivalent: ""
      )
      applyConfiguredShortcut(item, for: .areaAnnotate, using: shortcutManager)
      item.target = self
      item.image = NSImage(systemSymbolName: "pencil.and.scribble", accessibilityDescription: nil)
      item.isEnabled = viewModel.hasPermission
      return item

    case .captureApplication:
      let item = NSMenuItem(
        title: L10n.PreferencesShortcuts.applicationCaptureTitle,
        action: #selector(captureApplicationAction),
        keyEquivalent: ""
      )
      Self.configureOverlayMenuItem(
        item,
        base: L10n.PreferencesShortcuts.applicationCaptureTitle,
        shortcut: CaptureOverlayShortcutSettings.applicationCaptureShortcut,
        parentKind: .area,
        using: shortcutManager
      )
      item.target = self
      item.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
      item.isEnabled = viewModel.hasPermission
      return item

    case .captureFullscreen:
      let item = NSMenuItem(
        title: L10n.Actions.captureFullscreen,
        action: #selector(captureFullscreenAction),
        keyEquivalent: ""
      )
      applyConfiguredShortcut(item, for: .fullscreen, using: shortcutManager)
      item.target = self
      item.image = NSImage(
        systemSymbolName: "rectangle.dashed", accessibilityDescription: nil)
      item.isEnabled = viewModel.hasPermission
      return item

    case .captureDelayed:
      let item = NSMenuItem(
        title: L10n.Menu.delayedCapture(CaptureDelayOption.current().seconds),
        action: #selector(captureDelayedAction),
        keyEquivalent: ""
      )
      applyConfiguredShortcut(item, for: .delayedCapture, using: shortcutManager)
      item.target = self
      item.image = NSImage(systemSymbolName: "timer", accessibilityDescription: nil)
      item.isEnabled = viewModel.hasPermission
      return item

    case .captureDelayedFullscreen:
      let item = NSMenuItem(
        title: L10n.Menu.delayedFullscreenCapture(CaptureDelayOption.current().seconds),
        action: #selector(captureDelayedFullscreenAction),
        keyEquivalent: ""
      )
      applyConfiguredShortcut(item, for: .delayedFullscreen, using: shortcutManager)
      item.target = self
      item.image = NSImage(systemSymbolName: "display", accessibilityDescription: nil)
      item.isEnabled = viewModel.hasPermission
      return item

    case .captureActiveWindow:
      let item = NSMenuItem(
        title: L10n.Actions.captureActiveWindow,
        action: #selector(captureActiveWindowAction),
        keyEquivalent: ""
      )
      applyConfiguredShortcut(item, for: .activeWindow, using: shortcutManager)
      item.target = self
      item.image = NSImage(
        systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: nil)
      item.isEnabled = viewModel.hasPermission
      return item

    case .scrollingCapture:
      let item = NSMenuItem(
        title: L10n.Actions.scrollingCapture,
        action: #selector(captureScrollingAction),
        keyEquivalent: ""
      )
      applyConfiguredShortcut(item, for: .scrollingCapture, using: shortcutManager)
      item.target = self
      item.image = NSImage(systemSymbolName: "arrow.up.and.down", accessibilityDescription: nil)
      item.isEnabled = viewModel.hasPermission && !ScrollingCaptureCoordinator.shared.isActive
      return item

    case .captureOCR:
      let item = NSMenuItem(
        title: L10n.Actions.captureTextOCR,
        action: #selector(captureOCRAction),
        keyEquivalent: ""
      )
      applyConfiguredShortcut(item, for: .ocr, using: shortcutManager)
      item.target = self
      item.image = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: nil)
      item.isEnabled = viewModel.hasPermission
      return item

    case .captureSmartElement:
      let item = NSMenuItem(
        title: L10n.Actions.captureSmartElement,
        action: #selector(captureSmartElementAction),
        keyEquivalent: ""
      )
      applyConfiguredShortcut(item, for: .smartElement, using: shortcutManager)
      item.target = self
      item.image = NSImage(systemSymbolName: "dot.viewfinder", accessibilityDescription: nil)
      item.isEnabled = viewModel.hasPermission
      return item

    case .captureObjectCutout:
      let item = NSMenuItem(
        title: GlobalShortcutKind.objectCutout.displayName,
        action: #selector(captureObjectCutoutAction),
        keyEquivalent: ""
      )
      applyConfiguredShortcut(item, for: .objectCutout, using: shortcutManager)
      item.target = self
      item.image = NSImage(systemSymbolName: "person.crop.rectangle", accessibilityDescription: nil)
      if #available(macOS 14.0, *) {
        item.isEnabled = viewModel.hasPermission
      } else {
        item.isEnabled = false
      }
      return item

    case .recordScreen:
      let item = NSMenuItem(
        title: L10n.Menu.recordScreen,
        action: #selector(recordScreenAction),
        keyEquivalent: ""
      )
      applyConfiguredShortcut(item, for: .recording, using: shortcutManager)
      item.target = self
      item.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: nil)
      item.isEnabled = viewModel.hasPermission && !recorder.isActive
      return item

    case .recordApplication:
      let item = NSMenuItem(
        title: L10n.PreferencesShortcuts.applicationRecordingTitle,
        action: #selector(recordApplicationAction),
        keyEquivalent: ""
      )
      Self.configureOverlayMenuItem(
        item,
        base: L10n.PreferencesShortcuts.applicationRecordingTitle,
        shortcut: CaptureOverlayShortcutSettings.recordingApplicationCaptureShortcut,
        parentKind: .recording,
        using: shortcutManager
      )
      item.target = self
      item.image = NSImage(systemSymbolName: "square.on.square", accessibilityDescription: nil)
      item.isEnabled = viewModel.hasPermission && !recorder.isActive
      return item

    case .openAnnotate:
      let item = NSMenuItem(
        title: L10n.Actions.openAnnotate,
        action: #selector(openAnnotateAction),
        keyEquivalent: ""
      )
      applyConfiguredShortcut(item, for: .annotate, using: shortcutManager)
      item.target = self
      item.image = NSImage(
        systemSymbolName: "pencil.and.outline", accessibilityDescription: nil)
      item.isEnabled = true
      return item

    case .combineImages:
      let item = NSMenuItem(
        title: L10n.Combine.open,
        action: #selector(openCombineImagesAction),
        keyEquivalent: ""
      )
      item.target = self
      item.image = NSImage(
        systemSymbolName: "rectangle.3.group", accessibilityDescription: nil)
      item.isEnabled = true
      return item

    case .pickColor:
      let item = NSMenuItem(
        title: L10n.Actions.pickColor,
        action: #selector(pickColorAction),
        keyEquivalent: ""
      )
      applyConfiguredShortcut(item, for: .pickColor, using: shortcutManager)
      item.target = self
      item.image = NSImage(systemSymbolName: "eyedropper", accessibilityDescription: nil)
      item.isEnabled = viewModel.hasPermission
      return item

    case .measureScreen:
      let item = NSMenuItem(
        title: L10n.Actions.measureScreen,
        action: #selector(measureScreenAction),
        keyEquivalent: ""
      )
      applyConfiguredShortcut(item, for: .measureScreen, using: shortcutManager)
      item.target = self
      item.image = NSImage(systemSymbolName: "ruler", accessibilityDescription: nil)
      item.isEnabled = viewModel.hasPermission
      return item

    case .editVideo:
      let item = NSMenuItem(
        title: L10n.Menu.editVideo,
        action: #selector(editVideoAction),
        keyEquivalent: ""
      )
      applyConfiguredShortcut(item, for: .videoEditor, using: shortcutManager)
      item.target = self
      item.image = NSImage(systemSymbolName: "film", accessibilityDescription: nil)
      item.isEnabled = true
      return item

    case .cloudUploads:
      let item = NSMenuItem(
        title: L10n.Actions.cloudUploads,
        action: #selector(openCloudUploadsAction),
        keyEquivalent: ""
      )
      applyConfiguredShortcut(item, for: .cloudUploads, using: shortcutManager)
      item.target = self
      item.image = NSImage(systemSymbolName: "icloud.and.arrow.up", accessibilityDescription: nil)
      item.isEnabled = true
      return item

    case .openHistory:
      let item = NSMenuItem(
        title: L10n.Actions.openHistory,
        action: #selector(openHistoryAction),
        keyEquivalent: ""
      )
      applyConfiguredShortcut(item, for: .history, using: shortcutManager)
      item.target = self
      item.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
      item.isEnabled = true
      return item

    case .shortcutList:
      let item = NSMenuItem(
        title: L10n.Menu.keyboardShortcuts,
        action: #selector(showShortcutListAction),
        keyEquivalent: ""
      )
      applyConfiguredShortcut(item, for: .shortcutList, using: shortcutManager)
      item.target = self
      item.image = NSImage(systemSymbolName: "list.bullet.rectangle", accessibilityDescription: nil)
      item.isEnabled = true
      return item

    case .checkForUpdates:
      let item = NSMenuItem(
        title: L10n.Menu.checkForUpdates,
        action: #selector(checkForUpdatesAction),
        keyEquivalent: ""
      )
      item.target = self
      item.image = NSImage(
        systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
      item.isEnabled = true
      return item
    }
  }

  // MARK: - Menu Actions

  @objc private func stopRecordingAction() {
    logMenuAction("stopRecording", context: ["state": "\(recorder.state)"])
    stopRecording()
  }

  @objc private func togglePauseRecordingAction() {
    logMenuAction("togglePauseRecording", context: ["state": "\(recorder.state)"])
    recorder.togglePause()
  }

  @objc private func capturePreviousAreaAction() { viewModel?.captureRepeatArea() }

  @objc private func captureAllInOneAction() { viewModel?.captureAllInOne() }

  @objc private func toggleCaptureDesktopIconsAction() {
    OwnShotDesktopIconsController.shared.toggle()
  }

  @objc private func openAboutAction() { PreferencesWindowController.shared.show(tab: .about) }

  @objc private func openImageAction() {
    let panel = NSOpenPanel()
    // Проекты OwnShot открываются тем же пунктом, что и картинки.
    panel.allowedContentTypes = [.image, OwnShotProjectFormat.contentType]
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    AnnotateManager.shared.openAnnotation(url: url)
  }

  @objc private func openFromClipboardAction() {
    logMenuAction("openFromClipboard")
    viewModel?.openAnnotationFromClipboard()
  }

  /// Пользователь хоть раз менял состав меню в Preferences → Menu Bar.
  private var hasCustomizedMenuBar: Bool {
    UserDefaults.standard.object(forKey: PreferencesKeys.menuBarHiddenItems) != nil
  }

  /// More в покое не показывается (у эталона в меню 17 пунктов без него).
  /// Он появляется с Option или когда пользователь сам настроил меню.
  static func showsMoreSubmenu(extras: [MenuBarItemKind], optionPressed: Bool, hasCustomizedMenu: Bool) -> Bool {
    guard !extras.isEmpty else { return false }
    return optionPressed || hasCustomizedMenu
  }

  @objc private func pinImageAction() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.image]
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task { _ = await QuickAccessManager.shared.pinScreenshot(url: url) }
  }

  @objc private func captureAreaAction() {
    logMenuAction("captureArea")
    viewModel?.captureArea()
  }

  @objc private func captureAreaAnnotateAction() {
    logMenuAction("captureAreaAnnotate")
    viewModel?.captureAreaAnnotate()
  }

  @objc private func captureApplicationAction() {
    logMenuAction("captureApplication")
    viewModel?.captureApplication()
  }

  @objc private func captureFullscreenAction() {
    logMenuAction("captureFullscreen")
    viewModel?.captureFullscreen()
  }

  @objc private func captureDelayedAction() {
    logMenuAction("captureDelayed")
    viewModel?.captureDelayed()
  }

  @objc private func captureDelayedFullscreenAction() {
    logMenuAction("captureDelayedFullscreen")
    viewModel?.captureDelayedFullscreen()
  }

  @objc private func captureActiveWindowAction() {
    logMenuAction("captureActiveWindow")
    viewModel?.captureActiveWindow()
  }

  @objc private func captureScrollingAction() {
    logMenuAction("captureScrolling")
    viewModel?.captureScrolling()
  }

  @objc private func captureOCRAction() {
    logMenuAction("captureOCR")
    viewModel?.captureOCR()
  }

  @objc private func captureSmartElementAction() {
    logMenuAction("captureSmartElement")
    SmartElementCaptureController.shared.startCapture()
  }

  @objc private func captureObjectCutoutAction() {
    logMenuAction("captureObjectCutout")
    viewModel?.captureObjectCutout()
  }

  @objc private func recordScreenAction() {
    logMenuAction("recordScreen")
    viewModel?.startRecordingFlow()
  }

  @objc private func recordApplicationAction() {
    logMenuAction("recordApplication")
    viewModel?.startApplicationRecordingFlow()
  }

  @objc private func openAnnotateAction() {
    logMenuAction("openAnnotate")
    AnnotateManager.shared.openEmptyAnnotation()
  }

  @objc private func openCombineImagesAction() {
    logMenuAction("openCombineImages")
    CombineImagesCoordinator.shared.presentPicker()
  }

  @objc private func pickColorAction() {
    logMenuAction("pickColor")
    viewModel?.pickColor()
  }

  @objc private func measureScreenAction() {
    logMenuAction("measureScreen")
    viewModel?.measureScreen()
  }

  @objc private func editVideoAction() {
    logMenuAction("editVideo")
    VideoEditorManager.shared.openEmptyEditor()
  }

  @objc private func openCloudUploadsAction() {
    logMenuAction(
      "openCloudUploads",
      context: ["cloudConfigured": CloudManager.shared.isConfigured ? "true" : "false"]
    )
    let didShow = CloudUploadHistoryWindowController.shared.toggleWindow()
    DiagnosticLogger.shared.log(
      .debug,
      .cloud,
      "Cloud uploads window toggled",
      context: ["shown": didShow ? "true" : "false"]
    )
    if didShow {
      NSApp.activate(ignoringOtherApps: true)
    }
  }

  @objc private func openHistoryAction() {
    logMenuAction("openHistory")
    HistoryFloatingManager.shared.toggle()
  }

  @objc private func showShortcutListAction() {
    logMenuAction("showShortcutList")
    ShortcutOverlayManager.shared.toggle()
  }

  @objc private func grantPermissionAction() {
    logMenuAction("grantPermission")
    viewModel?.requestPermission()
  }

  @objc private func checkForUpdatesAction() {
    logMenuAction("checkForUpdates")
    UpdaterManager.shared.checkForUpdates()
  }

  @objc private func showPendingFeatureIntroAction() {
    logMenuAction("showPendingFeatureIntro")
    if let campaign = FeatureIntroManager.shared.getPendingCampaign() {
      FeatureIntroManager.shared.showCampaign(campaign)
    }
  }

  @objc private func reportProblemAction() {
    logMenuAction("reportProblem")
    CrashReportService.presentAlert()
    didDetectCrash = false
  }

  @objc private func openPreferencesAction() {
    logMenuAction("openPreferences")
    openPreferencesWindow()
  }

  @objc private func replayOnboardingAction() {
    PreferencesWindowController.shared.show(tab: .permissions)
  }

  func openPreferencesWindow(tab: PreferencesTab? = nil) {
    if let tab {
      PreferencesNavigationState.shared.select(tab)
    }
    DiagnosticLogger.shared.log(
      .info,
      .preferences,
      "Preferences window requested",
      context: ["tab": tab.map { "\($0)" } ?? "current"]
    )
    presentPreferencesWindow(tab: tab)
  }

  private func presentPreferencesWindow(tab: PreferencesTab? = nil) {
    // Elevate to regular app so Snapzy appears in top-left menu bar
    if !didElevateForSettings {
      NSApp.setActivationPolicy(.regular)
      didElevateForSettings = true
      DiagnosticLogger.shared.log(.debug, .ui, "Activation policy elevated for preferences window")

      // Observe when Settings window closes to revert policy
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(windowDidClose(_:)),
        name: NSWindow.willCloseNotification,
        object: nil
      )
    }

    PreferencesWindowController.shared.show(tab: tab)

    if let window = PreferencesWindowController.shared.window {
      trackedPreferencesWindow = window
      syncTrackedPreferencesWindowExclusion()
    }
  }

  // MARK: - Ready Bubble

  /// Сколько держится пузырь «OwnShot is ready to use!» после повторного запуска.
  static let readyBubbleDuration: TimeInterval = 3

  private var readyBubble: OwnShotReadyBubbleWindow?
  private var readyBubbleHideWorkItem: DispatchWorkItem?

  /// Рамка значка в строке меню в координатах экрана; nil, если значка нет или его не видно.
  var statusItemScreenFrame: CGRect? {
    guard let statusItem, statusItem.isVisible, !isMenuBarIconObscured,
          let window = statusItem.button?.window else { return nil }
    return window.frame
  }

  /// Повторный запуск при видимом значке: эталон показывает под значком пузырь
  /// «… is ready to use!» на несколько секунд и Settings не открывает.
  func showReadyBubble() {
    guard let anchor = statusItemScreenFrame else { return }
    readyBubbleHideWorkItem?.cancel()
    let bubble = readyBubble ?? OwnShotReadyBubbleWindow(text: L10n.Menu.readyToUse)
    readyBubble = bubble
    let screenFrame = statusItem?.button?.window?.screen?.frame
    let frame = Self.readyBubbleFrame(anchor: anchor, size: bubble.bubbleSize, screenFrame: screenFrame)
    bubble.arrowX = anchor.midX - frame.minX
    bubble.setFrame(frame, display: true)
    bubble.orderFrontRegardless()
    let hide = DispatchWorkItem { [weak self] in self?.readyBubble?.orderOut(nil) }
    readyBubbleHideWorkItem = hide
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.readyBubbleDuration, execute: hide)
    DiagnosticLogger.shared.log(.info, .ui, "Ready bubble shown on reopen")
  }

  /// Рамка пузыря: по центру под значком, впритык к нижнему краю строки меню, не выходит за экран.
  nonisolated static func readyBubbleFrame(anchor: CGRect, size: CGSize, screenFrame: CGRect?) -> CGRect {
    var x = anchor.midX - size.width / 2
    if let screenFrame {
      x = min(max(x, screenFrame.minX + 4), screenFrame.maxX - size.width - 4)
    }
    return CGRect(x: x, y: anchor.minY - size.height - 2, width: size.width, height: size.height)
  }

  // MARK: - Settings Scene Trigger

  /// The app menu can lag behind the activation policy transition, so the
  /// Settings menu item lookup retries a few times before falling back.
  private static let settingsTriggerMaxAttempts = 5
  private static let settingsTriggerRetryDelay: TimeInterval = 0.1

  /// Physical key that macOS binds to the "Settings…" app menu item.
  private static let settingsShortcutKeyCode = UInt16(kVK_ANSI_Comma)

  private func attemptToTriggerSettings(remainingAttempts: Int) {
    if let mainMenu = NSApp.mainMenu,
       let settingsItem = Self.findSettingsMenuItem(
         in: mainMenu,
         shortcutCharacter: Self.settingsShortcutCharacter()
       ),
       let parentMenu = settingsItem.menu,
       let itemIndex = parentMenu.items.firstIndex(of: settingsItem) {
      parentMenu.performActionForItem(at: itemIndex)
      return
    }

    if remainingAttempts > 1 {
      DispatchQueue.main.asyncAfter(deadline: .now() + Self.settingsTriggerRetryDelay) { [weak self] in
        self?.attemptToTriggerSettings(remainingAttempts: remainingAttempts - 1)
      }
    } else {
      DiagnosticLogger.shared.log(
        .warning,
        .preferences,
        "Settings menu item not found; opening preferences directly"
      )
      PreferencesWindowController.shared.show()
    }
  }

  /// Finds the "Settings…" menu item created by the SwiftUI `Settings` scene.
  ///
  /// The scene item uses a private action (`menuAction:`), so when no standard
  /// action selector matches, it is identified by its shortcut: Command plus
  /// the character the physical comma key produces on the active keyboard
  /// layout. AppKit mirrors the item's key equivalent to that character
  /// ("," on U.S., "ö" on Turkish Q), which is why matching must be
  /// layout-aware (issue #311). The shortcut match is scoped to the
  /// application menu to avoid colliding with unrelated items.
  static func findSettingsMenuItem(in mainMenu: NSMenu, shortcutCharacter: String) -> NSMenuItem? {
    if let actionMatch = findMenuItem(in: mainMenu, where: { item in
      item.action == Selector(("showSettingsWindow:"))
        || item.action == Selector(("showPreferencesWindow:"))
    }) {
      return actionMatch
    }

    guard let appMenu = mainMenu.items.first?.submenu else { return nil }
    return appMenu.items.first { item in
      item.keyEquivalentModifierMask.contains(.command)
        && !item.keyEquivalent.isEmpty
        && (item.keyEquivalent == shortcutCharacter || item.keyEquivalent == ",")
    }
  }

  private static func findMenuItem(in menu: NSMenu, where predicate: (NSMenuItem) -> Bool) -> NSMenuItem? {
    for item in menu.items {
      if predicate(item) { return item }
      if let submenu = item.submenu, let found = findMenuItem(in: submenu, where: predicate) {
        return found
      }
    }
    return nil
  }

  /// Символ физической клавиши «запятая» на раскладке подписей сочетаний (та же
  /// ASCII-совместимая, что и у остальных подписей); "," – если перевести не удалось.
  private static func settingsShortcutCharacter() -> String {
    ShortcutConfig.layoutKeyCharacter(for: UInt32(settingsShortcutKeyCode)) ?? ","
  }

  @objc private func windowDidClose(_ notification: Notification) {
    let closingWindow = notification.object as? NSWindow
    if let window = closingWindow, trackedPreferencesWindow === window {
      DiagnosticLogger.shared.log(.debug, .preferences, "Tracked preferences window closed")
      trackedPreferencesWindow = nil
      removeTrackedPreferencesWindowExclusion()
    }

    if didElevateForSettings {
      NSApp.revertActivationPolicyToAccessoryIfNeeded(excluding: closingWindow)
    }
    if NSApp.activationPolicy() == .accessory && didElevateForSettings {
      didElevateForSettings = false
      DiagnosticLogger.shared.log(.debug, .ui, "Activation policy restored after preferences closed")
      NotificationCenter.default.removeObserver(
        self,
        name: NSWindow.willCloseNotification,
        object: nil
      )
    }
  }

  @objc private func activateLicenseAction() {
    logMenuAction("activateLicense")
    OwnShotLicensePresenter.shared.showActivationWindow()
  }

  @objc private func quitAction() {
    logMenuAction("quit")
    NSApp.terminate(nil)
  }

  private func logMenuAction(_ action: String, context: [String: String]? = nil) {
    DiagnosticLogger.shared.log(
      .info,
      .action,
      "Menu action invoked",
      context: {
        var values = context ?? [:]
        values["action"] = action
        return values
      }()
    )
  }

  private func applyConfiguredShortcut(
    _ item: NSMenuItem,
    for kind: GlobalShortcutKind,
    using manager: KeyboardShortcutManager
  ) {
    guard manager.isShortcutEnabled(for: kind) else {
      item.keyEquivalent = ""
      item.keyEquivalentModifierMask = []
      return
    }

    let config = manager.shortcut(for: kind)
    guard let config, let keyEquivalent = config.menuKeyEquivalent else {
      item.keyEquivalent = ""
      item.keyEquivalentModifierMask = []
      return
    }

    item.keyEquivalent = keyEquivalent
    item.keyEquivalentModifierMask = config.menuModifierFlags
  }

  static func configureOverlayMenuItem(
    _ item: NSMenuItem,
    base: String,
    shortcut: CaptureOverlayShortcut?,
    parentKind: GlobalShortcutKind,
    using manager: KeyboardShortcutManager
  ) {
    guard let shortcut else {
      item.title = base
      item.keyEquivalent = ""
      item.keyEquivalentModifierMask = []
      return
    }

    if shortcut.isIndependent {
      item.title = base
      guard let config = shortcut.independentShortcutConfig,
            let keyEquivalent = config.menuKeyEquivalent else {
        item.keyEquivalent = ""
        item.keyEquivalentModifierMask = []
        return
      }

      item.keyEquivalent = keyEquivalent
      item.keyEquivalentModifierMask = config.menuModifierFlags
      return
    }

    // Зависимая клавиша (Space после ⇧⌘4) не получает сочетание родителя: иначе ⇧⌘4
    // повторяется у Capture Area и Capture Window, а у эталона каждое сочетание уникально.
    item.title = base
    item.keyEquivalent = ""
    item.keyEquivalentModifierMask = []
  }

  static let hideDesktopIconsSymbol = "eye.slash"


  private func schedulePreferencesWindowTracking(excludingWindowNumbers existingWindowNumbers: Set<Int>) {
    pendingPreferencesWindowTrackingWorkItem?.cancel()
    DiagnosticLogger.shared.log(
      .debug,
      .preferences,
      "Preferences window tracking scheduled",
      context: ["existingWindows": "\(existingWindowNumbers.count)"]
    )

    let workItem = DispatchWorkItem { [weak self] in
      self?.trackPreferencesWindow(excludingWindowNumbers: existingWindowNumbers, remainingAttempts: 12)
    }
    pendingPreferencesWindowTrackingWorkItem = workItem
    DispatchQueue.main.async(execute: workItem)
  }

  private func trackPreferencesWindow(excludingWindowNumbers existingWindowNumbers: Set<Int>, remainingAttempts: Int) {
    pendingPreferencesWindowTrackingWorkItem = nil

    if let trackedPreferencesWindow, trackedPreferencesWindow.isVisible {
      syncTrackedPreferencesWindowExclusion()
      return
    }

    if let candidate = NSApp.windows.first(where: {
      $0.isVisible &&
      $0.level == .normal &&
      $0.className != "NSStatusBarWindow" &&
      !existingWindowNumbers.contains($0.windowNumber)
    }) {
      trackedPreferencesWindow = candidate
      DiagnosticLogger.shared.log(
        .debug,
        .preferences,
        "Preferences window tracked",
        context: ["windowNumber": "\(candidate.windowNumber)"]
      )
      syncTrackedPreferencesWindowExclusion()
      return
    }

    guard remainingAttempts > 1 else {
      DiagnosticLogger.shared.log(.warning, .preferences, "Preferences window tracking timed out")
      return
    }

    let workItem = DispatchWorkItem { [weak self] in
      self?.trackPreferencesWindow(
        excludingWindowNumbers: existingWindowNumbers,
        remainingAttempts: remainingAttempts - 1
      )
    }
    pendingPreferencesWindowTrackingWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
  }

  private func syncTrackedPreferencesWindowExclusion() {
    guard let trackedPreferencesWindow, trackedPreferencesWindow.isVisible else {
      removeTrackedPreferencesWindowExclusion()
      return
    }

    let windowID = CGWindowID(trackedPreferencesWindow.windowNumber)

    guard recorder.isActive else {
      removeTrackedPreferencesWindowExclusion()
      return
    }

    guard trackedPreferencesExcludedWindowID != windowID else { return }

    let previousWindowID = trackedPreferencesExcludedWindowID
    trackedPreferencesExcludedWindowID = windowID
    DiagnosticLogger.shared.log(
      .debug,
      .recording,
      "Preferences window added to runtime recording exclusion",
      context: ["windowID": "\(windowID)"]
    )

    Task { @MainActor [weak self] in
      guard let self else { return }
      if let previousWindowID, previousWindowID != windowID {
        await self.recorder.removeRuntimeExcludedWindow(windowID: previousWindowID)
      }
      await self.recorder.addRuntimeExcludedWindow(windowID: windowID)
    }
  }

  private func removeTrackedPreferencesWindowExclusion() {
    guard let windowID = trackedPreferencesExcludedWindowID else { return }
    trackedPreferencesExcludedWindowID = nil
    DiagnosticLogger.shared.log(
      .debug,
      .recording,
      "Preferences window removed from runtime recording exclusion",
      context: ["windowID": "\(windowID)"]
    )

    Task { @MainActor [weak self] in
      guard let self else { return }
      await self.recorder.removeRuntimeExcludedWindow(windowID: windowID)
    }
  }

  #if DEBUG
    var didElevateForSettingsForTesting: Bool {
      get { didElevateForSettings }
      set { didElevateForSettings = newValue }
    }

    var trackedPreferencesWindowForTesting: NSWindow? {
      get { trackedPreferencesWindow }
      set { trackedPreferencesWindow = newValue }
    }

    func simulateWindowDidClose(notification: Notification) {
      windowDidClose(notification)
    }

    var isHoverBarVisibleForTesting: Bool { isHoverBarVisible }
    var showsRecordingTimeOnMenuBarForTesting: Bool { showsRecordingTimeOnMenuBar }
  #endif
}

/// Пузырь под значком строки меню, как у эталона при повторном запуске (≈209×46 pt,
/// чёрная капсула с хвостиком вверх, белый полужирный текст). Мышь не перехватывает.
@MainActor
final class OwnShotReadyBubbleWindow: NSPanel {
  /// Высота хвостика над капсулой.
  static let arrowHeight: CGFloat = 7
  static let font = NSFont.systemFont(ofSize: 15, weight: .semibold)

  let bubbleSize: CGSize
  var arrowX: CGFloat = 0 {
    didSet { bubbleView.arrowX = arrowX }
  }

  private let bubbleView: BubbleView

  init(text: String) {
    let textWidth = ceil((text as NSString).size(withAttributes: [.font: Self.font]).width)
    bubbleSize = CGSize(width: max(209, textWidth + 46), height: 46)
    bubbleView = BubbleView(text: text, font: Self.font, arrowHeight: Self.arrowHeight)
    super.init(
      contentRect: CGRect(origin: .zero, size: bubbleSize),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    ignoresMouseEvents = true
    isReleasedWhenClosed = false
    level = .popUpMenu
    collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
    bubbleView.frame = CGRect(origin: .zero, size: bubbleSize)
    bubbleView.arrowX = bubbleSize.width / 2
    contentView = bubbleView
    CaptureChromeWindowRegistry.configureToastWindow(self)
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  private final class BubbleView: NSView {
    let text: String
    let font: NSFont
    let arrowHeight: CGFloat
    var arrowX: CGFloat = 0 { didSet { needsDisplay = true } }

    init(text: String, font: NSFont, arrowHeight: CGFloat) {
      self.text = text
      self.font = font
      self.arrowHeight = arrowHeight
      super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
      let body = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height - arrowHeight)
      let path = NSBezierPath(roundedRect: body, xRadius: body.height / 2, yRadius: body.height / 2)
      let tipX = min(max(arrowX, body.height / 2 + arrowHeight), bounds.width - body.height / 2 - arrowHeight)
      let arrow = NSBezierPath()
      arrow.move(to: CGPoint(x: tipX - arrowHeight, y: body.maxY - 1))
      arrow.line(to: CGPoint(x: tipX, y: bounds.maxY))
      arrow.line(to: CGPoint(x: tipX + arrowHeight, y: body.maxY - 1))
      arrow.close()
      NSColor.black.setFill()
      path.fill()
      arrow.fill()

      let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
      let size = (text as NSString).size(withAttributes: attributes)
      let origin = CGPoint(x: body.midX - size.width / 2, y: body.midY - size.height / 2)
      (text as NSString).draw(at: origin, withAttributes: attributes)
    }
  }
}
