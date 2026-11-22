//
//  QuickAccessPinWindowManager.swift
//  Snapzy
//
//  Manages independent always-on-top pinned screenshot windows.
//

import AppKit
import SwiftUI

@MainActor
final class QuickAccessPinWindowManager {
  static let shared = QuickAccessPinWindowManager()

  private var controllers: [UUID: QuickAccessPinWindowController] = [:]

  private init() {}

  @discardableResult
  func show(item: QuickAccessItem, onUserClose: @escaping (UUID) -> Void) -> Bool {
    guard !item.isVideo else { return false }

    if let controller = controllers[item.id] {
      controller.update(item: item)
      controller.orderFront()
      return true
    }

    let controller = QuickAccessPinWindowController(item: item)
    controller.onUserClose = { [weak self] id in
      self?.controllers[id] = nil
      onUserClose(id)
    }
    controllers[item.id] = controller
    controller.show()
    return true
  }

  func update(item: QuickAccessItem, imageOverride: NSImage? = nil) {
    controllers[item.id]?.update(item: item, imageOverride: imageOverride)
  }

  func setPinZoomMode(_ mode: QuickAccessPinZoomMode) {
    for controller in controllers.values { controller.setZoomMode(mode) }
  }

  func close(id: UUID) {
    controllers.removeValue(forKey: id)?.close()
  }

  func closeAll() {
    for controller in controllers.values {
      controller.close()
    }
    controllers.removeAll()
  }

  func suspendAllMouseMonitors() {
    for controller in controllers.values {
      controller.suspendMouseMonitors()
    }
  }

  func resumeAllMouseMonitors() {
    for controller in controllers.values {
      controller.resumeMouseMonitors()
    }
  }
}

@MainActor
private final class QuickAccessPinWindowController {
  var onUserClose: ((UUID) -> Void)?

  private let id: UUID
  private var item: QuickAccessItem
  private let state: QuickAccessPinWindowState
  private let window: QuickAccessPinWindow
  private var resizeObserver: NSObjectProtocol?

  init(item: QuickAccessItem) {
    id = item.id
    self.item = item

    let image = Self.loadImage(for: item)
    let screen = ScreenUtility.activeScreen()
    let mode = QuickAccessPinZoomModeStore.shared.mode
    let baseSize = QuickAccessPinWindowSizing.size(for: image.size, visibleSize: screen.visibleFrame.size, mode: mode)
    state = QuickAccessPinWindowState(
      id: item.id,
      url: item.url,
      image: image,
      thumbnail: item.thumbnail,
      baseSize: baseSize,
      zoomMode: mode
    )

    let frame = QuickAccessPinWindowSizing.centeredFrame(size: state.displaySize, on: screen)
    window = QuickAccessPinWindow(contentRect: frame, state: state)
    state.onWindowResize = { [weak self] size, anchorFraction in
      self?.resize(to: size, preservingAnchorFraction: anchorFraction, animated: false)
    }
    window.contentView = hostingView(size: state.displaySize)
    window.minSize = QuickAccessPinWindowSizing.minimumZoomedSize
    window.contentAspectRatio = state.displaySize
    // Живой resize за край окна пересчитывает размер pin, программный setFrame сюда не попадает
    resizeObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didResizeNotification,
      object: window,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.window.inLiveResize else { return }
        self.state.applyUserResize(self.window.frame.size)
        self.window.updateMousePassthrough()
      }
    }
    window.onEscapeRequested = { [weak self] in
      self?.handleUserClose()
    }
    window.contextMenuProvider = { [weak self] in
      self?.makeContextMenu()
    }
    window.onMenuCommand = { [weak self] command in
      self?.perform(command)
    }
  }

  func show() {
    window.alphaValue = 1.0
    orderFront()
  }

  func orderFront() {
    window.orderFrontRegardless()
    window.updateMousePassthrough()
  }

  func update(item: QuickAccessItem, imageOverride: NSImage? = nil) {
    self.item = item
    let image = imageOverride ?? Self.loadImage(for: item)
    let screen = window.screen ?? ScreenUtility.activeScreen()
    let baseSize = QuickAccessPinWindowSizing.size(for: image.size, visibleSize: screen.visibleFrame.size, mode: state.zoomMode)
    let newSize = state.update(
      url: item.url,
      image: image,
      thumbnail: item.thumbnail,
      baseSize: baseSize
    )
    resize(to: newSize, animated: false)
  }

  func close() {
    if let resizeObserver {
      NotificationCenter.default.removeObserver(resizeObserver)
      self.resizeObserver = nil
    }
    window.close()
  }

  func suspendMouseMonitors() {
    window.suspendMouseMonitors()
  }

  func resumeMouseMonitors() {
    window.resumeMouseMonitors()
  }

  private func hostingView(size: CGSize) -> NSHostingView<QuickAccessPinWindowView> {
    let view = QuickAccessPinWindowView(
      state: state,
      onClose: { [weak self] in
        self?.handleUserClose()
      },
      onLockChanged: { [weak self] in
        self?.window.updateMousePassthrough()
      }
    )
    let hostingView = NSHostingView(rootView: view)
    hostingView.frame = NSRect(origin: .zero, size: size)
    return hostingView
  }

  // MARK: - Context Menu

  /// Меню pin в составе эталона: Close, редактор, копирование, облако, OCR, Save As,
  /// Lock, Zoom, Opacity и переключатели внешнего вида.
  private func makeContextMenu() -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    for entry in QuickAccessPinMenuLayout.entries(includesCloud: true, includesRaycast: OwnShotRaycastStub.isMenuVisible) {
      switch entry {
      case .separator:
        menu.addItem(.separator())
      case .header(let header):
        let title = header == .zoom ? L10n.QuickAccessMenu.zoom : L10n.QuickAccessMenu.opacity
        if #available(macOS 14.0, *) {
          menu.addItem(.sectionHeader(title: title))
        } else {
          let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
          item.isEnabled = false
          menu.addItem(item)
        }
      case .command(let command):
        let menuItem = NSMenuItem(title: title(for: command), action: nil, keyEquivalent: "")
        if let key = QuickAccessPinMenuLayout.key(for: command) {
          menuItem.keyEquivalent = key.key
          menuItem.keyEquivalentModifierMask = key.modifiers
        }
        menuItem.state = isChecked(command) ? .on : .off
        QuickAccessMenuBlockTarget.attach(to: menuItem) { [weak self] in
          // Модальные окна (Save As) открываются после закрытия меню.
          DispatchQueue.main.async { self?.perform(command) }
        }
        menu.addItem(menuItem)
      }
    }
    return menu
  }

  private func title(for command: QuickAccessPinMenuCommand) -> String {
    switch command {
    case .close: return L10n.Common.close
    case .openAnnotation: return L10n.QuickAccessMenu.openAnnotationTool
    case .copy: return L10n.QuickAccessMenu.copyToClipboard
    case .uploadToCloud: return L10n.AnnotateUI.uploadToCloud
    case .extractText: return L10n.QuickAccessMenu.extractText
    case .saveAs: return L10n.QuickAccessMenu.saveAs
    case .sendToRaycastAIChat: return L10n.PersonalBuildStubs.sendToRaycastAIChat
    case .lock: return state.isLocked ? L10n.QuickAccessMenu.unlock : L10n.QuickAccessMenu.lock
    case .zoom(let percent), .opacity(let percent): return "\(percent)%"
    case .shadow: return L10n.QuickAccessMenu.shadow
    case .roundedCorners: return L10n.QuickAccessMenu.roundedCorners
    case .border: return L10n.QuickAccessMenu.border
    }
  }

  private func isChecked(_ command: QuickAccessPinMenuCommand) -> Bool {
    switch command {
    case .shadow: return state.showsShadow
    case .roundedCorners: return state.roundedCorners
    case .border: return state.showsBorder
    case .zoom(let percent): return state.zoomPercent == percent
    case .opacity(let percent): return state.opacityPercent == percent
    default: return false
    }
  }

  private func perform(_ command: QuickAccessPinMenuCommand) {
    let manager = QuickAccessManager.shared
    let current = manager.item(id: id) ?? item
    switch command {
    case .close:
      handleUserClose()
    case .openAnnotation:
      AnnotateManager.shared.openAnnotation(for: current)
    case .copy:
      manager.copyPinnedImage(item: current)
    case .uploadToCloud:
      manager.uploadToCloudFromPin(item: current)
    case .extractText:
      QuickAccessFileActions.extractText(from: current.url)
    case .saveAs:
      if manager.item(id: id) != nil {
        manager.saveItem(id: id, useSavePanel: true)
      } else {
        saveTransientCopy(of: current.url)
      }
    case .sendToRaycastAIChat:
      OwnShotRaycastStub.send()
    case .lock:
      state.isLocked.toggle()
      window.updateMousePassthrough()
    case .zoom(let percent):
      state.setZoomPercent(percent)
    case .opacity(let percent):
      state.setOpacityPercent(percent)
    case .shadow:
      state.showsShadow.toggle()
    case .roundedCorners:
      state.roundedCorners.toggle()
    case .border:
      state.showsBorder.toggle()
    }
  }

  /// Save As для pin без карточки (открыт из History): копия файла в выбранное место.
  private func saveTransientCopy(of url: URL) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = url.lastPathComponent
    panel.canCreateDirectories = true
    NSApp.activate(ignoringOtherApps: true)
    guard panel.runModal() == .OK, let destination = panel.url, destination != url else { return }
    let sourceAccess = SandboxFileAccessManager.shared.beginAccessingURL(url)
    let destinationAccess = SandboxFileAccessManager.shared.beginAccessingURL(destination)
    defer {
      sourceAccess.stop()
      destinationAccess.stop()
    }
    do {
      if FileManager.default.fileExists(atPath: destination.path) {
        try FileManager.default.removeItem(at: destination)
      }
      try FileManager.default.copyItem(at: url, to: destination)
    } catch {
      DiagnosticLogger.shared.logError(.fileAccess, error, "Pinned screenshot save as failed")
      NSSound.beep()
    }
  }

  private func handleUserClose() {
    QuickAccessManager.shared.setWindowOpen(id: id, isOpen: false)
    self.close()
    self.onUserClose?(self.id)
  }

  private func resize(to size: CGSize, animated: Bool) {
    let currentFrame = window.frame
    let center = CGPoint(x: currentFrame.midX, y: currentFrame.midY)
    let proposedFrame = NSRect(
      x: center.x - size.width / 2,
      y: center.y - size.height / 2,
      width: size.width,
      height: size.height
    )
    let screen = window.screen ?? ScreenUtility.activeScreen()
    let targetFrame = QuickAccessPinWindowSizing.constrainedFrame(proposedFrame, on: screen)
    window.setFrame(targetFrame, display: true, animate: animated)
    window.contentView?.frame = NSRect(origin: .zero, size: targetFrame.size)
    window.contentAspectRatio = targetFrame.size
    window.updateMousePassthrough()
  }

  func setZoomMode(_ mode: QuickAccessPinZoomMode) {
    let screen = window.screen ?? ScreenUtility.activeScreen()
    let size = QuickAccessPinWindowSizing.size(for: state.image.size, visibleSize: screen.visibleFrame.size, mode: mode)
    guard state.setZoomMode(mode, baseSize: size) else { return }
    let frame = QuickAccessPinWindowSizing.resizedFrame(
      window.frame,
      to: size,
      within: screen.visibleFrame
    )
    window.setFrame(frame, display: true, animate: false)
    window.contentView?.frame = NSRect(origin: .zero, size: size)
    window.updateMousePassthrough()
  }

  private func resize(to size: CGSize, preservingAnchorFraction fraction: CGPoint, animated: Bool) {
    let oldFrame = window.frame
    let frame = QuickAccessPinWindowSizing.resizedFrame(
      oldFrame,
      to: size,
      preservingAnchorFraction: fraction
    )
    window.setFrame(frame, display: true, animate: animated)
    window.contentView?.frame = NSRect(origin: .zero, size: size)
    window.updateMousePassthrough()
  }

  private static func loadImage(for item: QuickAccessItem) -> NSImage {
    let access = SandboxFileAccessManager.shared.beginAccessingURL(item.url)
    defer { access.stop() }
    return NSImage(contentsOf: item.url) ?? item.thumbnail
  }
}
