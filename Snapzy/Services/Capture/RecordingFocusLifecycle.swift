import Foundation

@MainActor
final class RecordingFocusLifecycle {
  private(set) var token: UUID?
  private let session: RecordingFocusSession
  private var operation: Task<Void, Never>?

  init(session: RecordingFocusSession) {
    self.session = session
  }

  func begin(
    enabled: Bool,
    preservingCurrentLease: Bool = false,
    isCurrent: @escaping () -> Bool = { true }
  ) async throws {
    let previous = operation
    let acquisition = Task { @MainActor in
      await previous?.value
      guard isCurrent() else { return }
      if let token = self.token {
        if preservingCurrentLease { return }
        try await self.session.end(token)
        self.token = nil
      }
      guard isCurrent() else { return }
      self.token = try await self.session.begin(enabled: enabled)
    }
    operation = Task { _ = try? await acquisition.value }
    try await acquisition.value
  }

  @discardableResult
  func end(expectedToken: UUID? = nil) -> Task<Void, Never> {
    if let expectedToken, token != expectedToken { return Task {} }
    let previous = operation
    let cleanup = Task { @MainActor in
      await previous?.value
      guard let token = self.token else { return }
      if let expectedToken, token != expectedToken { return }
      do {
        try await self.session.end(token)
        if self.token == token { self.token = nil }
      } catch {
        // Сохраняем токен для повторной очистки перед новой записью.
        DiagnosticLogger.shared.log(.warning, .recording, "Recording Focus cleanup failed")
      }
    }
    operation = cleanup
    return cleanup
  }

  func renew() async throws {
    guard let token else { return }
    let previous = operation
    let renewal = Task { @MainActor in
      await previous?.value
      guard self.token == token else { return }
      try await self.session.renew(token)
    }
    operation = Task { _ = try? await renewal.value }
    do {
      try await renewal.value
    } catch {
      // Ошибка старой операции может прийти уже после начала следующей записи.
      // Проверяем токен и сейчас, и внутри очереди очистки после её ожиданий.
      end(expectedToken: token)
      throw error
    }
  }
}
