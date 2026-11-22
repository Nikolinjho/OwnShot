//
//  HistoryWindowController.swift
//  Snapzy
//
//  Manages the capture history browser window lifecycle
//

import AppKit
import Carbon.HIToolbox

extension Notification.Name {
  static let historyCopySelection = Notification.Name("historyCopySelection")
  static let historyActivateSelection = Notification.Name("historyActivateSelection")
  static let historyDeleteSelection = Notification.Name("historyDeleteSelection")
  static let historySelectAll = Notification.Name("historySelectAll")
  static let historyMoveFocus = Notification.Name("historyMoveFocus")
  static let historyQuickLookSelection = Notification.Name("historyQuickLookSelection")
}

/// Подтверждение удаления одной записи History с флажком Don't ask for confirmation.
enum HistoryDeleteConfirmationPolicy {
  static let suppressKey = "ownshot.history.deleteWithoutConfirmation"

  static func shouldAsk(defaults: UserDefaults = .standard) -> Bool {
    !defaults.bool(forKey: suppressKey)
  }

  static func setSuppressed(_ suppressed: Bool, defaults: UserDefaults = .standard) {
    defaults.set(suppressed, forKey: suppressKey)
  }

  /// Заголовок диалога: имя файла без расширения, как в эталоне.
  static func title(for record: CaptureHistoryRecord) -> String {
    L10n.HistoryMenu.deleteFromHistoryTitle((record.fileName as NSString).deletingPathExtension)
  }
}

/// Delete в History убирает запись, сохранённые файлы остаются на диске, как в эталоне
/// (spec-042 delete-file-settled: импортированный PNG сохранил SHA-256).
/// В Корзину уходят только внутренние временные копии OwnShot, иначе они копились бы без записи.
nonisolated enum HistoryDeleteFilePolicy {
  static func shouldRecycleFile(at url: URL, tempDirectory: URL) -> Bool {
    let tempPath = tempDirectory.standardizedFileURL.resolvingSymlinksInPath().path
    let standardized = url.standardizedFileURL
    // Avoid filesystem resolution for saved files far outside the capture directory.
    guard standardized.deletingLastPathComponent().pathComponents.contains(tempDirectory.lastPathComponent) else {
      return false
    }
    let filePath = SandboxFileAccessManager.directoryEntryPath(for: standardized)
    return filePath.hasPrefix(tempPath + "/")
  }
}

final class HistoryWindow: NSWindow {
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard event.type == .keyDown else {
      return super.performKeyEquivalent(with: event)
    }

    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

    if event.keyCode == 8 && flags == .command {
      if isTextInputActive {
        return super.performKeyEquivalent(with: event)
      }

      NotificationCenter.default.post(name: .historyCopySelection, object: self)
      return true
    }

    if event.keyCode == 0 && flags == .command {
      if isTextInputActive {
        return super.performKeyEquivalent(with: event)
      }

      NotificationCenter.default.post(name: .historySelectAll, object: self)
      return true
    }

    if HistoryFloatingManager.shared.isToggleModeShortcutEnabled,
       let toggleShortcut = HistoryFloatingManager.shared.toggleModeShortcut,
       let eventShortcut = ShortcutConfig(from: event) {
      if eventShortcut.keyCode == toggleShortcut.keyCode && eventShortcut.modifiers == toggleShortcut.modifiers {
        if isTextInputActive {
          return super.performKeyEquivalent(with: event)
        }
        HistoryFloatingManager.shared.togglePresentationMode()
        return true
      }
    }

    return super.performKeyEquivalent(with: event)
  }

  override func keyDown(with event: NSEvent) {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

    if !isTextInputActive, flags.isEmpty, (event.keyCode == 51 || event.keyCode == 117) {
      NotificationCenter.default.post(name: .historyDeleteSelection, object: self)
      return
    }

    super.keyDown(with: event)
  }

  private var isTextInputActive: Bool {
    guard let responder = firstResponder else { return false }
    return responder is NSTextView || responder is NSTextField
  }
}

/// Manages the capture history browser window
@MainActor
final class HistoryWindowController {
  static let shared = HistoryWindowController()

  private var isDeletingRecords = false
  private var deletionCompletions: [@MainActor () -> Void] = []

  private init() {}

  func showWindow() {
    DiagnosticLogger.shared.log(.info, .history, "History window requested")
    HistoryFloatingManager.shared.showExpanded()
    NSApp.activate(ignoringOtherApps: true)
  }

  func hideWindow() {
    DiagnosticLogger.shared.log(.debug, .history, "History window hide requested")
    HistoryFloatingManager.shared.hide()
  }

  func copyToClipboard(_ records: [CaptureHistoryRecord]) {
    let existingRecords = records.filter(\.fileExists)
    guard !existingRecords.isEmpty else {
      DiagnosticLogger.shared.log(
        .warning,
        .clipboard,
        "History clipboard copy skipped; no existing files",
        context: ["requestedCount": "\(records.count)"]
      )
      return
    }

    if existingRecords.count == 1, let record = existingRecords.first {
      switch record.captureType {
      case .screenshot, .gif:
        ClipboardHelper.copyImage(from: record.fileURL)
      case .video:
        ClipboardHelper.copyMediaFile(from: record.fileURL)
      }
    } else {
      ClipboardHelper.copyFileURLs(existingRecords.map(\.fileURL))
    }

    AppToastManager.shared.show(
      message: L10n.Common.copiedToClipboard,
      style: .success,
      duration: 1.6,
      variant: .compact
    )
    DiagnosticLogger.shared.log(
      .info,
      .clipboard,
      "History copied selection to clipboard",
      context: [
        "requestedCount": "\(records.count)",
        "copiedCount": "\(existingRecords.count)",
        "multiItem": existingRecords.count > 1 ? "true" : "false",
      ]
    )
  }

  func openItem(_ record: CaptureHistoryRecord) {
    guard record.fileExists else {
      DiagnosticLogger.shared.log(
        .warning,
        .history,
        "History open skipped; file missing",
        context: ["fileName": record.fileName, "type": record.captureType.rawValue]
      )
      return
    }

    HistoryFloatingManager.shared.hide()

    Task { @MainActor in
      guard let item = await QuickAccessManager.shared.restoreHistoryItem(record) else {
        return
      }

      switch record.captureType {
      case .screenshot:
        DiagnosticLogger.shared.log(
          .info,
          .history,
          "History opening screenshot through quick access",
          context: ["fileName": record.fileName, "itemId": item.id.uuidString]
        )
        AnnotateManager.shared.openAnnotation(for: item)
      case .video, .gif:
        DiagnosticLogger.shared.log(
          .info,
          .history,
          "History opening media through quick access",
          context: [
            "fileName": record.fileName,
            "type": record.captureType.rawValue,
            "itemId": item.id.uuidString,
          ]
        )
        VideoEditorManager.shared.openEditor(for: item)
      }
    }
  }

  /// Restore эталона: запись возвращается в Quick Access без редактора.
  /// Кнопка и пункт меню оставляют History открытой, Return её скрывает.
  func restoreItem(_ record: CaptureHistoryRecord, hidesHistory: Bool) {
    guard record.fileExists else { return }
    if hidesHistory {
      HistoryFloatingManager.shared.hide()
    }
    Task { @MainActor in
      _ = await QuickAccessManager.shared.restoreHistoryItem(record)
    }
  }

  /// Pin to the Screen из History: отдельный pin, History скрывается, Quick Access не трогается.
  func pinItem(_ record: CaptureHistoryRecord) {
    guard record.captureType == .screenshot, record.fileExists else { return }
    HistoryFloatingManager.shared.hide()
    Task { @MainActor in
      _ = await QuickAccessManager.shared.pinScreenshot(url: record.fileURL)
    }
  }

  /// Quick Look выбранной записи. Повтор для той же записи закрывает превью.
  func toggleQuickLook(_ record: CaptureHistoryRecord) {
    guard record.fileExists else { return }
    QuickAccessQuickLookController.shared.toggle(record.fileURL)
  }

  /// Delete одной записи с подтверждением эталона, несколько записей – общим подтверждением.
  func deleteRecordsConfirmingIfNeeded(_ records: [CaptureHistoryRecord]) {
    guard records.count == 1, let record = records.first else {
      deleteRecords(records, asksConfirmation: true)
      return
    }
    scheduleDeletion(records) { _ in
      !HistoryDeleteConfirmationPolicy.shouldAsk() || HistoryFloatingManager.shared.performModalInteraction {
        confirmSingleDelete(record)
      }
    }
  }

  private func confirmSingleDelete(_ record: CaptureHistoryRecord) -> Bool {
    let alert = NSAlert()
    alert.messageText = HistoryDeleteConfirmationPolicy.title(for: record)
    alert.informativeText = L10n.HistoryMenu.deleteCannotUndo
    alert.alertStyle = .warning
    alert.showsSuppressionButton = true
    alert.suppressionButton?.title = L10n.HistoryMenu.deleteDontAsk
    alert.addButton(withTitle: L10n.Common.deleteAction)
    alert.addButton(withTitle: L10n.Common.cancel)
    let confirmed = alert.runModal() == .alertFirstButtonReturn
    if confirmed, alert.suppressionButton?.state == .on {
      HistoryDeleteConfirmationPolicy.setSuppressed(true)
    }
    return confirmed
  }

  func deleteRecords(_ records: [CaptureHistoryRecord], asksConfirmation: Bool) {
    scheduleDeletion(records) { records in
      !asksConfirmation || HistoryFloatingManager.shared.performModalInteraction {
        confirmDelete(records: records)
      }
    }
  }

  private func scheduleDeletion(
    _ records: [CaptureHistoryRecord],
    completion: (@MainActor () -> Void)? = nil,
    confirm: ([CaptureHistoryRecord]) -> Bool
  ) {
    if isDeletingRecords {
      if let completion { deletionCompletions.append(completion) }
      return
    }
    let recordsToDelete = uniqueRecords(records)
    guard !recordsToDelete.isEmpty else {
      completion?()
      return
    }

    // AppKit runs a nested event loop while confirmation is open.
    isDeletingRecords = true
    guard confirm(recordsToDelete) else {
      finishDeletion()
      return
    }
    if let completion { deletionCompletions.append(completion) }

    Task { @MainActor in
      let outcome = await removeHistoryRecords(recordsToDelete)
      presentDeletionOutcome(outcome)
      finishDeletion()
    }
  }

  private func finishDeletion() {
    let completions = deletionCompletions
    deletionCompletions.removeAll()
    isDeletingRecords = false
    completions.forEach { $0() }
  }

  private func presentDeletionOutcome(_ outcome: DeletionOutcome) {
    if let errorMessage = outcome.errorMessage {
      let messages = outcome.removed > 0
        ? [L10n.PreferencesHistory.deletedCaptures(outcome.removed), errorMessage]
        : [errorMessage]
      DiagnosticLogger.shared.log(.warning, .fileAccess, "History recycle reported failures")
      AppToastManager.shared.show(message: messages.joined(separator: "\n"), style: .warning)
      return
    }
    let removedCount = outcome.removed
    guard removedCount > 0 else { return }

    AppToastManager.shared.show(
      message: L10n.PreferencesHistory.deletedCaptures(removedCount),
      style: .success,
      duration: 1.7,
      variant: .compact
    )

    DiagnosticLogger.shared.log(
      .info,
      .history,
      "History records deleted",
      context: [
        "recordCount": "\(removedCount)",
      ]
    )
  }

  nonisolated struct RecycleOutcome: Sendable {
    let moved: Set<URL>
    let errorMessage: String?

    @MainActor static func recycle(_ urls: [URL]) async -> Self {
      await withCheckedContinuation { continuation in
        NSWorkspace.shared.recycle(urls) { @Sendable destinations, error in
          continuation.resume(returning: RecycleOutcome(
            moved: Set(destinations.keys),
            errorMessage: error?.localizedDescription
          ))
        }
      }
    }
  }

  struct DeletionOutcome {
    var removed = 0
    var errorMessage: String?
  }

  /// Shared deletion path for History rows, selection, and Clear History.
  func removeHistoryRecords(
    _ records: [CaptureHistoryRecord],
    store: CaptureHistoryStore = .shared,
    sessionStore: AnnotationSessionStore = .shared,
    tempDirectory: URL = TempCaptureManager.shared.tempCaptureDirectory,
    deleteThumbnail: (UUID) -> Void = { HistoryThumbnailGenerator.shared.deleteThumbnail(for: $0) },
    recycle: @MainActor ([URL]) async -> RecycleOutcome = RecycleOutcome.recycle
  ) async -> DeletionOutcome {
    guard let liveRecords = store.fetchRecords() else { return DeletionOutcome() }
    let requestedPaths = Dictionary(uniqueKeysWithValues: uniqueRecords(records).map { ($0.id, $0.filePath) })
    let selected = liveRecords.filter { requestedPaths[$0.id] == $0.filePath }
    let selectedIDs = Set(selected.map(\.id))
    let internalRecords = selected.filter {
      HistoryDeleteFilePolicy.shouldRecycleFile(at: $0.fileURL, tempDirectory: tempDirectory)
    }
    let internalIDs = Set(internalRecords.map(\.id))
    var eligibleIDs = selectedIDs.subtracting(internalIDs)
    var pendingByURL: [URL: [UUID]] = [:]
    var absentByURL: [URL: [UUID]] = [:]
    var scopedAccesses: [SandboxFileAccessManager.ScopedAccess] = []
    defer { scopedAccesses.forEach { $0.stop() } }

    let groups = Dictionary(grouping: internalRecords) {
      SandboxFileAccessManager.directoryEntryPath(for: $0.fileURL)
    }
    let retainedPaths = matchingDirectoryEntries(
      in: liveRecords.filter { !selectedIDs.contains($0.id) },
      candidates: internalRecords
    )

    for (path, group) in groups {
      guard let url = group.first?.fileURL else { continue }
      if retainedPaths.contains(path) {
        eligibleIDs.formUnion(group.map(\.id))
        continue
      }
      guard !AnnotateManager.shared.isEditingFile(at: url),
            !VideoEditorManager.shared.isEditingFile(at: url) else { continue }

      scopedAccesses.append(SandboxFileAccessManager.shared.beginAccessingURL(url))
      scopedAccesses.append(SandboxFileAccessManager.shared.beginAccessingURL(url.deletingLastPathComponent()))
      do {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        // A History entry is a file. Never recycle a directory that replaced it.
        if attributes[.type] as? FileAttributeType != .typeDirectory {
          pendingByURL[url] = group.map(\.id)
        }
      } catch let error as CocoaError where [.fileNoSuchFile, .fileReadNoSuchFile].contains(error.code) {
        absentByURL[url] = group.map(\.id)
      } catch {
        DiagnosticLogger.shared.logError(
          .fileAccess, error, "History source inspection failed", context: ["fileName": url.lastPathComponent]
        )
      }
    }

    let outcome = pendingByURL.isEmpty
      ? RecycleOutcome(moved: [], errorMessage: nil)
      : await recycle(Array(pendingByURL.keys))
    for url in outcome.moved {
      absentByURL[url] = pendingByURL[url]
    }

    // Another save can create a source while the recycle callback is pending.
    for (url, ids) in absentByURL {
      do {
        _ = try FileManager.default.attributesOfItem(atPath: url.path)
      } catch let error as CocoaError where [.fileNoSuchFile, .fileReadNoSuchFile].contains(error.code) {
        eligibleIDs.formUnion(ids)
      } catch {
        DiagnosticLogger.shared.logError(
          .fileAccess, error, "History source absence check failed", context: ["fileName": url.lastPathComponent]
        )
      }
    }

    // Other windows can move a capture or update the record while AppKit recycles.
    guard let current = store.fetchRecords() else {
      return DeletionOutcome(errorMessage: outcome.errorMessage)
    }
    let eligible = current.filter { eligibleIDs.contains($0.id) && requestedPaths[$0.id] == $0.filePath }
    guard !eligible.isEmpty else { return DeletionOutcome(errorMessage: outcome.errorMessage) }

    store.remove(ids: eligible.map(\.id))
    guard let remaining = store.fetchRecords() else {
      return DeletionOutcome(errorMessage: outcome.errorMessage)
    }
    let remainingIDs = Set(remaining.map(\.id))
    let removed = eligible.filter { !remainingIDs.contains($0.id) }
    let retainedSessionPaths = Set(remaining.filter { $0.captureType == .screenshot }.map {
      AnnotationSessionStore.normalizedPath(for: $0.fileURL)
    })
    for record in removed {
      deleteThumbnail(record.id)
      if record.captureType == .screenshot,
         !retainedSessionPaths.contains(AnnotationSessionStore.normalizedPath(for: record.fileURL)) {
        sessionStore.deleteSession(for: record.fileURL)
      }
    }
    return DeletionOutcome(removed: removed.count, errorMessage: outcome.errorMessage)
  }

  private func matchingDirectoryEntries(
    in records: [CaptureHistoryRecord],
    candidates: [CaptureHistoryRecord]
  ) -> Set<String> {
    // Parent directory aliases can match, while the final path component stays distinct.
    let names = Set(candidates.map { $0.fileURL.lastPathComponent })
    return Set(records.lazy.filter { names.contains($0.fileURL.lastPathComponent) }.map {
      SandboxFileAccessManager.directoryEntryPath(for: $0.fileURL)
    })
  }

  private func uniqueRecords(_ records: [CaptureHistoryRecord]) -> [CaptureHistoryRecord] {
    var seenIds = Set<UUID>()
    return records.filter { record in
      seenIds.insert(record.id).inserted
    }
  }

  /// Removes History entries and moves owned temporary captures to Trash after confirmation.
  func clearAllHistory(
    fromPreferences: Bool = false,
    completion: (@MainActor () -> Void)? = nil
  ) {
    scheduleDeletion(CaptureHistoryStore.shared.records, completion: completion) { _ in
      if fromPreferences { return confirmClearHistory(fromPreferences: true) }
      return HistoryFloatingManager.shared.performModalInteraction {
        confirmClearHistory(fromPreferences: false)
      }
    }
  }

  private func confirmClearHistory(fromPreferences: Bool) -> Bool {
    let alert = NSAlert()
    alert.messageText = fromPreferences
      ? L10n.PreferencesHistory.clearHistoryAlertTitle
      : L10n.PreferencesHistory.clearHistoryDeleteAllTitle
    alert.informativeText = L10n.PreferencesHistory.historySavedFilesKept
    alert.alertStyle = .warning
    alert.addButton(withTitle: L10n.PreferencesHistory.clearHistoryConfirm)
    alert.addButton(withTitle: L10n.Common.cancel)
    return alert.runModal() == .alertFirstButtonReturn
  }

  private func confirmDelete(records: [CaptureHistoryRecord]) -> Bool {
    let alert = NSAlert()
    alert.messageText = L10n.PreferencesHistory.deleteSelectedAlertTitle
    alert.informativeText = L10n.PreferencesHistory.removeSelectedAlertMessage(records.count)
    alert.alertStyle = .warning
    alert.addButton(withTitle: L10n.Common.deleteAction)
    alert.addButton(withTitle: L10n.Common.cancel)

    return alert.runModal() == .alertFirstButtonReturn
  }
}
