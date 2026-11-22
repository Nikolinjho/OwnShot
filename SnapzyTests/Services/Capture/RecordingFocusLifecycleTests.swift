import XCTest
@testable import Snapzy

@MainActor
final class RecordingFocusLifecycleTests: XCTestCase {
  func testОшибкаСтарогоПродленияНеСнимаетФокусНовойЗаписи() async throws {
    let runner = SuspendedFocusRunner()
    let lifecycle = RecordingFocusLifecycle(session: RecordingFocusSession(runner: runner))
    try await lifecycle.begin(enabled: true)
    let oldToken = try XCTUnwrap(lifecycle.token)

    let oldRenewal = Task { try await lifecycle.renew() }
    await runner.waitUntilRenewalSuspends()
    let cleanup = lifecycle.end()
    let replacement = Task {
      await cleanup.value
      try await lifecycle.begin(enabled: true)
    }
    runner.failRenewal()
    _ = try? await oldRenewal.value
    try await replacement.value

    let replacementToken = try XCTUnwrap(lifecycle.token)
    // Моделируем также доставку запоздавшего обработчика после новой записи.
    await lifecycle.end(expectedToken: oldToken).value
    XCTAssertNotEqual(oldToken, replacementToken)
    XCTAssertEqual(lifecycle.token, replacementToken)
    XCTAssertEqual(runner.offCount, 1)
    XCTAssertEqual(runner.currentFocus, "Do Not Disturb")
  }
}

private enum SuspendedFocusError: Error {
  case renewalFailed
}

@MainActor
private final class SuspendedFocusRunner: RecordingFocusShortcutRunning {
  private(set) var currentFocus = ""
  private(set) var offCount = 0
  private var onCount = 0
  private var renewalContinuation: CheckedContinuation<String, Error>?
  private var suspensionWaiter: CheckedContinuation<Void, Never>?

  func run(shortcut: RecordingFocusShortcut, input: String?) async throws -> String {
    switch shortcut {
    case .status:
      return currentFocus
    case .on:
      onCount += 1
      if onCount == 2 {
        return try await withCheckedThrowingContinuation { continuation in
          renewalContinuation = continuation
          suspensionWaiter?.resume()
          suspensionWaiter = nil
        }
      }
      currentFocus = "Do Not Disturb"
      return "{\"identifier\":\"com.apple.donotdisturb.mode.default\",\"name\":\"Do Not Disturb\"}"
    case .off:
      offCount += 1
      currentFocus = ""
      return ""
    }
  }

  func waitUntilRenewalSuspends() async {
    if renewalContinuation != nil { return }
    await withCheckedContinuation { suspensionWaiter = $0 }
  }

  func failRenewal() {
    renewalContinuation?.resume(throwing: SuspendedFocusError.renewalFailed)
    renewalContinuation = nil
  }
}
