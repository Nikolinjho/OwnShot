//
//  VideoEditorManager.swift
//  Snapzy
//
//  Singleton manager for video editor windows
//

import AppKit
import Foundation
import UniformTypeIdentifiers

/// Manages video editor window instances
@MainActor
final class VideoEditorManager {
  static let shared = VideoEditorManager()

  private var windowControllers: [UUID: VideoEditorWindowController] = [:]
  private var urlWindowControllers: [URL: VideoEditorWindowController] = [:]
  private var emptyWindowController: VideoEditorWindowController?
  private var emptyWindowObserver: NSObjectProtocol?
  private var observers: [UUID: NSObjectProtocol] = [:]
  private var urlObservers: [URL: NSObjectProtocol] = [:]
  private var sessionCache: [UUID: VideoEditorSessionData] = [:]
  private var urlSessionCache: [URL: VideoEditorSessionData] = [:]

  private init() {}

  // MARK: - Activation Policy Management

  /// Check if any video editor windows are open
  var hasOpenWindows: Bool {
    !windowControllers.isEmpty || !urlWindowControllers.isEmpty || emptyWindowController != nil
  }

  func isEditingFile(at url: URL) -> Bool {
    windowEditingFile(at: url) != nil
  }

  private func windowEditingFile(at url: URL) -> VideoEditorWindowController? {
    let filePath = SandboxFileAccessManager.directoryEntryPath(for: url)
    return windowControllers.values.first { $0.ownsFile(atDirectoryEntryPath: filePath) }
      ?? urlWindowControllers.values.first { $0.ownsFile(atDirectoryEntryPath: filePath) }
  }

  /// Switch to regular app mode (visible in Dock + Cmd+Tab)
  private func becomeRegularApp() {
    if NSApp.activationPolicy() != .regular {
      NSApp.setActivationPolicy(.regular)
    }
  }

  /// Switch back to accessory mode (menu bar only) if no windows open
  private func becomeAccessoryAppIfNeeded() {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      guard !hasOpenWindows else { return }
      guard !AnnotateManager.shared.hasOpenWindows else { return }
      NSApp.revertActivationPolicyToAccessoryIfNeeded()
    }
  }

  /// Open video editor for a quick access item
  func openEditor(for item: QuickAccessItem) {
    guard !NSScreen.screens.isEmpty, item.isVideo, !item.processingState.isProcessing,
          Self.isVideoFile(item.url) else { return }

    // Reuse an editor already opened from the card or from the file.
    if let existing = windowControllers[item.id] ?? windowEditingFile(at: item.url) {
      DiagnosticLogger.shared.log(.debug, .editor, "Video editor reused", context: ["itemId": item.id.uuidString])
      existing.showWindow()
      return
    }

    // Switch to regular app mode for Cmd+Tab visibility
    becomeRegularApp()

    DiagnosticLogger.shared.log(.info, .editor, "Opening video editor", context: ["itemId": item.id.uuidString])

    let sessionData = sessionCache[item.id] ?? VideoEditorSessionStore.shared.load(for: item.url)
    if let sessionData, sessionCache[item.id] == nil {
      sessionCache[item.id] = sessionData
    }
    let controller = VideoEditorWindowController(item: item, sessionData: sessionData)
    windowControllers[item.id] = controller

    // Pause Quick Access countdown for this item + newer items
    QuickAccessManager.shared.pauseCountdownForEditingItem(item.id)

    // Remove from tracking when window closes
    let itemId = item.id
    if let window = controller.window {
      let observer = NotificationCenter.default.addObserver(
        forName: NSWindow.willCloseNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.cleanupWindow(for: itemId)
          self?.becomeAccessoryAppIfNeeded()

          // Resume Quick Access countdown
          QuickAccessManager.shared.resumeCountdownForEditingItem(itemId)
        }
      }
      observers[itemId] = observer
    }

    controller.showWindow()
    QuickAccessManager.shared.setWindowOpen(id: item.id, isOpen: true)
  }

  /// Open video editor for a video URL directly
  func openEditor(for url: URL, originalURL: URL? = nil) {
    guard !NSScreen.screens.isEmpty, Self.isVideoFile(url) else { return }

    // Retain the Quick Access session when the recording already has a card.
    let captureURL = originalURL ?? url
    let filePath = SandboxFileAccessManager.directoryEntryPath(for: captureURL)
    if let existingItem = QuickAccessManager.shared.items.first(where: {
      $0.isVideo && SandboxFileAccessManager.directoryEntryPath(for: $0.url) == filePath
    }) {
      openEditor(for: existingItem)
      return
    }

    // Reuse existing window if open
    let sessionKey = url.standardizedFileURL
    if let existing = windowEditingFile(at: captureURL) ?? urlWindowControllers[sessionKey] {
      DiagnosticLogger.shared.log(.debug, .editor, "Video editor reused", context: ["file": url.lastPathComponent])
      existing.showWindow()
      return
    }

    // Switch to regular app mode for Cmd+Tab visibility
    becomeRegularApp()

    DiagnosticLogger.shared.log(
      .info,
      .editor,
      "Opening video editor for URL",
      context: ["file": url.lastPathComponent]
    )

    let sessionLookupURL = originalURL ?? url
    let sessionData = urlSessionCache[sessionKey]
      ?? VideoEditorSessionStore.shared.load(for: sessionLookupURL)
    if let sessionData, urlSessionCache[sessionKey] == nil {
      urlSessionCache[sessionKey] = sessionData
    }
    let controller = VideoEditorWindowController(
      url: url,
      originalURL: originalURL,
      sessionData: sessionData
    )
    urlWindowControllers[sessionKey] = controller

    // Remove from tracking when window closes
    if let window = controller.window {
      let observer = NotificationCenter.default.addObserver(
        forName: NSWindow.willCloseNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.cleanupURLWindow(for: sessionKey)
          self?.becomeAccessoryAppIfNeeded()
        }
      }
      urlObservers[sessionKey] = observer
    }

    controller.showWindow()
  }

  /// Open video editor with empty state for drag & drop
  func openEmptyEditor() {
    guard !NSScreen.screens.isEmpty else { return }
    // Reuse existing empty window if open
    if let existing = emptyWindowController {
      DiagnosticLogger.shared.log(.debug, .editor, "Empty video editor reused")
      existing.showWindow()
      return
    }

    // Switch to regular app mode for Cmd+Tab visibility
    becomeRegularApp()

    DiagnosticLogger.shared.log(.info, .editor, "Opening empty video editor")

    let controller = VideoEditorWindowController()
    controller.onVideoLoaded = { [weak self, weak controller] url, originalURL in
      guard let controller, Self.isVideoFile(url) else { return }
      controller.window?.close()
      self?.openEditor(for: url, originalURL: originalURL)
    }
    emptyWindowController = controller

    if let window = controller.window {
      emptyWindowObserver = NotificationCenter.default.addObserver(
        forName: NSWindow.willCloseNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.cleanupEmptyWindow()
          self?.becomeAccessoryAppIfNeeded()
        }
      }
    }

    controller.showWindow()
  }

  /// Validate the file before handing it to the editor.
  static func isVideoFile(_ url: URL) -> Bool {
    guard url.isFileURL else { return false }
    return SandboxFileAccessManager.shared.withScopedAccess(to: url) {
      let target = url.resolvingSymlinksInPath()
      guard let values = try? target.resourceValues(forKeys: [.isRegularFileKey, .contentTypeKey]),
            values.isRegularFile == true,
            let type = values.contentType ?? UTType(filenameExtension: url.pathExtension) else {
        return false
      }
      return type.conforms(to: .movie) || type.conforms(to: .video) || type.conforms(to: .gif)
    }
  }

  private func cleanupEmptyWindow() {
    if let emptyWindowObserver {
      NotificationCenter.default.removeObserver(emptyWindowObserver)
      self.emptyWindowObserver = nil
    }
    emptyWindowController = nil
  }

  private func cleanupURLWindow(for url: URL) {
    if let observer = urlObservers[url] {
      NotificationCenter.default.removeObserver(observer)
      urlObservers.removeValue(forKey: url)
    }
    urlWindowControllers.removeValue(forKey: url)
  }

  // MARK: - Session Cache

  func saveSessionData(_ sessionData: VideoEditorSessionData, for itemId: UUID) {
    sessionCache[itemId] = sessionData
  }

  func getSessionData(for itemId: UUID) -> VideoEditorSessionData? {
    sessionCache[itemId]
  }

  func clearSessionData(for itemId: UUID) {
    sessionCache.removeValue(forKey: itemId)
  }

  func saveSessionData(_ sessionData: VideoEditorSessionData, for url: URL) {
    urlSessionCache[url.standardizedFileURL] = sessionData
  }

  func getSessionData(for url: URL) -> VideoEditorSessionData? {
    urlSessionCache[url.standardizedFileURL]
  }

  func clearSessionData(for url: URL) {
    urlSessionCache.removeValue(forKey: url.standardizedFileURL)
  }

  /// Close all video editor windows
  func closeAll() {
    // Remove all observers
    for (_, observer) in observers {
      NotificationCenter.default.removeObserver(observer)
    }
    observers.removeAll()

    for (_, observer) in urlObservers {
      NotificationCenter.default.removeObserver(observer)
    }
    urlObservers.removeAll()

    // Close all windows
    for controller in windowControllers.values {
      controller.window?.close()
    }
    windowControllers.removeAll()

    for controller in urlWindowControllers.values {
      controller.window?.close()
    }
    urlWindowControllers.removeAll()

    emptyWindowController?.window?.close()
    cleanupEmptyWindow()

    becomeAccessoryAppIfNeeded()
  }

  private func cleanupWindow(for itemId: UUID) {
    if let observer = observers[itemId] {
      NotificationCenter.default.removeObserver(observer)
      observers.removeValue(forKey: itemId)
    }
    windowControllers.removeValue(forKey: itemId)
    DiagnosticLogger.shared.log(.debug, .editor, "Video editor window closed", context: ["itemId": itemId.uuidString])
  }
}
