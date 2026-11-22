import XCTest
@testable import Snapzy

@MainActor
final class RecordingFocusSessionTests: XCTestCase {
  func testЧужойФокусПослеКомандыВключенияНеСтановитсяСвоим() async throws {
    let runner = FocusShortcutStub([.success(""), .success(""), .success("Work")])
    let session = RecordingFocusSession(runner: runner)

    let token = try await session.begin(enabled: true)
    try await session.end(UUID())

    XCTAssertNil(token)
    XCTAssertEqual(runner.calls.map(\.shortcut), [.status, .on, .status])
  }

  func testКомандаНеМожетОбъявитьРабочийФокусЦельюНеБеспокоить() async throws {
    let runner = FocusShortcutStub([
      .success(""), .success("{\"identifier\":\"com.apple.focus.work\",\"name\":\"Work\"}"), .success("Work")
    ])
    let session = RecordingFocusSession(runner: runner)

    do {
      _ = try await session.begin(enabled: true)
      XCTFail("Целью должен быть системный режим Не беспокоить")
    } catch {}

    XCTAssertFalse(runner.calls.contains { $0.shortcut == .off })
  }

  func testНеизвестныйОтветКомандыНеДаётПраваНаОчисткуФокуса() async throws {
    let runner = FocusShortcutStub([.success(""), .success("unrecognized"), .success("Do Not Disturb")])
    let session = RecordingFocusSession(runner: runner)

    do {
      _ = try await session.begin(enabled: true)
      XCTFail("Неизвестный ответ должен отклоняться")
    } catch {}

    XCTAssertFalse(runner.calls.contains { $0.shortcut == .off })
  }
  func testВыключеннаяНастройкаНеЗапускаетКоманды() async throws {
    let runner = FocusShortcutStub([])
    let session = RecordingFocusSession(runner: runner)

    let token = try await session.begin(enabled: false)

    XCTAssertNil(token)
    XCTAssertTrue(runner.calls.isEmpty)
  }

  func testУжеАктивныйФокусСохраняетсяБезИзменений() async throws {
    let runner = FocusShortcutStub([.success("Work")])
    let session = RecordingFocusSession(runner: runner)

    let token = try await session.begin(enabled: true)

    XCTAssertNil(token)
    XCTAssertEqual(runner.calls.map(\.shortcut), [.status])
  }

  func testВключениеПередаётКонечныйСрокИПроверяетФактическийФокус() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let runner = FocusShortcutStub([.success(""), .success(""), .success("Do Not Disturb")])
    let session = RecordingFocusSession(runner: runner, leaseDuration: 3600, now: { now })

    let token = try await session.begin(enabled: true)

    XCTAssertNotNil(token)
    XCTAssertEqual(runner.calls.map(\.shortcut), [.status, .on, .status])
    let expiration = runner.calls.first { $0.shortcut == .on }?.input
    XCTAssertEqual(expiration.flatMap { ISO8601DateFormatter().date(from: $0) }, now.addingTimeInterval(3600))
  }

  func testПовторноеЗавершениеНеВыключаетФокусДважды() async throws {
    let runner = FocusShortcutStub([
      .success(""), .success(""), .success("Do Not Disturb"),
      .success("Do Not Disturb"), .success("")
    ])
    let session = RecordingFocusSession(runner: runner)
    let token = try await acquire(session)

    try await session.end(token)
    try await session.end(token)

    XCTAssertEqual(runner.calls.map(\.shortcut), [.status, .on, .status, .status, .off])
  }

  func testФокусВыбранныйПользователемВоВремяЗаписиНеВыключается() async throws {
    let runner = FocusShortcutStub([
      .success(""), .success(""), .success("Do Not Disturb"), .success("Work")
    ])
    let session = RecordingFocusSession(runner: runner)
    let token = try await acquire(session)

    try await session.end(token)
    try await session.end(token)

    XCTAssertEqual(runner.calls.map(\.shortcut), [.status, .on, .status, .status])
  }

  func testОшибкаВключенияНеПорождаетСлепоеВыключение() async throws {
    let runner = FocusShortcutStub([.success(""), .failure(FocusStubError.failed)])
    let session = RecordingFocusSession(runner: runner)

    do {
      _ = try await session.begin(enabled: true)
      XCTFail("Ошибка команды должна передаваться вызывающему коду")
    } catch {}

    XCTAssertEqual(runner.calls.map(\.shortcut), [.status, .on])
  }

  func testНеопределённыйРезультатПроверкиПослеВключенияНеДаётПраваНаВыключение() async throws {
    let runner = FocusShortcutStub([
      .success(""), .success(""), .failure(FocusStubError.failed), .success("Work")
    ])
    let session = RecordingFocusSession(runner: runner)

    do {
      _ = try await session.begin(enabled: true)
      XCTFail("Ошибка проверки должна передаваться вызывающему коду")
    } catch {}
    let nextToken = try await session.begin(enabled: true)

    XCTAssertNil(nextToken)
    XCTAssertFalse(runner.calls.contains { $0.shortcut == .off })
  }

  func testПослеОшибкиВыключенияМожноПовторитьОчистку() async throws {
    let runner = FocusShortcutStub([
      .success(""), .success(""), .success("Do Not Disturb"),
      .success("Do Not Disturb"), .failure(FocusStubError.failed),
      .success("Do Not Disturb"), .success("")
    ])
    let session = RecordingFocusSession(runner: runner)
    let token = try await acquire(session)

    do {
      try await session.end(token)
      XCTFail("Ошибка выключения должна сохранять возможность повторной очистки")
    } catch {}
    try await session.end(token)

    XCTAssertEqual(runner.calls.filter { $0.shortcut == .off }.count, 2)
  }

  func testСтарыйТокенНеЗавершаетНовуюСессию() async throws {
    let runner = FocusShortcutStub([
      .success(""), .success(""), .success("Do Not Disturb"),
      .success("Do Not Disturb"), .success(""),
      .success(""), .success(""), .success("Do Not Disturb")
    ])
    let session = RecordingFocusSession(runner: runner)
    let oldToken = try await acquire(session)
    try await session.end(oldToken)
    let newToken = try await acquire(session)
    let callsBefore = runner.calls.count

    try await session.end(oldToken)

    XCTAssertNotEqual(oldToken, newToken)
    XCTAssertEqual(runner.calls.count, callsBefore)
  }

  func testПродлениеОбновляетСрокТолькоДляСвоегоАктивногоФокуса() async throws {
    var clock = Date(timeIntervalSince1970: 1_800_000_000)
    let runner = FocusShortcutStub([
      .success(""), .success(""), .success("Do Not Disturb"),
      .success("Do Not Disturb"), .success("")
    ])
    let session = RecordingFocusSession(runner: runner, now: { clock })
    let token = try await acquire(session)
    clock = clock.addingTimeInterval(60)

    try await session.renew(token)

    XCTAssertEqual(runner.calls.map(\.shortcut), [.status, .on, .status, .status, .on])
    let expiration = runner.calls.last?.input
    XCTAssertEqual(expiration.flatMap { ISO8601DateFormatter().date(from: $0) }, clock.addingTimeInterval(180))
  }

  func testСменаФокусаПрекращаетПродлениеИОчистку() async throws {
    let runner = FocusShortcutStub([
      .success(""), .success(""), .success("Do Not Disturb"), .success("Work")
    ])
    let session = RecordingFocusSession(runner: runner)
    let token = try await acquire(session)

    try await session.renew(token)
    try await session.renew(token)
    try await session.end(token)

    XCTAssertEqual(runner.calls.map(\.shortcut), [.status, .on, .status, .status])
  }

  func testВыключениеФокусаПользователемПрекращаетПродление() async throws {
    let runner = FocusShortcutStub([
      .success(""), .success(""), .success("Do Not Disturb"), .success("")
    ])
    let session = RecordingFocusSession(runner: runner)
    let token = try await acquire(session)

    try await session.renew(token)
    try await session.end(token)

    XCTAssertEqual(runner.calls.map(\.shortcut), [.status, .on, .status, .status])
  }

  func testПостороннийТокенНеПродлеваетСессию() async throws {
    let runner = FocusShortcutStub([])
    let session = RecordingFocusSession(runner: runner)

    try await session.renew(UUID())

    XCTAssertTrue(runner.calls.isEmpty)
  }

  func testИстёкшаяАрендаНеМеняетПозжеВключённыйПользователемФокус() async throws {
    var clock = Date(timeIntervalSince1970: 1_800_000_000)
    let runner = FocusShortcutStub([
      .success(""), .success(""), .success("Do Not Disturb")
    ])
    let session = RecordingFocusSession(runner: runner, now: { clock })
    let token = try await acquire(session)
    clock = clock.addingTimeInterval(180)

    try await session.renew(token)
    try await session.end(token)

    XCTAssertEqual(runner.calls.map(\.shortcut), [.status, .on, .status])
  }
  private func acquire(_ session: RecordingFocusSession) async throws -> UUID {
    let token = try await session.begin(enabled: true)
    return try XCTUnwrap(token)
  }
}

private enum FocusStubError: Error {
  case failed
  case unexpectedCall
}

@MainActor
private final class FocusShortcutStub: RecordingFocusShortcutRunning {
  struct Call {
    let shortcut: RecordingFocusShortcut
    let input: String?
  }

  private var results: [Result<String, Error>]
  private(set) var calls: [Call] = []

  init(_ results: [Result<String, Error>]) {
    self.results = results
  }

  func run(shortcut: RecordingFocusShortcut, input: String?) async throws -> String {
    calls.append(Call(shortcut: shortcut, input: input))
    guard !results.isEmpty else { throw FocusStubError.unexpectedCall }
    let result = try results.removeFirst().get()
    if shortcut == .on, result.isEmpty {
      return "{\"identifier\":\"com.apple.donotdisturb.mode.default\",\"name\":\"Do Not Disturb\"}"
    }
    return result
  }
}
