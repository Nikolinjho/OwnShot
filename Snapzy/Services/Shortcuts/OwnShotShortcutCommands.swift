//
//  OwnShotShortcutCommands.swift
//  Snapzy
//
//  Действия глобальных команд из GlobalShortcutKind.extraKinds (паритет с CleanShot X).
//  Здесь только склейка поверх существующих менеджеров: Quick Access, пины, редактор, OCR.
//

import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor
enum OwnShotShortcutCommands {
  static func perform(_ kind: GlobalShortcutKind, viewModel: ScreenCaptureViewModel) {
    switch kind {
    case .ocrWithLineBreaks:
      viewModel.captureOCR(preserveBreaks: true)
    case .ocrWithoutLineBreaks:
      viewModel.captureOCR(preserveBreaks: false)
    case .toggleCameraFullscreen:
      // Сочетание регистрируется только на время записи. Без включённой камеры переключать нечего.
      if !RecordingCoordinator.shared.toggleCameraFullscreenFromShortcut() {
        NSSound.beep()
      }
    case .toggleOverlays:
      OverlayVisibilityController.shared.toggleOverlays()
    case .saveAllOverlays:
      QuickAccessManager.shared.saveAll()
    case .closeAllOverlays:
      QuickAccessManager.shared.requestCloseAll()
    case .chooseAndPinImage:
      guard let url = chooseImage() else { return }
      Task { _ = await QuickAccessManager.shared.pinScreenshot(url: url) }
    case .togglePinsVisibility:
      OverlayVisibilityController.shared.togglePins()
    case .closeAllPins:
      closeAllPins()
    case .pinLastScreenshot:
      pinLastScreenshot()
    case .openFile:
      openFile()
    case .openFromClipboard:
      viewModel.openAnnotationFromClipboard()
    case .annotateLastScreenshot:
      annotateLastScreenshot()
    default:
      break
    }
  }

  // MARK: - Pins

  private static func closeAllPins() {
    let manager = QuickAccessManager.shared
    // Сначала снимаем закрепление с карточек, чтобы их состояние совпало с окнами.
    for item in manager.items where item.isPinned {
      manager.togglePin(id: item.id)
    }
    // Затем закрываем пины без карточки (например, «Choose and Pin an Image»).
    QuickAccessPinWindowManager.shared.closeAll()
    OverlayVisibilityController.shared.resetPinsVisibility()
  }

  private static func pinLastScreenshot() {
    if let item = QuickAccessManager.shared.items.first(where: { !$0.isVideo }) {
      QuickAccessManager.shared.pinScreenshot(id: item.id)
      return
    }
    guard let url = latestScreenshotURL() else {
      NSSound.beep()
      return
    }
    Task { _ = await QuickAccessManager.shared.pinScreenshot(url: url) }
  }

  // MARK: - Editor

  private static func annotateLastScreenshot() {
    if let item = QuickAccessManager.shared.items.first(where: { !$0.isVideo }) {
      AnnotateManager.shared.openAnnotation(for: item)
      return
    }
    guard let url = latestScreenshotURL() else {
      NSSound.beep()
      return
    }
    AnnotateManager.shared.openAnnotation(url: url)
  }

  static func makeOpenFilePanel() -> NSOpenPanel {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.image, .movie, OwnShotProjectFormat.contentType]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    return panel
  }

  private static func openFile() {
    let panel = makeOpenFilePanel()
    NSApp.activate(ignoringOtherApps: true)
    guard panel.runModal() == .OK, let url = panel.url else { return }
    if VideoEditorManager.isVideoFile(url) {
      VideoEditorManager.shared.openEditor(for: url)
    } else {
      AnnotateManager.shared.openAnnotation(url: url)
    }
  }

  // MARK: - Helpers

  /// Типы для Choose and Pin an Image: эталон пускает только PNG и JPEG (TIFF, GIF, PDF недоступны).
  static let pinnableImageTypes: [UTType] = [.png, .jpeg]

  private static func chooseImage() -> URL? {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = pinnableImageTypes
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    // У эталона в панели есть кнопка New Folder.
    panel.canCreateDirectories = true
    NSApp.activate(ignoringOtherApps: true)
    guard panel.runModal() == .OK else { return nil }
    return panel.url
  }

  /// Последний скриншот из истории, файл которого ещё существует.
  static func latestScreenshotURL(in history: CaptureHistoryStore = .shared) -> URL? {
    history.records.first { $0.captureType == .screenshot && !$0.isDeleted && $0.fileExists }?
      .fileURL
  }
}

/// Скрывает и возвращает карточки Quick Access и пины, не трогая их состояние.
/// Новая карточка возвращает скрытые оверлеи на экран, чтобы снимок не потерялся.
@MainActor
final class OverlayVisibilityController {
  static let shared = OverlayVisibilityController()

  private(set) var areOverlaysHidden = false
  private(set) var arePinsHidden = false
  private var itemsObserver: AnyCancellable?
  private var lastItemCount = 0

  private init() {
    lastItemCount = QuickAccessManager.shared.items.count
    itemsObserver = QuickAccessManager.shared.$items
      .receive(on: RunLoop.main)
      .sink { [weak self] items in
        MainActor.assumeIsolated { self?.handleItemsChange(count: items.count) }
      }
  }

  func toggleOverlays() {
    // Стек уезжает вниз с полоской возврата, как Temporarily Hide у эталона
    if QuickAccessManager.shared.toggleTemporaryHide() {
      areOverlaysHidden = QuickAccessHiddenStackStrip.shared.isVisible
      return
    }
    let panels = NSApp.windows.compactMap { $0 as? QuickAccessPanel }
    guard !panels.isEmpty else {
      areOverlaysHidden = false
      NSSound.beep()
      return
    }
    areOverlaysHidden.toggle()
    for panel in panels {
      if areOverlaysHidden {
        panel.orderOut(nil)
      } else {
        panel.orderFrontRegardless()
      }
    }
  }

  func togglePins() {
    let pins = NSApp.windows.compactMap { $0 as? QuickAccessPinWindow }
    guard !pins.isEmpty else {
      arePinsHidden = false
      NSSound.beep()
      return
    }
    arePinsHidden.toggle()
    for pin in pins {
      if arePinsHidden {
        pin.orderOut(nil)
      } else {
        pin.orderFrontRegardless()
        pin.updateMousePassthrough()
      }
    }
  }

  func resetPinsVisibility() {
    arePinsHidden = false
  }

  private func handleItemsChange(count: Int) {
    defer { lastItemCount = count }
    if count == 0 {
      areOverlaysHidden = false
      return
    }
    guard areOverlaysHidden, count > lastItemCount else { return }
    // Новый захват возвращает скрытый стек, повторно он не прячется
    areOverlaysHidden = false
    if QuickAccessHiddenStackStrip.shared.isVisible {
      QuickAccessManager.shared.showTemporarilyHiddenItems()
    } else {
      NSApp.windows.compactMap { $0 as? QuickAccessPanel }.forEach { $0.orderFrontRegardless() }
    }
  }
}
