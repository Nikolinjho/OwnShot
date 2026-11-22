import Foundation

enum RecordingFocusShortcut: String {
  case status = "OwnShot Focus Status"
  case on = "OwnShot Focus On"
  case off = "OwnShot Focus Off"
}

@MainActor
protocol RecordingFocusShortcutRunning {
  func run(shortcut: RecordingFocusShortcut, input: String?) async throws -> String
}

enum RecordingFocusSessionError: Error {
  case unconfirmedTarget
}

@MainActor
final class RecordingFocusSession {
  // Публичные команды не различают непрерывный DND и его ручное выключение
  // с повторным включением между проверками. Существующий Focus не меняем,
  // а право на очистку ограничиваем проверками и коротким сроком аренды.
  // Текстовый статус также не различает два режима с одинаковым именем.
  private struct Ownership {
    let sessionID: UUID
    let fingerprint: String
    var expiration: Date
  }

  private struct TargetReceipt: Decodable {
    let identifier: String
    let name: String
  }

  private let runner: RecordingFocusShortcutRunning
  private let leaseDuration: TimeInterval
  private let now: () -> Date
  private var ownership: Ownership?
  private var operationInProgress = false
  private var waitingOperations: [CheckedContinuation<Void, Never>] = []

  init(
    runner: RecordingFocusShortcutRunning,
    leaseDuration: TimeInterval = 180,
    now: @escaping () -> Date = Date.init
  ) {
    self.runner = runner
    self.leaseDuration = leaseDuration
    self.now = now
  }

  func begin(enabled: Bool) async throws -> UUID? {
    guard enabled else { return nil }
    await lock()
    defer { unlock() }
    try Task.checkCancellation()
    discardExpiredOwnership()
    if let ownership { return ownership.sessionID }

    guard try await currentFingerprint().isEmpty else { return nil }
    let expiration = now().addingTimeInterval(leaseDuration)
    // При неоднозначном результате команды не выключаем чужой фокус.
    // Нативный срок действия команды снимает режим даже после аварии приложения.
    let result = try await runner.run(shortcut: .on, input: ISO8601DateFormatter().string(from: expiration))
    guard let receipt = try? JSONDecoder().decode(TargetReceipt.self, from: Data(result.utf8)),
          receipt.identifier == "com.apple.donotdisturb.mode.default",
          !receipt.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw RecordingFocusSessionError.unconfirmedTarget
    }
    let fingerprint = try await currentFingerprint()
    // Имя в квитанции задаётся выбранной целью DND, а не результатом
    // Get Current Focus: сменившийся во время команды Work нельзя присвоить себе.
    // При другой локализации имя цели должно совпадать с нативным именем DND.
    // Несовпадение не даёт права на очистку, режим завершится по своему сроку.
    guard fingerprint == receipt.name, now() < expiration else { return nil }
    let sessionID = UUID()
    ownership = Ownership(sessionID: sessionID, fingerprint: fingerprint, expiration: expiration)
    return sessionID
  }

  func end(_ sessionID: UUID) async throws {
    await lock()
    defer { unlock() }
    discardExpiredOwnership()
    guard let owned = ownership, owned.sessionID == sessionID else { return }
    guard try await currentFingerprint() == owned.fingerprint else {
      ownership = nil
      return
    }
    guard now() < owned.expiration else {
      ownership = nil
      return
    }
    _ = try await runner.run(shortcut: .off, input: owned.fingerprint)
    ownership = nil
  }

  func renew(_ sessionID: UUID) async throws {
    await lock()
    defer { unlock() }
    try Task.checkCancellation()
    discardExpiredOwnership()
    guard let owned = ownership, owned.sessionID == sessionID else { return }
    guard try await currentFingerprint() == owned.fingerprint else {
      ownership = nil
      return
    }
    guard now() < owned.expiration else {
      ownership = nil
      return
    }
    let expiration = now().addingTimeInterval(leaseDuration)
    // Сохраняем старый срок при ошибке: команда могла изменить систему,
    // но без подтверждения не продлеваем своё право на последующую очистку.
    _ = try await runner.run(shortcut: .on, input: ISO8601DateFormatter().string(from: expiration))
    ownership?.expiration = expiration
  }

  private func currentFingerprint() async throws -> String {
    try await runner.run(shortcut: .status, input: nil).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func discardExpiredOwnership() {
    if let ownership, now() >= ownership.expiration { self.ownership = nil }
  }

  // Изоляция MainActor не запрещает повторный вход во время await.
  // Очередь удерживает полный цикл проверки и изменения фокуса одной операцией.
  private func lock() async {
    if operationInProgress {
      await withCheckedContinuation { waitingOperations.append($0) }
    } else {
      operationInProgress = true
    }
  }

  private func unlock() {
    if waitingOperations.isEmpty {
      operationInProgress = false
    } else {
      waitingOperations.removeFirst().resume()
    }
  }
}
