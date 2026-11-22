//
//  OwnShotQuitGuard.swift
//  Snapzy
//
//  Подтверждение выхода: эталон перехватывает applicationShouldTerminate.
//  Идущая запись останавливается и сохраняется, несохранённые окна (видеоредактор,
//  аннотации) спрашивают подтверждение.
//

import AppKit

@MainActor
enum OwnShotQuitGuard {
  enum Decision: Equatable {
    case terminateNow
    case confirmRecording
    case confirmUnsavedDocuments
  }

  /// Запись важнее несохранённых окон: её файл нужно финализировать до выхода.
  static func decision(isRecordingActive: Bool, hasEditedDocuments: Bool) -> Decision {
    if isRecordingActive { return .confirmRecording }
    if hasEditedDocuments { return .confirmUnsavedDocuments }
    return .terminateNow
  }

  /// Окна с isDocumentEdited (видеоредактор и любые окна, которые ставят этот флаг)
  /// и окна аннотаций с несохранёнными изменениями.
  static func hasEditedDocuments(in windows: [NSWindow]? = nil) -> Bool {
    (windows ?? NSApp.windows).contains { window in
      window.isVisible && (window.isDocumentEdited || hasUnsavedAnnotations(in: window))
    }
  }

  /// Окно аннотаций само isDocumentEdited не ставит (контроллер в зоне редактора),
  /// поэтому флаг hasUnsavedChanges читается из его состояния.
  static func hasUnsavedAnnotations(in window: NSWindow) -> Bool {
    guard let controller = window.windowController as? AnnotateWindowController else { return false }
    return annotateState(of: controller)?.hasUnsavedChanges ?? false
  }

  /// Состояние лежит в приватном свойстве state контроллера; Mirror читает его без правки редактора.
  static func annotateState(of controller: AnnotateWindowController) -> AnnotateState? {
    Mirror(reflecting: controller).children.first { $0.label == "state" }?.value as? AnnotateState
  }

  static func reply(for sender: NSApplication) -> NSApplication.TerminateReply {
    let recorder = ScreenRecordingManager.shared
    let isRecordingActive = recorder.state == .recording || recorder.state == .paused
    switch decision(isRecordingActive: isRecordingActive, hasEditedDocuments: hasEditedDocuments()) {
    case .terminateNow:
      return .terminateNow
    case .confirmUnsavedDocuments:
      return confirm(
        title: L10n.QuitGuard.unsavedTitle,
        message: L10n.QuitGuard.unsavedMessage,
        confirmTitle: L10n.QuitGuard.quit
      ) ? .terminateNow : .terminateCancel
    case .confirmRecording:
      guard confirm(
        title: L10n.QuitGuard.recordingTitle,
        message: L10n.QuitGuard.recordingMessage,
        confirmTitle: L10n.QuitGuard.stopAndQuit
      ) else { return .terminateCancel }
      stopRecordingThenTerminate(sender)
      return .terminateLater
    }
  }

  private static func confirm(title: String, message: String, confirmTitle: String) -> Bool {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: confirmTitle)
    alert.addButton(withTitle: L10n.Common.cancel)
    NSApp.activate(ignoringOtherApps: true)
    return alert.runModal() == .alertFirstButtonReturn
  }

  /// Ждёт финализации файла записи, не дольше 15 секунд.
  private static func stopRecordingThenTerminate(_ sender: NSApplication) {
    RecordingCoordinator.shared.stopFromStatusItem()
    Task { @MainActor in
      let deadline = Date().addingTimeInterval(15)
      while ScreenRecordingManager.shared.state != .idle, Date() < deadline {
        try? await Task.sleep(nanoseconds: 100_000_000)
      }
      DiagnosticLogger.shared.log(.info, .lifecycle, "Recording finalized before quit", context: [
        "state": "\(ScreenRecordingManager.shared.state)",
      ])
      sender.reply(toApplicationShouldTerminate: true)
    }
  }
}
