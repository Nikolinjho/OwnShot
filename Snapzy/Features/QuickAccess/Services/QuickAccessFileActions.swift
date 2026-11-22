//
//  QuickAccessFileActions.swift
//  Snapzy
//
//  Действия над файлом захвата, общие для карточки Quick Access, pin и History:
//  Extract text, Print, Open With, Open in Mail, Show in Finder, Share.
//

import AppKit
import Foundation
import QuickLookUI

enum QuickAccessFileActions {
  // MARK: - Open With

  /// Приложение по умолчанию первым, остальные по имени. Как в эталоне,
  /// повторные регистрации одного приложения в разных местах не схлопываются.
  static func orderedApplications(
    _ applications: [URL],
    defaultApplication: URL?,
    displayName: (URL) -> String
  ) -> [URL] {
    var seen = Set<URL>()
    let unique = applications.filter { seen.insert($0.standardizedFileURL).inserted }
    let defaultURL = defaultApplication?.standardizedFileURL
    let others = unique
      .filter { $0.standardizedFileURL != defaultURL }
      .sorted { displayName($0).localizedStandardCompare(displayName($1)) == .orderedAscending }
    guard let defaultApplication, unique.contains(where: { $0.standardizedFileURL == defaultURL }) else {
      return others
    }
    return [defaultApplication] + others
  }

  static func applicationDisplayName(_ url: URL) -> String {
    FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
  }

  /// Подменю Open With из обработчиков, которые система предлагает для файла.
  static func openWithMenu(for fileURL: URL) -> NSMenu {
    let menu = NSMenu()
    let workspace = NSWorkspace.shared
    let applications = orderedApplications(
      workspace.urlsForApplications(toOpen: fileURL),
      defaultApplication: workspace.urlForApplication(toOpen: fileURL),
      displayName: applicationDisplayName
    )
    for applicationURL in applications {
      let item = NSMenuItem(
        title: applicationDisplayName(applicationURL),
        action: #selector(QuickAccessMenuBlockTarget.perform(_:)),
        keyEquivalent: ""
      )
      let icon = workspace.icon(forFile: applicationURL.path)
      icon.size = NSSize(width: 16, height: 16)
      item.image = icon
      QuickAccessMenuBlockTarget.attach(to: item) {
        open(fileURL, with: applicationURL)
      }
      menu.addItem(item)
    }
    return menu
  }

  static func open(_ fileURL: URL, with applicationURL: URL) {
    let access = SandboxFileAccessManager.shared.beginAccessingURL(fileURL)
    let configuration = NSWorkspace.OpenConfiguration()
    NSWorkspace.shared.open([fileURL], withApplicationAt: applicationURL, configuration: configuration) { _, error in
      access.stop()
      if let error {
        DiagnosticLogger.shared.logError(.action, error, "Quick access open with failed")
      }
    }
  }

  // MARK: - Share

  /// Системный пункт Share с подменю служб (AirDrop, Mail, Messages…).
  static func shareMenuItem(for fileURL: URL) -> NSMenuItem {
    NSSharingServicePicker(items: [fileURL]).standardShareMenuItem
  }

  // MARK: - Mail

  static func openInMail(_ fileURL: URL) {
    guard let service = NSSharingService(named: .composeEmail) else {
      NSSound.beep()
      return
    }
    service.perform(withItems: [fileURL])
  }

  // MARK: - Finder

  /// Показывает файл в Finder, карточка остаётся на месте.
  static func showInFinder(_ fileURL: URL) {
    let access = SandboxFileAccessManager.shared.beginAccessingURL(fileURL)
    defer { access.stop() }
    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
  }

  // MARK: - Print

  static func printImage(at fileURL: URL) {
    let access = SandboxFileAccessManager.shared.beginAccessingURL(fileURL)
    defer { access.stop() }
    guard let image = NSImage(contentsOf: fileURL) else {
      NSSound.beep()
      return
    }

    let imageView = NSImageView(frame: NSRect(origin: .zero, size: image.size))
    imageView.image = image
    imageView.imageScaling = .scaleProportionallyUpOrDown

    let printInfo = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
    printInfo.horizontalPagination = .fit
    printInfo.verticalPagination = .fit
    printInfo.isHorizontallyCentered = true
    printInfo.isVerticallyCentered = true
    printInfo.orientation = image.size.width > image.size.height ? .landscape : .portrait

    let operation = NSPrintOperation(view: imageView, printInfo: printInfo)
    operation.showsPrintPanel = true
    operation.showsProgressPanel = true
    operation.jobTitle = fileURL.deletingPathExtension().lastPathComponent
    NSApp.activate(ignoringOtherApps: true)
    operation.run()
  }

  // MARK: - Extract text

  /// Распознаёт текст картинки и кладёт его в буфер обмена, как Extract text эталона.
  static func extractText(from fileURL: URL) {
    let access = SandboxFileAccessManager.shared.beginAccessingURL(fileURL)
    let image = NSImage(contentsOf: fileURL)
    access.stop()
    guard let image else {
      OCRResultNotifier.shared.report(.failed(errorDescription: L10n.QuickAccessMenu.extractTextUnreadable))
      return
    }

    Task { @MainActor in
      do {
        let text = try await OCRService.shared.recognizeText(from: image, contentType: .interfaceText)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
          OCRResultNotifier.shared.report(.noText)
          return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        DiagnosticLogger.shared.log(.info, .ocr, "Quick access OCR text copied to clipboard", context: [
          "chars": "\(text.count)",
        ])
        OCRResultNotifier.shared.report(.copied(text))
      } catch OCRError.noTextFound {
        OCRResultNotifier.shared.report(.noText)
      } catch {
        DiagnosticLogger.shared.logError(.ocr, error, "Quick access OCR failed")
        OCRResultNotifier.shared.report(.failed(errorDescription: error.localizedDescription))
      }
    }
  }
}

// MARK: - Menu target

/// Цель NSMenuItem с замыканием. Объект держится через representedObject пункта.
final class QuickAccessMenuBlockTarget: NSObject {
  private let action: () -> Void

  private init(_ action: @escaping () -> Void) {
    self.action = action
    super.init()
  }

  static func attach(to item: NSMenuItem, action: @escaping () -> Void) {
    let target = QuickAccessMenuBlockTarget(action)
    item.representedObject = target
    item.target = target
    item.action = #selector(perform(_:))
  }

  @objc func perform(_ sender: NSMenuItem) {
    action()
  }
}

// MARK: - Quick Look

/// Окно Quick Look для одного файла. Повторный вызов для того же файла закрывает окно,
/// как Space в History эталона.
final class QuickAccessQuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
  static let shared = QuickAccessQuickLookController()

  private var previewURL: URL?
  private var access: SandboxFileAccessManager.ScopedAccess?

  var isPreviewing: Bool {
    QLPreviewPanel.sharedPreviewPanelExists() && (QLPreviewPanel.shared()?.isVisible ?? false)
  }

  func toggle(_ url: URL) {
    if isPreviewing, previewURL == url {
      close()
      return
    }
    show(url)
  }

  func show(_ url: URL) {
    guard let panel = QLPreviewPanel.shared() else { return }
    access?.stop()
    access = SandboxFileAccessManager.shared.beginAccessingURL(url)
    previewURL = url
    panel.dataSource = self
    panel.delegate = self
    panel.reloadData()
    NSApp.activate(ignoringOtherApps: true)
    panel.makeKeyAndOrderFront(nil)
  }

  func close() {
    if QLPreviewPanel.sharedPreviewPanelExists() {
      QLPreviewPanel.shared()?.orderOut(nil)
    }
    access?.stop()
    access = nil
    previewURL = nil
  }

  func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
    previewURL == nil ? 0 : 1
  }

  func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
    previewURL as NSURL?
  }
}
