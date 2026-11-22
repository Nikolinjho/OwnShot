//
//  AnnotateWindow.swift
//  Snapzy
//
//  Dark mode annotation window with proper styling
//

import AppKit
import Combine
import SwiftUI

// MARK: - Notifications

extension Notification.Name {
  static let annotateSave = Notification.Name("annotateSave")
  static let annotateSaveAs = Notification.Name("annotateSaveAs")
  static let annotatePrint = Notification.Name("annotatePrint")
  static let annotateCopyAndClose = Notification.Name("annotateCopyAndClose")
  static let annotateCloudUpload = Notification.Name("annotateCloudUpload")
  static let annotateAutoRedactSensitiveData = Notification.Name("annotateAutoRedactSensitiveData")
  static let annotatePasteImage = Notification.Name("annotatePasteImage")
  static let annotateAddImage = Notification.Name("annotateAddImage")
  /// Снять новую область экрана и добавить её в текущий холст.
  static let annotateAddNewScreenshot = Notification.Name("annotateAddNewScreenshot")
  static let annotateTogglePin = Notification.Name("annotateTogglePin")
  static let annotateDragStarted = Notification.Name("annotateDragStarted")
  static let annotateDragEnded = Notification.Name("annotateDragEnded")
  static let annotateZoomIn = Notification.Name("annotateZoomIn")
  static let annotateZoomOut = Notification.Name("annotateZoomOut")
  static let annotateZoomReset = Notification.Name("annotateZoomReset")
  /// Масштаб 100%, как ⌘0 эталона. annotateZoomReset означает Fit Canvas (⌘1).
  static let annotateZoomActualSize = Notification.Name("annotateZoomActualSize")
  static let annotateScrollZoom = Notification.Name("annotateScrollZoom")
  static let annotateMagnifyZoom = Notification.Name("annotateMagnifyZoom")
  static let annotateSpaceDown = Notification.Name("annotateSpaceDown")
  static let annotateSpaceUp = Notification.Name("annotateSpaceUp")
  static let annotatePanDrag = Notification.Name("annotatePanDrag")
  static let annotatePanScroll = Notification.Name("annotatePanScroll")
}

/// Routes full-editor notifications to the view tree belonging to one window.
/// The weak reference keeps the SwiftUI content from retaining a closed window.
final class AnnotateWindowEventRouter {
  private weak var window: NSWindow?

  init(window: NSWindow) {
    self.window = window
  }

  func publisher(for name: Notification.Name) -> AnyPublisher<Notification, Never> {
    NotificationCenter.default.publisher(for: name)
      .filter { [weak self] notification in
        guard let object = notification.object as? NSWindow,
              let window = self?.window else { return false }
        return object === window
      }
      .eraseToAnyPublisher()
  }
}

/// Сочетания масштаба эталона: Zoom In ⌘+, Zoom Out ⌘−, Fit Canvas ⌘1, 100% ⌘0.
enum AnnotateZoomShortcut: Equatable {
  case zoomIn
  case zoomOut
  case fitCanvas
  case actualSize

  /// Основной ряд и цифровой блок; ⌘+ набирается и как ⌘=, и как ⇧⌘=.
  nonisolated static func match(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> AnnotateZoomShortcut? {
    let flags = flags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock])
    guard flags == .command || flags == [.command, .shift] else { return nil }
    let shifted = flags.contains(.shift)
    switch keyCode {
    case 24, 69: return .zoomIn
    case 27, 78: return shifted ? nil : .zoomOut
    case 18, 83: return shifted ? nil : .fitCanvas
    case 29, 82: return shifted ? nil : .actualSize
    default: return nil
    }
  }

  var notificationName: Notification.Name {
    switch self {
    case .zoomIn: .annotateZoomIn
    case .zoomOut: .annotateZoomOut
    case .fitCanvas: .annotateZoomReset
    case .actualSize: .annotateZoomActualSize
    }
  }
}

enum AnnotateObjectShortcut: Equatable {
  case copy
  case paste
  case duplicate
}

/// Custom NSWindow for annotation editing with dark mode appearance
class AnnotateWindow: NSWindow {
  weak var interactionState: AnnotateState?
  var onEscape: (() -> Bool)?
  private var restingLevel: NSWindow.Level = .normal
  private var themeObserver: AnyCancellable?
  // SET-192: эталон фиксирует Always on top при создании каждого редактора.
  private let opensAlwaysOnTop = OwnShotAnnotatePreferences().alwaysOnTop

  init(contentRect: NSRect) {
    super.init(
      contentRect: contentRect,
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    configure()
  }

  private func configure() {
    applyTheme()
    setupThemeObserver()

    // Enable full-size content view
    styleMask.insert(.fullSizeContentView)

    titlebarAppearsTransparent = true
    titleVisibility = .hidden
    minSize = NSSize(width: 990, height: 450)
    isReleasedWhenClosed = false
    center()

    // Explicit normal level for proper Cmd+Tab behavior
    level = preferredRestingLevel

    // Register as managed window for normal Cmd+` cycling
    collectionBehavior = [.managed, .participatesInCycle]

    // Increase window corner radius
    configureCornerRadius()
  }

  private func setupThemeObserver() {
    themeObserver = ThemeManager.shared.objectWillChange
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        self?.applyTheme()
      }
  }

  /// Configure custom corner radius for the window
  private func configureCornerRadius() {
    applyCornerRadius()
  }

  /// Apply current theme from ThemeManager
  func applyTheme() {
    let themeManager = ThemeManager.shared
    appearance = themeManager.nsAppearance
    // Окно прозрачно: под тулбаром и нижней панелью просвечивает то, что за окном,
    // как у эталона. Непрозрачный фон рисует сама область холста (AnnotateMainView).
    // Вместо .clear – подложка с альфой 2/255: с нулевой альфой WindowServer отдаёт
    // клики окну позади (зона светофора, промежутки между кнопками панели).
    isOpaque = false
    backgroundColor = AnnotateEditorBarMetrics.windowFloorColor
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }

  func setRestingLevel(_ newLevel: NSWindow.Level) {
    restingLevel = newLevel
    syncLevelWithFocusState()
  }

  func applyActiveEditorLevel() {
    level = preferredRestingLevel
  }

  func restoreRestingLevel() {
    level = preferredRestingLevel
  }

  private var preferredRestingLevel: NSWindow.Level {
    // Измеренный уровень окна эталона – 103; .floating (3) остаётся под меню.
    opensAlwaysOnTop ? NSWindow.Level(rawValue: 103) : restingLevel
  }

  func syncLevelWithFocusState() {
    level = preferredRestingLevel
  }

  override func layoutIfNeeded() {
    super.layoutIfNeeded()
    layoutTrafficLights(config: TrafficLightConfiguration(
      toolbarTopPadding: -4, horizontalOffset: 19, buttonSpacing: 9))
  }

  nonisolated static func annotationObjectShortcut(
    for event: NSEvent,
    isTextInputActive: Bool
  ) -> AnnotateObjectShortcut? {
    guard !isTextInputActive, event.type == .keyDown else { return nil }
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard flags.contains(.command),
          !flags.contains(.control),
          !flags.contains(.option),
          !flags.contains(.shift) else { return nil }

    if let characters = event.charactersIgnoringModifiers?.lowercased(), !characters.isEmpty {
      switch characters {
      case "c": return .copy
      case "v": return .paste
      case "d": return .duplicate
      default: return nil
      }
    }

    switch event.keyCode {
    case 8: return .copy
    case 9: return .paste
    case 2: return .duplicate
    default: return nil
    }
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard event.type == .keyDown else {
      return super.performKeyEquivalent(with: event)
    }

    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let textInputActive = isTextInputActive || interactionState?.editingTextAnnotationId != nil

    // Own Annotate undo/redo at the window boundary so Cmd+Z never falls
    // through to stale AppKit text-system undo actions from inline editing.
    if event.keyCode == 6 && flags == .command {
      interactionState?.undo()
      return true
    }

    if event.keyCode == 6 && flags == [.command, .shift] {
      interactionState?.redo()
      return true
    }

    let shortcuts = AnnotateShortcutManager.shared

    // Save (по умолчанию ⌘S) при активном кадрировании сначала подтверждает кадр.
    if shortcuts.matchesAction(.save, event: event) && interactionState?.isCropInteractionActive == true && !isTextInputActive {
      interactionState?.confirmCropInteraction()
      return true
    }

    // Save (Done action) — настраивается, по умолчанию ⌘S
    if shortcuts.matchesAction(.save, event: event) {
      NotificationCenter.default.post(name: .annotateSave, object: self)
      return true
    }

    // Save as — настраивается, по умолчанию ⇧⌘S
    if shortcuts.matchesAction(.saveAs, event: event) {
      NotificationCenter.default.post(name: .annotateSaveAs, object: self)
      return true
    }

    // Print — настраивается, по умолчанию ⌘P. Обработчик один: .annotatePrint в AnnotateWindowController.
    if shortcuts.matchesAction(.print, event: event), !textInputActive {
      NotificationCenter.default.post(name: .annotatePrint, object: self)
      return true
    }

    // Send to Raycast AI Chat — ⌘R, только при установленном Raycast; заглушка без отправки
    if OwnShotRaycastStub.isMenuVisible, !textInputActive,
       OwnShotRaycastStub.isSendShortcut(characters: event.charactersIgnoringModifiers, modifiers: flags) {
      OwnShotRaycastStub.send()
      return true
    }

    // Add Screenshot From File — по умолчанию ⌘I, тот же выбор файлов, что у кнопки Add Image
    if shortcuts.matchesAction(.addScreenshotFromFile, event: event), !textInputActive {
      NotificationCenter.default.post(name: .annotateAddImage, object: self)
      return true
    }

    // Add New Screenshot — по умолчанию ⇧⌘I
    if shortcuts.matchesAction(.addNewScreenshot, event: event), !textInputActive {
      NotificationCenter.default.post(name: .annotateAddNewScreenshot, object: self)
      return true
    }

    // Toggle Sidebar — configurable (default: ⌘B)
    if AnnotateShortcutManager.shared.matchesToggleSidebar(event) {
      guard !isTextInputActive, let interactionState else {
        return super.performKeyEquivalent(with: event)
      }
      if AnnotateShortcutManager.shared.toggleSidebarShortcut == AnnotateShortcutManager.defaultToggleSidebar {
        interactionState.showSidebar = true
      } else {
        interactionState.toggleSidebarVisibility()
      }
      return true
    }

    // Copy Screenshot to Clipboard — configurable (default: ⌘⇧C).
    // Как в CleanShot X: копируем без закрытия редактора.
    if AnnotateShortcutManager.shared.matchesCopyAndClose(event) {
      NotificationCenter.default.post(
        name: .annotateCopyAndClose,
        object: self,
        userInfo: AnnotateCopyCompletionPolicy.userInfo(for: .shortcut)
      )
      return true
    }

    // Pin to the Screen — configurable (по умолчанию без сочетания)
    if AnnotateShortcutManager.shared.matchesTogglePin(event) {
      NotificationCenter.default.post(name: .annotateTogglePin, object: self)
      return true
    }

    // Cloud Upload — configurable (default: ⌘U)
    if AnnotateShortcutManager.shared.matchesCloudUpload(event) {
      NotificationCenter.default.post(name: .annotateCloudUpload, object: self)
      return true
    }

    // Auto Redact Sensitive Data — configurable (default: unset). ⌘V всегда остаётся вставкой,
    // даже если сочетание Auto Redact совпало с ним.
    if AnnotateShortcutManager.shared.matchesAutoRedactSensitiveData(event),
       Self.annotationObjectShortcut(for: event, isTextInputActive: false) != .paste {
      if isTextInputActive {
        return super.performKeyEquivalent(with: event)
      }
      NotificationCenter.default.post(name: .annotateAutoRedactSensitiveData, object: self)
      return true
    }

    // Copy Object / Duplicate Object — настраиваются; при дефолтных ⌘C/⌘D работает и
    // распознавание по символу для раскладок, где C и D стоят не на своих местах.
    if !textInputActive {
      if shortcuts.matchesAction(.copyObject, event: event) {
        interactionState?.copySelectedAnnotations()
        return true
      }
      if shortcuts.matchesAction(.duplicateObject, event: event) {
        interactionState?.duplicateSelectedAnnotations()
        return true
      }
    }

    if let objectShortcut = Self.annotationObjectShortcut(
      for: event,
      isTextInputActive: textInputActive
    ) {
      switch objectShortcut {
      case .copy:
        guard Self.usesDefaultShortcut(.copyObject) else { break }
        interactionState?.copySelectedAnnotations()
        return true
      case .paste:
        if interactionState?.pasteAnnotationsFromClipboard() == true {
          return true
        }
        NotificationCenter.default.post(name: .annotatePasteImage, object: self)
        return true
      case .duplicate:
        guard Self.usesDefaultShortcut(.duplicateObject) else { break }
        interactionState?.duplicateSelectedAnnotations()
        return true
      }
    }

    // Cmd+V - Paste image into current annotate canvas.
    if event.keyCode == 9 && flags == .command {
      // Allow normal text paste while editing text annotations.
      if textInputActive {
        return super.performKeyEquivalent(with: event)
      }
      NotificationCenter.default.post(name: .annotatePasteImage, object: self)
      return true
    }

    // ⌘A — выделить все аннотации; в поле ввода остаётся выделение текста.
    if event.keyCode == 0 && flags == .command && !textInputActive,
       interactionState?.selectAllAnnotations() == true {
      return true
    }

    // Масштаб: ⌘+ / ⌘− / ⌘1 Fit Canvas / ⌘0 100%, в том числе с цифрового блока.
    if let zoom = AnnotateZoomShortcut.match(keyCode: event.keyCode, flags: event.modifierFlags) {
      // ⌘+ и ⌘− идут по ступеням эталона (AnnotateState.zoomIn/zoomOut), а не прибавкой к доле Fit.
      if let interactionState, interactionState.hasImage, zoom == .zoomIn || zoom == .zoomOut {
        withAnimation(.easeOut(duration: 0.15)) {
          if zoom == .zoomIn { interactionState.zoomIn() } else { interactionState.zoomOut() }
        }
        return true
      }
      NotificationCenter.default.post(name: zoom.notificationName, object: self)
      return true
    }

    return super.performKeyEquivalent(with: event)
  }

  /// Команда включена и стоит на дефолтном сочетании.
  private static func usesDefaultShortcut(_ kind: AnnotateActionShortcutKind) -> Bool {
    let manager = AnnotateShortcutManager.shared
    return manager.isActionShortcutEnabled(for: kind)
      && manager.shortcut(for: kind) == AnnotateShortcutManager.defaultShortcut(for: kind)
  }

  /// Однобуквенные команды редактора: размер инструмента и переназначенный Background Tool.
  /// Обрабатываются в sendEvent, потому что клавиши без модификаторов не доходят до performKeyEquivalent.
  private func handleSingleKeyAction(_ event: NSEvent) -> Bool {
    guard !isTextInputActive,
          interactionState?.editingTextAnnotationId == nil,
          let state = interactionState else { return false }
    let shortcuts = AnnotateShortcutManager.shared
    if shortcuts.matchesAction(.increaseToolSize, event: event) {
      state.adjustQuickStrokeWidth(by: 1)
      return true
    }
    if shortcuts.matchesAction(.decreaseToolSize, event: event) {
      state.adjustQuickStrokeWidth(by: -1)
      return true
    }
    // Дефолтную B обрабатывает холст (с учётом клавиш инструментов); здесь только своё назначение.
    if !event.isARepeat, let custom = shortcuts.toggleSidebarShortcut, custom.modifiers == 0,
       custom != AnnotateShortcutManager.defaultToggleSidebar,
       shortcuts.matchesToggleSidebar(event) {
      state.toggleSidebarVisibility()
      return true
    }
    return false
  }

  @objc func undo(_ sender: Any?) {
    interactionState?.undo()
  }

  @objc func redo(_ sender: Any?) {
    interactionState?.redo()
  }

  override func close() {
    // Restore cursor if the window is closed during a space-hold pan gesture
    // (e.g., user presses ⌘W while Space is held). The keyUp event that would
    // normally restore the arrow cursor never fires after window closure.
    if isSpaceHeld {
      isSpaceHeld = false
      NSCursor.arrow.set()
    }
    super.close()
  }

  // MARK: - Scroll Wheel, Magnification Zoom & Pan

  /// Track whether Space key is currently held for pan mode
  private var isSpaceHeld = false

  /// Whether the current first responder is a text input (TextEditor, NSTextView, etc.)
  private var isTextInputActive: Bool {
    guard let responder = firstResponder else { return false }
    return responder is NSTextView || responder is NSTextField
  }

  private func viewUnderCursor(for event: NSEvent) -> NSView? {
    guard let contentView else { return nil }
    let point = contentView.convert(event.locationInWindow, from: nil)
    return contentView.hitTest(point)
  }

  private func isCursorOverScrollableView(for event: NSEvent) -> Bool {
    var currentView = viewUnderCursor(for: event)
    while let view = currentView {
      if view is NSScrollView || view is NSScroller {
        return true
      }
      currentView = view.superview
    }
    return false
  }

  private func shouldPanForScrollEvent(_ event: NSEvent) -> Bool {
    guard !event.modifierFlags.contains(.command),
          !isTextInputActive,
          interactionState?.canPanInteractively == true,
          !isCursorOverScrollableView(for: event) else { return false }
    return event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0
  }

  private func gesturePanDelta(for event: NSEvent) -> CGSize {
    // Direct manipulation UX: finger gesture direction should match image movement.
    // `state.pan(by:)` eventually feeds `.offset(...)` on the canvas, so using the
    // raw scroll deltas here keeps touchpad pan feeling like "grab and move".
    CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY)
  }

  /// Intercept scroll wheel (Cmd+scroll), trackpad magnify, Space key,
  /// and mouse drag events at the window level for zoom & pan.
  override func sendEvent(_ event: NSEvent) {
    if event.type == .keyDown, handleSingleKeyAction(event) {
      return
    }

    switch event.type {
    case .keyDown where event.keyCode == 53:
      if isTextInputActive { break }
      if interactionState?.isCutOutInteractionActive == true {
        interactionState?.cancelCutOutInteraction()
        return
      }
      if interactionState?.isCropInteractionActive == true {
        interactionState?.cancelCrop()
        return
      }
      if onEscape?() == true { return }

    case .keyDown where event.keyCode == 36 || event.keyCode == 76:
      guard !isTextInputActive, let state = interactionState else { break }
      if state.isCutOutInteractionActive {
        if state.cutOutPreviewStrip != nil { state.commitCutOut() }
        return
      }
      guard state.isCropInteractionActive else { break }
      state.confirmCropInteraction()
      return

    case .scrollWheel where event.modifierFlags.contains(.command):
      // Cmd + scroll wheel → zoom
      let delta = event.scrollingDeltaY
      guard delta != 0 else { break }
      NotificationCenter.default.post(
        name: .annotateScrollZoom,
        object: self,
        userInfo: ["delta": delta]
      )
      return  // Consume event

    case .scrollWheel where shouldPanForScrollEvent(event):
      let delta = gesturePanDelta(for: event)
      NotificationCenter.default.post(
        name: .annotatePanScroll,
        object: self,
        userInfo: [
          "deltaX": delta.width,
          "deltaY": delta.height
        ]
      )
      return

    case .magnify:
      // Trackpad pinch → zoom
      let magnification = event.magnification
      NotificationCenter.default.post(
        name: .annotateMagnifyZoom,
        object: self,
        userInfo: ["magnification": magnification]
      )
      return  // Consume event

    case .keyDown where event.keyCode == 49:
      // If a text input is focused, let Space pass through for typing
      if isTextInputActive { break }
      // Space key down — consume ALL (including repeats) to prevent system beep
      if !event.isARepeat, interactionState?.canPanInteractively == true {
        isSpaceHeld = true
        NSCursor.openHand.set()
        NotificationCenter.default.post(name: .annotateSpaceDown, object: self)
      }
      return  // Always consume to silence beep

    case .keyUp where event.keyCode == 49:
      // If a text input is focused, let Space pass through
      if isTextInputActive { break }
      // Space key up → deactivate pan mode
      let wasSpaceHeld = isSpaceHeld
      isSpaceHeld = false
      if wasSpaceHeld {
        NSCursor.arrow.set()
        NotificationCenter.default.post(name: .annotateSpaceUp, object: self)
      }
      return

    case .leftMouseDragged where isSpaceHeld || (interactionState?.isCanvasPanningMode == true && !isTextInputActive):
      // Mouse drag while the hand tool is active → pan.
      NSCursor.closedHand.set()
      let dx = event.deltaX
      let dy = event.deltaY
      NotificationCenter.default.post(
        name: .annotatePanDrag,
        object: self,
        userInfo: ["deltaX": dx, "deltaY": dy]
      )
      return  // Consume — don't forward to drawing canvas

    case .leftMouseDown where isSpaceHeld || (interactionState?.isCanvasPanningMode == true && !isTextInputActive):
      // Consume mouse-down during pan to prevent drawing.
      return

    case .leftMouseUp where isSpaceHeld || interactionState?.isCanvasPanningMode == true:
      // Consume mouse-up during pan, restore the appropriate hand cursor.
      if interactionState?.isCanvasPanningMode == true {
        NSCursor.openHand.set()
      } else {
        NSCursor.arrow.set()
      }
      return

    default:
      break
    }
    super.sendEvent(event)
  }
}
