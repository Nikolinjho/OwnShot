import AVFoundation
import XCTest
@testable import Snapzy

@MainActor
final class OwnShotRecordingAudioIntegrationTests: XCTestCase {
  func testСведениеСоздаётОднуМоноДорожкуАРаздельныйРежимСохраняетДве() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let audioURL = directory.appendingPathComponent("tone.caf")
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
    buffer.frameLength = 48_000
    for channel in 0..<2 {
      let samples = try XCTUnwrap(buffer.floatChannelData?[channel])
      for index in 0..<48_000 {
        samples[index] = Float(sin(Double(index) * 2 * .pi * 440 / 48_000) * 0.1)
      }
    }
    do {
      let file = try AVAudioFile(forWriting: audioURL, settings: format.settings)
      try file.write(from: buffer)
    }
    let source = AVURLAsset(url: audioURL)
    let sourceTracks = try await source.loadTracks(withMediaType: .audio)
    let sourceTrack = try XCTUnwrap(sourceTracks.first)
    let composition = AVMutableComposition()
    for _ in 0..<2 {
      let track = try XCTUnwrap(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
      try track.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 1)), of: sourceTrack, at: .zero)
    }
    let videoURL = directory.appendingPathComponent("silent.mov")
    try await makeVideo(at: videoURL)
    let videoAsset = AVURLAsset(url: videoURL)
    let sourceVideoTracks = try await videoAsset.loadTracks(withMediaType: .video)
    let sourceVideoTrack = try XCTUnwrap(sourceVideoTracks.first)
    let videoTrack = try XCTUnwrap(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
    try videoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 1)), of: sourceVideoTrack, at: .zero)
    let sourceURL = directory.appendingPathComponent("two-tracks.mov")
    let exporter = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
    try await exporter.export(to: sourceURL, as: .mov)
    let tracksBefore = try await AVURLAsset(url: sourceURL).loadTracks(withMediaType: .audio)
    XCTAssertEqual(tracksBefore.count, 2)

    let separate = try await RecordingAudioCompatibilityExporter.normalizeIfNeeded(
      at: sourceURL, fileType: .mov, separateTracks: true
    )
    XCTAssertFalse(separate.didNormalize)
    let separateTracks = try await AVURLAsset(url: separate.outputURL).loadTracks(withMediaType: .audio)
    XCTAssertEqual(separateTracks.count, 2)

    let revision = try XCTUnwrap(CaptureFilePublication.FileRevision(at: sourceURL))
    let mixed = try await RecordingAudioCompatibilityExporter.normalizeIfNeeded(
      at: sourceURL, fileType: .mov, separateTracks: false, mono: true, expectedSourceRevision: revision
    )
    XCTAssertTrue(mixed.didNormalize)
    XCTAssertEqual(try XCTUnwrap(mixed.outputRevision), CaptureFilePublication.FileRevision(at: sourceURL))
    let mixedTracks = try await AVURLAsset(url: mixed.outputURL).loadTracks(withMediaType: .audio)
    XCTAssertEqual(mixedTracks.count, 1)
    let track = try XCTUnwrap(mixedTracks.first)
    let descriptions = try await track.load(.formatDescriptions)
    let description = try XCTUnwrap(descriptions.first)
    let audio = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(description))
    XCTAssertEqual(audio.pointee.mChannelsPerFrame, 1)
    XCTAssertEqual(audio.pointee.mSampleRate, 48_000)
    XCTAssertEqual(audio.pointee.mFormatID, kAudioFormatMPEG4AAC)
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

}
