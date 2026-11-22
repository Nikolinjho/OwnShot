import AVFoundation
import Combine
import SwiftUI
import XCTest
@testable import Snapzy

@MainActor
final class RecordingAudioMixerParityTests: XCTestCase {
  private var directory: URL!
  private var cleanupVideoURLs: [URL] = []

  override func setUp() async throws {
    try await super.setUp()
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("OwnShotAudioMixer_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDown() async throws {
    for url in cleanupVideoURLs {
      if let source = RecordingMetadataStore.load(for: url)?.audioSourceURL {
        try? FileManager.default.removeItem(at: source)
      }
      try? RecordingMetadataStore.delete(for: url)
    }
    try? FileManager.default.removeItem(at: directory)
    try await super.tearDown()
  }

  // MARK: - Громкости

  func testГромкостиЗажимаютсяИДаютЗапасАвтоматическогоСведения() {
    let volumes = RecordingAudioMixerVolumes(microphone: 5, systemAudio: -1)
    XCTAssertEqual(volumes.microphone, 2)
    XCTAssertEqual(volumes.systemAudio, 0)
    XCTAssertEqual(RecordingAudioMixerVolumes.clamped(.nan), 1)
    // 100% совпадает с автоматическим сведением двух дорожек.
    XCTAssertEqual(RecordingAudioMixerVolumes.gain(for: 1), 0.5, accuracy: 0.0001)
    XCTAssertEqual(RecordingAudioMixerVolumes.gain(for: 2), 1, accuracy: 0.0001)
    XCTAssertEqual(RecordingAudioMixerVolumes.percentText(1.234), "123%")
    XCTAssertTrue(RecordingAudioMixerVolumes.default.isOriginal)
    XCTAssertFalse(volumes.isOriginal)
  }

  func testГромкостиРаскладываютсяПоДорожкамРолей() {
    let source = RecordingAudioMixerSource(
      videoURL: URL(fileURLWithPath: "/tmp/a.mov"), sourceURL: URL(fileURLWithPath: "/tmp/a.mov"),
      kind: .separateTracksInVideo, systemAudioTrackID: 2, microphoneTrackID: 3
    )
    let map = RecordingAudioMixerVolumes(microphone: 2, systemAudio: 0.5).trackVolumes(for: source)
    XCTAssertEqual(map[3] ?? -1, 1, accuracy: 0.0001)
    XCTAssertEqual(map[2] ?? -1, 0.25, accuracy: 0.0001)
  }

  // MARK: - Выбор источника

  func testДвеДорожкиВидеоДаютРаздельныйИсточникСистемныйПервым() throws {
    let url = URL(fileURLWithPath: "/tmp/sep.mov")
    let source = try XCTUnwrap(RecordingAudioMixer.resolveSource(
      videoURL: url, videoAudioTrackIDs: [5, 2], metadata: nil, storedSourceAudioTrackIDs: nil
    ))
    XCTAssertEqual(source.kind, .separateTracksInVideo)
    XCTAssertEqual(source.sourceURL, url)
    XCTAssertEqual(source.systemAudioTrackID, 2)
    XCTAssertEqual(source.microphoneTrackID, 5)
  }

  func testСведённоеВидеоБерётСохранённыйИсходникИРолиМетаданных() throws {
    let video = URL(fileURLWithPath: "/tmp/merged.mov")
    let stored = URL(fileURLWithPath: "/tmp/stored.mov")
    let metadata = RecordingMetadata(
      captureSize: CGSize(width: 10, height: 10), samplesPerSecond: 60, mouseSamples: [],
      audioSourceURL: stored, audioSourceTrackRoles: [.systemAudio, .microphone],
      audioSourceTracks: [
        RecordingAudioSourceTrack(trackID: 2, role: .microphone),
        RecordingAudioSourceTrack(trackID: 3, role: .systemAudio),
      ]
    )
    let source = try XCTUnwrap(RecordingAudioMixer.resolveSource(
      videoURL: video, videoAudioTrackIDs: [2], metadata: metadata, storedSourceAudioTrackIDs: [3, 2]
    ))
    XCTAssertEqual(source.kind, .storedAudioSource)
    XCTAssertEqual(source.sourceURL, stored)
    XCTAssertEqual(source.microphoneTrackID, 2)
    XCTAssertEqual(source.systemAudioTrackID, 3)
  }

  func testБезВторойДорожкиСводитьНечего() {
    let url = URL(fileURLWithPath: "/tmp/one.mov")
    XCTAssertNil(RecordingAudioMixer.resolveSource(
      videoURL: url, videoAudioTrackIDs: [2], metadata: nil, storedSourceAudioTrackIDs: nil
    ))
    let metadata = RecordingMetadata(captureSize: .zero, samplesPerSecond: 60, mouseSamples: [])
    XCTAssertNil(RecordingAudioMixer.resolveSource(
      videoURL: url, videoAudioTrackIDs: [], metadata: metadata, storedSourceAudioTrackIDs: [1, 2]
    ))
    XCTAssertNil(RecordingAudioMixer.source(for: directory.appendingPathComponent("missing.mov")))
  }

  func testЗакрытиеБезСведенияСпрашиваетТолькоУРаздельныхДорожек() {
    XCTAssertTrue(RecordingAudioMixerWindowController.shouldConfirmClose(
      kind: .separateTracksInVideo, didSave: false, isSaving: false))
    XCTAssertFalse(RecordingAudioMixerWindowController.shouldConfirmClose(
      kind: .separateTracksInVideo, didSave: true, isSaving: false))
    XCTAssertFalse(RecordingAudioMixerWindowController.shouldConfirmClose(
      kind: .storedAudioSource, didSave: false, isSaving: false))
  }

  // MARK: - Сведение файла

  func testСведениеСГромкостямиДаётОднуДорожкуИСохраняетИсходник() async throws {
    let video = try await makeTwoTrackVideo(named: "two.mov")
    cleanupVideoURLs.append(video)
    XCTAssertTrue(RecordingAudioMixerWindowController.canMix(video))
    let source = try XCTUnwrap(RecordingAudioMixer.source(for: video))
    XCTAssertEqual(source.kind, .separateTracksInVideo)

    do {
      try await RecordingAudioMixer.merge(source, volumes: .default, mono: false)
    } catch {
      XCTFail("merge: \(error)")
      throw error
    }
    let tracks = try await AVURLAsset(url: video).loadTracks(withMediaType: .audio)
    XCTAssertEqual(tracks.count, 1)
    let loudPeak = try await peak(of: video)
    XCTAssertGreaterThan(loudPeak, 0.05)

    // Повторное сведение идёт из сохранённого исходника.
    let metadata = try XCTUnwrap(RecordingMetadataStore.load(for: video))
    XCTAssertEqual(metadata.audioSourceTracks.map(\.role), [.systemAudio, .microphone])
    let again = try XCTUnwrap(RecordingAudioMixer.source(for: video))
    XCTAssertEqual(again.kind, .storedAudioSource)
    try await RecordingAudioMixer.merge(again, volumes: RecordingAudioMixerVolumes(microphone: 0, systemAudio: 0), mono: false)
    let silentPeak = try await peak(of: video)
    XCTAssertLessThan(silentPeak, 0.001)
  }

  func testОтменаСведенияНеТрогаетФайл() async throws {
    let video = try await makeTwoTrackVideo(named: "cancel.mov")
    cleanupVideoURLs.append(video)
    let source = try XCTUnwrap(RecordingAudioMixer.source(for: video))
    let cancellation = RecordingAudioMergeCancellation()
    cancellation.cancel()
    do {
      try await RecordingAudioMixer.merge(source, volumes: .default, mono: false, cancellation: cancellation)
      XCTFail("Ожидалась отмена")
    } catch {}
    let tracks = try await AVURLAsset(url: video).loadTracks(withMediaType: .audio)
    XCTAssertEqual(tracks.count, 2)
    XCTAssertNil(RecordingMetadataStore.load(for: video)?.audioSourceURL)
  }

  // MARK: - Глиф и VU-метр

  func testГлифСоотношенияВКвадрате15pt() {
    XCTAssertEqual(RecordingRatioGlyph.size, 15)
    let bounds = RecordingRatioGlyphShape().path(in: CGRect(x: 0, y: 0, width: 15, height: 15)).boundingRect
    XCTAssertGreaterThan(bounds.minX, 0)
    XCTAssertLessThan(bounds.maxX, 15)
    XCTAssertEqual(bounds.width, 14.23 - 0.77, accuracy: 0.01)
  }

  func testПолоскаVUЗажимаетУровень() {
    XCTAssertEqual(RecordingSetupVUMeterView.fillWidth(level: -1), 0)
    XCTAssertEqual(RecordingSetupVUMeterView.fillWidth(level: 0.5), RecordingSetupVUMeterView.width / 2)
    XCTAssertEqual(RecordingSetupVUMeterView.fillWidth(level: 3), RecordingSetupVUMeterView.width)
  }

  // MARK: - Фикстуры

  private func makeTwoTrackVideo(named name: String) async throws -> URL {
    let audioURL = directory.appendingPathComponent("\(UUID().uuidString).caf")
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
    buffer.frameLength = 48_000
    for channel in 0..<2 {
      let samples = try XCTUnwrap(buffer.floatChannelData?[channel])
      for index in 0..<48_000 {
        samples[index] = Float(sin(Double(index) * 2 * .pi * 440 / 48_000) * 0.4)
      }
    }
    do {
      let file = try AVAudioFile(forWriting: audioURL, settings: format.settings)
      try file.write(from: buffer)
    } catch {
      XCTFail("audio fixture: \(error)")
      throw error
    }
    // Ассеты держатся в переменных: дорожка без живого ассета не вставляется.
    let audioAsset = AVURLAsset(url: audioURL)
    let sourceTracks = try await audioAsset.loadTracks(withMediaType: .audio)
    let sourceTrack = try XCTUnwrap(sourceTracks.first)
    let composition = AVMutableComposition()
    let range = CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 1))
    for _ in 0..<2 {
      let track = try XCTUnwrap(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
      try track.insertTimeRange(range, of: sourceTrack, at: .zero)
    }
    let silentURL = directory.appendingPathComponent("\(UUID().uuidString).mov")
    try await makeVideo(at: silentURL)
    let silentAsset = AVURLAsset(url: silentURL)
    let videoTracks = try await silentAsset.loadTracks(withMediaType: .video)
    let sourceVideoTrack = try XCTUnwrap(videoTracks.first)
    let videoTrack = try XCTUnwrap(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
    try videoTrack.insertTimeRange(range, of: sourceVideoTrack, at: .zero)
    let url = directory.appendingPathComponent(name)
    let exporter = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
    do {
      try await exporter.export(to: url, as: .mov)
    } catch {
      XCTFail("export fixture: \(error)")
      throw error
    }
    return url
  }

  private func makeVideo(at url: URL) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 32, AVVideoHeightKey: 32
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: 32, kCVPixelBufferHeightKey as String: 32
    ])
    writer.add(input)
    XCTAssertTrue(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    for index in 0..<10 {
      while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
      var pixel: CVPixelBuffer?
      XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 32, 32, kCVPixelFormatType_32BGRA, nil, &pixel), kCVReturnSuccess)
      let buffer = try XCTUnwrap(pixel)
      CVPixelBufferLockBaseAddress(buffer, [])
      memset(CVPixelBufferGetBaseAddress(buffer), 255, CVPixelBufferGetDataSize(buffer))
      CVPixelBufferUnlockBaseAddress(buffer, [])
      XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 10)))
    }
    input.markAsFinished()
    writer.endSession(atSourceTime: CMTime(value: 1, timescale: 1))
    await writer.finishWriting()
    XCTAssertEqual(writer.status, .completed)
  }

  /// Пиковая амплитуда первой аудиодорожки в Float32 PCM.
  private func peak(of url: URL) async throws -> Float {
    let asset = AVURLAsset(url: url)
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    let track = try XCTUnwrap(tracks.first)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVLinearPCMBitDepthKey: 32,
      AVLinearPCMIsFloatKey: true,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ])
    reader.add(output)
    XCTAssertTrue(reader.startReading())
    var maxValue: Float = 0
    while let sample = output.copyNextSampleBuffer() {
      guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
      var length = 0
      var pointer: UnsafeMutablePointer<CChar>?
      CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
      guard let pointer else { continue }
      let count = length / MemoryLayout<Float>.size
      pointer.withMemoryRebound(to: Float.self, capacity: count) { floats in
        for index in 0..<count { maxValue = max(maxValue, abs(floats[index])) }
      }
    }
    return maxValue
  }
}

// MARK: - VU-метр панели записи

private final class FakeProbe: RecordingSetupAudioProbe {
  var started = 0
  var stopped = 0
  func start() { started += 1 }
  func stop() { stopped += 1 }
}

private final class FakeProbeFactory: RecordingSetupAudioProbeFactory {
  var microphoneProbes: [(String, FakeProbe)] = []
  var systemProbes: [FakeProbe] = []

  func makeMicrophoneProbe(deviceID: String, meter _: RecordingAudioLevelMeter) -> RecordingSetupAudioProbe? {
    let probe = FakeProbe()
    microphoneProbes.append((deviceID, probe))
    return probe
  }

  func makeSystemAudioProbe(meter _: RecordingAudioLevelMeter) -> RecordingSetupAudioProbe? {
    let probe = FakeProbe()
    systemProbes.append(probe)
    return probe
  }
}

@MainActor
final class RecordingSetupAudioMonitorTests: XCTestCase {
  func testСпросПробЗависитОтКнопокИОткрытойПанели() {
    XCTAssertEqual(
      RecordingSetupAudioMonitor.demand(isActive: true, captureMicrophone: true, microphoneDeviceID: "m", captureSystemAudio: false),
      .init(microphoneDeviceID: "m", systemAudio: false)
    )
    XCTAssertEqual(
      RecordingSetupAudioMonitor.demand(isActive: false, captureMicrophone: true, microphoneDeviceID: "m", captureSystemAudio: true),
      .none
    )
  }

  func testПробыСтартуютИОстанавливаютсяПоСменеКнопок() {
    let factory = FakeProbeFactory()
    let monitor = RecordingSetupAudioMonitor(factory: factory)
    let state = RecordingToolbarState(audioMonitor: monitor)
    state.captureMicrophone = true
    state.microphoneDeviceID = "first"
    state.captureAudio = true
    monitor.observe(state)

    XCTAssertTrue(monitor.isMonitoringMicrophone)
    XCTAssertTrue(monitor.isMonitoringSystemAudio)
    XCTAssertEqual(factory.microphoneProbes.map(\.0), ["first"])
    XCTAssertEqual(factory.systemProbes.first?.started, 1)

    // Смена устройства перезапускает только микрофон.
    state.microphoneDeviceID = "second"
    XCTAssertEqual(factory.microphoneProbes.map(\.0), ["first", "second"])
    XCTAssertEqual(factory.microphoneProbes[0].1.stopped, 1)
    XCTAssertEqual(factory.systemProbes.count, 1)

    state.captureAudio = false
    XCTAssertFalse(monitor.isMonitoringSystemAudio)
    XCTAssertEqual(factory.systemProbes.first?.stopped, 1)

    // Старт записи освобождает микрофон.
    state.isPreparingToRecord = true
    XCTAssertFalse(monitor.isMonitoringMicrophone)
    state.isPreparingToRecord = false
    XCTAssertTrue(monitor.isMonitoringMicrophone)

    monitor.stop()
    XCTAssertFalse(monitor.isMonitoringMicrophone)
    XCTAssertEqual(monitor.demand, .none)
    // После stop подписка снята.
    state.captureAudio = true
    XCTAssertFalse(monitor.isMonitoringSystemAudio)
  }

  func testПодXCTestЖивыеПробыНеСоздаются() {
    let factory = RecordingSetupLiveAudioProbeFactory.makeDefault(environment: ["XCTestConfigurationFilePath": "x"])
    XCTAssertNil(factory.makeMicrophoneProbe(deviceID: "m", meter: RecordingAudioLevelMeter()))
    XCTAssertNil(factory.makeSystemAudioProbe(meter: RecordingAudioLevelMeter()))
  }

  func testЗакрытиеПанелиЗаписиОстанавливаетПробы() {
    let factory = FakeProbeFactory()
    let monitor = RecordingSetupAudioMonitor(factory: factory)
    monitor.apply(.init(microphoneDeviceID: "m", systemAudio: true))
    XCTAssertTrue(monitor.isMonitoringMicrophone)
    monitor.stop()
    XCTAssertEqual(factory.microphoneProbes.first?.1.stopped, 1)
    XCTAssertEqual(factory.systemProbes.first?.stopped, 1)
  }
}
