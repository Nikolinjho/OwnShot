//
//  QuickAccessManager.swift
//  Snapzy
//
//  State management for quick access screenshot stack
//

import AppKit
import Carbon.HIToolbox
import Combine
import Darwin
import Foundation
import os.log
import SwiftUI
import UniformTypeIdentifiers

private let logger = Logger(subsystem: "Snapzy", category: "QuickAccessManager")

enum QuickAccessAnimationStyle: String, CaseIterable, Identifiable {
  case slide
  case scale

  var id: String {
    rawValue
  }

  var displayName: String {
    switch self {
    case .slide: L10n.PreferencesQuickAccess.animationStyleSlide
    case .scale: L10n.PreferencesQuickAccess.animationStyleScale
    }
  }
}

/// Manages the quick access screenshot preview stack
@MainActor
final class QuickAccessManager: ObservableObject {
  static let shared = QuickAccessManager(presentsPanel: true)

  // MARK: - Published State

  @Published private(set) var items: [QuickAccessItem] = [] {
    didSet {
      refreshPanelInteractionMetrics()
      invalidateHoverIfItemGone()
      if !oldValue.isEmpty && items.isEmpty {
        QuickAccessHiddenStackStrip.shared.hide()
      }
    }
  }

  @Published var position: QuickAccessPosition = .bottomRight {
    didSet {
      UserDefaults.standard.set(position.rawValue, forKey: Keys.position)
      panelController.updatePosition(position)
    }
  }

  @Published var isEnabled: Bool = true {
    didSet {
      UserDefaults.standard.set(isEnabled, forKey: Keys.enabled)
      if !isEnabled {
        dismissAll()
      }
    }
  }

  @Published var autoDismissEnabled: Bool = true {
    didSet {
      UserDefaults.standard.set(autoDismissEnabled, forKey: Keys.autoDismissEnabled)
    }
  }

  @Published var hideCardWhenWindowOpen: Bool = true {
    didSet {
      UserDefaults.standard.set(hideCardWhenWindowOpen, forKey: Keys.hideCardWhenWindowOpen)
      refreshPanelInteractionMetrics()
    }
  }

  @Published var animationStyle: QuickAccessAnimationStyle = .slide {
    didSet {
      UserDefaults.standard.set(animationStyle.rawValue, forKey: Keys.quickAccessAnimationStyle)
    }
  }

  @Published var autoDismissDelay: TimeInterval = 10 {
    didSet {
      UserDefaults.standard.set(autoDismissDelay, forKey: Keys.autoDismissDelay)
    }
  }

  @Published var overlayScale: Double = 1.0 {
    didSet {
      UserDefaults.standard.set(overlayScale, forKey: Keys.overlayScale)
      // Live-resize panel when slider changes
      if panelController.isVisible {
        panelController.updateSize(calculateMaxPanelSize())
      }
      refreshPanelInteractionMetrics()
    }
  }

  @Published var dragDropEnabled: Bool = true {
    didSet {
      UserDefaults.standard.set(dragDropEnabled, forKey: Keys.dragDropEnabled)
    }
  }

  @Published var twoFingerSwipeToDismissEnabled: Bool = true {
    didSet {
      UserDefaults.standard.set(twoFingerSwipeToDismissEnabled, forKey: Keys.twoFingerSwipeToDismissEnabled)
    }
  }

  @Published var swipeSensitivity: Double = 1.0 {
    didSet {
      UserDefaults.standard.set(swipeSensitivity, forKey: Keys.swipeSensitivity)
    }
  }

  @Published var pauseCountdownOnHover: Bool = true {
    didSet {
      UserDefaults.standard.set(pauseCountdownOnHover, forKey: Keys.pauseCountdownOnHover)
    }
  }

  @Published private(set) var openEditorShortcut: ShortcutConfig?
  @Published var openEditorShortcutEnabled: Bool = false {
    didSet {
      UserDefaults.standard.set(openEditorShortcutEnabled, forKey: Keys.openEditorShortcutEnabled)
      if openEditorShortcutEnabled {
        if panelController.isVisible {
          installEditHotKeyIfNeeded()
        }
      } else {
        removeEditHotKey()
      }
    }
  }

  static let defaultOpenEditorShortcut = ShortcutConfig(
    keyCode: UInt32(kVK_Return),
    modifiers: UInt32(cmdKey)
  )

  /// Card the pointer is currently over. Card action shortcuts are only live
  /// while this is non-nil, so it must be cleared on every path that ends a hover.
  ///
  /// Deliberately NOT `@Published`: only this manager reads it (shortcut
  /// targeting), and publishing it would invalidate every manager observer —
  /// including `QuickAccessStackView` and all visible cards — on every hover
  /// enter/exit, re-rendering the stack without changing anything visible.
  private(set) var hoveredItemID: UUID?

  /// Emits when a card action shortcut fires, targeted at the hovered card.
  /// `QuickAccessCardView` owns the availability rules, so it runs the action.
  let cardShortcutTrigger = PassthroughSubject<QuickAccessCardShortcutTrigger, Never>()

  // MARK: - Configuration

  let maxVisibleItems = 6

  // MARK: - Private

  private let panelController = QuickAccessPanelController()
  private let presentsPanel: Bool
  private let pinWindowManager = QuickAccessPinWindowManager.shared
  private let fileAccessManager = SandboxFileAccessManager.shared
  private let tempCaptureManager = TempCaptureManager.shared
  private enum RecentlyClosedPlacement {
    case closed, overflow, displacedByRestore
  }

  private struct RecentlyClosedCapture {
    let url: URL
    let isVideo: Bool
    let restoreIdentity: CaptureFileIdentity
    let cleanupIdentity: CaptureFileIdentity?
  }

  private var recentlyClosedCaptures: [RecentlyClosedCapture] = []

  private var dismissTimers: [UUID: QuickAccessCountdownTimer] = [:]
  /// Monotonic per-item save tokens; guards the async save-and-close thumbnail push
  /// against out-of-order arrival when the same item is saved twice quickly.
  private var thumbnailSaveGenerations: [UUID: UInt64] = [:]
  /// Tracks which item IDs are currently being edited (paused by editor)
  private var editingItemIds: Set<UUID> = []
  /// Tracks items doing async work, such as GIF conversion or cloud upload.
  private var activityHoldItemIds: Set<UUID> = []
  private var savingItemIds: Set<UUID> = []
  private var hoveredItemIds: Set<UUID> = []
  private let hoverShortcutRegistry = QuickAccessHoverShortcutRegistry()
  private var editHotKeyRef: EventHotKeyRef?
  private var editHotKeyOverrideObservation: AnyCancellable?
  private var editHotKeyHandler: EventHandlerRef?
  fileprivate let editHotKeyID = EventHotKeyID(signature: OSType(0x5A51_4145), id: 1)

  // MARK: - UserDefaults Keys (preserved for backward compatibility)

  private enum Keys {
    static let enabled = "floatingScreenshot.enabled"
    static let position = "floatingScreenshot.position"
    static let autoDismissEnabled = "floatingScreenshot.autoDismissEnabled"
    static let hideCardWhenWindowOpen = "quickAccess.hideCardWhenWindowOpen"
    static let quickAccessAnimationStyle = "quickAccess.animationStyle"
    static let autoDismissDelay = "floatingScreenshot.autoDismissDelay"
    static let overlayScale = "floatingScreenshot.overlayScale"
    static let dragDropEnabled = "floatingScreenshot.dragDropEnabled"
    static let twoFingerSwipeToDismissEnabled = "floatingScreenshot.twoFingerSwipeToDismissEnabled"
    static let swipeSensitivity = "floatingScreenshot.swipeSensitivity"
    static let pauseCountdownOnHover = "floatingScreenshot.pauseCountdownOnHover"
    static let openEditorShortcut = "quickAccess.openEditorShortcut"
    static let openEditorShortcutEnabled = "quickAccess.openEditorShortcutEnabled"
  }

  private let explicitEmptyShortcutData = Data("null".utf8)

  // MARK: - Init

  init(presentsPanel: Bool, initialItems: [QuickAccessItem] = []) {
    self.presentsPanel = presentsPanel
    self.items = initialItems
    loadSettings()
    hoverShortcutRegistry.onTrigger = { [weak self] trigger in
      self?.handleCardShortcut(trigger)
    }
  }

  private func loadSettings() {
    isEnabled = UserDefaults.standard.object(forKey: Keys.enabled) as? Bool ?? true

    if let positionRaw = UserDefaults.standard.string(forKey: Keys.position),
       let savedPosition = QuickAccessPosition(rawValue: positionRaw) {
      position = savedPosition
    }

    autoDismissEnabled =
      UserDefaults.standard.object(forKey: Keys.autoDismissEnabled) as? Bool ?? true
    hideCardWhenWindowOpen =
      UserDefaults.standard.object(forKey: Keys.hideCardWhenWindowOpen) as? Bool ?? true

    if let savedAnimStyle = UserDefaults.standard.string(forKey: Keys.quickAccessAnimationStyle),
       let style = QuickAccessAnimationStyle(rawValue: savedAnimStyle) {
      animationStyle = style
    }

    autoDismissDelay =
      UserDefaults.standard.object(forKey: Keys.autoDismissDelay) as? Double ?? 10
    overlayScale =
      UserDefaults.standard.object(forKey: Keys.overlayScale) as? Double ?? 1.0
    dragDropEnabled =
      UserDefaults.standard.object(forKey: Keys.dragDropEnabled) as? Bool ?? true
    twoFingerSwipeToDismissEnabled =
      UserDefaults.standard.object(forKey: Keys.twoFingerSwipeToDismissEnabled) as? Bool ?? true
    swipeSensitivity =
      UserDefaults.standard.object(forKey: Keys.swipeSensitivity) as? Double ?? 1.0
    pauseCountdownOnHover =
      UserDefaults.standard.object(forKey: Keys.pauseCountdownOnHover) as? Bool ?? true
    openEditorShortcutEnabled =
      UserDefaults.standard.object(forKey: Keys.openEditorShortcutEnabled) as? Bool ?? false
    loadOpenEditorShortcut()
    DiagnosticLogger.shared.log(
      .debug,
      .ui,
      "Quick access settings loaded",
      context: [
        "enabled": isEnabled ? "true" : "false",
        "position": position.rawValue,
        "autoDismiss": autoDismissEnabled ? "true" : "false",
        "delay": "\(autoDismissDelay)",
        "twoFingerSwipeToDismiss": twoFingerSwipeToDismissEnabled ? "true" : "false",
        "swipeSensitivity": "\(swipeSensitivity)",
      ]
    )
  }

  // MARK: - Public Methods

  /// Imports media for an explicit URL request once its contents can be opened.
  @discardableResult
  func addExternalMedia(url: URL, isVideo: Bool) async -> QuickAccessItem? {
    guard isEnabled else { return nil }
    let access = fileAccessManager.beginAccessingURL(url)
    defer { access.stop() }
    guard let identity = CaptureFileIdentity(at: url) else { return nil }
    let result = await ThumbnailGenerator.generate(from: url)
    let hasVideoDuration = isVideo && result.duration.map { $0.isFinite && $0 > 0 } == true
    guard (result.thumbnail != nil || hasVideoDuration),
          CaptureFileIdentity(at: url) == identity else { return nil }
    if isVideo {
      return await addVideo(url: url, restoring: nil) { _ in result }
    }
    return await addScreenshot(url: url, restoring: nil) { _ in result }
  }

  /// Add a new screenshot to the quick access stack
  @discardableResult
  func addScreenshot(url: URL) async -> QuickAccessItem? {
    await addScreenshot(url: url, restoring: nil)
  }

  private func addScreenshot(
    url: URL,
    restoring identity: CaptureFileIdentity?,
    thumbnailForURL: @MainActor (URL) async -> ThumbnailResult = { await ThumbnailGenerator.generate(from: $0) }
  ) async -> QuickAccessItem? {
    guard isEnabled else {
      DiagnosticLogger.shared.log(
        .debug,
        .action,
        "Quick access screenshot skipped; feature disabled",
        context: ["fileName": url.lastPathComponent]
      )
      return nil
    }
    let fileAccess = fileAccessManager.beginAccessingURL(url)
    defer { fileAccess.stop() }
    let result = await thumbnailForURL(url)
    if let identity {
      guard CaptureFileIdentity(at: url) == identity else { return nil }
      if let existingItem = item(matching: url) {
        showPanelIfNeeded()
        return existingItem
      }
    }

    // Use placeholder if thumbnail generation failed
    let thumbnail: NSImage
    let needsRetry: Bool
    if let generated = result.thumbnail {
      thumbnail = generated
      needsRetry = false
    } else {
      logger.warning("Thumbnail failed for \(url.lastPathComponent), using placeholder")
      DiagnosticLogger.shared.log(
        .warning,
        .ui,
        "Quick access screenshot thumbnail failed; using placeholder",
        context: ["fileName": url.lastPathComponent]
      )
      thumbnail = ThumbnailGenerator.placeholderThumbnail()
      needsRetry = true
    }

    let item = QuickAccessItem(url: url, thumbnail: thumbnail, cardThumbnail: result.cardThumbnail)

    // Animate insertion explicitly — no implicit .animation on the stack
    withAnimation(QuickAccessAnimations.cardInsert) {
      trimOldestItemIfNeeded(logMessage: "Quick access trimmed oldest item", restoring: identity != nil)
      items.insert(item, at: 0)
    }
    DiagnosticLogger.shared.log(
      .info,
      .action,
      "Quick access screenshot added",
      context: ["fileName": url.lastPathComponent, "itemCount": "\(items.count)"]
    )

    // Ensure the panel window exists — heals any state where items outlived
    // the panel (e.g. a previously interrupted show/hide transition).
    showPanelIfNeeded()

    // Start auto-dismiss timer
    if autoDismissEnabled {
      startDismissTimer(for: item.id)
    }

    // Schedule background thumbnail retry if needed
    if needsRetry {
      scheduleThumbnailRetry(for: item.id, url: url)
    }

    return item
  }

  /// Add a new video recording to the quick access stack
  @discardableResult
  func addVideo(url: URL) async -> QuickAccessItem? {
    await addVideo(url: url, restoring: nil)
  }

  private func addVideo(
    url: URL,
    restoring identity: CaptureFileIdentity?,
    thumbnailForURL: @MainActor (URL) async -> ThumbnailResult = { await ThumbnailGenerator.generate(from: $0) }
  ) async -> QuickAccessItem? {
    guard isEnabled else {
      DiagnosticLogger.shared.log(
        .debug,
        .action,
        "Quick access video skipped; feature disabled",
        context: ["fileName": url.lastPathComponent]
      )
      return nil
    }
    let fileAccess = fileAccessManager.beginAccessingURL(url)
    defer { fileAccess.stop() }
    let result = await thumbnailForURL(url)
    if let identity {
      guard CaptureFileIdentity(at: url) == identity else { return nil }
      if let existingItem = item(matching: url) {
        showPanelIfNeeded()
        return existingItem
      }
    }

    // Use placeholder if thumbnail generation failed
    let thumbnail: NSImage
    let needsRetry: Bool
    if let generated = result.thumbnail {
      thumbnail = generated
      needsRetry = false
    } else {
      logger.warning("Video thumbnail failed for \(url.lastPathComponent), using placeholder")
      DiagnosticLogger.shared.log(
        .warning,
        .ui,
        "Quick access video thumbnail failed; using placeholder",
        context: ["fileName": url.lastPathComponent]
      )
      thumbnail = ThumbnailGenerator.placeholderThumbnail()
      needsRetry = true
    }

    // Use actual duration or nil (will show no badge if duration unavailable)
    let item = QuickAccessItem(url: url, thumbnail: thumbnail, duration: result.duration ?? 0)

    // Animate insertion explicitly — no implicit .animation on the stack
    withAnimation(QuickAccessAnimations.cardInsert) {
      trimOldestItemIfNeeded(logMessage: "Quick access trimmed oldest item", restoring: identity != nil)
      items.insert(item, at: 0)
    }

    // Ensure the panel window exists — heals any state where items outlived
    // the panel (e.g. a previously interrupted show/hide transition).
    showPanelIfNeeded()

    if autoDismissEnabled {
      startDismissTimer(for: item.id)
    }

    // Schedule background thumbnail retry if needed
    if needsRetry {
      scheduleThumbnailRetry(for: item.id, url: url)
    }
    DiagnosticLogger.shared.log(
      .info,
      .action,
      "Quick access video added",
      context: [
        "fileName": url.lastPathComponent,
        "itemCount": "\(items.count)",
        "duration": "\(result.duration ?? 0)",
      ]
    )

    return item
  }

  /// Present a history record as a Quick Access card and return the session item.
  /// This intentionally restores through Quick Access even for manually opened
  /// history records, so editors get the same item-scoped save/session behavior
  /// as fresh captures.
  func restoreRecentlyClosed(
    thumbnailForURL: @MainActor (URL) async -> ThumbnailResult = { await ThumbnailGenerator.generate(from: $0) }
  ) async {
    var unavailableURLs = Set<URL>()
    while let capture = recentlyClosedCaptures.popLast() {
      let access = fileAccessManager.beginAccessingURL(capture.url)
      defer { access.stop() }
      let identity = capture.restoreIdentity
      guard CaptureFileIdentity(at: capture.url) == identity else {
        unavailableURLs.insert(capture.url.standardizedFileURL)
        continue
      }
      if let record = CaptureHistoryStore.shared.records.first(where: { $0.fileURL == capture.url }) {
        if await restoreHistoryItem(record, thumbnailForURL: thumbnailForURL) != nil { return }
      } else if isEnabled, item(matching: capture.url) != nil {
        showPanelIfNeeded()
        return
      } else {
        let restored = capture.isVideo
          ? await addVideo(url: capture.url, restoring: identity, thumbnailForURL: thumbnailForURL)
          : await addScreenshot(url: capture.url, restoring: identity, thumbnailForURL: thumbnailForURL)
        if restored != nil { return }
      }
    }
    // Как в эталоне: после перезапуска восстанавливается последний файл History.
    await restoreLastFromHistoryOrWarn(excluding: unavailableURLs)
  }

  private func rememberClosedItem(url: URL, isVideo: Bool, placement: RecentlyClosedPlacement = .closed) {
    recentlyClosedCaptures.removeAll { $0.url == url }
    let access = fileAccessManager.beginAccessingURL(url)
    defer { access.stop() }
    guard let restoreIdentity = CaptureFileIdentity(at: url) else { return }
    let cleanupIdentity = placement == .closed && tempCaptureManager.isTempFile(url)
      ? CaptureFileIdentity(at: url, entry: .regularLeaf) : nil
    let capture = RecentlyClosedCapture(
      url: url, isVideo: isVideo, restoreIdentity: restoreIdentity, cleanupIdentity: cleanupIdentity
    )
    if placement == .displacedByRestore {
      // Keep pending restores ahead of the card displaced to make room for this one.
      recentlyClosedCaptures.insert(capture, at: 0)
    } else {
      recentlyClosedCaptures.append(capture)
    }
    if recentlyClosedCaptures.count > 20 {
      let expired = recentlyClosedCaptures.removeFirst()
      if placement == .closed, let identity = expired.cleanupIdentity,
         !items.contains(where: { $0.url == expired.url }) {
        scheduleDismissCleanup(for: expired.url, expectedIdentity: identity)
      }
    }
  }

  private nonisolated struct CaptureFileIdentity: Equatable {
    enum Entry {
      case regularTarget
      case regularLeaf
      case deletableLeaf
    }

    let device: dev_t
    let inode: ino_t
    let birthSeconds: Int
    let birthNanoseconds: Int

    init?(at url: URL, entry: Entry = .regularTarget) {
      var info = stat()
      let status = url.withUnsafeFileSystemRepresentation { path in
        guard let path else { return Int32(-1) }
        return entry == .regularTarget ? stat(path, &info) : lstat(path, &info)
      }
      let type = info.st_mode & S_IFMT
      guard status == 0, type == S_IFREG || (entry == .deletableLeaf && type == S_IFLNK) else { return nil }
      device = info.st_dev
      inode = info.st_ino
      birthSeconds = info.st_birthtimespec.tv_sec
      birthNanoseconds = info.st_birthtimespec.tv_nsec
    }
  }

  func restoreHistoryItem(
    _ record: CaptureHistoryRecord,
    thumbnailForURL: @MainActor (URL) async -> ThumbnailResult = { await ThumbnailGenerator.generate(from: $0) }
  ) async -> QuickAccessItem? {
    let url = record.fileURL

    if let existingItem = item(matching: url) {
      showPanelIfNeeded()
      DiagnosticLogger.shared.log(
        .info,
        .history,
        "History restore reused quick access item",
        context: [
          "fileName": record.fileName,
          "type": record.captureType.rawValue,
          "itemId": existingItem.id.uuidString,
        ]
      )
      return existingItem
    }

    let fileAccess = fileAccessManager.beginAccessingURL(url)
    defer { fileAccess.stop() }

    guard let identity = CaptureFileIdentity(at: url) else {
      DiagnosticLogger.shared.log(
        .warning,
        .history,
        "History restore skipped; source unavailable",
        context: ["fileName": record.fileName, "type": record.captureType.rawValue]
      )
      return nil
    }

    let result = await thumbnailForURL(url)
    guard CaptureFileIdentity(at: url) == identity else {
      DiagnosticLogger.shared.log(
        .warning,
        .history,
        "History restore skipped; source changed during thumbnail generation",
        context: ["fileName": record.fileName, "type": record.captureType.rawValue]
      )
      return nil
    }

    if let existingItem = item(matching: url) {
      showPanelIfNeeded()
      return existingItem
    }

    let thumbnail: NSImage
    let needsRetry: Bool
    if let generated = result.thumbnail {
      thumbnail = generated
      needsRetry = false
    } else {
      thumbnail = ThumbnailGenerator.placeholderThumbnail()
      needsRetry = true
      DiagnosticLogger.shared.log(
        .warning,
        .ui,
        "History restore thumbnail failed; using placeholder",
        context: ["fileName": record.fileName, "type": record.captureType.rawValue]
      )
    }

    let item = switch record.captureType {
    case .screenshot:
      QuickAccessItem(
        id: UUID(),
        url: url,
        thumbnail: thumbnail,
        capturedAt: record.capturedAt,
        itemType: .screenshot,
        duration: nil,
        cardThumbnail: result.cardThumbnail
      )
    case .video, .gif:
      QuickAccessItem(
        id: UUID(),
        url: url,
        thumbnail: thumbnail,
        capturedAt: record.capturedAt,
        itemType: .video,
        duration: record.duration ?? result.duration ?? 0
      )
    }

    insertRestoredHistoryItem(item, needsRetry: needsRetry, retryURL: url)
    DiagnosticLogger.shared.log(
      .info,
      .history,
      "History restored into quick access",
      context: [
        "fileName": record.fileName,
        "type": record.captureType.rawValue,
        "itemId": item.id.uuidString,
      ]
    )
    return item
  }

  /// Drops the oldest card to make room for a new one. Frees its in-memory
  /// editor caches like `removeItem(id:)`, but keeps the file: a new capture
  /// must never delete an older unsaved one (launch-time cleanup reclaims it).
  private func trimOldestItemIfNeeded(logMessage: String, restoring: Bool) {
    guard items.count >= maxVisibleItems, let oldest = items.last else { return }
    cancelDismissTimer(for: oldest.id)
    pinWindowManager.close(id: oldest.id)
    activityHoldItemIds.remove(oldest.id)
    // An open editor still owns its session; it saves back on close.
    if !editingItemIds.contains(oldest.id) {
      AnnotateManager.shared.clearSessionData(for: oldest.id)
      VideoEditorManager.shared.clearSessionData(for: oldest.id)
      VideoEditorManager.shared.clearSessionData(for: oldest.url)
    }
    items.removeLast()
    // A regular unsaved capture stays recoverable after the stack makes room.
    if !oldest.isPinned, !oldest.isWindowOpen, !oldest.processingState.isProcessing,
       !editingItemIds.contains(oldest.id), !savingItemIds.contains(oldest.id),
       tempCaptureManager.isTempFile(oldest.url), item(matching: oldest.url) == nil {
      rememberClosedItem(
        url: oldest.url, isVideo: oldest.isVideo, placement: restoring ? .displacedByRestore : .overflow
      )
    }
    DiagnosticLogger.shared.log(
      .debug,
      .ui,
      logMessage,
      context: ["maxVisibleItems": "\(maxVisibleItems)"]
    )
  }

  /// Remove an item (screenshot or video) from the stack
  func removeItem(id: UUID) {
    guard let item = items.first(where: { $0.id == id }) else {
      cancelDismissTimer(for: id)
      editingItemIds.remove(id)
      activityHoldItemIds.remove(id)
      DiagnosticLogger.shared.log(
        .debug,
        .action,
        "Quick access remove requested for missing item",
        context: ["itemId": id.uuidString]
      )
      return
    }

    let url = item.url
    let isTempFile = tempCaptureManager.isTempFile(url)
    let cleanupIdentity = isTempFile ? CaptureFileIdentity(at: url, entry: .regularLeaf) : nil

    cancelDismissTimer(for: id)
    pinWindowManager.close(id: id)
    editingItemIds.remove(id)
    activityHoldItemIds.remove(id)
    hoveredItemIds.remove(id)
    // Clear annotation session cache for this item
    AnnotateManager.shared.clearSessionData(for: id)
    VideoEditorManager.shared.clearSessionData(for: id)
    VideoEditorManager.shared.clearSessionData(for: url)
    if items.count == 1, items.first?.id == id { hidePanel() }
    withAnimation(QuickAccessAnimations.cardRemove) {
      items.removeAll { $0.id == id }
    }

    if items.isEmpty {
      hidePanel()
    }

    if let cleanupIdentity {
      scheduleDismissCleanup(for: url, expectedIdentity: cleanupIdentity)
    } else if !isTempFile {
      DiagnosticLogger.shared.log(
        .info,
        .action,
        "Quick access item dismissed; saved file retained",
        context: ["fileName": url.lastPathComponent]
      )
    }
  }

  /// Remove a screenshot from the stack (backward compatible alias)
  func removeScreenshot(id: UUID) {
    if let item = items.first(where: { $0.id == id }) { rememberClosedItem(url: item.url, isVideo: item.isVideo) }
    removeItem(id: id)
  }

  private func scheduleDismissCleanup(for url: URL, expectedIdentity: CaptureFileIdentity) {
    // Restore забирает запись из очереди до появления восстановленной карточки.
    guard !isRetainedForRestore(url: url, identity: expectedIdentity) else { return }

    // Let SwiftUI commit the card removal before checking history or touching disk.
    Task { @MainActor in
      await Task.yield()

      // Последние закрытые карточки сохраняют файл независимо от истории.
      guard !isRetainedForRestore(url: url, identity: expectedIdentity),
            !VideoEditorManager.shared.isEditingFile(at: url) else { return }

      // Auto-delete temp files on dismiss (unsaved captures).
      // Skip deletion if history is enabled and the file has a history record —
      // the retention service will clean it up when the record ages out.
      let historyEnabled = UserDefaults.standard.snapzyHistoryEnabled
      let hasHistoryRecord = historyEnabled && CaptureHistoryStore.shared.hasRecord(forFilePath: url.path)

      if hasHistoryRecord {
        DiagnosticLogger.shared.log(
          .info,
          .action,
          "Quick access item dismissed; temp file preserved for history",
          context: ["fileName": url.lastPathComponent]
        )
      } else if ClipboardHelper.isReferencedByGeneralPasteboard(url) {
        // The capture was auto-copied to the clipboard and nothing has been
        // copied since: receivers resolve the file URL at paste time, so
        // deleting it now would break the paste (#234). Leave reclamation to
        // launch-time orphan cleanup.
        DiagnosticLogger.shared.log(
          .info,
          .action,
          "Quick access item dismissed; temp file preserved while referenced by pasteboard",
          context: ["fileName": url.lastPathComponent]
        )
      } else {
        guard CaptureFileIdentity(at: url, entry: .regularLeaf) == expectedIdentity,
              !items.contains(where: { CaptureFileIdentity(at: $0.url) == expectedIdentity }) else { return }
        DiagnosticLogger.shared.log(
          .info,
          .action,
          "Quick access item dismissed; temp file auto-delete requested",
          context: ["fileName": url.lastPathComponent]
        )
        AnnotationSessionStore.shared.deleteSession(for: url)
        VideoEditorSessionStore.shared.deleteSession(for: url)
        tempCaptureManager.deleteTempFile(at: url)
      }
    }
  }

  private func isRetainedForRestore(url: URL, identity: CaptureFileIdentity) -> Bool {
    recentlyClosedCaptures.contains { capture in
      capture.url == url || CaptureFileIdentity(at: capture.url) == identity
    }
  }

  func retainsCapture(at url: URL) -> Bool {
    guard let identity = CaptureFileIdentity(at: url) else { return false }
    return isRetainedForRestore(url: url, identity: identity)
      || items.contains { CaptureFileIdentity(at: $0.url) == identity }
  }

  func retainedCapturePaths(for type: QuickAccessItemType) -> Set<String> {
    let isVideo = type == .video
    let visible = items.filter { $0.isVideo == isVideo }.map { $0.url.path }
    let restorable = recentlyClosedCaptures.filter { $0.isVideo == isVideo }.map { $0.url.path }
    return Set(visible + restorable)
  }

  /// Remove card from UI only — does NOT delete the underlying file.
  /// Used after drag-to-app so the receiving app can still read the file.
  /// Orphaned temp files get cleaned up on next launch via cleanupOrphanedFiles().
  func dismissCard(id: UUID) {
    let itemURL = items.first(where: { $0.id == id })?.url
    if let item = items.first(where: { $0.id == id }) { rememberClosedItem(url: item.url, isVideo: item.isVideo) }
    DiagnosticLogger.shared.log(
      .debug,
      .action,
      "Quick access card dismissed without deleting file",
      context: ["itemId": id.uuidString]
    )
    cancelDismissTimer(for: id)
    pinWindowManager.close(id: id)
    editingItemIds.remove(id)
    activityHoldItemIds.remove(id)
    hoveredItemIds.remove(id)
    // Clear annotation session cache for this item
    AnnotateManager.shared.clearSessionData(for: id)
    VideoEditorManager.shared.clearSessionData(for: id)
    if let itemURL {
      VideoEditorManager.shared.clearSessionData(for: itemURL)
    }
    if items.count == 1, items.first?.id == id { hidePanel() }
    withAnimation(QuickAccessAnimations.cardRemove) {
      items.removeAll { $0.id == id }
    }
    if items.isEmpty {
      hidePanel()
    }
  }

  /// Toggle pin state for an item. Pinned items bypass auto-dismiss.
  func togglePin(id: UUID) {
    guard let index = items.firstIndex(where: { $0.id == id }) else {
      DiagnosticLogger.shared.log(
        .warning,
        .action,
        "Quick access toggle pin missed item",
        context: ["itemId": id.uuidString]
      )
      return
    }

    setPinState(id: id, isPinned: !items[index].isPinned, closePinWindow: true)
  }

  /// Pin a screenshot item without toggling it back off.
  func pinScreenshot(id: UUID) {
    setPinState(id: id, isPinned: true, closePinWindow: false)
  }

  /// Pin a saved screenshot URL, creating a transient pin window if no Quick Access item owns it.
  @discardableResult
  func pinScreenshot(url: URL) async -> QuickAccessItem? {
    if let existingItem = item(matching: url) {
      pinScreenshot(id: existingItem.id)
      return item(matching: url) ?? existingItem
    }

    let fileAccess = fileAccessManager.beginAccessingURL(url)
    defer { fileAccess.stop() }

    guard FileManager.default.fileExists(atPath: url.path) else {
      DiagnosticLogger.shared.log(
        .warning,
        .action,
        "Quick access direct pin skipped; file missing",
        context: ["fileName": url.lastPathComponent]
      )
      return nil
    }

    let result = await ThumbnailGenerator.generate(from: url)
    let thumbnail = result.thumbnail ?? ThumbnailGenerator.placeholderThumbnail()
    let item = QuickAccessItem(url: url, thumbnail: thumbnail, cardThumbnail: result.cardThumbnail)
    let didShowWindow = pinWindowManager.show(item: item) { closedId in
      DiagnosticLogger.shared.log(
        .debug,
        .action,
        "Transient pinned screenshot closed",
        context: ["itemId": closedId.uuidString]
      )
    }

    guard didShowWindow else { return nil }

    DiagnosticLogger.shared.log(
      .info,
      .action,
      "Screenshot URL pinned directly",
      context: ["fileName": url.lastPathComponent, "itemId": item.id.uuidString]
    )
    return item
  }

  func setWindowOpen(id: UUID, isOpen: Bool) {
    if let index = items.firstIndex(where: { $0.id == id }) {
      PerfSignpost.event("setWindowOpenCommit")
      // No inline withAnimation here: QuickAccessStackView's
      // `.animation(value: visibleItems.count)` is the single driver for the
      // hide/reappear spring. Wrapping this mutation too would compound two springs.
      if isOpen, hideCardWhenWindowOpen, hoveredItemID == id {
        clearHoveredItem()
      }
      items[index].isWindowOpen = isOpen

      if !isOpen {
        // An editor window just closed and the card reappeared: self-heal the
        // hover monitors in case the runloop stall got the global event tap killed.
        panelController.reinstallMouseMonitors()
      }
    }
  }

  private func setPinState(id: UUID, isPinned: Bool, closePinWindow: Bool) {
    guard let index = items.firstIndex(where: { $0.id == id }) else {
      if closePinWindow {
        pinWindowManager.close(id: id)
      }
      return
    }

    guard !items[index].isVideo else {
      items[index].isPinned = false
      pinWindowManager.close(id: id)
      return
    }

    items[index].isPinned = isPinned

    if isPinned {
      let didShowWindow = pinWindowManager.show(item: items[index]) { [weak self] closedId in
        self?.handlePinWindowClosed(id: closedId)
      }

      guard didShowWindow else {
        items[index].isPinned = false
        return
      }

      cancelDismissTimer(for: id)
      // Исходная карточка остаётся на экране рядом с pin, как в эталоне
      if QuickAccessCompletionPolicy.hidesCardWhenOpening(pin: true, hideCardWhenWindowOpen: hideCardWhenWindowOpen) {
        setWindowOpen(id: id, isOpen: true)
      }

      DiagnosticLogger.shared.log(
        .info,
        .action,
        "Quick access item pinned",
        context: ["itemId": id.uuidString]
      )
    } else {
      if closePinWindow {
        pinWindowManager.close(id: id)
      }
      if autoDismissEnabled {
        startDismissTimer(for: id)
      }
      DiagnosticLogger.shared.log(
        .info,
        .action,
        "Quick access item unpinned",
        context: ["itemId": id.uuidString]
      )
    }
  }

  private func handlePinWindowClosed(id: UUID) {
    guard let index = items.firstIndex(where: { $0.id == id }) else { return }
    items[index].isPinned = false
    if autoDismissEnabled {
      startDismissTimer(for: id)
    }
    DiagnosticLogger.shared.log(
      .info,
      .action,
      "Pin window closed, item unpinned",
      context: ["itemId": id.uuidString]
    )
  }

  /// Update processing state for an item (used during GIF conversion)
  /// Обработку на карточке можно отменить, только пока идёт конвертация в GIF.
  func canCancelProcessing(id: UUID) -> Bool {
    guard items.first(where: { $0.id == id })?.processingState.isProcessing == true else { return false }
    return RecordingCoordinator.shared.isConvertingGIF(itemID: id)
  }

  /// Кнопка отмены на карточке с прогрессом: вопрос эталона о сохранении видео или удалении записи.
  func cancelProcessing(id: UUID) {
    guard canCancelProcessing(id: id) else { return }
    RecordingCoordinator.shared.requestGIFConversionCancel(itemID: id)
  }

  func updateProcessingState(id: UUID, state: QuickAccessProcessingState) {
    guard let index = items.firstIndex(where: { $0.id == id }) else {
      DiagnosticLogger.shared.log(
        .warning,
        .action,
        "Quick access processing state update missed item",
        context: ["itemId": id.uuidString, "state": "\(state)"]
      )
      return
    }
    items[index].processingState = state
    DiagnosticLogger.shared.log(
      .debug,
      .action,
      "Quick access processing state changed",
      context: ["itemId": id.uuidString, "state": "\(state)"]
    )
    if state == .idle {
      resumeCountdownForActivity(id)
    } else {
      pauseCountdownForActivity(id)
    }
  }

  /// Replace item URL and thumbnail after processing (e.g. GIF conversion)
  func updateItemURL(id: UUID, newURL: URL, newThumbnail: NSImage? = nil) {
    guard let index = items.firstIndex(where: { $0.id == id }) else {
      DiagnosticLogger.shared.log(
        .warning,
        .action,
        "Quick access item URL update missed item",
        context: ["itemId": id.uuidString, "fileName": newURL.lastPathComponent]
      )
      return
    }
    let existing = items[index]
    items[index] = existing.replacingURL(newURL, thumbnail: newThumbnail)
    pinWindowManager.update(item: items[index])
    DiagnosticLogger.shared.log(
      .info,
      .action,
      "Quick access item URL updated",
      context: ["itemId": id.uuidString, "fileName": newURL.lastPathComponent]
    )
  }

  /// Update thumbnail directly from an already-rendered image (synchronous, instant)
  /// Used after annotation save — avoids the slow ThumbnailGenerator pipeline.
  /// Preserves existing isCloudStale — callers should use markCloudStale(id:) if needed.
  func updateItemThumbnail(id: UUID, image: NSImage) {
    guard let index = items.firstIndex(where: { $0.id == id }) else { return }
    _ = nextThumbnailGeneration(for: id)
    let existing = items[index]
    let maxSize: CGFloat = 200
    let thumbnail = scaleThumbnail(image, maxSize: maxSize)
    items[index] = existing.replacingThumbnail(thumbnail,
      cardThumbnail: QuickAccessThumbnailRenderer.render(image, width: QuickAccessLayout.cardWidth))
    pinWindowManager.update(item: items[index], imageOverride: image)
    logger.info("Thumbnail updated directly for item \(id)")
  }

  /// Update thumbnail directly with an already-scaled thumbnail and an optional full-resolution image.
  /// Skips lockFocus scaling on the main thread.
  /// - `fullResImage`: when non-nil, also pushed to the pin window as `imageOverride`
  ///   (pin sizing derives from it, so never pass a downscaled thumb here).
  /// - `generation`: stale-write guard from `nextThumbnailGeneration(for:)`; a late
  ///   off-main render with an older generation is dropped so last-save-wins holds.
  func updateItemThumbnail(id: UUID, thumbnail: NSImage, fullResImage: NSImage?, generation: UInt64? = nil) {
    guard let index = items.firstIndex(where: { $0.id == id }) else { return }
    if let generation {
      guard generation >= thumbnailSaveGenerations[id, default: 0] else { return }
    } else {
      _ = nextThumbnailGeneration(for: id)
    }
    let existing = items[index]
    items[index] = existing.replacingThumbnail(thumbnail,
      cardThumbnail: fullResImage.map { QuickAccessThumbnailRenderer.render($0, width: QuickAccessLayout.cardWidth) })
    if let fullResImage {
      pinWindowManager.update(item: items[index], imageOverride: fullResImage)
    }
    logger.info("Thumbnail updated directly with pre-scaled image for item \(id)")
  }

  /// Monotonic per-item token for the save-and-close async thumbnail push.
  /// Call on main when the save starts; pass the token to the async `updateItemThumbnail`
  /// so a slower earlier render can never overwrite a newer one.
  func nextThumbnailGeneration(for id: UUID) -> UInt64 {
    let next = thumbnailSaveGenerations[id, default: 0] + 1
    thumbnailSaveGenerations[id] = next
    return next
  }

  /// Scale image to thumbnail size using CGContext (thread-safe, runs on any queue)
  nonisolated static func cgScaleThumbnail(_ image: NSImage, maxSize: CGFloat) -> NSImage {
    let originalSize = image.size
    guard originalSize.width > 0, originalSize.height > 0 else { return image }

    let scale = min(maxSize / max(originalSize.width, originalSize.height), 1.0)
    if scale >= 1.0 { return image }

    let newSize = CGSize(
      width: originalSize.width * scale,
      height: originalSize.height * scale
    )

    var rect = CGRect(origin: .zero, size: originalSize)
    guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return image }
    let width = Int(newSize.width)
    let height = Int(newSize.height)

    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ) else { return image }

    context.interpolationQuality = .high
    context.draw(cgImage, in: CGRect(origin: .zero, size: newSize))

    guard let scaledCgImage = context.makeImage() else { return image }
    return NSImage(cgImage: scaledCgImage, size: newSize)
  }

  /// Scale image to thumbnail size (synchronous, no file I/O)
  private func scaleThumbnail(_ image: NSImage, maxSize: CGFloat) -> NSImage {
    PerfSignpost.measure("scaleThumbnailInner") {
      let originalSize = image.size
      guard originalSize.width > 0, originalSize.height > 0 else { return image }

      let scale: CGFloat = if originalSize.width > originalSize.height {
        min(maxSize / originalSize.width, 1.0)
      } else {
        min(maxSize / originalSize.height, 1.0)
      }
      if scale >= 1.0 { return image }

      let newSize = CGSize(
        width: originalSize.width * scale,
        height: originalSize.height * scale
      )
      let thumbnail = NSImage(size: newSize)
      thumbnail.lockFocus()
      NSGraphicsContext.current?.imageInterpolation = .high
      image.draw(
        in: NSRect(origin: .zero, size: newSize),
        from: NSRect(origin: .zero, size: originalSize),
        operation: .copy,
        fraction: 1.0
      )
      thumbnail.unlockFocus()
      return thumbnail
    }
  }

  /// Refresh thumbnail for an item after its image was updated on disk (e.g. annotation saved)
  func refreshItemThumbnail(
    id: UUID,
    thumbnailForURL: @MainActor (URL) async -> ThumbnailResult = { await ThumbnailGenerator.generate(from: $0) }
  ) async {
    guard let index = items.firstIndex(where: { $0.id == id }) else {
      DiagnosticLogger.shared.log(
        .debug,
        .ui,
        "Quick access thumbnail refresh skipped; item missing",
        context: ["itemId": id.uuidString]
      )
      return
    }
    let item = items[index]
    let url = item.url
    let generation = nextThumbnailGeneration(for: id)
    let fileAccess = fileAccessManager.beginAccessingURL(url)
    defer { fileAccess.stop() }
    let result = await thumbnailForURL(url)
    guard !Task.isCancelled, thumbnailSaveGenerations[id] == generation,
          let freshIndex = items.firstIndex(where: { $0.id == id }),
          items[freshIndex].url == url,
          items[freshIndex].thumbnailVersion == item.thumbnailVersion else { return }
    guard let newThumbnail = result.thumbnail else {
      logger.warning("Thumbnail refresh failed for \(url.lastPathComponent)")
      DiagnosticLogger.shared.log(
        .warning,
        .ui,
        "Quick access thumbnail refresh failed",
        context: ["fileName": url.lastPathComponent]
      )
      return
    }
    let existing = items[freshIndex]
    items[freshIndex] = existing.replacingThumbnail(
      newThumbnail, cardThumbnail: result.cardThumbnail, duration: existing.isVideo ? result.duration : nil
    )
    pinWindowManager.update(item: items[freshIndex])
    logger.info("Thumbnail refreshed for \(url.lastPathComponent)")
    DiagnosticLogger.shared.log(
      .debug,
      .ui,
      "Quick access thumbnail refreshed",
      context: ["fileName": url.lastPathComponent]
    )
  }

  // MARK: - Card Action Shortcuts

  /// Single writer for hover state. Card action shortcuts shadow the frontmost
  /// app's keyboard while registered, so hover-exit must always reach here.
  func setHoveredItem(id: UUID, hovering: Bool) {
    if hovering {
      guard items.contains(where: { $0.id == id }) else { return }
      hoveredItemID = id
    } else {
      guard hoveredItemID == id else { return }
      hoveredItemID = nil
    }
    hoverShortcutRegistry.setHoveredItem(hoveredItemID)
  }

  func clearHoveredItem() {
    guard hoveredItemID != nil else { return }
    hoveredItemID = nil
    hoverShortcutRegistry.setHoveredItem(nil)
  }

  /// A card can vanish under the pointer (countdown, delete, editor open) without
  /// SwiftUI reporting hover-exit, which would leave the bindings registered.
  private func invalidateHoverIfItemGone() {
    guard let hoveredItemID else { return }
    guard !items.contains(where: { $0.id == hoveredItemID }) else { return }
    clearHoveredItem()
  }

  private func handleCardShortcut(_ trigger: QuickAccessCardShortcutTrigger) {
    guard trigger.itemID == hoveredItemID,
          let item = items.first(where: { $0.id == trigger.itemID }),
          !(hideCardWhenWindowOpen && item.isWindowOpen) else { return }
    guard QuickAccessActionConfigurationStore.shared.isEnabled(trigger.action) else { return }

    cardShortcutTrigger.send(trigger)
    DiagnosticLogger.shared.log(
      .info,
      .action,
      "Quick access card action triggered via shortcut",
      context: ["itemId": trigger.itemID.uuidString, "action": trigger.action.rawValue]
    )
  }

  func suspendForCapture() {
    clearHoveredItem()
    panelController.suspendMouseMonitors()
    pinWindowManager.suspendAllMouseMonitors()
  }

  func resumeAfterCapture() {
    panelController.resumeMouseMonitors()
    pinWindowManager.resumeAllMouseMonitors()
  }

  /// Dismiss all screenshots
  func dismissAll() {
    let count = items.count
    for item in items {
      cancelDismissTimer(for: item.id)
      // Clear annotation session cache
      AnnotateManager.shared.clearSessionData(for: item.id)
      VideoEditorManager.shared.clearSessionData(for: item.id)
      VideoEditorManager.shared.clearSessionData(for: item.url)
    }
    pinWindowManager.closeAll()
    QuickAccessHiddenStackStrip.shared.hide()
    hidePanel()
    items.removeAll()
    editingItemIds.removeAll()
    activityHoldItemIds.removeAll()
    hoveredItemIds.removeAll()
    DiagnosticLogger.shared.log(
      .info,
      .action,
      "Quick access dismissed all items",
      context: ["itemCount": "\(count)"]
    )
  }

  // MARK: - Save All / Close All

  /// Пункты Save All и Close All показываются только при нескольких карточках.
  var isBulkActionAvailable: Bool {
    QuickAccessBulkActions.isAvailable(itemCount: items.count)
  }

  /// Save All: сохраняет каждую несохранённую карточку в папку экспорта без диалогов
  /// и без Finder на каждый файл. Карточка закрывается после успешного сохранения, как у Save.
  func saveAll() {
    saveAll { [weak self] id in
      self?.saveItem(id: id, useSavePanel: false, revealInFinder: false)
    }
  }

  /// Шов для тестов: выбор несохранённых карточек отдельно от записи файлов.
  func saveAll(using save: (UUID) -> Void) {
    let ids = QuickAccessBulkActions.unsavedItemIDs(
      in: items.filter { !hasEditorOwnership(of: $0.url, id: $0.id) },
      isTemporary: { tempCaptureManager.isTempFile($0) },
      excluding: savingItemIds
    )
    DiagnosticLogger.shared.log(
      .info,
      .action,
      "Quick access save all requested",
      context: ["itemCount": "\(items.count)", "unsavedCount": "\(ids.count)"]
    )
    ids.forEach(save)
  }

  /// Close All из контекстного меню: подтверждение с Don't ask, затем закрытие всех карточек.
  /// `confirmation` и `prompt` подменяются в тестах, по умолчанию – UserDefaults и NSAlert.
  func requestCloseAll(
    confirmation: QuickAccessCloseAllConfirmation? = nil,
    prompt: (() -> QuickAccessCloseAllDecision)? = nil
  ) {
    guard !items.isEmpty else { return }
    let confirmation = confirmation ?? QuickAccessCloseAllConfirmation()
    let prompt = prompt ?? { QuickAccessCloseAllAlert.run() }
    guard confirmation.shouldClose(prompt: prompt) else {
      DiagnosticLogger.shared.log(
        .info,
        .action,
        "Quick access close all cancelled",
        context: ["itemCount": "\(items.count)"]
      )
      return
    }
    closeAll()
  }

  /// Закрывает все карточки как обычный Close: несохранённые временные файлы удаляются,
  /// закрытые попадают в список недавно закрытых.
  func closeAll() {
    let ids = items.map(\.id)
    for id in ids {
      removeScreenshot(id: id)
    }
    DiagnosticLogger.shared.log(
      .info,
      .action,
      "Quick access closed all items",
      context: ["itemCount": "\(ids.count)"]
    )
  }

  /// Copy item to clipboard (cloud link if available, otherwise image or video file URL)
  func copyToClipboard(
    id: UUID, optionHeld: Bool = NSEvent.modifierFlags.contains(.option), reduceMotion: Bool = false
  ) {
    let dismissesCard = QuickAccessCompletionPolicy.shouldDismissAfterCopy(optionHeld: optionHeld)
    guard let item = items.first(where: { $0.id == id }) else {
      DiagnosticLogger.shared.log(
        .warning,
        .clipboard,
        "Quick access clipboard copy missed item",
        context: ["itemId": id.uuidString]
      )
      return
    }

    // If cloud URL is available, copy the cloud link as text
    if let cloudURL = item.cloudURL {
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      pasteboard.setString(cloudURL.absoluteString, forType: .string)
      DiagnosticLogger.shared.log(
        .info,
        .clipboard,
        "Quick access copied cloud link to clipboard",
        context: ["fileName": item.url.lastPathComponent]
      )
      if dismissesCard { dismissCard(id: id) }
      QuickAccessSound.copy.play(reduceMotion: reduceMotion)
      return
    }

    let url = item.url
    let isVideo = item.isVideo

    // Load data and write to clipboard BEFORE removing the card.
    // removeItem/removeScreenshot deletes temp files, which would cause
    // reads to fail if done after removal.
    if isVideo {
      guard ClipboardHelper.copyMediaFile(from: url) else { return }
      DiagnosticLogger.shared.log(
        .info,
        .clipboard,
        "Quick access copied video file to clipboard",
        context: ["fileName": url.lastPathComponent]
      )
    } else {
      guard ClipboardHelper.copyImage(from: url) else { return }
      DiagnosticLogger.shared.log(
        .info,
        .clipboard,
        "Quick access copied image to clipboard",
        context: ["fileName": url.lastPathComponent]
      )
    }

    // Remove card from UI without deleting the temp file (same as drag-to-app).
    // С Option карточка остаётся, как у эталона.
    if dismissesCard { dismissCard(id: id) }

    // File-based clipboard: the file must stay on disk so the receiving app
    // can read it at paste time. Orphaned temp files are cleaned on next launch.

    QuickAccessSound.copy.play(reduceMotion: reduceMotion)
  }

  func requestDeleteItem(id: UUID, expectedURL: URL, completion: @escaping @MainActor (Bool) -> Void) {
    let requestedIdentity = fileAccessManager.withScopedAccess(to: expectedURL) {
      CaptureFileIdentity(at: expectedURL, entry: .deletableLeaf)
    }
    Task { @MainActor in
      let currentIdentity = fileAccessManager.withScopedAccess(to: expectedURL) {
        CaptureFileIdentity(at: expectedURL, entry: .deletableLeaf)
      }
      guard currentIdentity == requestedIdentity else {
        DiagnosticLogger.shared.log(
          .warning,
          .fileAccess,
          "Quick access delete skipped; source changed",
          context: ["fileName": expectedURL.lastPathComponent]
        )
        completion(false)
        return
      }
      completion(deleteItem(id: id, expectedURL: expectedURL))
    }
  }

  /// Move the file and clear its references in one main-actor turn.
  @discardableResult
  func deleteItem(
    id: UUID,
    expectedURL: URL,
    trashFile: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
  ) -> Bool {
    guard let item = items.first(where: { $0.id == id }),
          SandboxFileAccessManager.directoryEntryPath(for: item.url)
            == SandboxFileAccessManager.directoryEntryPath(for: expectedURL) else {
      DiagnosticLogger.shared.log(
        .warning,
        .action,
        "Quick access delete skipped; card is missing or changed",
        context: ["itemId": id.uuidString]
      )
      return false
    }

    let url = item.url
    let isTempFile = tempCaptureManager.isTempFile(url)
    DiagnosticLogger.shared.log(
      .info,
      .action,
      "Quick access delete requested",
      context: ["fileName": url.lastPathComponent, "temp": isTempFile ? "true" : "false"]
    )

    let filePath = SandboxFileAccessManager.directoryEntryPath(for: url)
    let relatedItems = isTempFile ? [item] : items.filter {
      SandboxFileAccessManager.directoryEntryPath(for: $0.url) == filePath
    }
    guard !relatedItems.contains(where: {
      savingItemIds.contains($0.id) || editingItemIds.contains($0.id) || $0.isWindowOpen || $0.processingState.isProcessing
    }) else { return false }

    guard !VideoEditorManager.shared.isEditingFile(at: url) else { return false }
    if !isTempFile {
      guard !AnnotateManager.shared.isEditingFile(at: url) else { return false }
      let fileAccess = fileAccessManager.beginAccessingURL(url)
      let directoryAccess = fileAccessManager.beginAccessingURL(url.deletingLastPathComponent())
      defer {
        fileAccess.stop()
        directoryAccess.stop()
      }

      guard CaptureFileIdentity(at: url, entry: .deletableLeaf) != nil else {
        DiagnosticLogger.shared.log(
          .warning,
          .fileAccess,
          "Quick access delete skipped; source is unavailable",
          context: ["fileName": url.lastPathComponent]
        )
        return false
      }
      do {
        try trashFile(url)
      } catch {
        logger.error("Failed to delete item \(url.lastPathComponent): \(error.localizedDescription)")
        DiagnosticLogger.shared.logError(
          .fileAccess,
          error,
          "Quick access delete failed",
          context: ["fileName": url.lastPathComponent]
        )
        return false
      }

      for videoURL in Set(relatedItems.filter(\.isVideo).map(\.url)) {
        try? RecordingMetadataStore.delete(for: videoURL)
      }
    }

    // Keep all card and editor state until the external move has succeeded.
    // Internal temporary captures still use the ordinary deferred cleanup.
    recentlyClosedCaptures.removeAll {
      isTempFile ? $0.url.standardizedFileURL == url.standardizedFileURL
        : SandboxFileAccessManager.directoryEntryPath(for: $0.url) == filePath
    }
    for savedURL in Set(relatedItems.map(\.url)) {
      CaptureHistoryStore.shared.removeByFilePath(savedURL.path)
      AnnotationSessionStore.shared.deleteSession(for: savedURL)
      VideoEditorSessionStore.shared.deleteSession(for: savedURL)
      VideoEditorManager.shared.clearSessionData(for: savedURL)
    }
    for relatedItem in relatedItems {
      removeItem(id: relatedItem.id)
    }
    return true
  }

  /// Open screenshot in Finder
  func openInFinder(id: UUID) {
    guard let item = items.first(where: { $0.id == id }) else {
      DiagnosticLogger.shared.log(
        .warning,
        .action,
        "Quick access reveal in Finder missed item",
        context: ["itemId": id.uuidString]
      )
      return
    }

    // Capture URL before removal
    let url = item.url

    // Remove immediately - animation starts now
    removeScreenshot(id: id)

    // Async Finder reveal
    DiagnosticLogger.shared.log(
      .info,
      .action,
      "Quick access reveal in Finder requested",
      context: ["fileName": url.lastPathComponent]
    )
    Task { @MainActor in
      let fileAccess = fileAccessManager.beginAccessingURL(url)
      defer { fileAccess.stop() }
      NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
    }
  }

  func beginSavingItem(id: UUID) -> Bool {
    savingItemIds.insert(id).inserted
  }

  private func hasEditorOwnership(of url: URL, id: UUID) -> Bool {
    editingItemIds.contains(id) || AnnotateManager.shared.isEditingFile(at: url)
      || VideoEditorManager.shared.isEditingFile(at: url)
  }

  func finishSavingItem(id: UUID) {
    savingItemIds.remove(id)
  }

  func saveItem(id: UUID, useSavePanel: Bool? = nil, revealInFinder: Bool = true) {
    guard let item = items.first(where: { $0.id == id }) else {
      DiagnosticLogger.shared.log(
        .warning,
        .action,
        "Quick access save missed item",
        context: ["itemId": id.uuidString]
      )
      return
    }
    let tempURL = item.url
    let sourceIsTemporary = tempCaptureManager.isTempFile(tempURL)
    guard !sourceIsTemporary || !hasEditorOwnership(of: tempURL, id: id) else { return }
    guard beginSavingItem(id: id) else { return }
    let sourceIdentity = fileAccessManager.withScopedAccess(to: tempURL) { CaptureFileIdentity(at: tempURL) }
    let hadActivityHold = activityHoldItemIds.contains(id)
    pauseCountdownForActivity(id)
    let cachedSessionData = AnnotateManager.shared.getSessionData(for: id)
      ?? AnnotationSessionStore.shared.load(for: tempURL)
    let cachedVideoSessionData = VideoEditorManager.shared.getSessionData(for: id)
      ?? VideoEditorSessionStore.shared.load(for: tempURL)
    DiagnosticLogger.shared.log(
      .info,
      .action,
      "Quick access manual save requested",
      context: ["fileName": tempURL.lastPathComponent]
    )

    let chooseDestination = useSavePanel ?? QuickAccessCompletionPolicy.chooseDestination(
      behavior: UserDefaults.standard.string(forKey: "ownshot.quickAccess.saveButtonBehavior"),
      optionHeld: NSEvent.modifierFlags.contains(.option)
    )
    var selectedDestination: QuickAccessSaveDestination?
    if chooseDestination {
      let panel = NSSavePanel()
      // Эталон подставляет имя без расширения («qa1»), расширение задаёт тип панели.
      let suggestion = Self.savePanelSuggestion(for: tempURL)
      panel.nameFieldStringValue = suggestion.name
      if let contentType = suggestion.contentType {
        panel.allowedContentTypes = [contentType]
        panel.isExtensionHidden = true
      }
      let destinationCapture = QuickAccessSavePanelDestinationCapture(
        extensions: [tempURL.pathExtension, suggestion.contentType?.preferredFilenameExtension ?? ""]
      )
      panel.delegate = destinationCapture
      panel.canCreateDirectories = true
      guard panel.runModal() == .OK, let url = panel.url else {
        finishSavingItem(id: id)
        if !hadActivityHold { resumeCountdownForActivity(id) }
        return
      }
      selectedDestination = destinationCapture.destination(at: url)
    }
    Task { @MainActor in
      defer {
        finishSavingItem(id: id)
        if !hadActivityHold { resumeCountdownForActivity(id) }
      }
      // An editor can open while the destination panel or this task is pending.
      guard !sourceIsTemporary || !hasEditorOwnership(of: tempURL, id: id) else { return }
      let currentIdentity = fileAccessManager.withScopedAccess(to: tempURL) { CaptureFileIdentity(at: tempURL) }
      guard currentIdentity == sourceIdentity else {
        DiagnosticLogger.shared.log(
          .warning,
          .fileAccess,
          "Quick access manual save skipped; source changed",
          context: ["fileName": tempURL.lastPathComponent]
        )
        return
      }
      cancelDismissTimer(for: id)
      let savedURL: URL?
      if let selectedDestination {
        let sourceAccess = fileAccessManager.beginAccessingURL(tempURL)
        let destinationAccess = fileAccessManager.beginAccessingURL(selectedDestination.url)
        defer { sourceAccess.stop(); destinationAccess.stop() }
        do {
          let publishedURL = try selectedDestination.save(source: tempURL, sourceIsTemporary: sourceIsTemporary)
          QuickAccessSaveDestination.copyRecordingMetadata(
            from: tempURL, to: publishedURL, removingOriginal: sourceIsTemporary
          )
          savedURL = publishedURL
        } catch {
          savedURL = nil
        }
      } else {
        if sourceIsTemporary {
          savedURL = tempCaptureManager.saveToExportLocation(tempURL: tempURL)
        } else {
          let sourceAccess = fileAccessManager.beginAccessingURL(tempURL)
          let exportAccess = fileAccessManager.beginAccessingURL(fileAccessManager.resolvedExportDirectoryURL())
          defer { sourceAccess.stop(); exportAccess.stop() }
          savedURL = try? QuickAccessImportedFileSave.copy(source: sourceAccess.url, to: exportAccess.url)
          if let savedURL, savedURL != tempURL, let metadata = RecordingMetadataStore.load(for: tempURL) {
            try? RecordingMetadataStore.save(metadata, for: savedURL)
          }
        }
      }
      if let savedURL {
        dismissCard(id: id)
        rememberClosedItem(url: savedURL, isVideo: item.isVideo)
        // Update history records by original file path. QuickAccess item IDs are
        // independent from persisted history record IDs.
        if sourceIsTemporary {
          CaptureHistoryStore.shared.updateFilePath(from: tempURL.path, to: savedURL.path)
        }
        if (!sourceIsTemporary || !AnnotationSessionStore.shared.moveSession(from: tempURL, to: savedURL)),
           let cachedSessionData,
           AnnotationSessionStore.shared.shouldPersist(for: savedURL) {
          AnnotationSessionStore.shared.persist(cachedSessionData, for: savedURL)
        }
        if (!sourceIsTemporary || !VideoEditorSessionStore.shared.moveSession(from: tempURL, to: savedURL)),
           let cachedVideoSessionData {
          VideoEditorSessionStore.shared.persist(cachedVideoSessionData, for: savedURL)
        }

        let captureType: CaptureType = item.isVideo ? .recording : .screenshot
        PostCaptureActionHandler.shared.copyEditedCaptureToClipboardIfEnabled(
          for: captureType,
          url: savedURL,
          movedRecordingFrom: item.isVideo && sourceIsTemporary ? tempURL : nil
        )

        if revealInFinder && (UserDefaults.standard.object(forKey: PreferencesKeys.quickAccessOpenInFinderAfterSave) as? Bool ?? true) {
          let fileAccess = fileAccessManager.beginAccessingURL(savedURL)
          defer { fileAccess.stop() }
          NSWorkspace.shared.selectFile(savedURL.path, inFileViewerRootedAtPath: "")
        }
        DiagnosticLogger.shared.log(
          .info,
          .action,
          "Quick access manual save completed",
          context: ["fileName": savedURL.lastPathComponent]
        )
      } else {
        DiagnosticLogger.shared.log(
          .error,
          .fileAccess,
          "Quick access manual save failed",
          context: ["fileName": tempURL.lastPathComponent]
        )
        let alert = NSAlert()
        alert.messageText = "Unable to save capture"
        alert.informativeText = "The capture is still available in Quick Access. Check the destination and try again."
        alert.runModal()
        return
      }
      AnnotateManager.shared.clearSessionData(for: id)
      VideoEditorManager.shared.clearSessionData(for: id)
      VideoEditorManager.shared.clearSessionData(for: tempURL)
    }
  }

  /// Update position setting
  func setPosition(_ newPosition: QuickAccessPosition) {
    position = newPosition
    DiagnosticLogger.shared.log(
      .info,
      .preferences,
      "Quick access position changed",
      context: ["position": newPosition.rawValue]
    )
  }

  // MARK: - Private Methods

  private func showPanel() {
    QuickAccessHiddenStackStrip.shared.hide()
    let stackView = QuickAccessStackView(manager: self)
    let size = calculateMaxPanelSize()
    panelController.show(
      stackView,
      size: size,
      itemCount: visiblePanelItemCount,
      scale: CGFloat(overlayScale)
    )
    installEditHotKeyIfNeeded()
    DiagnosticLogger.shared.log(
      .debug,
      .ui,
      "Quick access panel shown",
      context: ["itemCount": "\(items.count)"]
    )
  }

  /// Ensure a panel exists for the capture that just landed, on the display that
  /// capture happened on. A panel already sliding out is not reusable — it would
  /// finish closing and swallow the new card — so that case gets a fresh show.
  private func showPanelIfNeeded() {
    guard presentsPanel else { return }
    guard panelController.isVisible, !panelController.isDismissing else {
      showPanel()
      return
    }
    panelController.moveToActiveScreenIfNeeded()
  }

  private func hidePanel() {
    if !panelController.isDismissing {
      panelController.updateContent(QuickAccessStackView(manager: self, frozenItems: items))
    }
    clearHoveredItem()
    removeEditHotKey()
    panelController.hide()
  }

  @discardableResult
  func openEditorForNewestItem() -> Bool {
    guard isEnabled, panelController.isVisible, let item = items.first else { return false }
    if item.isVideo {
      VideoEditorManager.shared.openEditor(for: item)
    } else {
      AnnotateManager.shared.openAnnotation(for: item)
    }
    DiagnosticLogger.shared.log(
      .info,
      .action,
      "Quick access editor opened via keyboard shortcut",
      context: ["itemId": item.id.uuidString, "isVideo": item.isVideo ? "true" : "false"]
    )
    return true
  }

  private func installEditHotKeyIfNeeded() {
    guard openEditorShortcutEnabled else { return }
    let keyboardManager = KeyboardShortcutManager.shared
    if editHotKeyOverrideObservation == nil {
      editHotKeyOverrideObservation = keyboardManager.$videoEditorShortcutOverrides
        .dropFirst()
        .sink { [weak self] overrides in
          guard let self, self.panelController.isVisible, !self.panelController.isDismissing else { return }
          self.updateEditHotKey(videoEditorOverrides: overrides)
        }
    }
    updateEditHotKey(videoEditorOverrides: keyboardManager.videoEditorShortcutOverrides)
  }

  private func updateEditHotKey(videoEditorOverrides: [ShortcutConfig]) {
    guard openEditorShortcutEnabled, let shortcut = openEditorShortcut else { return }
    if videoEditorOverrides.contains(shortcut) {
      removeEditHotKey()
      return
    }
    guard editHotKeyRef == nil else { return }

    if editHotKeyHandler == nil {
      var spec = EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard),
        eventKind: OSType(kEventHotKeyPressed)
      )
      let callback: EventHandlerUPP = { _, event, userData in
        guard let userData, let event else { return OSStatus(eventNotHandledErr) }
        var hotKeyID = EventHotKeyID()
        GetEventParameter(
          event,
          EventParamName(kEventParamDirectObject),
          EventParamType(typeEventHotKeyID),
          nil,
          MemoryLayout<EventHotKeyID>.size,
          nil,
          &hotKeyID
        )
        let manager = Unmanaged<QuickAccessManager>.fromOpaque(userData).takeUnretainedValue()
        guard hotKeyID.signature == manager.editHotKeyID.signature else {
          return OSStatus(eventNotHandledErr)
        }
        DispatchQueue.main.async {
          MainActor.assumeIsolated { _ = manager.openEditorForNewestItem() }
        }
        return noErr
      }
      InstallEventHandler(
        GetApplicationEventTarget(),
        callback,
        1,
        &spec,
        Unmanaged.passUnretained(self).toOpaque(),
        &editHotKeyHandler
      )
    }

    RegisterEventHotKey(
      shortcut.keyCode,
      shortcut.modifiers,
      editHotKeyID,
      GetApplicationEventTarget(),
      0,
      &editHotKeyRef
    )
  }

  private func removeEditHotKey() {
    if let editHotKeyRef {
      UnregisterEventHotKey(editHotKeyRef)
      self.editHotKeyRef = nil
    }
  }

  func setOpenEditorShortcut(_ config: ShortcutConfig?) {
    openEditorShortcut = config
    if let config, let data = try? JSONEncoder().encode(config) {
      UserDefaults.standard.set(data, forKey: Keys.openEditorShortcut)
    } else {
      UserDefaults.standard.set(explicitEmptyShortcutData, forKey: Keys.openEditorShortcut)
    }
    if editHotKeyRef != nil || openEditorShortcutEnabled {
      removeEditHotKey()
      installEditHotKeyIfNeeded()
    }
  }

  private func loadOpenEditorShortcut() {
    guard let data = UserDefaults.standard.data(forKey: Keys.openEditorShortcut) else {
      openEditorShortcut = Self.defaultOpenEditorShortcut
      return
    }
    if data == explicitEmptyShortcutData {
      openEditorShortcut = nil
      return
    }
    openEditorShortcut =
      (try? JSONDecoder().decode(ShortcutConfig.self, from: data)) ?? Self.defaultOpenEditorShortcut
  }

  private var visiblePanelItemCount: Int {
    let actuallyVisibleItems = items.filter { !(hideCardWhenWindowOpen && $0.isWindowOpen) }
    return min(actuallyVisibleItems.count, maxVisibleItems)
  }

  private func refreshPanelInteractionMetrics() {
    panelController.updateInteractionMetrics(
      itemCount: visiblePanelItemCount,
      scale: CGFloat(overlayScale)
    )
  }

  private func item(matching url: URL) -> QuickAccessItem? {
    let standardizedURL = url.standardizedFileURL
    return items.first { $0.url.standardizedFileURL == standardizedURL }
  }

  private func insertRestoredHistoryItem(
    _ item: QuickAccessItem,
    needsRetry: Bool,
    retryURL: URL
  ) {
    withAnimation(QuickAccessAnimations.cardInsert) {
      trimOldestItemIfNeeded(logMessage: "Quick access trimmed oldest item for history restore", restoring: true)
      items.insert(item, at: 0)
    }

    showPanelIfNeeded()

    if autoDismissEnabled {
      startDismissTimer(for: item.id)
    }

    if needsRetry {
      scheduleThumbnailRetry(for: item.id, url: retryURL)
    }
  }

  /// Fixed max-size panel — never resizes, prevents SwiftUI re-layout jitter
  private func calculateMaxPanelSize() -> CGSize {
    let itemCount = maxVisibleItems
    let scale = CGFloat(overlayScale)
    let cardW = QuickAccessLayout.scaledCardWidth(scale)
    let cardH = QuickAccessLayout.scaledCardHeight(scale)
    let height =
      CGFloat(itemCount) * cardH
        + CGFloat(itemCount - 1) * QuickAccessLayout.cardSpacing
        + QuickAccessLayout.containerPadding * 2
    let width = cardW + QuickAccessLayout.containerPadding * 2
    return CGSize(width: width, height: height)
  }

  private func startDismissTimer(for id: UUID) {
    guard let index = items.firstIndex(where: { $0.id == id }), !items[index].isPinned else { return }
    let delay = autoDismissDelay
    let timer = QuickAccessCountdownTimer(duration: delay) { [weak self] in
      guard let self else { return }
      if UserDefaults.standard.string(forKey: "ownshot.quickAccess.autoCloseAction") == "close" {
        self.removeScreenshot(id: id)
      } else {
        self.saveItem(id: id, useSavePanel: false, revealInFinder: false)
      }
    }
    dismissTimers[id] = timer
    timer.start()

    if isItemCountdownHeld(id) {
      timer.pause()
    }
  }

  private func cancelDismissTimer(for id: UUID) {
    dismissTimers[id]?.cancel()
    dismissTimers.removeValue(forKey: id)
  }

  // MARK: - Pause / Resume Countdown

  /// Pause countdown for a single item (used by hover)
  func pauseCountdown(for id: UUID) {
    hoveredItemIds.insert(id)
    dismissTimers[id]?.pause()
  }

  /// Resume countdown for a single item (used by hover un-hover)
  func resumeCountdown(for id: UUID) {
    hoveredItemIds.remove(id)
    // Don't resume if an editor, upload, or conversion still owns the countdown.
    guard !isItemCountdownHeld(id) else { return }
    dismissTimers[id]?.resume()
  }

  /// Pause countdown while an async activity is running for an item.
  func pauseCountdownForActivity(_ id: UUID) {
    activityHoldItemIds.insert(id)
    dismissTimers[id]?.pause()
  }

  /// Resume countdown after an async activity finishes, unless another hold remains.
  func resumeCountdownForActivity(_ id: UUID) {
    activityHoldItemIds.remove(id)
    guard !isItemCountdownHeld(id) else { return }
    dismissTimers[id]?.resume()
  }

  private func isItemCountdownHeld(_ id: UUID) -> Bool {
    activityHoldItemIds.contains(id) || hoveredItemIds.contains(id) || isItemPausedByEditing(id)
  }

  /// Check if an item should remain paused because of an active editing session.
  /// True if the item itself is being edited, OR if it's newer (above) than any edited item.
  private func isItemPausedByEditing(_ id: UUID) -> Bool {
    guard !editingItemIds.isEmpty else { return false }
    if editingItemIds.contains(id) { return true }
    guard let itemIndex = items.firstIndex(where: { $0.id == id }) else { return false }
    for editId in editingItemIds {
      if let editIndex = items.firstIndex(where: { $0.id == editId }), itemIndex < editIndex {
        return true
      }
    }
    return false
  }

  /// Pause countdown for an item being edited + all items captured after it (newer/above)
  func pauseCountdownForEditingItem(_ id: UUID) {
    editingItemIds.insert(id)
    guard let editIndex = items.firstIndex(where: { $0.id == id }) else { return }
    DiagnosticLogger.shared.log(
      .debug,
      .action,
      "Quick access countdown paused for editing",
      context: ["itemId": id.uuidString, "affectedCount": "\(editIndex + 1)"]
    )

    // Pause the edited item + items at lower indices (captured after, newer)
    for i in 0 ... editIndex {
      dismissTimers[items[i].id]?.pause()
    }
  }

  /// Resume countdown for an item done editing + all items captured after it (newer/above)
  func resumeCountdownForEditingItem(_ id: UUID) {
    editingItemIds.remove(id)
    DiagnosticLogger.shared.log(
      .debug,
      .action,
      "Quick access countdown resumed after editing",
      context: ["itemId": id.uuidString]
    )

    if let editIndex = items.firstIndex(where: { $0.id == id }) {
      // Item still exists — restart it + items at lower indices (newer) with a fresh countdown
      for i in 0 ... editIndex {
        let itemId = items[i].id
        guard !isItemCountdownHeld(itemId) else { continue }
        dismissTimers[itemId]?.restart(duration: autoDismissDelay)
      }
    } else {
      // Edited item was already removed (swiped/dismissed during editing).
      // Resume all remaining items that aren't held by another editor.
      for item in items {
        guard !isItemCountdownHeld(item.id) else { continue }
        dismissTimers[item.id]?.resume()
      }
    }
  }

  /// Retry thumbnail generation in background and update item if successful
  private func scheduleThumbnailRetry(for id: UUID, url: URL) {
    guard let version = items.first(where: { $0.id == id && $0.url == url })?.thumbnailVersion else { return }
    func stillUsesPlaceholder(_ item: QuickAccessItem) -> Bool {
      item.id == id && item.url == url && item.thumbnailVersion == version
    }

    Task { @MainActor in
      // Wait 500ms then retry
      try? await Task.sleep(nanoseconds: 500_000_000)
      guard !Task.isCancelled else { return }
      guard items.contains(where: stillUsesPlaceholder) else { return }

      let fileAccess = fileAccessManager.beginAccessingURL(url)
      defer { fileAccess.stop() }

      let result = await ThumbnailGenerator.generate(from: url)
      guard let index = items.firstIndex(where: stillUsesPlaceholder) else { return }
      guard let newThumbnail = result.thumbnail else {
        logger.error("Thumbnail retry also failed for \(url.lastPathComponent)")
        DiagnosticLogger.shared.log(
          .error,
          .ui,
          "Quick access thumbnail retry failed",
          context: ["fileName": url.lastPathComponent]
        )
        return
      }

      items[index] = items[index].replacingThumbnail(newThumbnail, cardThumbnail: result.cardThumbnail)
      logger.info("Thumbnail retry succeeded for \(url.lastPathComponent)")
      DiagnosticLogger.shared.log(
        .debug,
        .ui,
        "Quick access thumbnail retry succeeded",
        context: ["fileName": url.lastPathComponent]
      )
    }
  }

  /// Set cloud URL and key for an item after successful upload
  func setCloudURL(id: UUID, url: URL, key: String) {
    guard let index = items.firstIndex(where: { $0.id == id }) else {
      DiagnosticLogger.shared.log(
        .warning,
        .cloud,
        "Quick access cloud URL update missed item",
        context: ["itemId": id.uuidString]
      )
      return
    }
    items[index].cloudURL = url
    items[index].cloudKey = key
    items[index].isCloudStale = false
    DiagnosticLogger.shared.log(
      .info,
      .cloud,
      "Quick access cloud URL attached",
      context: ["itemId": id.uuidString, "fileName": items[index].url.lastPathComponent]
    )
  }

  /// Mark an item's cloud state as stale (local differs from cloud)
  func markCloudStale(id: UUID) {
    guard let index = items.firstIndex(where: { $0.id == id }) else {
      DiagnosticLogger.shared.log(
        .warning,
        .cloud,
        "Quick access cloud stale mark missed item",
        context: ["itemId": id.uuidString]
      )
      return
    }
    guard items[index].cloudURL != nil else { return }
    items[index].isCloudStale = true
    DiagnosticLogger.shared.log(
      .debug,
      .cloud,
      "Quick access cloud state marked stale",
      context: ["itemId": id.uuidString, "fileName": items[index].url.lastPathComponent]
    )
  }
}

// MARK: - Контекстное меню карточки и pin

/// Выбор записи History для Restore Last Capture, когда в памяти ничего не осталось.
enum QuickAccessRestorePolicy {
  /// Неудалённые и закрытые записи в порядке восстановления.
  static func historyCandidates(
    in records: [CaptureHistoryRecord],
    excluding openURLs: Set<URL>
  ) -> [CaptureHistoryRecord] {
    records
      .filter { !$0.isDeleted && !openURLs.contains($0.fileURL.standardizedFileURL) }
      .sorted { $0.capturedAt > $1.capturedAt }
  }
}

extension QuickAccessManager {
  /// Temporarily Hide: стек уезжает, карточки остаются и вернутся со следующим захватом
  /// или восстановлением.
  func temporarilyHide() {
    guard !items.isEmpty else { return }
    hidePanel()
    // Внизу остаётся полоска со стрелкой, по клику стек возвращается
    QuickAccessHiddenStackStrip.shared.show(
      on: ScreenUtility.activeScreen(),
      isLeftSide: position.isLeftSide,
      scale: CGFloat(overlayScale)
    ) { [weak self] in
      self?.showTemporarilyHiddenItems()
    }
    DiagnosticLogger.shared.log(
      .info,
      .action,
      "Quick access temporarily hidden",
      context: ["itemCount": "\(items.count)"]
    )
  }

  /// Возвращает временно скрытый стек на экран.
  func showTemporarilyHiddenItems() {
    QuickAccessHiddenStackStrip.shared.hide()
    guard !items.isEmpty else { return }
    showPanelIfNeeded()
  }

  /// Show/hide overlays: стек уезжает вниз с полоской возврата, повторный вызов возвращает его
  @discardableResult
  func toggleTemporaryHide() -> Bool {
    guard !items.isEmpty else { return false }
    if QuickAccessHiddenStackStrip.shared.isVisible {
      showTemporarilyHiddenItems()
    } else {
      temporarilyHide()
    }
    return true
  }

  /// Restore Last Capture, когда список закрытых в памяти пуст: берёт последний файл History,
  /// а если его нет, показывает предупреждение, как эталон.
  func restoreLastFromHistoryOrWarn(excluding unavailableURLs: Set<URL> = []) async {
    let openURLs = Set(items.map { $0.url.standardizedFileURL })
    let candidates = QuickAccessRestorePolicy.historyCandidates(
      in: CaptureHistoryStore.shared.records,
      excluding: openURLs.union(unavailableURLs)
    )
    for record in candidates where record.fileExists {
      if await restoreHistoryItem(record) != nil { return }
    }
    if !items.isEmpty {
      showTemporarilyHiddenItems()
      return
    }
    let alert = NSAlert()
    alert.messageText = L10n.QuickAccessMenu.noRecentCapturesTitle
    alert.informativeText = L10n.QuickAccessMenu.noRecentCapturesMessage
    alert.alertStyle = .informational
    alert.addButton(withTitle: L10n.Common.ok)
    NSApp.activate(ignoringOtherApps: true)
    alert.runModal()
  }

  /// Rotate Left, Flip Horizontal и Resize перезаписывают исходный файл карточки.
  /// Аннотации сессии привязаны к старой геометрии, поэтому сессия сбрасывается.
  func transformImage(id: UUID, _ transform: QuickAccessImageFileTransform) {
    guard let item = items.first(where: { $0.id == id }), !item.isVideo else { return }
    let url = item.url
    let access = SandboxFileAccessManager.shared.beginAccessingURL(url)
    let directoryAccess = SandboxFileAccessManager.shared.beginAccessingURL(url.deletingLastPathComponent())
    defer {
      access.stop()
      directoryAccess.stop()
    }

    do {
      try transform.apply(toFileAt: url)
    } catch {
      DiagnosticLogger.shared.logError(
        .fileAccess,
        error,
        "Quick access image transform failed",
        context: ["fileName": url.lastPathComponent, "transform": "\(transform)"]
      )
      let alert = NSAlert()
      alert.messageText = L10n.QuickAccessMenu.imageUpdateFailed
      alert.informativeText = error.localizedDescription
      alert.alertStyle = .warning
      alert.runModal()
      return
    }

    AnnotateManager.shared.clearSessionData(for: id)
    AnnotationSessionStore.shared.deleteSession(for: url)
    markCloudStale(id: id)
    DiagnosticLogger.shared.log(
      .info,
      .action,
      "Quick access image transformed",
      context: ["fileName": url.lastPathComponent, "transform": "\(transform)"]
    )
    Task { @MainActor in
      await refreshItemThumbnail(id: id)
    }
  }

  /// Resize...: диалог Resize Image, затем перезапись исходника новым размером.
  func resizeImage(id: UUID) {
    guard let item = items.first(where: { $0.id == id }), !item.isVideo else { return }
    let access = SandboxFileAccessManager.shared.beginAccessingURL(item.url)
    let pixelSize = QuickAccessImageFileTransform.pixelSize(of: item.url)
    access.stop()
    guard let pixelSize else {
      NSSound.beep()
      return
    }

    pauseCountdownForActivity(id)
    defer { resumeCountdownForActivity(id) }
    let dialog = QuickAccessResizeDialog(originalPixelSize: pixelSize)
    guard let targetSize = dialog.runModal() else { return }
    transformImage(id: id, .resize(targetSize))
  }

  /// Upload to Cloud из меню pin: карточка может быть скрыта, поэтому без её прогресса.
  func uploadToCloudFromPin(item: QuickAccessItem) {
    guard OwnShotFeaturePolicy.allow(.cloud) else { return }
    let current = items.first(where: { $0.id == item.id }) ?? item
    if let cloudURL = current.cloudURL, !current.isCloudStale {
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      pasteboard.setString(cloudURL.absoluteString, forType: .string)
      return
    }
    let oldKey = current.cloudKey
    Task { @MainActor in
      do {
        let access = SandboxFileAccessManager.shared.beginAccessingURL(current.url)
        defer { access.stop() }
        let result = try await CloudManager.shared.upload(fileURL: current.url)
        if let oldKey {
          Task.detached(priority: .utility) {
            try? await CloudManager.shared.deleteByKey(key: oldKey)
          }
        }
        if self.items.contains(where: { $0.id == current.id }) {
          self.setCloudURL(id: current.id, url: result.publicURL, key: result.key)
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(result.publicURL.absoluteString, forType: .string)
        QuickAccessSound.copy.play()
      } catch {
        DiagnosticLogger.shared.logError(.cloud, error, "Pinned screenshot cloud upload failed")
      }
    }
  }

  /// Копирование из pin: карточка остаётся на месте, в отличие от Copy карточки.
  func copyPinnedImage(item: QuickAccessItem) {
    let current = items.first(where: { $0.id == item.id }) ?? item
    ClipboardHelper.copyImage(from: current.url)
    QuickAccessSound.copy.play()
  }

  func item(id: UUID) -> QuickAccessItem? {
    items.first(where: { $0.id == id })
  }
}

extension QuickAccessManager {
  /// Имя и тип для панели Save карточки: имя без расширения, тип – по расширению файла.
  /// Без известного типа имя остаётся с расширением, чтобы файл не потерял его.
  nonisolated static func savePanelSuggestion(for url: URL) -> (name: String, contentType: UTType?) {
    let pathExtension = url.pathExtension
    guard !pathExtension.isEmpty, let type = UTType(filenameExtension: pathExtension) else {
      return (url.lastPathComponent, nil)
    }
    return (url.deletingPathExtension().lastPathComponent, type)
  }
}


@MainActor
private final class QuickAccessSavePanelDestinationCapture: NSObject, NSOpenSavePanelDelegate {
  private let extensions: [String]
  private var selection = QuickAccessSaveDestinationSnapshot()

  init(extensions: [String]) {
    self.extensions = extensions
  }

  func panel(_ sender: Any, userEnteredFilename filename: String, confirmed: Bool) -> String? {
    if confirmed, let panel = sender as? NSSavePanel {
      // AppKit calls this before adding an extension and before its Replace prompt.
      selection = QuickAccessSaveDestinationSnapshot(
        directory: panel.directoryURL, enteredName: filename, extensions: extensions
      )
    }
    return filename
  }

  func destination(at url: URL) -> QuickAccessSaveDestination {
    selection.destination(at: url)
  }
}
