import AppKit
import Combine
@testable import Snapzy
import Testing

@MainActor
@Suite(.serialized)
struct RecordingCoordinatorLifecycleTests {
  @Test
  func repeatedStopWaitsForOneFinishAndDoesNotCleanUpEarly() async throws {
    let coordinator = RecordingCoordinator()
    let output = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
    let (started, startedSignal) = AsyncStream<Void>.makeStream()
    let (release, releaseSignal) = AsyncStream<Void>.makeStream()
    var finishCount = 0
    var cleanupCount = 0
    var delivered: [URL] = []
    let observation = coordinator.$isActive.dropFirst().sink { _ in cleanupCount += 1 }
    defer {
      observation.cancel()
      startedSignal.finish()
      releaseSignal.finish()
    }

    @MainActor func finish() async -> URL? {
      finishCount += 1
      guard finishCount == 1 else { return nil }
      startedSignal.finish()
      for await _ in release {}
      return output
    }

    let firstRequest = coordinator.stopRecording(using: finish, deliverOutput: { delivered.append($0) })
    let first = try #require(firstRequest)
    let immediatelyRepeated = coordinator.stopRecording(using: finish)
    for await _ in started {}
    let repeatedWhileFinishing = coordinator.stopRecording(using: finish)
    await immediatelyRepeated?.value
    await repeatedWhileFinishing?.value

    #expect(immediatelyRepeated == nil)
    #expect(repeatedWhileFinishing == nil)
    #expect(finishCount == 1)
    #expect(cleanupCount == 0)
    #expect(delivered.isEmpty)

    releaseSignal.finish()
    await first.value
    #expect(cleanupCount == 1)
    #expect(delivered == [output])

    let next = try #require(coordinator.stopRecording(using: { nil }))
    await next.value
    #expect(cleanupCount == 2)
  }

  @Test
  func ignoredAutomaticStopDoesNotShowItsNoticeAtNextStop() async throws {
    try #require(ScreenRecordingManager.shared.state == .idle)
    let coordinator = RecordingCoordinator()
    var presented: [String] = []
    let collectNotice: @MainActor (RecordingCoordinator.StopNotice) -> Void = { presented.append($0.message) }
    let originalRequest = coordinator.stopRecording(using: { nil }, presentNotice: collectNotice)
    let original = try #require(originalRequest)
    let rejected = coordinator.stopRecording(
      notice: ("Previous recording", "Previous message"),
      using: { nil },
      presentNotice: collectNotice
    )
    #expect(rejected == nil)
    await rejected?.value
    await original.value

    let nextRequest = coordinator.stopRecording(using: { nil }, presentNotice: collectNotice)
    let next = try #require(nextRequest)
    await next.value
    #expect(presented.isEmpty)
  }

  @Test
  func automaticStopThatOwnsTheRecordingShowsItsNoticeOnce() async throws {
    try #require(ScreenRecordingManager.shared.state == .idle)
    let coordinator = RecordingCoordinator()
    var presented: [String] = []
    let collectNotice: @MainActor (RecordingCoordinator.StopNotice) -> Void = { presented.append($0.message) }
    let automaticRequest = coordinator.stopRecording(
      notice: ("Recording Stopped", "Current message"),
      using: { nil },
      presentNotice: collectNotice
    )
    let automatic = try #require(automaticRequest)
    await automatic.value

    let nextRequest = coordinator.stopRecording(using: { nil }, presentNotice: collectNotice)
    let next = try #require(nextRequest)
    await next.value
    #expect(presented == ["Current message"])
  }

  @Test
  func cancelRequestDuringStopDoesNotRunCleanup() async throws {
    try #require(ScreenRecordingManager.shared.state == .idle)
    let coordinator = RecordingCoordinator()
    let (release, releaseSignal) = AsyncStream<Void>.makeStream()
    var cleanupCount = 0
    let observation = coordinator.$isActive.dropFirst().sink { _ in cleanupCount += 1 }
    defer {
      releaseSignal.finish()
      observation.cancel()
    }

    let stop = try #require(coordinator.stopRecording(using: {
      for await _ in release {}
      return nil
    }))
    let cancellation = coordinator.cancel()
    await cancellation?.value

    #expect(cancellation == nil)
    #expect(cleanupCount == 0)
    releaseSignal.finish()
    await stop.value
    #expect(cleanupCount == 1)
  }

  @Test(arguments: [RecordingCoordinator.DiscardAction.delete, .restart])
  func discardRequestWhileStoppingDoesNotBypassConfirmation(_ action: RecordingCoordinator.DiscardAction) {
    let coordinator = RecordingCoordinator()
    var presented = false
    let mayDiscard = coordinator.confirmDiscardIfNeeded(action, recording: (.stopping, 8)) {
      presented = true
      return true
    }
    #expect(!mayDiscard)
    #expect(!presented)
  }

  @Test(arguments: [RecordingCoordinator.DiscardAction.delete, .restart])
  func discardConfirmationRejectsSessionInvalidatedWhileModalWasOpen(
    _ action: RecordingCoordinator.DiscardAction
  ) async throws {
    try #require(ScreenRecordingManager.shared.state == .idle)
    let savedArea = UserDefaults.standard.object(forKey: PreferencesKeys.recordingLastAreaRect)
    defer { UserDefaults.standard.set(savedArea, forKey: PreferencesKeys.recordingLastAreaRect) }
    let coordinator = RecordingCoordinator()
    coordinator.showToolbar(for: CGRect(x: 100, y: 100, width: 640, height: 480))
    let window = try #require(coordinator.toolbarWindow)
    defer { window.close() }
    var cancellation: Task<Void, Never>?

    let mayDiscard = coordinator.confirmDiscardIfNeeded(action, recording: (.paused, 8)) {
      cancellation = coordinator.cancel()
      return true
    }
    #expect(cancellation != nil)
    #expect(coordinator.isActive)
    #expect(!mayDiscard)
    await cancellation?.value
    #expect(!coordinator.isActive)
  }

  @Test(arguments: [(false, false), (true, false), (true, true)])
  func stopDuringOverlayRegistrationDoesNotReopenToolbar(
    scenario: (waitForCleanup: Bool, replaceSession: Bool)
  ) async throws {
    let savedArea = UserDefaults.standard.object(forKey: PreferencesKeys.recordingLastAreaRect)
    defer { UserDefaults.standard.set(savedArea, forKey: PreferencesKeys.recordingLastAreaRect) }
    let coordinator = RecordingCoordinator()
    let rect = CGRect(x: 100, y: 100, width: 640, height: 480)
    var sessionEnded: CheckedContinuation<Void, Never>?
    var didEnd = false
    coordinator.showToolbar(for: rect, onSessionEnded: {
      didEnd = true
      sessionEnded?.resume()
    })
    let window = try #require(coordinator.toolbarWindow)
    var registrations = 0

    let completed = await coordinator.completeRecordingStart(for: rect) { _ in
      registrations += 1
      guard registrations == 1 else { return }
      if scenario.waitForCleanup {
        // Suspend the real setup path until Stop has closed the original windows.
        await withCheckedContinuation { continuation in
          sessionEnded = continuation
          window.onStop?()
        }
      } else {
        // Stop must invalidate setup even before asynchronous cleanup runs.
        window.onStop?()
        #expect(coordinator.isActive)
      }
      if scenario.replaceSession {
        didEnd = false
        sessionEnded = nil
        coordinator.showToolbar(for: rect, onSessionEnded: {
          didEnd = true
          sessionEnded?.resume()
        })
      }
    }

    #expect(!completed)
    #expect(registrations == 1)
    if scenario.replaceSession {
      #expect(coordinator.toolbarWindow !== window)
      coordinator.cancel()
    }
    if !didEnd {
      await withCheckedContinuation { sessionEnded = $0 }
    }
    #expect(!window.isVisible)
    #expect(!coordinator.isActive)
    window.close()
  }

  @Test("Занятый Recorder освобождает каталог отклонённой подготовки")
  func rejectedPreparationDoesNotLeaveProcessingDirectory() async throws {
    let recorder = ScreenRecordingManager.shared
    try #require(recorder.state == .idle)
    let testRoot = try #require(OwnShotStoragePaths.testRoot)
    let plan = try TempCaptureManager.shared.makeRecordingSavePlan(exportDirectory: testRoot)
    let directory = plan.processingSession.directory
    defer { TempCaptureManager.shared.deleteRecordingProcessingDirectory(plan.processingSession) }
    try #require(FileManager.default.fileExists(atPath: directory.path))

    recorder.setStateForTesting(.stopping)
    defer { recorder.setStateForTesting(.idle) }

    do {
      try await recorder.prepareRecording(
        rect: CGRect(x: 100, y: 100, width: 320, height: 240),
        maxResolution: .native,
        saveDirectory: plan.finalDirectory,
        processingSession: plan.processingSession
      )
      Issue.record("Занятый Recorder принял новый сеанс")
    } catch RecordingError.alreadyActive {
      #expect(recorder.state == .stopping)
      #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
  }

  @Test("Отклонённая подготовка сохраняет другой файл в каталоге обработки")
  func rejectedPreparationKeepsUnownedOutput() async throws {
    let recorder = ScreenRecordingManager.shared
    try #require(recorder.state == .idle)
    let root = try #require(OwnShotStoragePaths.testRoot)
    let captures = TempCaptureManager.shared
    let plan = try captures.makeRecordingSavePlan(exportDirectory: root)
    let directory = plan.processingSession.directory
    defer { captures.deleteRecordingProcessingDirectory(plan.processingSession) }
    let output = directory.appendingPathComponent("other.mov")
    let foreign = Data("Файл до передачи каталога Recorder".utf8)
    try foreign.write(to: output)

    recorder.setStateForTesting(.stopping)
    defer { recorder.setStateForTesting(.idle) }
    do {
      try await recorder.prepareRecording(
        rect: CGRect(x: 100, y: 100, width: 320, height: 240),
        maxResolution: .native,
        saveDirectory: plan.finalDirectory,
        processingSession: plan.processingSession
      )
      Issue.record("Занятый Recorder принял новый сеанс")
    } catch RecordingError.alreadyActive {
      #expect((try? Data(contentsOf: output)) == foreign)
    }
  }

  @Test("Отмена обратного отсчёта не оставляет каталог обработки записи")
  func cancelledCountdownDoesNotLeaveProcessingDirectory() async throws {
    try #require(ScreenRecordingManager.shared.state == .idle)
    let testRoot = try #require(OwnShotStoragePaths.testRoot)
    let files = FileManager.default
    let export = testRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try files.createDirectory(at: export, withIntermediateDirectories: false)
    defer { try? files.removeItem(at: export) }

    let defaults = UserDefaults.standard
    let keys = [
      PreferencesKeys.exportLocation, PreferencesKeys.exportLocationBookmark,
      PreferencesKeys.recordingFormat, PreferencesKeys.recordingLastAreaRect,
      PreferencesKeys.playSounds, RecordingLifecycleKeys.suppressLowDiskWarning,
      OwnShotRecordingPreferenceKeys.showCountdown,
    ]
    let previousValues = keys.map { defaults.object(forKey: $0) }
    defer {
      for (key, value) in zip(keys, previousValues) { defaults.set(value, forKey: key) }
    }
    defaults.set(export.path, forKey: PreferencesKeys.exportLocation)
    defaults.removeObject(forKey: PreferencesKeys.exportLocationBookmark)
    defaults.set(true, forKey: OwnShotRecordingPreferenceKeys.showCountdown)
    defaults.set(false, forKey: PreferencesKeys.playSounds)
    defaults.set(true, forKey: RecordingLifecycleKeys.suppressLowDiskWarning)

    let processingRoot = TempCaptureManager.shared.recordingProcessingRootDirectory
    let before = Set(try files.contentsOfDirectory(atPath: processingRoot.path))
    defer {
      if let after = try? files.contentsOfDirectory(atPath: processingRoot.path) {
        for added in Set(after).subtracting(before) {
          try? files.removeItem(at: processingRoot.appendingPathComponent(added))
        }
      }
    }

    let coordinator = RecordingCoordinator()
    coordinator.showToolbar(for: CGRect(x: 100, y: 100, width: 320, height: 240))
    defer { if coordinator.isActive { coordinator.cancel() } }
    let toolbar = try #require(coordinator.toolbarWindow)
    toolbar.captureCamera = false
    toolbar.captureMicrophone = false

    let visible = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
    let record = try #require(toolbar.onRecord)
    record()

    var countdown: NSPanel?
    let deadline = ContinuousClock.now + .seconds(1)
    while countdown == nil, ContinuousClock.now < deadline {
      countdown = NSApp.windows.compactMap { $0 as? NSPanel }.first {
        $0.isVisible && $0.level == .screenSaver && !visible.contains(ObjectIdentifier($0))
      }
      if countdown == nil { try await Task.sleep(for: .milliseconds(20)) }
    }

    await coordinator.cancel()?.value
    let panel = try #require(countdown)
    let dismissalDeadline = ContinuousClock.now + .seconds(1)
    while panel.isVisible, ContinuousClock.now < dismissalDeadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(!panel.isVisible)
    #expect(ScreenRecordingManager.shared.state == .idle)
    #expect(Set(try files.contentsOfDirectory(atPath: processingRoot.path)) == before)
  }

  @Test
  func completedSetupRegistersRetainedOverlaysAgain() async throws {
    let defaults = UserDefaults.standard
    let savedArea = defaults.object(forKey: PreferencesKeys.recordingLastAreaRect)
    let keys = [PreferencesKeys.recordingHighlightClicks, PreferencesKeys.recordingShowKeystrokes]
    let savedOptions = keys.map { defaults.object(forKey: $0) }
    defer {
      defaults.set(savedArea, forKey: PreferencesKeys.recordingLastAreaRect)
      for (key, value) in zip(keys, savedOptions) { defaults.set(value, forKey: key) }
    }
    for key in keys { defaults.set(true, forKey: key) }
    let coordinator = RecordingCoordinator()
    let rect = CGRect(x: 100, y: 100, width: 640, height: 480)
    var sessionEnded: CheckedContinuation<Void, Never>?
    coordinator.showToolbar(for: rect, onSessionEnded: { sessionEnded?.resume() })
    let window = try #require(coordinator.toolbarWindow)
    var firstRegistration: [CGWindowID] = []
    var secondRegistration: [CGWindowID] = []

    let started = await coordinator.completeRecordingStart(for: rect) {
      firstRegistration.append($0)
    }
    let restarted = await coordinator.completeRecordingStart(for: rect) {
      secondRegistration.append($0)
    }

    #expect(started && restarted)
    #expect(firstRegistration.count == 3)
    #expect(firstRegistration == secondRegistration)
    #expect(coordinator.toolbarWindow === window)
    #expect(window.isMovableByWindowBackground)
    await withCheckedContinuation { continuation in
      sessionEnded = continuation
      coordinator.cancel()
    }
  }
}
