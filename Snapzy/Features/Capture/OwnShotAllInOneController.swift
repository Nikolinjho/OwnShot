import AppKit
import Combine
import SwiftUI

@MainActor
final class OwnShotAllInOneController: NSObject, ObservableObject, RecordingRegionOverlayDelegate {
  static let shared = OwnShotAllInOneController()
  enum Mode: String, CaseIterable { case area = "Area", fullscreen = "Fullscreen", window = "Window", scrolling = "Scrolling", timer = "Timer", ocr = "OCR", recording = "Recording" }

  /// Действие клавиши в панели: буквы режимов из подсказок эталона и ⌘C.
  enum KeyAction: Equatable {
    case activate(Mode)
    case copy
    case dismiss
  }
  @Published var rect: CGRect = .zero
  @Published var mode: Mode = .area
  @Published private var aspectRatio: CGFloat?
  var isAspectRatioLocked: Bool { aspectRatio != nil }
  private var overlays: [RecordingRegionOverlayWindow] = []
  private var panel: NSPanel?
  private var escapeMonitor: Any?
  private var globalEscapeMonitor: Any?
  private var previousApp: NSRunningApplication?
  private weak var viewModel: ScreenCaptureViewModel?
  private var windowTarget: WindowCaptureTarget?

  func present(viewModel: ScreenCaptureViewModel, on requestedScreen: NSScreen? = nil, selection: CGRect? = nil) {
    guard panel == nil, !AreaSelectionController.shared.isPresenting, !RecordingCoordinator.shared.isActive else { return }
    self.viewModel = viewModel
    previousApp = NSWorkspace.shared.frontmostApplication
    guard let screen = requestedScreen
      ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
      ?? NSScreen.main else { return }
    mode = .area
    aspectRatio = nil
    rect = selection ?? OwnShotAdvancedPreferences.initialSelection(
      previous: ScreenshotLastAreaStore.load(), screenFrame: screen.frame)
    rect = OwnShotCaptureGeometry.resized(rect, width: rect.width, height: rect.height, locked: false, within: screen.frame)
    showOverlays()
    let panel = OwnShotAllInOnePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    panel.isFloatingPanel = true
    panel.level = NSWindow.Level(rawValue: 103)
    panel.identifier = NSUserInterfaceItemIdentifier("OwnShotAllInOne")
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
    // Панели HUD всегда тёмные (R28): поля, меню и системный цвет выделения (R33) берутся
    // из тёмной темы и в светлой теме приложения.
    panel.appearance = NSAppearance(named: .darkAqua)
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.contentView = NSHostingView(rootView: OwnShotAllInOneView(controller: self))
    let size = panel.contentView!.fittingSize
    panel.setContentSize(size)
    panel.setFrameOrigin(OwnShotCaptureGeometry.toolbarOrigin(for: rect, panelSize: size, visibleFrame: screen.visibleFrame))
    CaptureChromeWindowRegistry.shared.register(panel, role: .captureOverlay)
    self.panel = panel
    panel.makeKeyAndOrderFront(nil)
    panel.makeFirstResponder(nil)
    escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard !AreaSelectionController.shared.isPresenting else { return event }
      let keyCode = event.keyCode
      let characters = event.charactersIgnoringModifiers
      let modifiers = event.modifierFlags
      let handled = MainActor.assumeIsolated { () -> Bool in
        guard let self else { return false }
        // Ввод в поля ширины и высоты не перехватывается, кроме Esc.
        let isEditingField = self.panel?.firstResponder is NSText
        guard let action = Self.keyAction(
          keyCode: keyCode,
          characters: characters,
          modifiers: modifiers,
          isEditingField: isEditingField
        ) else { return false }
        self.handle(action)
        return true
      }
      return handled ? nil : event
    }
    globalEscapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard event.keyCode == 53 else { return }
      Task { @MainActor in
        guard !AreaSelectionController.shared.isPresenting else { return }
        self?.dismiss()
      }
    }
  }

  private func showOverlays() {
    overlays.forEach { $0.close() }
    overlays = NSScreen.screens.map { screen in
      let overlay = RecordingRegionOverlayWindow(screen: screen, highlightRect: rect, chromeRole: .captureOverlay)
      overlay.interactionDelegate = self
      overlay.identifier = NSUserInterfaceItemIdentifier("OwnShotAllInOneOverlay")
      overlay.setAspectRatio(aspectRatio)
      // Рамка – белые скобки углов и меток середин без контура, как и у записи (R27).
      overlay.setInteractionEnabled(true)
      overlay.orderFrontRegardless()
      return overlay
    }
    panel?.orderFrontRegardless()
  }

  func choose(_ mode: Mode) {
    self.mode = mode
    windowTarget = nil
    if mode == .fullscreen, let screen = selectionScreen {
      update(screen.frame)
    } else if mode == .window {
      selectRegion(window: true)
    }
  }

  static func keyAction(
    keyCode: UInt16,
    characters: String?,
    modifiers: NSEvent.ModifierFlags,
    isEditingField: Bool
  ) -> KeyAction? {
    if keyCode == 53 { return .dismiss }
    guard !isEditingField else { return nil }
    let significant = modifiers.intersection([.command, .option, .control, .shift])
    let key = characters?.lowercased()
    if significant == .command { return key == "c" ? .copy : nil }
    guard significant.isEmpty else { return nil }
    if keyCode == 49 { return .activate(.window) } // Space
    switch key {
    case "a": return .activate(.area)
    case "f": return .activate(.fullscreen)
    case "w": return .activate(.window)
    case "s": return .activate(.scrolling)
    case "o": return .activate(.ocr)
    case "r": return .activate(.recording)
    default: return nil
    }
  }

  /// Буква режима в подсказке кнопки, как «Capture Area (A)» у эталона.
  static func helpText(for mode: Mode) -> String {
    switch mode {
    case .area: L10n.AllInOne.captureAreaHelp
    case .fullscreen: L10n.AllInOne.captureFullscreenHelp
    case .window: L10n.AllInOne.captureWindowHelp
    case .scrolling: L10n.AllInOne.scrollingCaptureHelp
    case .timer: L10n.AllInOne.selfTimerHelp
    case .ocr: L10n.AllInOne.captureTextHelp
    case .recording: L10n.AllInOne.recordScreenHelp
    }
  }

  private func handle(_ action: KeyAction) {
    switch action {
    case .dismiss: dismiss()
    case .activate(let mode): activate(mode)
    case .copy: perform(action: "copy")
    }
  }

  /// Малая кнопка expand: выделение растягивается до экрана без снимка.
  func expandToScreen() {
    guard let screen = selectionScreen ?? NSScreen.main else { return }
    windowTarget = nil
    if mode == .window || mode == .fullscreen { mode = .area }
    update(screen.frame)
  }

  func activate(_ mode: Mode) {
    self.mode = mode
    if mode == .window {
      selectRegion(window: true, performAfterSelection: true)
    } else {
      choose(mode)
      perform()
    }
  }

  func selectRegion(window: Bool = false, performAfterSelection: Bool = false) {
    overlays.forEach { $0.orderOut(nil) }
    panel?.orderOut(nil)
    AreaSelectionController.shared.startSelection(mode: .screenshot, backdrops: [:], applicationConfiguration: AreaSelectionApplicationConfiguration(prefetchedContentTask: ScreenCaptureManager.shared.prefetchShareableContent(), excludeOwnApplication: true), initialInteractionMode: window ? .applicationWindow : .manualRegion) { [weak self] selection in
      guard let self else { return }
      guard let selection else { dismiss(); return }
      windowTarget = selection.target.windowTarget
      update(selection.rect)
      if performAfterSelection { perform(); return }
      overlays.forEach { $0.orderFrontRegardless() }
      panel?.makeKeyAndOrderFront(nil)
    }
  }

  func resize(width: CGFloat?, height: CGFloat?, locked: Bool) {
    guard let screen = selectionScreen else { return }
    windowTarget = nil
    update(OwnShotCaptureGeometry.resized(rect, width: width, height: height, locked: locked, within: screen.frame, keepingCenter: true))
  }

  func setAspectRatio(_ ratio: CGFloat?) {
    DiagnosticLogger.shared.log(.debug, .ui, "Capture aspect ratio requested", context: [
      "ratio": ratio.map { String(Double($0)) } ?? "freeform",
      "rect": "\(rect)",
    ])
    aspectRatio = ratio
    overlays.forEach { $0.setAspectRatio(ratio) }
    guard let ratio, let screen = selectionScreen else { return }
    windowTarget = nil
    update(OwnShotCaptureGeometry.applyingAspectRatio(ratio, to: rect, within: screen.frame))
  }

  private var selectionScreen: NSScreen? {
    let screens = NSScreen.screens
    return OwnShotCaptureGeometry.screenIndex(for: rect, in: screens.map(\.frame)).map { screens[$0] }
  }

  private func update(_ rect: CGRect) {
    self.rect = rect
    overlays.forEach { $0.updateHighlightRect(rect) }
    if let panel, let screen = selectionScreen {
      panel.setFrameOrigin(OwnShotCaptureGeometry.toolbarOrigin(for: rect, panelSize: panel.frame.size, visibleFrame: screen.visibleFrame))
    }
    if mode != .fullscreen { ScreenshotLastAreaStore.save(rect) }
  }

  func dismiss() {
    if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
    escapeMonitor = nil
    if let globalEscapeMonitor { NSEvent.removeMonitor(globalEscapeMonitor) }
    globalEscapeMonitor = nil
    overlays.forEach { $0.close() }; overlays = []
    if let panel { CaptureChromeWindowRegistry.shared.unregister(panel); panel.close() }; panel = nil
    previousApp?.activate(options: [])
  }

  func perform() { perform(action: nil) }

  /// action "copy" для ⌘C: снимок сразу копируется в буфер. Запись и OCR идут своим путём.
  func perform(action: String?) {
    guard let viewModel else { return }
    let rect = rect, mode = mode, target = windowTarget
    dismiss()
    switch mode {
    case .area: viewModel.captureRegion(rect, action: action)
    case .fullscreen: viewModel.captureRegion(rect, action: action, rememberArea: false)
    case .window:
      if let target { viewModel.captureSelectedWindow(target, action: action) }
      else { viewModel.captureRegion(rect, action: action) }
    case .scrolling: viewModel.captureScrolling(rect: rect)
    case .ocr: viewModel.captureOCR(rect: rect)
    case .recording: RecordingCoordinator.shared.showToolbar(for: rect, captureMode: target == nil ? .area : .application, windowTarget: target)
    case .timer:
      viewModel.captureDelayedRegion(rect, action: action)
    }
  }

  func overlayDidRequestReselection(_ overlay: RecordingRegionOverlayWindow) { selectRegion() }
  func overlay(_ overlay: RecordingRegionOverlayWindow, didMoveRegionTo rect: CGRect) { update(rect) }
  func overlayDidFinishMoving(_ overlay: RecordingRegionOverlayWindow) {}
  func overlay(_ overlay: RecordingRegionOverlayWindow, didReselectWithRect rect: CGRect) { update(rect) }
  func overlay(_ overlay: RecordingRegionOverlayWindow, didResizeRegionTo rect: CGRect) { update(rect) }
  func overlayDidFinishResizing(_ overlay: RecordingRegionOverlayWindow) {}
}

private struct OwnShotAllInOneView: View {
  @ObservedObject var controller: OwnShotAllInOneController

  var body: some View {
    // Зазор между панелями – 10 pt, как у эталона (R29).
    HStack(spacing: OwnShotHUDStyle.panelSpacing) {
      ZStack(alignment: .topLeading) {
        ForEach(OwnShotAllInOneController.Mode.allCases, id: \.self) { mode in
          Button { controller.activate(mode) } label: {
            VStack(spacing: 5) {
              glyph(for: mode)
              Text(mode.rawValue)
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: OwnShotHUDStyle.secondaryForeground))
            }
            .frame(width: 62, height: 52)
            .contentShape(Rectangle())
          }
          .buttonStyle(OwnShotAllInOneModeButtonStyle())
          .help(OwnShotAllInOneController.helpText(for: mode))
          .position(x: center(for: mode), y: 27)
        }
        separator.position(x: 320, y: 27)
        separator.position(x: 389, y: 27)
      }
      .frame(width: 458, height: 54)
      .modifier(OwnShotCapturePanelSurface())

      ZStack(alignment: .topLeading) {
        // Поля, малая кнопка expand и сегмент соотношений по рамкам AX эталона.
        OwnShotCaptureSizeView(
          rect: controller.rect,
          onResize: controller.resize,
          onAspectRatio: controller.setAspectRatio,
          onExpand: controller.expandToScreen,
          isRatioLocked: controller.isAspectRatioLocked
        )
          .position(x: 79, y: 27)
        separator
          .position(x: 150.5, y: 27)
        OwnShotCaptureAspectRatioSegment(rect: controller.rect, onAspectRatio: controller.setAspectRatio)
          .position(x: 185, y: 27)
      }
      .frame(width: 218, height: 54)
      .modifier(OwnShotCapturePanelSurface())
    }
    .foregroundStyle(.white)
    .padding(.horizontal, 3)
    .padding(.vertical, 7.5)
    .fixedSize()
    .onExitCommand { controller.dismiss() }
    .background {
      Button("Capture", action: controller.perform)
        .keyboardShortcut(.return, modifiers: [])
        .hidden()
    }
  }

  /// Разделитель того же цвета, что внутренняя кромка панели (R07).
  private var separator: some View {
    Rectangle().fill(Color(nsColor: OwnShotHUDStyle.innerEdge(.allInOne)))
      .frame(width: OwnShotHUDStyle.edgeWidth, height: 36)
  }

  private func center(for mode: OwnShotAllInOneController.Mode) -> CGFloat {
    switch mode {
    case .area: 34.5
    case .fullscreen: 97.5
    case .window: 160
    case .scrolling: 222.75
    case .timer: 285.5
    case .ocr: 354.25
    case .recording: 423.25
    }
  }

  @ViewBuilder
  private func glyph(for mode: OwnShotAllInOneController.Mode) -> some View {
    switch mode {
    case .area: OwnShotCaptureGlyph(kind: .area)
    case .fullscreen: OwnShotCaptureGlyph(kind: .fullscreen)
    case .window: OwnShotCaptureGlyph(kind: .window)
    case .scrolling: OwnShotCaptureGlyph(kind: .scrolling)
    case .recording: OwnShotCaptureGlyph(kind: .recording)
    case .timer: OwnShotCaptureGlyph(kind: .timer)
    case .ocr: OwnShotCaptureGlyph(kind: .ocr)
    }
  }
}

/// Подсветка кнопки режима при наведении: у OneButton эталона есть trackingArea.
private struct OwnShotAllInOneModeButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    OwnShotAllInOneModeButton(configuration: configuration)
  }
}

private struct OwnShotAllInOneModeButton: View {
  let configuration: ButtonStyle.Configuration
  @State private var isHovered = false

  var body: some View {
    configuration.label
      .background(
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .fill(.white.opacity(configuration.isPressed ? 0.14 : (isHovered ? 0.08 : 0)))
      )
      .onHover { isHovered = $0 }
  }
}

/// Панель AIO: непрозрачная #2A2929 с двойной кромкой (R28, R07).
private struct OwnShotCapturePanelSurface: ViewModifier {
  func body(content: Content) -> some View {
    content.modifier(OwnShotHUDPanelSurface(surface: .allInOne, cornerRadius: 14))
  }
}

@MainActor
private final class OwnShotAllInOnePanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}
