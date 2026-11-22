import AVFoundation
import XCTest
@testable import Snapzy

@MainActor
final class RecordingLifecycleParityTests: XCTestCase {
  func testОтменаДоСтартаСохраняетФайлПоявившийсяПоПутиЗаписи() async throws {
    let (plan, writer) = try makeCancellationFixture()
    let recorder = ScreenRecordingManager.shared
    let files = FileManager.default
    defer { try? files.removeItem(at: plan.processingSession.directory) }
    recorder.prepareWriterForLifecycleTest(writer, processingSession: plan.processingSession, startsWriting: false)
    let foreign = Data("Файл, появившийся до старта".utf8)
    do {
      try foreign.write(to: writer.outputURL)
    } catch {
      await recorder.cancelRecording()
      throw error
    }
    await recorder.cancelRecording()
    XCTAssertEqual(try? Data(contentsOf: writer.outputURL), foreign)
    XCTAssertEqual(recorder.state, .idle)
  }

  func testОтменаАктивнойЗаписиСохраняетПодменённыйФайлПриВосстановлении() async throws {
    let (plan, writer) = try makeCancellationFixture()
    let recorder = ScreenRecordingManager.shared
    let files = FileManager.default
    let directory = plan.processingSession.directory
    let displaced = plan.finalDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
    defer {
      try? files.removeItem(at: directory)
      try? files.removeItem(at: displaced)
    }
    recorder.prepareWriterForLifecycleTest(writer, processingSession: plan.processingSession, startsWriting: true)
    guard writer.status == .writing else {
      await recorder.cancelRecording()
      XCTFail("AVAssetWriter не начал запись: \(String(describing: writer.error))")
      return
    }
    let foreign = Data("Файл, появившийся во время записи".utf8)
    do {
      try files.moveItem(at: writer.outputURL, to: displaced)
      try foreign.write(to: writer.outputURL)
    } catch {
      await recorder.cancelRecording()
      throw error
    }
    await recorder.cancelRecording()
    XCTAssertEqual(try? Data(contentsOf: writer.outputURL), foreign)
    XCTAssertEqual(recorder.state, .idle)

    var inspected: [URL] = []
    let processingRoot = directory.deletingLastPathComponent()
    let recovery = RecordingCrashRecovery.startRecovery(
      in: processingRoot,
      listDirectory: { folder, options in
        if folder == processingRoot { return [directory] }
        return try RecordingCrashRecoveryScanner.listDirectory(folder, options)
      },
      isPlayable: {
        inspected.append($0)
        return false
      },
      destinationFor: { TempCaptureManager.shared.proposedRecoveredRecordingURL(for: $0) },
      deleteSession: { TempCaptureManager.shared.deleteRecordingProcessingDirectory($0) },
      onRecovered: { _ in XCTFail("Отменённая запись попала в восстановление") }
    )
    await recovery?.value
    XCTAssertFalse(inspected.contains { $0.path == writer.outputURL.path })
    XCTAssertEqual(try? Data(contentsOf: writer.outputURL), foreign)
  }

  func testОтменаПропускаетПодменённыйКаталогПриВосстановлении() async throws {
    let (plan, writer) = try makeCancellationFixture()
    let recorder = ScreenRecordingManager.shared
    let files = FileManager.default
    let directory = plan.processingSession.directory
    let displaced = plan.finalDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer {
      try? files.removeItem(at: directory)
      try? files.removeItem(at: displaced)
    }
    recorder.prepareWriterForLifecycleTest(writer, processingSession: plan.processingSession, startsWriting: true)
    guard writer.status == .writing else {
      await recorder.cancelRecording()
      XCTFail("AVAssetWriter не начал запись: \(String(describing: writer.error))")
      return
    }

    let foreign = Data("Файл в новом каталоге обработки".utf8)
    do {
      try files.moveItem(at: directory, to: displaced)
      try files.createDirectory(at: directory, withIntermediateDirectories: false)
      try foreign.write(to: writer.outputURL)
    } catch {
      await recorder.cancelRecording()
      throw error
    }
    await recorder.cancelRecording()
    XCTAssertEqual(try? Data(contentsOf: writer.outputURL), foreign)

    var inspected = false
    let processingRoot = directory.deletingLastPathComponent()
    let recovery = RecordingCrashRecovery.startRecovery(
      in: processingRoot,
      listDirectory: { folder, options in
        if folder == processingRoot { return [directory] }
        return try RecordingCrashRecoveryScanner.listDirectory(folder, options)
      },
      isPlayable: {
        if $0.path == writer.outputURL.path { inspected = true }
        return false
      },
      destinationFor: { TempCaptureManager.shared.proposedRecoveredRecordingURL(for: $0) },
      deleteSession: { TempCaptureManager.shared.deleteRecordingProcessingDirectory($0) },
      onRecovered: { _ in XCTFail("Заменённый каталог попал в восстановление") }
    )
    await recovery?.value
    XCTAssertFalse(inspected)
    XCTAssertEqual(try? Data(contentsOf: writer.outputURL), foreign)
  }

  func testОтменаУдаляетСвойФайлИПустойКаталогЗаписи() async throws {
    let (plan, writer) = try makeCancellationFixture()
    let recorder = ScreenRecordingManager.shared
    let files = FileManager.default
    defer { try? files.removeItem(at: plan.processingSession.directory) }
    recorder.prepareWriterForLifecycleTest(writer, processingSession: plan.processingSession, startsWriting: true)
    let started = writer.status == .writing && files.fileExists(atPath: writer.outputURL.path)
    await recorder.cancelRecording()
    XCTAssertTrue(started)
    XCTAssertFalse(files.fileExists(atPath: plan.processingSession.directory.path))
    XCTAssertEqual(recorder.state, .idle)
  }

  func testStopСохраняетПостороннийФайлВКаталогеОбработки() async throws {
    let (plan, writer) = try makeCancellationFixture()
    let recorder = ScreenRecordingManager.shared
    let files = FileManager.default
    let directory = plan.processingSession.directory
    let destination = plan.finalDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
    let displaced = plan.finalDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
    defer {
      try? files.removeItem(at: directory)
      try? files.removeItem(at: destination)
      try? files.removeItem(at: displaced)
    }
    recorder.prepareWriterForLifecycleTest(
      writer, processingSession: plan.processingSession, startsWriting: true, finalOutput: destination
    )
    guard writer.status == .writing else {
      await recorder.cancelRecording()
      XCTFail("AVAssetWriter не начал запись: \(String(describing: writer.error))")
      return
    }

    let foreign = Data("Файл, появившийся перед Stop".utf8)
    do {
      try files.moveItem(at: writer.outputURL, to: displaced)
      try foreign.write(to: writer.outputURL)
    } catch {
      await recorder.cancelRecording()
      throw error
    }
    let stopped = await recorder.stopRecording()
    XCTAssertNil(stopped)
    XCTAssertEqual(try? Data(contentsOf: writer.outputURL), foreign)
    XCTAssertFalse(files.fileExists(atPath: destination.path))
    XCTAssertEqual(recorder.state, .idle)
  }

  func testStopПубликуетВидеофайлСвоегоWriter() async throws {
    let (plan, writer) = try makeCancellationFixture()
    let recorder = ScreenRecordingManager.shared
    let files = FileManager.default
    let directory = plan.processingSession.directory
    let destination = plan.finalDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
    defer {
      try? files.removeItem(at: directory)
      try? files.removeItem(at: destination)
    }

    let input = try XCTUnwrap(writer.inputs.first)
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
    var pixelBuffer: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixelBuffer), kCVReturnSuccess)
    let frame = try XCTUnwrap(pixelBuffer)

    recorder.prepareWriterForLifecycleTest(
      writer, processingSession: plan.processingSession, startsWriting: true, finalOutput: destination
    )
    guard writer.status == .writing else {
      await recorder.cancelRecording()
      XCTFail("AVAssetWriter не начал запись: \(String(describing: writer.error))")
      return
    }
    writer.startSession(atSourceTime: .zero)
    for index in 0..<3 {
      XCTAssertTrue(adaptor.append(frame, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: 30)))
    }
    input.markAsFinished()

    let output = await recorder.stopRecording()
    XCTAssertEqual(output?.standardizedFileURL.path, destination.standardizedFileURL.path)
    XCTAssertFalse(files.fileExists(atPath: directory.path))
    XCTAssertEqual(recorder.state, .idle)
    let tracks = try await AVURLAsset(url: destination).loadTracks(withMediaType: .video)
    XCTAssertEqual(tracks.count, 1)
  }

  func testStopСохраняетФайлПоявившийсяПередСведениемЗвука() async throws {
    try await assertStopPreservesFileChangedDuringAudioProcessing(replacesBeforeMerge: true)
  }

  func testStopСохраняетФайлИзменившийсяПослеСведенияЗвука() async throws {
    try await assertStopPreservesFileChangedDuringAudioProcessing(replacesBeforeMerge: false)
  }

  private func assertStopPreservesFileChangedDuringAudioProcessing(replacesBeforeMerge: Bool) async throws {
    let (plan, writer) = try makeCancellationFixture()
    let recorder = ScreenRecordingManager.shared
    let files = FileManager.default
    let directory = plan.processingSession.directory
    let destination = plan.finalDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
    let displaced = plan.finalDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
    defer {
      try? files.removeItem(at: directory)
      try? files.removeItem(at: destination)
      try? files.removeItem(at: displaced)
    }

    let input = try XCTUnwrap(writer.inputs.first)
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
    var pixelBuffer: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixelBuffer), kCVReturnSuccess)
    let frame = try XCTUnwrap(pixelBuffer)

    let previousWillBegin = recorder.onAudioMergeWillBegin
    let previousDidEnd = recorder.onAudioMergeDidEnd
    defer {
      recorder.onAudioMergeWillBegin = previousWillBegin
      recorder.onAudioMergeDidEnd = previousDidEnd
    }
    let foreign = Data("Файл изменился во время обработки звука".utf8)
    var changed = false
    func changeOutput() {
      do {
        if replacesBeforeMerge { try files.moveItem(at: writer.outputURL, to: displaced) }
        try foreign.write(to: writer.outputURL)
        changed = true
      } catch {
        XCTFail("Не удалось изменить файл: \(error)")
      }
    }
    if replacesBeforeMerge {
      recorder.onAudioMergeWillBegin = { _ in changeOutput() }
    } else {
      recorder.onAudioMergeDidEnd = { changeOutput() }
    }

    recorder.prepareWriterForLifecycleTest(
      writer, processingSession: plan.processingSession, startsWriting: true,
      finalOutput: destination, requestsAudioMerge: true
    )
    guard writer.status == .writing else {
      await recorder.cancelRecording()
      XCTFail("AVAssetWriter не начал запись: \(String(describing: writer.error))")
      return
    }
    writer.startSession(atSourceTime: .zero)
    for index in 0..<3 {
      XCTAssertTrue(adaptor.append(frame, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: 30)))
    }
    input.markAsFinished()

    let saved = await recorder.stopRecording()
    XCTAssertTrue(changed)
    XCTAssertNil(saved)
    XCTAssertEqual(try? Data(contentsOf: writer.outputURL), foreign)
    XCTAssertFalse(files.fileExists(atPath: destination.path))
    XCTAssertEqual(recorder.state, .idle)
  }

  func testStopСохраняетПодменённыйФайлРаздельногоЗвука() async throws {
    try await assertRecordingAudioSourceAfterMix(replacesAudioSource: true)
  }

  func testStopСохраняетСвоиРаздельныеДорожкиДляРедактора() async throws {
    try await assertRecordingAudioSourceAfterMix(replacesAudioSource: false)
  }

  private func assertRecordingAudioSourceAfterMix(replacesAudioSource: Bool) async throws {
    let testRoot = try XCTUnwrap(OwnShotStoragePaths.testRoot)
    let captures = TempCaptureManager.shared
    let plan = try captures.makeRecordingSavePlan(exportDirectory: testRoot)
    let directory = plan.processingSession.directory
    let source = directory.appendingPathComponent("recording.mov")
    let destination = plan.finalDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
    let recorder = ScreenRecordingManager.shared
    let files = FileManager.default
    let previousDidEnd = recorder.onAudioMergeDidEnd
    defer {
      recorder.onAudioMergeDidEnd = previousDidEnd
      try? RecordingMetadataStore.delete(for: destination)
      try? files.removeItem(at: directory)
      try? files.removeItem(at: destination)
    }

    let foreign = Data("Файл, занявший путь раздельных аудиодорожек".utf8)
    var substituted: URL?
    if replacesAudioSource {
      recorder.onAudioMergeDidEnd = {
        do {
          let candidates = try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
          let audioSource = try XCTUnwrap(candidates.first { $0.lastPathComponent.contains("-audio-sources-") })
          try foreign.write(to: audioSource, options: .atomic)
          substituted = audioSource
        } catch {
          XCTFail("Не удалось подменить временный файл с двумя дорожками: \(error)")
        }
      }
    }
    do {
      try await Self.writeMovieWithTwoAudioTracks(to: source) { writer in
        recorder.prepareWriterForLifecycleTest(
          writer, processingSession: plan.processingSession, startsWriting: true,
          finalOutput: destination, requestsAudioMerge: true
        )
      }
    } catch {
      await recorder.cancelRecording()
      throw error
    }
    let saved = await recorder.stopRecording()
    XCTAssertEqual(saved?.standardizedFileURL.path, destination.standardizedFileURL.path)
    let publishedTracks = try await AVURLAsset(url: destination).loadTracks(withMediaType: .audio)
    XCTAssertEqual(publishedTracks.count, 1)

    let audioSource = RecordingMetadataStore.load(for: destination)?.audioSourceURL
    if replacesAudioSource {
      XCTAssertNil(audioSource)
      XCTAssertEqual(try? Data(contentsOf: XCTUnwrap(substituted)), foreign)
    } else {
      let stored = try XCTUnwrap(audioSource)
      let originalTracks = try await AVURLAsset(url: stored).loadTracks(withMediaType: .audio)
      XCTAssertEqual(originalTracks.count, 2)
      XCTAssertFalse(files.fileExists(atPath: directory.path))
    }
  }

  func testНастройкаWriterСохраняетФайлИлиКаталогПоЗанятомуПути() throws {
    let testRoot = try XCTUnwrap(OwnShotStoragePaths.testRoot)
    let recorder = ScreenRecordingManager.shared
    XCTAssertEqual(recorder.state, .idle)
    let files = FileManager.default
    let fixture = testRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try files.createDirectory(at: fixture, withIntermediateDirectories: false)
    defer { try? files.removeItem(at: fixture) }
    let foreign = Data("Файл, появившийся до настройки writer".utf8)

    for isDirectory in [false, true] {
      let output = fixture.appendingPathComponent(isDirectory ? "directory.mov" : "file.mov")
      let original: URL
      if isDirectory {
        try files.createDirectory(at: output, withIntermediateDirectories: false)
        original = output.appendingPathComponent("original")
      } else {
        original = output
      }
      try foreign.write(to: original)
      XCTAssertThrowsError(try recorder.setupAssetWriterForTesting(at: output)) {
        XCTAssertEqual(($0 as? CocoaError)?.code, .fileWriteFileExists)
      }
      XCTAssertEqual(try? Data(contentsOf: original), foreign)
    }

    XCTAssertNoThrow(try recorder.setupAssetWriterForTesting(at: fixture.appendingPathComponent("available.mov")))
  }

  private func makeCancellationFixture() throws -> (RecordingSavePlan, AVAssetWriter) {
    let root = try XCTUnwrap(OwnShotStoragePaths.testRoot)
    let manager = TempCaptureManager.shared
    let plan = try manager.makeRecordingSavePlan(exportDirectory: root)
    let output = plan.processingSession.directory.appendingPathComponent("recording.mov")
    do {
      let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
      writer.add(AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
      ]))
      return (plan, writer)
    } catch {
      manager.deleteRecordingProcessingDirectory(plan.processingSession)
      throw error
    }
  }

  // MARK: - Audio Recording Failed

  func testСторожНеСрабатываетПокаЗвукИдёт() {
    var watchdog = RecordingSystemAudioWatchdog(startTimeout: 10, stallTimeout: 20)
    for second in 0..<60 {
      let health = RecordingSystemAudioHealth(samplesReceived: second * 10, appendFailed: false)
      XCTAssertFalse(watchdog.observe(health, isPaused: false, now: TimeInterval(second)))
    }
    XCTAssertFalse(watchdog.hasFired)
  }

  func testСторожСрабатываетЕслиЗвукНеПришёлКСроку() {
    var watchdog = RecordingSystemAudioWatchdog(startTimeout: 10, stallTimeout: 20)
    let silent = RecordingSystemAudioHealth(samplesReceived: 0, appendFailed: false)
    XCTAssertFalse(watchdog.observe(silent, isPaused: false, now: 0))
    XCTAssertFalse(watchdog.observe(silent, isPaused: false, now: 9))
    XCTAssertTrue(watchdog.observe(silent, isPaused: false, now: 10))
    // Один раз за запись.
    XCTAssertFalse(watchdog.observe(silent, isPaused: false, now: 30))
  }

  func testСторожЖдётДольшеПослеОстановкиПотока() {
    var watchdog = RecordingSystemAudioWatchdog(startTimeout: 10, stallTimeout: 20)
    XCTAssertFalse(watchdog.observe(.init(samplesReceived: 5, appendFailed: false), isPaused: false, now: 0))
    XCTAssertFalse(watchdog.observe(.init(samplesReceived: 50, appendFailed: false), isPaused: false, now: 1))
    XCTAssertFalse(watchdog.observe(.init(samplesReceived: 50, appendFailed: false), isPaused: false, now: 15))
    XCTAssertTrue(watchdog.observe(.init(samplesReceived: 50, appendFailed: false), isPaused: false, now: 21))
  }

  func testПаузаСдвигаетОтсчётСторожа() {
    var watchdog = RecordingSystemAudioWatchdog(startTimeout: 10, stallTimeout: 20)
    let silent = RecordingSystemAudioHealth(samplesReceived: 0, appendFailed: false)
    XCTAssertFalse(watchdog.observe(silent, isPaused: false, now: 0))
    XCTAssertFalse(watchdog.observe(silent, isPaused: true, now: 30))
    XCTAssertFalse(watchdog.observe(silent, isPaused: false, now: 35))
    XCTAssertTrue(watchdog.observe(silent, isPaused: false, now: 40))
  }

  func testСбойЗаписиДорожкиСрабатываетСразу() {
    var watchdog = RecordingSystemAudioWatchdog()
    XCTAssertTrue(watchdog.observe(.init(samplesReceived: 3, appendFailed: true), isPaused: false, now: 0))
  }

  func testНоваяСессияСообщаетПустоеЗдоровьеЗвука() {
    XCTAssertEqual(
      RecordingSession().systemAudioHealth(),
      RecordingSystemAudioHealth(samplesReceived: 0, appendFailed: false)
    )
  }

  func testТекстыСбояСистемногоЗвукаКакУЭталона() {
    XCTAssertEqual(L10n.RecordingParity.audioRecordingFailedTitle, "Audio Recording Failed")
    XCTAssertEqual(
      L10n.RecordingParity.audioRecordingFailedMessage,
      "Unable to capture system audio. Do you want to continue recording without audio or stop the recording?"
    )
  }

  // MARK: - Сведение дорожек

  func testМестоДляСведенияСчитаетсяСЗапасом() {
    let reserve = RecordingAudioMergeDiskPolicy.reserveBytes
    XCTAssertEqual(RecordingAudioMergeDiskPolicy.requiredBytes(sourceFileBytes: 100), 200 + reserve)
    XCTAssertEqual(RecordingAudioMergeDiskPolicy.requiredBytes(sourceFileBytes: -5), reserve)
    XCTAssertTrue(RecordingAudioMergeDiskPolicy.hasEnoughSpace(sourceFileBytes: 100, availableBytes: 200 + reserve))
    XCTAssertFalse(RecordingAudioMergeDiskPolicy.hasEnoughSpace(sourceFileBytes: 100, availableBytes: 199 + reserve))
    // Неизвестный объём диска не мешает сведению.
    XCTAssertTrue(RecordingAudioMergeDiskPolicy.hasEnoughSpace(sourceFileBytes: 100, availableBytes: nil))
  }

  func testСообщенияОНесведённыхДорожках() {
    XCTAssertEqual(L10n.RecordingParity.mergeFailedTitle, "Can't merge audio tracks")
    XCTAssertEqual(RecordingAudioMergeIssue.failed.alertMessage, L10n.RecordingParity.mergeFailedMessage)
    XCTAssertTrue(RecordingAudioMergeIssue.lowDisk.alertMessage?.hasPrefix("Your free disk space is too low.") == true)
    XCTAssertNil(RecordingAudioMergeIssue.cancelled.alertMessage)
  }

  func testФлагОтменыСведения() {
    let cancellation = RecordingAudioMergeCancellation()
    XCTAssertFalse(cancellation.isCancelled)
    cancellation.cancel()
    XCTAssertTrue(cancellation.isCancelled)
  }

  func testОтменённоеСведениеОставляетИсходныйФайл() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("rec-merge-cancel-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("two-tracks.mov")
    try await Self.writeMovieWithTwoAudioTracks(to: url)
    let originalSize = try XCTUnwrap(url.resourceValues(forKeys: [.fileSizeKey]).fileSize)

    let cancellation = RecordingAudioMergeCancellation()
    cancellation.cancel()
    do {
      _ = try await RecordingAudioCompatibilityExporter.normalizeIfNeeded(
        at: url, fileType: .mov, preservesAudioSource: false, cancellation: cancellation
      )
      XCTFail("Отменённое сведение должно бросить cancelled")
    } catch RecordingAudioCompatibilityExporter.ExportError.cancelled {
      // ожидаемо
    }
    let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio)
    XCTAssertEqual(tracks.count, 2)
    XCTAssertEqual(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, originalSize)
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    XCTAssertEqual(leftovers, ["two-tracks.mov"])
  }

  // MARK: - Сохранение

  func testОшибкаСохраненияТолькоПослеНастоящейЗаписи() {
    let url = URL(fileURLWithPath: "/tmp/recording.mov")
    XCTAssertTrue(RecordingSaveFailurePolicy.shouldReportSaveFailure(outputURL: nil, wasRecording: true))
    // Stop во время подготовки не должен открывать модальный алерт.
    XCTAssertFalse(RecordingSaveFailurePolicy.shouldReportSaveFailure(outputURL: nil, wasRecording: false))
    XCTAssertFalse(RecordingSaveFailurePolicy.shouldReportSaveFailure(outputURL: url, wasRecording: true))
  }

  // MARK: - GIF

  func testGIFConversionCompletionKeepsOtherCardCancellable() {
    var conversions = RecordingGIFConversions()
    let firstID = UUID()
    let secondID = UUID()
    let url = FileManager.default.temporaryDirectory
    let first = Task<URL, Error> { @MainActor in url }
    let second = Task<URL, Error> { @MainActor in url }
    defer {
      first.cancel()
      second.cancel()
    }

    XCTAssertNil(conversions.activeConversion(for: nil))
    conversions.start(first, id: UUID(), itemID: firstID)
    conversions.start(second, id: UUID(), itemID: secondID)
    XCTAssertEqual(conversions.activeConversion(for: firstID)?.task, first)
    XCTAssertEqual(conversions.activeConversion(for: secondID)?.task, second)
    XCTAssertEqual(conversions.activeConversion(for: nil)?.task, second)

    XCTAssertNil(conversions.finish(first))
    XCTAssertNil(conversions.activeConversion(for: firstID))
    XCTAssertEqual(conversions.activeConversion(for: secondID)?.task, second)
    XCTAssertFalse(conversions.cancel(first, choice: .deleteRecording), "A stale chooser cannot target the next job")
    XCTAssertFalse(conversions.cancel(second, choice: .continueConverting))
    XCTAssertFalse(second.isCancelled)
    XCTAssertTrue(conversions.cancel(second, choice: .saveAsVideo))
    XCTAssertTrue(second.isCancelled)
    XCTAssertEqual(conversions.finish(second), .saveAsVideo)
    XCTAssertNil(conversions.activeConversion(for: nil))
  }

  func testConcurrentGIFCancelChoicesStayWithTheirTasks() {
    var conversions = RecordingGIFConversions()
    let firstID = UUID()
    let secondID = UUID()
    let url = FileManager.default.temporaryDirectory
    let first = Task<URL, Error> { @MainActor in url }
    let second = Task<URL, Error> { @MainActor in url }
    defer {
      first.cancel()
      second.cancel()
    }

    conversions.start(first, id: UUID(), itemID: firstID)
    XCTAssertTrue(conversions.cancel(first, choice: .saveAsVideo))
    conversions.start(second, id: UUID(), itemID: secondID)
    XCTAssertTrue(conversions.cancel(second, choice: .deleteRecording))
    XCTAssertFalse(conversions.cancel(first, choice: .deleteRecording), "A repeated chooser cannot replace the choice")
    XCTAssertTrue(first.isCancelled)
    XCTAssertTrue(second.isCancelled)
    XCTAssertEqual(conversions.finish(first), .saveAsVideo)
    XCTAssertEqual(conversions.activeConversion(for: secondID)?.cancelChoice, .deleteRecording)
    XCTAssertEqual(conversions.finish(second), .deleteRecording)
  }

  func testGIFProgressRequiresItsOwnActiveConversion() {
    var conversions = RecordingGIFConversions()
    let firstID = UUID()
    let secondID = UUID()
    let cardID = UUID()
    let url = FileManager.default.temporaryDirectory
    let first = Task<URL, Error> { @MainActor in url }
    let second = Task<URL, Error> { @MainActor in url }
    defer {
      first.cancel()
      second.cancel()
    }

    XCTAssertFalse(conversions.acceptsProgress(for: firstID))
    conversions.start(first, id: firstID, itemID: cardID)
    XCTAssertTrue(conversions.acceptsProgress(for: firstID))
    XCTAssertNil(conversions.finish(first))
    // A queued progress callback still carries the first conversion's identity.
    conversions.start(second, id: secondID, itemID: cardID)
    XCTAssertFalse(conversions.acceptsProgress(for: firstID))
    XCTAssertTrue(conversions.acceptsProgress(for: secondID))
    XCTAssertTrue(conversions.cancel(second, choice: .saveAsVideo))
    XCTAssertFalse(conversions.acceptsProgress(for: secondID))
    XCTAssertEqual(conversions.finish(second), .saveAsVideo)
  }

  func testКнопкиОтменыGIF() {
    XCTAssertEqual(RecordingGIFCancelChoice.from(buttonIndex: 0), .saveAsVideo)
    XCTAssertEqual(RecordingGIFCancelChoice.from(buttonIndex: 1), .deleteRecording)
    XCTAssertEqual(RecordingGIFCancelChoice.from(buttonIndex: 2), .continueConverting)
    XCTAssertEqual(L10n.RecordingParity.stopConversionTitle, "Are you sure you want to stop the conversion?")
  }

  func testОтменаКонвертацииGIFБросаетCancellation() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("rec-gif-cancel-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("clip.mov")
    try await Self.writeMovieWithTwoAudioTracks(to: url, seconds: 2)

    let task = Task { @MainActor in
      try await GIFConverter.convert(videoURL: url, onProgress: { _ in })
    }
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Отменённая конвертация не должна вернуть GIF")
    } catch is CancellationError {
      // ожидаемо
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("clip.gif").path))
  }

  // MARK: - Выбор области и Do Not Disturb

  func testПодсказкаВыбораОбластиЗаписи() {
    XCTAssertEqual(
      L10n.RecordingParity.dragToRecordHint(windowShortcut: "Space"),
      "Drag to record a part of the screen. Press Space to select a window."
    )
    XCTAssertEqual(L10n.RecordingParity.dragToRecordHint(windowShortcut: nil), "Drag to record a part of the screen.")
  }

  func testКомандыFocusИщутсяВСпискеShortcuts() {
    let all = "Something\nOwnShot Focus Status\nOwnShot Focus On\n  OwnShot Focus Off  \n"
    XCTAssertEqual(RecordingFocusSetup.missingShortcuts(inListOutput: all), [])
    XCTAssertEqual(
      RecordingFocusSetup.missingShortcuts(inListOutput: "OwnShot Focus On\n"),
      [.status, .off]
    )
    XCTAssertEqual(RecordingFocusSetup.missingShortcuts(inListOutput: ""), [.status, .on, .off])
  }

  // MARK: - Глифы панели записи

  func testРазмерыГлифовПанелиЗаписи() {
    XCTAssertEqual(ToolbarConstants.recorderControlGlyphSize, 18)
    XCTAssertEqual(ToolbarConstants.recorderSettingsGlyphSize, 16)
  }

  // MARK: - Восстановление

  func testВосстановлениеНаходитВидеоВКаталогахСеансов() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("rec-recovery-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let session = root.appendingPathComponent("A", isDirectory: true)
    let empty = root.appendingPathComponent("B", isDirectory: true)
    try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    for name in ["rec.mov", "rec.MP4", ".rec-audio-compatible-1.mov", "notes.json"] {
      FileManager.default.createFile(atPath: session.appendingPathComponent(name).path, contents: Data())
    }

    let snapshot = try XCTUnwrap(RecordingCrashRecoveryScanner.snapshot(inProcessingRoot: root))
    let names = snapshot.sessions.flatMap(\.candidates).map(\.url.lastPathComponent)
    XCTAssertEqual(Set(names), ["rec.mov", "rec.MP4"])
    XCTAssertEqual(snapshot.sessions.count, 2)
    XCTAssertNil(RecordingCrashRecoveryScanner.snapshot(inProcessingRoot: root.appendingPathComponent("none")))
  }

  func testВосстановлениеНеУдаляетКаталогиЗаСсылкойНаКорнеОбработки() throws {
    let files = FileManager.default
    let directory = files.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let root = directory.appendingPathComponent("processing", isDirectory: true)
    let foreign = directory.appendingPathComponent("foreign", isDirectory: true)
    let session = foreign.appendingPathComponent("notes", isDirectory: true)
    let note = session.appendingPathComponent("note.txt")
    let contents = Data("сохранить".utf8)
    try files.createDirectory(at: session, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: directory) }
    try contents.write(to: note)
    try files.createSymbolicLink(at: root, withDestinationURL: foreign)

    let task = RecordingCrashRecovery.startRecovery(
      in: root,
      isPlayable: { _ in false },
      destinationFor: { _ in directory.appendingPathComponent("recovered.mov") },
      deleteSession: { try? files.removeItem(at: $0) },
      onRecovered: { _ in XCTFail("Восстановление не должно проходить по ссылке") }
    )

    XCTAssertNil(task)
    XCTAssertEqual(try? Data(contentsOf: note), contents)
  }

  func testВосстановлениеПрекращаетсяЕслиКореньСталСсылкойВоВремяПроверки() async throws {
    let files = FileManager.default
    let directory = files.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let root = directory.appendingPathComponent("processing", isDirectory: true)
    let moved = directory.appendingPathComponent("moved", isDirectory: true)
    let session = root.appendingPathComponent("session", isDirectory: true)
    let video = session.appendingPathComponent("recording.mov")
    let destination = directory.appendingPathComponent("recovered.mov")
    let contents = Data("запись".utf8)
    try files.createDirectory(at: session, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: directory) }
    try contents.write(to: video)

    var didInspect = false
    let task = try XCTUnwrap(RecordingCrashRecovery.startRecovery(
      in: root,
      isPlayable: { _ in
        try files.moveItem(at: root, to: moved)
        try files.createSymbolicLink(at: root, withDestinationURL: moved)
        didInspect = true
        return true
      },
      destinationFor: { _ in destination },
      deleteSession: { try? files.removeItem(at: $0) },
      onRecovered: { _ in XCTFail("Восстановление не должно публиковать файл после смены корня") }
    ))
    await task.value

    XCTAssertTrue(didInspect)
    XCTAssertFalse(files.fileExists(atPath: destination.path))
    XCTAssertEqual(try? Data(contentsOf: moved.appendingPathComponent("session/recording.mov")), contents)
  }

  func testВосстановлениеНеТрогаетСессиюНачатуюВоВремяПроверкиВидео() async throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent("rec-recovery-race-\(UUID().uuidString)", isDirectory: true)
    defer { try? files.removeItem(at: root) }
    let oldSession = root.appendingPathComponent("old", isDirectory: true)
    let emptySession = root.appendingPathComponent("empty", isDirectory: true)
    let newSession = root.appendingPathComponent("new", isDirectory: true)
    let oldVideo = oldSession.appendingPathComponent("old.mov")
    let newVideo = newSession.appendingPathComponent("new.mov")
    let destination = root.appendingPathComponent("recovered.mov")
    let oldBytes = Data("previous recording".utf8)
    let newBytes = Data("new recording".utf8)
    try files.createDirectory(at: oldSession, withIntermediateDirectories: true)
    try files.createDirectory(at: emptySession, withIntermediateDirectories: true)
    try oldBytes.write(to: oldVideo)

    let entered = expectation(description: "Восстановление ждёт проверки старой записи")
    var reply: CheckedContinuation<Bool, Never>?
    var validationFinished = false
    var recovered: [URL] = []
    let task = try XCTUnwrap(RecordingCrashRecovery.startRecovery(
      in: root,
      isPlayable: { candidate in
        XCTAssertEqual(candidate.resolvingSymlinksInPath().path, oldVideo.resolvingSymlinksInPath().path)
        if validationFinished { return true }
        return await withCheckedContinuation { continuation in
          reply = continuation
          entered.fulfill()
        }
      },
      destinationFor: { _ in destination },
      deleteSession: { try? files.removeItem(at: $0) }
    ) { recovered = $0 })

    await fulfillment(of: [entered], timeout: 2)
    let creation = Result {
      try files.createDirectory(at: newSession, withIntermediateDirectories: true)
      try newBytes.write(to: newVideo)
    }
    validationFinished = true
    reply?.resume(returning: true)
    reply = nil
    await task.value
    try creation.get()

    XCTAssertFalse(files.fileExists(atPath: oldSession.path))
    XCTAssertFalse(files.fileExists(atPath: emptySession.path))
    XCTAssertEqual(try Data(contentsOf: destination), oldBytes)
    XCTAssertEqual(recovered, [destination])
    XCTAssertTrue(files.fileExists(atPath: newSession.path))
    XCTAssertEqual(try? Data(contentsOf: newVideo), newBytes)
  }

  func testВосстановлениеПереноситЗаписьИСохраняетДругойСкрытыйФайл() async throws {
    try await assertRecoveryKeepsUnownedEntry(playable: true)
  }

  func testВосстановлениеУдаляетНегоднуюЗаписьИСохраняетДругойСкрытыйФайл() async throws {
    try await assertRecoveryKeepsUnownedEntry(playable: false)
  }

  func testВосстановлениеСохраняетКаталогСоСкрытымФайломБезВидео() async throws {
    try await assertRecoveryKeepsUnownedEntry(playable: nil)
  }

  private func assertRecoveryKeepsUnownedEntry(playable: Bool?) async throws {
    let files = FileManager.default
    let fixture = files.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let processingRoot = fixture.appendingPathComponent("Processing", isDirectory: true)
    let directory = processingRoot.appendingPathComponent("recording-session", isDirectory: true)
    let source = directory.appendingPathComponent("recording.mov")
    let destination = fixture.appendingPathComponent("recovered.mov")
    let unowned = directory.appendingPathComponent(".recording-audio-compatible-foreign.mov")
    let capturedBytes = Data("Данные исходной записи".utf8)
    let unownedBytes = Data("Содержимое другого файла в каталоге обработки".utf8)
    try files.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: fixture) }
    if playable != nil { try capturedBytes.write(to: source) }
    try unownedBytes.write(to: unowned)

    var inspected: [URL] = []
    var recovered: [URL] = []
    let task = RecordingCrashRecovery.startRecovery(
      in: processingRoot,
      isPlayable: { candidate in
        inspected.append(candidate)
        return playable == true
      },
      destinationFor: { _ in destination },
      deleteSession: { try? files.removeItem(at: $0) },
      onRecovered: { recovered = $0 }
    )
    await task?.value
    XCTAssertEqual(inspected.map(\.lastPathComponent), playable == nil ? [] : [source.lastPathComponent])
    XCTAssertEqual(recovered.map(\.path), playable == true ? [destination.path] : [])
    XCTAssertFalse(files.fileExists(atPath: source.path))
    XCTAssertEqual(try? Data(contentsOf: destination), playable == true ? capturedBytes : nil)
    XCTAssertEqual(try? Data(contentsOf: unowned), unownedBytes)
  }

  func testВосстановлениеБезВидеоОчищаетСтаруюПустуюСессиюСинхронно() throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent("rec-recovery-empty-\(UUID().uuidString)", isDirectory: true)
    defer { try? files.removeItem(at: root) }
    let emptySession = root.appendingPathComponent("empty", isDirectory: true)
    try files.createDirectory(at: emptySession, withIntermediateDirectories: true)

    let task = RecordingCrashRecovery.startRecovery(
      in: root,
      isPlayable: { _ in
        XCTFail("Нет видео для проверки")
        return false
      },
      destinationFor: { $0 },
      deleteSession: { try? files.removeItem(at: $0) }
    ) { _ in
      XCTFail("Нет восстановленных записей")
    }

    XCTAssertNil(task)
    XCTAssertFalse(files.fileExists(atPath: emptySession.path))
  }

  func testВосстановлениеСохраняетФайлПодменённыйВоВремяПроверки() async throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent("rec-recovery-race-\(UUID().uuidString)", isDirectory: true)
    try files.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? files.removeItem(at: root) }
    let originalBytes = Data("original recording".utf8)
    let replacementBytes = Data("another recording".utf8)

    for playable in [true, false] {
      let processing = root.appendingPathComponent("case-\(playable)", isDirectory: true)
      let session = processing.appendingPathComponent("old", isDirectory: true)
      let candidate = session.appendingPathComponent("current.mov")
      let original = root.appendingPathComponent("original-\(playable).mov")
      let destination = root.appendingPathComponent("recovered-\(playable).mov")
      try files.createDirectory(at: session, withIntermediateDirectories: true)
      try originalBytes.write(to: candidate)

      let work = try XCTUnwrap(RecordingCrashRecovery.startRecovery(
        in: processing,
        isPlayable: { inspected in
          guard inspected.lastPathComponent == candidate.lastPathComponent,
                inspected.deletingLastPathComponent().lastPathComponent == session.lastPathComponent else {
            throw CocoaError(.fileReadNoPermission)
          }
          XCTAssertEqual(try Data(contentsOf: inspected), originalBytes)
          await Task.yield()
          try files.moveItem(at: inspected, to: original)
          try replacementBytes.write(to: inspected)
          return playable
        },
        destinationFor: { _ in destination },
        deleteSession: { try? files.removeItem(at: $0) }
      ) { _ in XCTFail("Результат проверки нельзя применять к другому файлу") })
      await work.value

      XCTAssertEqual(try Data(contentsOf: original), originalBytes)
      XCTAssertEqual(try Data(contentsOf: candidate), replacementBytes)
      XCTAssertFalse(files.fileExists(atPath: destination.path))
    }
  }

  func testВосстановлениеСохраняетФайлИзменённыйНаМестеВоВремяПроверки() async throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try files.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? files.removeItem(at: root) }
    let initial = Data("старые данные".utf8)
    let newBytes = Data("добавленные данные".utf8)

    for editsVideo in [true, false] {
      let processing = root.appendingPathComponent("processing-\(editsVideo)", isDirectory: true)
      let session = processing.appendingPathComponent("session", isDirectory: true)
      let video = session.appendingPathComponent("previous.mov")
      let notes = session.appendingPathComponent("notes.txt")
      let changedFile = editsVideo ? video : notes
      let destination = root.appendingPathComponent("recovered-\(editsVideo).mov")
      try files.createDirectory(at: session, withIntermediateDirectories: true)
      try initial.write(to: video)
      try initial.write(to: notes)
      let identity = try XCTUnwrap(CaptureFilePublication.SourceIdentity.regularFile(at: changedFile))

      let work = try XCTUnwrap(RecordingCrashRecovery.startRecovery(
        in: processing,
        isPlayable: { _ in
          let handle = try FileHandle(forWritingTo: changedFile)
          defer { try? handle.close() }
          _ = try handle.seekToEnd()
          try handle.write(contentsOf: newBytes)
          XCTAssertEqual(CaptureFilePublication.SourceIdentity.regularFile(at: changedFile), identity)
          return editsVideo
        },
        destinationFor: { _ in destination },
        deleteSession: { try? files.removeItem(at: $0) },
        onRecovered: { _ in XCTFail("Изменившийся файл нельзя публиковать") }
      ))
      await work.value

      XCTAssertFalse(files.fileExists(atPath: destination.path))
      XCTAssertEqual(try? Data(contentsOf: changedFile), initial + newBytes)
    }
  }

  func testВосстановлениеНеПроверяетФайлПодменённыйПослеСканирования() async throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent("rec-recovery-before-inspection-\(UUID().uuidString)")
    let processing = root.appendingPathComponent("processing", isDirectory: true)
    let session = processing.appendingPathComponent("old", isDirectory: true)
    let candidate = session.appendingPathComponent("current.mov")
    let held = root.appendingPathComponent("original.mov")
    let destination = root.appendingPathComponent("recovered.mov")
    try files.createDirectory(at: session, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: root) }
    let bytes = Data("original recording".utf8)
    let replacement = Data("another recording".utf8)
    try bytes.write(to: candidate)

    var inspected = false
    let work = try XCTUnwrap(RecordingCrashRecovery.startRecovery(
      in: processing,
      isPlayable: { _ in
        inspected = true
        return true
      },
      destinationFor: { _ in destination },
      deleteSession: { try? files.removeItem(at: $0) }
    ) { _ in XCTFail("Подменённый файл не был частью снимка сканирования") })
    try files.moveItem(at: candidate, to: held)
    try replacement.write(to: candidate)
    await work.value

    XCTAssertFalse(inspected)
    XCTAssertEqual(try Data(contentsOf: candidate), replacement)
    XCTAssertEqual(try Data(contentsOf: held), bytes)
    XCTAssertFalse(files.fileExists(atPath: destination.path))
  }

  func testВосстановлениеНеУдаляетФайлПоявившийсяПослеСканирования() async throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent("rec-recovery-new-file-\(UUID().uuidString)")
    let processing = root.appendingPathComponent("processing", isDirectory: true)
    let session = processing.appendingPathComponent("old", isDirectory: true)
    let candidate = session.appendingPathComponent("original.mov")
    let lateFile = session.appendingPathComponent("new.mov")
    let destination = root.appendingPathComponent("recovered.mov")
    try files.createDirectory(at: session, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: root) }
    let originalBytes = Data("old recording".utf8)
    let lateBytes = Data("pending recording".utf8)
    try originalBytes.write(to: candidate)

    var recovered: [URL] = []
    let work = try XCTUnwrap(RecordingCrashRecovery.startRecovery(
      in: processing,
      isPlayable: { _ in
        await Task.yield()
        try lateBytes.write(to: lateFile)
        return true
      },
      destinationFor: { _ in destination },
      deleteSession: { try? files.removeItem(at: $0) }
    ) { recovered = $0 })
    await work.value

    XCTAssertEqual(recovered, [destination])
    XCTAssertEqual(try Data(contentsOf: destination), originalBytes)
    XCTAssertEqual(try Data(contentsOf: lateFile), lateBytes)
  }

  func testВосстановлениеСохраняетНовыйКаталогПоТомуЖеПути() async throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent("rec-recovery-new-directory-\(UUID().uuidString)")
    let processing = root.appendingPathComponent("processing", isDirectory: true)
    let old = processing.appendingPathComponent("empty", isDirectory: true)
    let held = root.appendingPathComponent("held", isDirectory: true)
    let normal = processing.appendingPathComponent("normal", isDirectory: true)
    let candidate = normal.appendingPathComponent("original.mov")
    let destination = root.appendingPathComponent("recovered.mov")
    let protectedSidecar = old.appendingPathComponent(".working")
    for directory in [old, normal] {
      try files.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    defer { try? files.removeItem(at: root) }
    let originalBytes = Data("old recording".utf8)
    let sidecar = Data("new session state".utf8)
    try originalBytes.write(to: candidate)

    let work = try XCTUnwrap(RecordingCrashRecovery.startRecovery(
      in: processing,
      isPlayable: { _ in
        await Task.yield()
        try files.moveItem(at: old, to: held)
        try files.createDirectory(at: old, withIntermediateDirectories: false)
        try sidecar.write(to: protectedSidecar)
        return true
      },
      destinationFor: { _ in destination },
      deleteSession: { try? files.removeItem(at: $0) }
    ) { _ in })
    await work.value

    XCTAssertEqual(try Data(contentsOf: destination), originalBytes)
    XCTAssertEqual(try Data(contentsOf: protectedSidecar), sidecar)
    XCTAssertTrue(files.fileExists(atPath: held.path))
  }

  func testВосстановлениеВыбираетСледующийСуффиксЕслиИмяЗаняли() async throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent("rec-recovery-name-race-\(UUID().uuidString)")
    let processing = root.appendingPathComponent("processing", isDirectory: true)
    let session = processing.appendingPathComponent("old", isDirectory: true)
    let source = session.appendingPathComponent("capture.mov")
    let initial = root.appendingPathComponent("capture.mov")
    let collision = root.appendingPathComponent("capture_2.mov")
    let destination = root.appendingPathComponent("capture_3.mov")
    try files.createDirectory(at: session, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: root) }
    let recoveredBytes = Data("recovered recording".utf8)
    let initialBytes = Data("existing recording".utf8)
    let collisionBytes = Data("another recording".utf8)
    try recoveredBytes.write(to: source)
    try initialBytes.write(to: initial)

    var recovered: [URL] = []
    let work = try XCTUnwrap(RecordingCrashRecovery.startRecovery(
      in: processing,
      isPlayable: { _ in true },
      destinationFor: { _ in
        let selected = CaptureOutputNaming.makeUniqueFileURL(
          in: root, baseName: "capture", fileExtension: "mov"
        )
        XCTAssertEqual(selected, collision)
        do {
          try collisionBytes.write(to: selected, options: [.withoutOverwriting])
        } catch {
          XCTFail("Не удалось создать файл для коллизии: \(error)")
        }
        return initial
      },
      deleteSession: { try? files.removeItem(at: $0) }
    ) { recovered = $0 })
    await work.value

    XCTAssertEqual(recovered, [destination])
    XCTAssertEqual(try Data(contentsOf: destination), recoveredBytes)
    XCTAssertEqual(try Data(contentsOf: initial), initialBytes)
    XCTAssertEqual(try Data(contentsOf: collision), collisionBytes)
    XCTAssertFalse(files.fileExists(atPath: session.path))
  }

  func testВосстановлениеСохраняетФайлПодменённыйПриВыбореИмени() async throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent("rec-recovery-destination-\(UUID().uuidString)")
    let processing = root.appendingPathComponent("processing", isDirectory: true)
    let session = processing.appendingPathComponent("old", isDirectory: true)
    let source = session.appendingPathComponent("original.mov")
    let held = root.appendingPathComponent("held.mov")
    let destination = root.appendingPathComponent("recovered.mov")
    try files.createDirectory(at: session, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: root) }
    let originalBytes = Data("unfinished recording".utf8)
    let replacementBytes = Data("another recording".utf8)
    try originalBytes.write(to: source)

    let work = try XCTUnwrap(RecordingCrashRecovery.startRecovery(
      in: processing,
      isPlayable: { _ in true },
      destinationFor: { _ in
        do {
          try files.moveItem(at: source, to: held)
          try replacementBytes.write(to: source)
        } catch {
          XCTFail("Не удалось подменить файл: \(error)")
        }
        return destination
      },
      deleteSession: { try? files.removeItem(at: $0) }
    ) { _ in XCTFail("Подменённый файл нельзя публиковать") })
    await work.value

    XCTAssertEqual(try Data(contentsOf: source), replacementBytes)
    XCTAssertEqual(try Data(contentsOf: held), originalBytes)
    XCTAssertFalse(files.fileExists(atPath: destination.path))
  }

  func testОшибкаПереносаСохраняетВосстановимуюСессиюИДанные() async throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent("rec-recovery-move-\(UUID().uuidString)", isDirectory: true)
    defer { try? files.removeItem(at: root) }
    let session = root.appendingPathComponent("old", isDirectory: true)
    let video = session.appendingPathComponent("previous.mov")
    let occupied = root.appendingPathComponent("occupied")
    let destination = occupied.appendingPathComponent("recovered.mov")
    let videoBytes = Data("recoverable video".utf8)
    let existingBytes = Data("existing file".utf8)
    try files.createDirectory(at: session, withIntermediateDirectories: true)
    try videoBytes.write(to: video)
    try existingBytes.write(to: occupied)

    let task = try XCTUnwrap(RecordingCrashRecovery.startRecovery(
      in: root,
      isPlayable: { _ in true },
      destinationFor: { _ in destination },
      deleteSession: { try? files.removeItem(at: $0) }
    ) { _ in
      XCTFail("Перенос не удался")
    })
    await task.value

    XCTAssertEqual(try Data(contentsOf: occupied), existingBytes)
    XCTAssertFalse(files.fileExists(atPath: destination.path))
    XCTAssertTrue(files.fileExists(atPath: session.path))
    XCTAssertEqual(try? Data(contentsOf: video), videoBytes)
  }

  func testОшибкаЧтенияСеансаНеУдаляетЗаписьИДругиеСеансыВосстанавливаются() async throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent("rec-recovery-read-\(UUID().uuidString)", isDirectory: true)
    defer { try? files.removeItem(at: root) }
    let unreadable = root.appendingPathComponent("unreadable", isDirectory: true)
    let normal = root.appendingPathComponent("normal", isDirectory: true)
    let empty = root.appendingPathComponent("empty", isDirectory: true)
    let unreadableVideo = unreadable.appendingPathComponent("untouched.mov")
    let normalVideo = normal.appendingPathComponent("previous.mov")
    let destination = root.appendingPathComponent("recovered.mov")
    let unreadableBytes = Data("unable to list this recording".utf8)
    let normalBytes = Data("recoverable recording".utf8)
    for directory in [unreadable, normal, empty] {
      try files.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    try unreadableBytes.write(to: unreadableVideo)
    try normalBytes.write(to: normalVideo)

    let expectedListings = Dictionary(uniqueKeysWithValues: [(root, 1), (unreadable, 1), (normal, 2), (empty, 2)].map {
      ($0.0.resolvingSymlinksInPath().path, $0.1)
    })
    let unreadablePath = unreadable.resolvingSymlinksInPath().path
    let normalVideoPath = normalVideo.resolvingSymlinksInPath().path

    var listings: [String: Int] = [:]
    var recovered: [URL] = []
    let task = try XCTUnwrap(RecordingCrashRecovery.startRecovery(
      in: root,
      listDirectory: { directory, options in
        let path = directory.resolvingSymlinksInPath().path
        listings[path, default: 0] += 1
        if path == unreadablePath { throw CocoaError(.fileReadNoPermission) }
        return try RecordingCrashRecoveryScanner.listDirectory(directory, options)
      },
      isPlayable: { candidate in
        XCTAssertEqual(candidate.resolvingSymlinksInPath().path, normalVideoPath)
        return true
      },
      destinationFor: { _ in destination },
      deleteSession: { try? files.removeItem(at: $0) }
    ) { recovered = $0 })
    await task.value

    XCTAssertEqual(listings, expectedListings)
    XCTAssertEqual(try? Data(contentsOf: unreadableVideo), unreadableBytes)
    XCTAssertFalse(files.fileExists(atPath: normal.path))
    XCTAssertFalse(files.fileExists(atPath: empty.path))
    XCTAssertEqual(try Data(contentsOf: destination), normalBytes)
    XCTAssertEqual(recovered, [destination])
  }

  func testОшибкаЧтенияКорняНеЗапускаетОчисткуИлиВосстановление() throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent("rec-recovery-root-read-\(UUID().uuidString)", isDirectory: true)
    defer { try? files.removeItem(at: root) }
    let session = root.appendingPathComponent("session", isDirectory: true)
    let candidate = session.appendingPathComponent("previous.mov")
    let bytes = Data("unreadable root recording".utf8)
    try files.createDirectory(at: session, withIntermediateDirectories: true)
    try bytes.write(to: candidate)

    var rootListingCount = 0
    let task = RecordingCrashRecovery.startRecovery(
      in: root,
      listDirectory: { directory, _ in
        XCTAssertEqual(directory.resolvingSymlinksInPath().path, root.resolvingSymlinksInPath().path)
        rootListingCount += 1
        throw CocoaError(.fileReadNoPermission)
      },
      isPlayable: { _ in
        XCTFail("Каталог не удалось прочитать")
        return false
      },
      destinationFor: { $0 },
      deleteSession: { _ in XCTFail("Неизвестный каталог нельзя удалять") }
    ) { _ in XCTFail("Восстановление не запускалось") }

    XCTAssertNil(task)
    XCTAssertEqual(rootListingCount, 1)
    XCTAssertEqual(try Data(contentsOf: candidate), bytes)
  }

  func testОшибкаЧтенияВидеоСохраняетСессиюИНеМешаетДругимЗаписям() async throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent("rec-recovery-inspection-\(UUID().uuidString)", isDirectory: true)
    defer { try? files.removeItem(at: root) }
    let unreadableSession = root.appendingPathComponent("unreadable", isDirectory: true)
    let invalidSession = root.appendingPathComponent("invalid", isDirectory: true)
    let normalSession = root.appendingPathComponent("normal", isDirectory: true)
    let unreadableVideo = unreadableSession.appendingPathComponent("blocked.mov")
    let invalidVideo = invalidSession.appendingPathComponent("invalid.mov")
    let normalVideo = normalSession.appendingPathComponent("normal.mov")
    let destination = root.appendingPathComponent("recovered.mov")
    let unreadableBytes = Data("recording awaiting retry".utf8)
    let normalBytes = Data("playable recording".utf8)
    for session in [unreadableSession, invalidSession, normalSession] {
      try files.createDirectory(at: session, withIntermediateDirectories: true)
    }
    try unreadableBytes.write(to: unreadableVideo)
    try Data("not playable".utf8).write(to: invalidVideo)
    try normalBytes.write(to: normalVideo)

    var inspected: Set<String> = []
    var moved: [String] = []
    var recoveries: [[URL]] = []
    let task = try XCTUnwrap(RecordingCrashRecovery.startRecovery(
      in: root,
      isPlayable: { candidate in
        inspected.insert(candidate.lastPathComponent)
        switch candidate.lastPathComponent {
        case unreadableVideo.lastPathComponent: throw CocoaError(.fileReadNoPermission)
        case invalidVideo.lastPathComponent: return false
        case normalVideo.lastPathComponent: return true
        default:
          XCTFail("Неожиданный файл для проверки")
          return false
        }
      },
      destinationFor: { candidate in
        moved.append(candidate.lastPathComponent)
        return destination
      },
      deleteSession: { try? files.removeItem(at: $0) }
    ) { recoveries.append($0) })
    await task.value

    XCTAssertEqual(inspected, [unreadableVideo.lastPathComponent, invalidVideo.lastPathComponent, normalVideo.lastPathComponent])
    XCTAssertEqual(moved, [normalVideo.lastPathComponent])
    XCTAssertEqual(recoveries, [[destination]])
    XCTAssertFalse(files.fileExists(atPath: invalidSession.path))
    XCTAssertFalse(files.fileExists(atPath: normalSession.path))
    XCTAssertEqual(try Data(contentsOf: destination), normalBytes)
    XCTAssertTrue(files.fileExists(atPath: unreadableSession.path))
    XCTAssertEqual(try? Data(contentsOf: unreadableVideo), unreadableBytes)
  }

  func testФрагментыЗаписиMOV() {
    XCTAssertEqual(CMTimeGetSeconds(ScreenRecordingManager.recordingFragmentInterval), 10, accuracy: 0.001)
  }

  // MARK: - Вспомогательное

  /// Короткий .mov: видео и две аудиодорожки (как микрофон и системный звук).
  private static func writeMovieWithTwoAudioTracks(
    to url: URL, seconds: Int = 1, startRecordingUsing: ((AVAssetWriter) -> Void)? = nil
  ) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let width = 64, height = 64, fps = 10
    let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
    ])
    writer.add(videoInput)
    let audioSettings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
    ]
    let audioInputs = (0..<2).map { _ in AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings) }
    audioInputs.forEach { writer.add($0) }
    if let startRecordingUsing {
      startRecordingUsing(writer)
    } else {
      XCTAssertTrue(writer.startWriting())
    }
    guard writer.status == .writing else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    writer.startSession(atSourceTime: .zero)

    var format = AudioStreamBasicDescription(
      mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
      mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
      mBitsPerChannel: 16, mReserved: 0
    )
    var formatDescription: CMAudioFormatDescription?
    CMAudioFormatDescriptionCreate(
      allocator: nil, asbd: &format, layoutSize: 0, layout: nil,
      magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &formatDescription
    )
    let audioFormat = try XCTUnwrap(formatDescription)

    // Дорожки пишутся вперемешку по времени, иначе писатель ждёт отстающую дорожку.
    func waitReady(_ input: AVAssetWriterInput) async throws {
      var waited = 0
      while !input.isReadyForMoreMediaData {
        waited += 1
        guard waited < 5_000 else { throw XCTSkip("Писатель не принимает данные") }
        try await Task.sleep(nanoseconds: 1_000_000)
      }
    }
    let samplesPerChunk = 1024
    let totalSamples = 48_000 * seconds
    let totalFrames = seconds * fps
    var nextFrame = 0
    var offset = 0
    while offset < totalSamples || nextFrame < totalFrames {
      let chunkTime = Double(offset) / 48_000
      while nextFrame < totalFrames, Double(nextFrame) / Double(fps) <= chunkTime || offset >= totalSamples {
        try await waitReady(videoInput)
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
        adaptor.append(
          try XCTUnwrap(buffer),
          withPresentationTime: CMTime(value: CMTimeValue(nextFrame), timescale: CMTimeScale(fps))
        )
        nextFrame += 1
      }
      guard offset < totalSamples else { continue }
      let count = min(samplesPerChunk, totalSamples - offset)
      for input in audioInputs {
        try await waitReady(input)
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
          allocator: nil, memoryBlock: nil, blockLength: count * 2, blockAllocator: nil,
          customBlockSource: nil, offsetToData: 0, dataLength: count * 2, flags: 0, blockBufferOut: &block
        )
        let blockBuffer = try XCTUnwrap(block)
        CMBlockBufferFillDataBytes(with: 0, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: count * 2)
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
          allocator: nil, dataBuffer: blockBuffer, formatDescription: audioFormat,
          sampleCount: count, presentationTimeStamp: CMTime(value: CMTimeValue(offset), timescale: 48_000),
          packetDescriptions: nil, sampleBufferOut: &sample
        )
        input.append(try XCTUnwrap(sample))
      }
      offset += count
    }
    audioInputs.forEach { $0.markAsFinished() }
    videoInput.markAsFinished()
    if startRecordingUsing == nil {
      await writer.finishWriting()
      XCTAssertEqual(writer.status, .completed)
    }
  }
}
