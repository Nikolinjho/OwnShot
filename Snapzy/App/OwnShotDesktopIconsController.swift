import AppKit

@MainActor
final class OwnShotDesktopIconsController {
  static let shared = OwnShotDesktopIconsController()
  private(set) var isHidden = false
  private var covers: [NSWindow] = []
  private var observers: [NSObjectProtocol] = []

  private init() {
    observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { if self?.isHidden == true { self?.rebuild() } }
    })
    observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { if self?.isHidden == true { self?.rebuild() } }
    })
  }

  func toggle() { setHidden(!isHidden) }

  /// Двойной клик по обложке рабочего стола у эталона возвращает иконки – как show-desktop-icons.
  /// Пункт меню берёт состояние из isHidden при сборке, поэтому снова становится «Hide Desktop Icons».
  func handleCoverDoubleClick() {
    guard isHidden else { return }
    DiagnosticLogger.shared.log(.info, .ui, "Desktop icons shown by double-click on cover")
    setHidden(false)
  }
  func setHidden(_ hidden: Bool) {
    isHidden = hidden
    covers.forEach { $0.close() }; covers = []
    if hidden { rebuild() }
  }

  private func rebuild() {
    covers.forEach { $0.close() }; covers = []
    for screen in NSScreen.screens {
      guard let url = NSWorkspace.shared.desktopImageURL(for: screen), let image = NSImage(contentsOf: url) else { continue }
      let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
      window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
      window.backgroundColor = .black
      let imageView = OwnShotDesktopCoverView(frame: CGRect(origin: .zero, size: screen.frame.size))
      imageView.image = image
      imageView.imageScaling = .scaleAxesIndependently
      // Окно закрывается после выхода из обработчика клика, а не внутри него.
      imageView.onDoubleClick = { [weak self] in Task { @MainActor in self?.handleCoverDoubleClick() } }
      window.contentView = imageView
      window.orderFrontRegardless()
      covers.append(window)
    }
  }
}

/// Обложка рабочего стола: картинка обоев, двойной клик по которой снимает обложку.
final class OwnShotDesktopCoverView: NSImageView {
  var onDoubleClick: (() -> Void)?

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func mouseDown(with event: NSEvent) {
    if event.clickCount == 2 {
      onDoubleClick?()
      return
    }
    super.mouseDown(with: event)
  }
}
