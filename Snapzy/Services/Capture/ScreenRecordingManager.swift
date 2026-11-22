//
//  ScreenRecordingManager.swift
//  Snapzy
//
//  Core manager for screen recording functionality using ScreenCaptureKit
//

import AVFoundation
import AppKit
import Combine
import CoreMedia
import Foundation
import ScreenCaptureKit

// MARK: - Video Format

enum VideoFormat: String, CaseIterable, Codable {
  case mov
  case mp4

  var fileType: AVFileType {
    switch self {
    case .mov: return .mov
    case .mp4: return .mp4
    }
  }

  var fileExtension: String { rawValue }

  var displayName: String {
    switch self {
    case .mov: return "MOV"
    case .mp4: return "MP4"
    }
  }
}

// MARK: - Video Quality

enum VideoQuality: String, CaseIterable, Codable {
  case high
  case medium
  case low

  /// Bits-per-pixel-per-frame target for screen content.
  /// Effective bitrate = width * height * fps * bitsPerPixelPerFrame, then clamped.
  var bitsPerPixelPerFrame: Double {
    switch self {
    case .high: return 0.20
    case .medium: return 0.13
    case .low: return 0.08
    }
  }

  /// Floor bitrate (bps) to keep UI/text legible for each preset.
  var minBitrate: Int {
    switch self {
    case .high: return 2_500_000
    case .medium: return 1_600_000
    case .low: return 1_000_000
    }
  }

  /// Cap bitrate (bps) to avoid encoder pressure and editor lag spikes.
  var maxBitrate: Int {
    switch self {
    case .high: return 60_000_000
    case .medium: return 35_000_000
    case .low: return 20_000_000
    }
  }

  /// H.264 profile per preset.
  var h264ProfileLevel: String {
    switch self {
    case .high: return AVVideoProfileLevelH264HighAutoLevel
    case .medium: return AVVideoProfileLevelH264MainAutoLevel
    case .low: return AVVideoProfileLevelH264BaselineAutoLevel
    }
  }

  var displayName: String {
    switch self {
    case .high: return L10n.RecordingToolbar.qualityHigh
    case .medium: return L10n.RecordingToolbar.qualityMedium
    case .low: return L10n.RecordingToolbar.qualityLow
    }
  }
}

enum RecordingMaxResolution: String, CaseIterable, Codable {
  case auto, native, uhd4k, qhd1440, fhd1080, hd720, sd480

  var box: (width: Int, height: Int)? {
    switch self {
    case .auto, .native: return nil
    case .uhd4k: return (3840, 2160)
    case .qhd1440: return (2560, 1440)
    case .fhd1080: return (1920, 1080)
    case .hd720: return (1280, 720)
    case .sd480: return (854, 480)
    }
  }

  var displayName: String {
    switch self {
    case .auto: return L10n.RecordingToolbar.maxResolutionAuto
    case .native: return L10n.RecordingToolbar.maxResolutionNative
    case .uhd4k: return "4K"
    case .qhd1440: return "1440p"
    case .fhd1080: return "1080p"
    case .hd720: return "720p"
    case .sd480: return "480p"
    }
  }
}

enum RecordingVideoEncodingSettings {
  static func preferredCodec(format: VideoFormat, quality: VideoQuality) -> AVVideoCodecType {
    guard format == .mov else { return .h264 }
    guard quality == .high else { return .h264 }
    #if arch(arm64)
      return .hevc
    #else
      return .h264
    #endif
  }

  static func calculatedBitrate(
    width: Int,
    height: Int,
    fps: Int,
    quality: VideoQuality,
    codec: AVVideoCodecType
  ) -> Int {
    let base = Double(width) * Double(height) * Double(fps) * quality.bitsPerPixelPerFrame
    let codecAdjusted = codec == .hevc ? base * 0.90 : base
    let clamped = min(max(codecAdjusted, Double(quality.minBitrate)), Double(quality.maxBitrate))
    return Int(clamped.rounded())
  }

  static func makeVideoSettings(
    width: Int,
    height: Int,
    fps: Int,
    quality: VideoQuality,
    codec: AVVideoCodecType,
    bitrate: Int
  ) -> [String: Any] {
    var compression: [String: Any] = [
      AVVideoAverageBitRateKey: bitrate,
      AVVideoExpectedSourceFrameRateKey: fps,
      AVVideoMaxKeyFrameIntervalKey: fps,
    ]

    if codec == .h264 {
      compression[AVVideoProfileLevelKey] = quality.h264ProfileLevel
    }

    let colorProperties: [String: Any] = [
      AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
      AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
      AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
    ]

    return [
      AVVideoCodecKey: codec,
      AVVideoWidthKey: width,
      AVVideoHeightKey: height,
      AVVideoCompressionPropertiesKey: compression,
      AVVideoColorPropertiesKey: colorProperties,
    ]
  }
}

/// Applies player/upload compatibility limits pre-capture to a stream configuration.
/// `RecordingAudioCompatibilityExporter` handles the same concern post-stop on a
/// finished file; this limiter operates at the opposite end of the pipeline.
/// `.auto` clamps only recordings that would otherwise exceed browser compatibility
/// limits, while `.native` never clamps and remains the deliberate escape hatch.
enum RecordingVideoCompatibilityLimiter {
  static func clampedOutputSize(
    width: Int,
    height: Int,
    resolution: RecordingMaxResolution,
    fps: Int
  ) -> (width: Int, height: Int) {
    if resolution == .auto {
      let maxMB = min(36_864, 2_073_600 / max(fps, 1))
      if macroblockCount(width: width, height: height) <= maxMB { return (width, height) }
      return clampedOutputSize(width: width, height: height, resolution: .uhd4k, fps: fps)
    }

    guard var box = resolution.box else { return (width, height) }

    if height > width {
      box = (box.height, box.width)
    }

    var scale = min(1, Double(box.width) / Double(width), Double(box.height) / Double(height))
    let maxMacroblocks = min(36_864, 2_073_600 / max(fps, 1))

    for _ in 0..<8 {
      let scaledWidth = Int(floor(Double(width) * scale))
      let scaledHeight = Int(floor(Double(height) * scale))
      let macroblocks = macroblockCount(width: scaledWidth, height: scaledHeight)
      guard macroblocks > maxMacroblocks else { break }
      scale *= sqrt(Double(maxMacroblocks) / Double(macroblocks)) * 0.999
    }

    guard scale < 1 else { return (width, height) }
    return (evenFloor(Double(width) * scale), evenFloor(Double(height) * scale))
  }

  private static func macroblockCount(width: Int, height: Int) -> Int {
    ((width + 15) / 16) * ((height + 15) / 16)
  }

  private static func evenFloor(_ value: Double) -> Int {
    max(2, Int(floor(value)) / 2 * 2)
  }
}

nonisolated enum RecordingAudioEncodingSettings {
  static let sampleRate = 48_000
  static let channelCount = 2
  static let systemAudioBitrate = 128_000
  static let microphoneAudioBitrate = 128_000
  static let mixedAudioBitrate = 192_000

  static func makeSystemAudioSettings(mono: Bool = false) -> [String: Any] {
    makeAACSettings(bitrate: systemAudioBitrate, mono: mono)
  }

  static func makeMicrophoneAudioSettings(mono: Bool = false) -> [String: Any] {
    makeAACSettings(bitrate: microphoneAudioBitrate, mono: mono)
  }

  static func makeMixedAudioSettings(mono: Bool = false) -> [String: Any] {
    makeAACSettings(bitrate: mixedAudioBitrate, mono: mono)
  }

  /// LPCM settings for the microphone `AVCaptureAudioDataOutput`.
  ///
  /// Forces AVFoundation to resample the mic to `sampleRate` (48 kHz) at the capture
  /// source, mirroring system audio's `SCStreamConfiguration.sampleRate = 48000`. Without
  /// this, `AVCaptureAudioDataOutput` emits the device-native rate (Bluetooth/HFP mics
  /// negotiate ~16 kHz); appending those buffers unmodified to the 48 kHz AAC writer input
  /// produces spectral imaging above 8 kHz — the piercing artifact.
  ///
  /// `AVNumberOfChannelsKey` is intentionally omitted: the mic stays native mono and the
  /// writer's AAC encoder upmixes mono→stereo exactly as before, so output layout is unchanged.
  static func makeMicrophoneCaptureLPCMSettings() -> [String: Any] {
    [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: sampleRate,
      AVLinearPCMBitDepthKey: 32,
      AVLinearPCMIsFloatKey: true,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ]
  }

  private static func makeAACSettings(bitrate: Int, mono: Bool) -> [String: Any] {
    [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: sampleRate,
      AVNumberOfChannelsKey: mono ? 1 : channelCount,
      AVEncoderBitRateKey: mono ? bitrate / 2 : bitrate,
      AVChannelLayoutKey: channelLayoutData(mono: mono),
    ]
  }

  private static func channelLayoutData(mono: Bool) -> Data {
    var layout = AudioChannelLayout()
    layout.mChannelLayoutTag = mono ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
    return Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
  }
}

enum RecordingAudioCompatibilityExporter {
  struct Result {
    let outputURL: URL
    let audioTrackCount: Int
    let didNormalize: Bool
    let audioSourceURL: URL?
    let audioSourceRevision: CaptureFilePublication.FileRevision?
    let outputRevision: CaptureFilePublication.FileRevision?
  }

  enum ExportError: LocalizedError {
    case missingVideoTrack
    case cannotAddReaderOutput(String)
    case cannotAddWriterInput(String)
    case readerStartFailed(String)
    case writerStartFailed(String)
    case appendFailed(String)
    case readerFailed(String)
    case writerFailed(String)
    case sourceChanged
    /// Пользователь остановил сведение дорожек.
    case cancelled

    var errorDescription: String? {
      switch self {
      case .missingVideoTrack:
        return "Recording audio normalization requires a video track."
      case .cannotAddReaderOutput(let mediaType):
        return "Cannot add \(mediaType) reader output."
      case .cannotAddWriterInput(let mediaType):
        return "Cannot add \(mediaType) writer input."
      case .readerStartFailed(let message):
        return "Audio normalization reader failed to start: \(message)"
      case .writerStartFailed(let message):
        return "Audio normalization writer failed to start: \(message)"
      case .appendFailed(let mediaType):
        return "Audio normalization failed while appending \(mediaType) samples."
      case .readerFailed(let message):
        return "Audio normalization reader failed: \(message)"
      case .writerFailed(let message):
        return "Audio normalization writer failed: \(message)"
      case .sourceChanged:
        return "The recording changed during audio normalization."
      case .cancelled:
        return "Audio normalization cancelled."
      }
    }
  }

  static func requiresMixDown(audioTrackCount: Int, separateTracks: Bool = false) -> Bool {
    !separateTracks && audioTrackCount > 1
  }

  static func mixdownInputVolume(audioTrackCount: Int) -> Float {
    guard audioTrackCount > 1 else { return 1.0 }
    return 1.0 / Float(audioTrackCount)
  }

  static func normalizeIfNeeded(
    at sourceURL: URL,
    fileType: AVFileType,
    preservesAudioSource: Bool = true,
    appliesMixdownHeadroom: Bool = false,
    separateTracks: Bool = false,
    mono: Bool = false,
    cancellation: RecordingAudioMergeCancellation? = nil,
    expectedSourceRevision: CaptureFilePublication.FileRevision? = nil
  ) async throws -> Result {
    try requireRevision(expectedSourceRevision, at: sourceURL)
    let asset = AVURLAsset(url: sourceURL)
    let audioTracks = try await asset.loadTracks(withMediaType: .audio)
    guard requiresMixDown(audioTrackCount: audioTracks.count, separateTracks: separateTracks) else {
      return Result(
        outputURL: sourceURL,
        audioTrackCount: audioTracks.count,
        didNormalize: false,
        audioSourceURL: nil,
        audioSourceRevision: nil,
        outputRevision: expectedSourceRevision
      )
    }

    guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
      throw ExportError.missingVideoTrack
    }

    let duration = try await asset.load(.duration)
    let preferredTransform = try await videoTrack.load(.preferredTransform)
    let sourceFormatHint = try await videoTrack.load(.formatDescriptions).first
    let normalizedURL = normalizedTemporaryURL(for: sourceURL)
    let preservedSourceURL = preservesAudioSource ? preservedAudioSourceTemporaryURL(for: sourceURL) : nil
    let inputVolume = appliesMixdownHeadroom ? mixdownInputVolume(audioTrackCount: audioTracks.count) : 1.0
    var audioSourceRevision: CaptureFilePublication.FileRevision?
    var stagedRevision: CaptureFilePublication.FileRevision?

    do {
      let staged = try await writeNormalizedFile(
        asset: asset,
        videoTrack: videoTrack,
        audioTracks: audioTracks,
        duration: duration,
        preferredTransform: preferredTransform,
        sourceFormatHint: sourceFormatHint,
        outputURL: normalizedURL,
        fileType: fileType,
        audioInputVolumes: Array(repeating: inputVolume, count: audioTracks.count),
        mono: mono,
        cancellation: cancellation
      )
      stagedRevision = staged
      try requireRevision(expectedSourceRevision, at: sourceURL)
      if let preservedSourceURL {
        try FileManager.default.copyItem(at: sourceURL, to: preservedSourceURL)
        audioSourceRevision = CaptureFilePublication.FileRevision(at: preservedSourceURL)
      }

      try requireRevision(staged, at: normalizedURL)
      let outputRevision: CaptureFilePublication.FileRevision?
      if let expectedSourceRevision {
        try CaptureFilePublication.replaceFile(from: normalizedURL, to: sourceURL, expecting: .file(expectedSourceRevision))
        guard let published = CaptureFilePublication.FileRevision(at: sourceURL),
              published.device == staged.device, published.inode == staged.inode else {
          throw ExportError.sourceChanged
        }
        outputRevision = published
      } else {
        _ = try FileManager.default.replaceItemAt(
          sourceURL,
          withItemAt: normalizedURL,
          backupItemName: nil,
          options: []
        )
        outputRevision = nil
      }
      return Result(
        outputURL: sourceURL,
        audioTrackCount: audioTracks.count,
        didNormalize: true,
        audioSourceURL: preservedSourceURL,
        audioSourceRevision: audioSourceRevision,
        outputRevision: outputRevision
      )
    } catch {
      try? stagedRevision?.removeOriginal(at: normalizedURL)
      if let preservedSourceURL, let audioSourceRevision {
        try? audioSourceRevision.removeOriginal(at: preservedSourceURL)
      }
      throw error
    }
  }

  private static func requireRevision(_ expected: CaptureFilePublication.FileRevision?, at url: URL) throws {
    if let expected, CaptureFilePublication.FileRevision(at: url) != expected {
      throw ExportError.sourceChanged
    }
  }

  /// Сведение из окна Audio Mixer: у каждой дорожки свой множитель громкости.
  /// Источник не меняется, результат атомарно заменяет destinationURL
  /// (источник и назначение могут совпадать).
  static func mixTracks(
    from sourceURL: URL,
    into destinationURL: URL,
    fileType: AVFileType,
    volumes: [CMPersistentTrackID: Float],
    mono: Bool = false,
    cancellation: RecordingAudioMergeCancellation? = nil,
    expectedDestinationRevision: CaptureFilePublication.DestinationRevision? = nil
  ) async throws {
    let destinationRevision = try expectedDestinationRevision ?? CaptureFilePublication.DestinationRevision.existing(at: destinationURL)
    let asset = AVURLAsset(url: sourceURL)
    let audioTracks = try await asset.loadTracks(withMediaType: .audio)
      .sorted { $0.trackID < $1.trackID }
    guard !audioTracks.isEmpty else { throw ExportError.cannotAddReaderOutput("audio") }
    guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
      throw ExportError.missingVideoTrack
    }
    let duration = try await asset.load(.duration)
    let preferredTransform = try await videoTrack.load(.preferredTransform)
    let sourceFormatHint = try await videoTrack.load(.formatDescriptions).first
    let mixedURL = normalizedTemporaryURL(for: destinationURL)
    var stagedRevision: CaptureFilePublication.FileRevision?
    do {
      let staged = try await writeNormalizedFile(
        asset: asset,
        videoTrack: videoTrack,
        audioTracks: audioTracks,
        duration: duration,
        preferredTransform: preferredTransform,
        sourceFormatHint: sourceFormatHint,
        outputURL: mixedURL,
        fileType: fileType,
        audioInputVolumes: audioTracks.map { volumes[$0.trackID] ?? 1.0 },
        mono: mono,
        cancellation: cancellation
      )
      stagedRevision = staged
      try requireRevision(staged, at: mixedURL)
      try CaptureFilePublication.replaceFile(from: mixedURL, to: destinationURL, expecting: destinationRevision)
    } catch {
      try? stagedRevision?.removeOriginal(at: mixedURL)
      throw error
    }
  }

  private static func normalizedTemporaryURL(for sourceURL: URL) -> URL {
    let directory = sourceURL.deletingLastPathComponent()
    let baseName = sourceURL.deletingPathExtension().lastPathComponent
    let fileExtension = sourceURL.pathExtension
    return directory
      .appendingPathComponent(".\(baseName)-audio-compatible-\(UUID().uuidString)")
      .appendingPathExtension(fileExtension)
  }

  private static func preservedAudioSourceTemporaryURL(for sourceURL: URL) -> URL {
    let directory = sourceURL.deletingLastPathComponent()
    let baseName = sourceURL.deletingPathExtension().lastPathComponent
    let fileExtension = sourceURL.pathExtension
    return directory
      .appendingPathComponent(".\(baseName)-audio-sources-\(UUID().uuidString)")
      .appendingPathExtension(fileExtension)
  }

  private static func makeReaderAudioSettings(mono: Bool) -> [String: Any] {
    [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: RecordingAudioEncodingSettings.sampleRate,
      AVNumberOfChannelsKey: mono ? 1 : RecordingAudioEncodingSettings.channelCount,
      AVLinearPCMBitDepthKey: 32,
      AVLinearPCMIsFloatKey: true,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ]
  }

  private static func writeNormalizedFile(
    asset: AVAsset,
    videoTrack: AVAssetTrack,
    audioTracks: [AVAssetTrack],
    duration: CMTime,
    preferredTransform: CGAffineTransform,
    sourceFormatHint: CMFormatDescription?,
    outputURL: URL,
    fileType: AVFileType,
    audioInputVolumes: [Float],
    mono: Bool,
    cancellation: RecordingAudioMergeCancellation?
  ) async throws -> CaptureFilePublication.FileRevision {
    // AVFoundation's asset objects are deliberately confined to the serial worker below.
    // The box documents that invariant at the DispatchQueue boundary instead of weakening
    // the whole AVFoundation import with @preconcurrency.
    let inputs = NormalizationAssetInputs(
      asset: asset,
      videoTrack: videoTrack,
      audioTracks: audioTracks
    )

    return try await withCheckedThrowingContinuation { continuation in
      let workerQueue = DispatchQueue(label: "com.trongduong.snapzy.recording.audio-compatibility", qos: .utility)
      workerQueue.async {
        do {
          let revision = try writeNormalizedFileSynchronously(
            asset: inputs.asset,
            videoTrack: inputs.videoTrack,
            audioTracks: inputs.audioTracks,
            duration: duration,
            preferredTransform: preferredTransform,
            sourceFormatHint: sourceFormatHint,
            outputURL: outputURL,
            fileType: fileType,
            audioInputVolumes: audioInputVolumes,
            mono: mono,
            cancellation: cancellation
          )
          continuation.resume(returning: revision)
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  private final class NormalizationAssetInputs: @unchecked Sendable {
    let asset: AVAsset
    let videoTrack: AVAssetTrack
    let audioTracks: [AVAssetTrack]

    init(asset: AVAsset, videoTrack: AVAssetTrack, audioTracks: [AVAssetTrack]) {
      self.asset = asset
      self.videoTrack = videoTrack
      self.audioTracks = audioTracks
    }
  }

  private static func writeNormalizedFileSynchronously(
    asset: AVAsset,
    videoTrack: AVAssetTrack,
    audioTracks: [AVAssetTrack],
    duration: CMTime,
    preferredTransform: CGAffineTransform,
    sourceFormatHint: CMFormatDescription?,
    outputURL: URL,
    fileType: AVFileType,
    audioInputVolumes: [Float],
    mono: Bool,
    cancellation: RecordingAudioMergeCancellation?
  ) throws -> CaptureFilePublication.FileRevision {
    let reader = try AVAssetReader(asset: asset)
    reader.timeRange = CMTimeRange(start: .zero, duration: duration)

    let writer = try AVAssetWriter(outputURL: outputURL, fileType: fileType)
    writer.shouldOptimizeForNetworkUse = fileType == .mp4

    let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
    videoOutput.alwaysCopiesSampleData = false
    guard reader.canAdd(videoOutput) else {
      throw ExportError.cannotAddReaderOutput("video")
    }
    reader.add(videoOutput)

    let videoInput = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: nil,
      sourceFormatHint: sourceFormatHint
    )
    videoInput.expectsMediaDataInRealTime = false
    videoInput.transform = preferredTransform
    guard writer.canAdd(videoInput) else {
      throw ExportError.cannotAddWriterInput("video")
    }
    writer.add(videoInput)

    let audioOutput = AVAssetReaderAudioMixOutput(
      audioTracks: audioTracks,
      audioSettings: makeReaderAudioSettings(mono: mono)
    )
    audioOutput.audioMix = makeAudioMix(for: audioTracks, volumes: audioInputVolumes)
    guard reader.canAdd(audioOutput) else {
      throw ExportError.cannotAddReaderOutput("audio")
    }
    reader.add(audioOutput)

    let audioInput = AVAssetWriterInput(
      mediaType: .audio,
      outputSettings: RecordingAudioEncodingSettings.makeMixedAudioSettings(mono: mono)
    )
    audioInput.expectsMediaDataInRealTime = false
    guard writer.canAdd(audioInput) else {
      throw ExportError.cannotAddWriterInput("audio")
    }
    writer.add(audioInput)

    guard writer.startWriting() else {
      throw ExportError.writerStartFailed(writer.error?.localizedDescription ?? "unknown")
    }
    guard let identity = CaptureFilePublication.SourceIdentity.regularFile(at: outputURL) else {
      throw ExportError.sourceChanged
    }
    var finished = false
    defer {
      if !finished { try? identity.removeOriginal(at: outputURL) }
    }
    guard reader.startReading() else {
      cancelWritingIfOwned(writer, identity: identity)
      throw ExportError.readerStartFailed(reader.error?.localizedDescription ?? "unknown")
    }

    writer.startSession(atSourceTime: .zero)
    try copySamples(
      reader: reader,
      writer: writer,
      outputIdentity: identity,
      outputsAndInputs: [
        ("video", videoOutput, videoInput),
        ("audio", audioOutput, audioInput),
      ],
      cancellation: cancellation
    )

    if reader.status == .failed {
      throw ExportError.readerFailed(reader.error?.localizedDescription ?? "unknown")
    }
    if reader.status == .cancelled {
      throw ExportError.readerFailed("cancelled")
    }

    let finishSemaphore = DispatchSemaphore(value: 0)
    writer.finishWriting {
      finishSemaphore.signal()
    }
    finishSemaphore.wait()

    guard writer.status == .completed else {
      throw ExportError.writerFailed(writer.error?.localizedDescription ?? "unknown")
    }
    guard let revision = CaptureFilePublication.FileRevision(at: outputURL),
          revision.device == identity.device, revision.inode == identity.inode else {
      throw ExportError.sourceChanged
    }
    finished = true
    return revision
  }

  private static func cancelWritingIfOwned(
    _ writer: AVAssetWriter, identity: CaptureFilePublication.SourceIdentity
  ) {
    guard CaptureFilePublication.SourceIdentity.regularFile(at: writer.outputURL) == identity else { return }
    writer.cancelWriting()
  }

  /// Громкость дорожки берётся по индексу, недостающие значения – 1.0.
  private static func makeAudioMix(for audioTracks: [AVAssetTrack], volumes: [Float]) -> AVAudioMix {
    let mix = AVMutableAudioMix()
    mix.inputParameters = audioTracks.enumerated().map { index, track in
      let parameters = AVMutableAudioMixInputParameters(track: track)
      parameters.setVolume(index < volumes.count ? volumes[index] : 1.0, at: .zero)
      return parameters
    }
    return mix
  }

  private static func copySamples(
    reader: AVAssetReader,
    writer: AVAssetWriter,
    outputIdentity: CaptureFilePublication.SourceIdentity,
    outputsAndInputs: [(String, AVAssetReaderOutput, AVAssetWriterInput)],
    cancellation: RecordingAudioMergeCancellation? = nil
  ) throws {
    let group = DispatchGroup()
    let errorLock = NSLock()
    var firstError: Error?

    func recordError(_ error: Error) {
      errorLock.withLock {
        if firstError == nil {
          firstError = error
          reader.cancelReading()
          cancelWritingIfOwned(writer, identity: outputIdentity)
        }
      }
    }

    for (label, output, input) in outputsAndInputs {
      group.enter()
      let queue = DispatchQueue(label: "com.trongduong.snapzy.recording.audio-compatibility.\(label)")
      var didFinish = false

      func finishInput() {
        if !didFinish {
          didFinish = true
          input.markAsFinished()
          group.leave()
        }
      }

      input.requestMediaDataWhenReady(on: queue) {
        while input.isReadyForMoreMediaData {
          if cancellation?.isCancelled == true {
            // Каждый вход завершается сам: cancelWriting здесь мог бы оставить
            // второй вход без вызова блока, и group.wait() не дождался бы его.
            errorLock.withLock {
              if firstError == nil { firstError = ExportError.cancelled }
            }
            finishInput()
            return
          }
          if let sampleBuffer = output.copyNextSampleBuffer() {
            if !input.append(sampleBuffer) {
              recordError(ExportError.appendFailed(label))
              finishInput()
              return
            }
          } else {
            finishInput()
            return
          }
        }
      }
    }

    group.wait()

    if let firstError {
      if case ExportError.cancelled = firstError {
        reader.cancelReading()
        cancelWritingIfOwned(writer, identity: outputIdentity)
      }
      throw firstError
    }
  }
}

// MARK: - Recording State

enum RecordingState: Equatable {
  case idle
  case preparing
  case recording
  case paused
  case stopping

  /// True when the recorder is mid-session and can be paused, resumed, or stopped.
  /// Used by the global pause/resume shortcut to decide whether to dispatch `togglePause()`.
  var isPauseResumeEligible: Bool {
    self == .recording || self == .paused
  }
}

// MARK: - Recording Error

enum RecordingError: Error, LocalizedError {
  case permissionDenied
  case microphonePermissionDenied
  case cameraPermissionDenied
  case noDisplayFound
  case setupFailed(String)
  case writeFailed(String)
  case cancelled
  case alreadyActive

  var errorDescription: String? {
    switch self {
    case .permissionDenied: return L10n.Recording.screenPermissionDenied
    case .microphonePermissionDenied: return L10n.Recording.microphonePermissionDenied
    case .cameraPermissionDenied: return L10n.Camera.recordingMessage
    case .noDisplayFound: return L10n.Recording.noDisplayFound
    case .setupFailed(let msg): return L10n.Recording.setupFailed(msg)
    case .writeFailed(let msg): return L10n.Recording.writeFailed(msg)
    case .cancelled: return L10n.Recording.cancelled
    case .alreadyActive: return L10n.RecordingToolbar.recordingInProgress
    }
  }
}

// MARK: - Screen Recording Manager

@MainActor
final class ScreenRecordingManager: NSObject, ObservableObject {

  static let shared = ScreenRecordingManager()

  /// Шаг фрагментов .mov: при аварии теряется не больше этого отрезка.
  nonisolated static let recordingFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)

  // MARK: - Published State

  @Published private(set) var state: RecordingState = .idle
  @Published private(set) var elapsedSeconds: Int = 0
  @Published private(set) var error: RecordingError?

  var formattedDuration: String {
    let mins = elapsedSeconds / 60
    let secs = elapsedSeconds % 60
    return String(format: "%02d:%02d", mins, secs)
  }

  var isRecording: Bool { state == .recording }
  var isPaused: Bool { state == .paused }
  var isActive: Bool { state != .idle }

  #if DEBUG
  /// Test-only hook: drive `state` without a real capture session so tests can
  /// exercise the real `$state` observation path (KeyboardShortcutManager session
  /// gating re-registers session shortcuts from this publisher).
  func setStateForTesting(_ newState: RecordingState) {
    state = newState
  }
  func prepareWriterForLifecycleTest(
    _ writer: AVAssetWriter, processingSession: RecordingProcessingSession, startsWriting: Bool,
    finalOutput: URL? = nil, requestsAudioMerge: Bool = false
  ) {
    outputURL = writer.outputURL
    finalOutputURL = finalOutput
    captureSystemAudio = requestsAudioMerge
    captureMicrophone = requestsAudioMerge
    separateAudioTracks = false
    recordingProcessingSession = processingSession
    session.assetWriter = writer
    if startsWriting { session.startWriting() }
    state = startsWriting ? .recording : .preparing
  }
  func setupAssetWriterForTesting(at url: URL) throws {
    outputURL = url
    defer {
      outputURL = nil
      session.reset()
    }
    try setupAssetWriter(width: 64, height: 64, captureSystemAudio: false, captureMicrophone: false)
  }
  #endif

  // MARK: - Recording Components

  private var stream: SCStream?
  private var streamDisplayID: Int?
  private var contentFilterRequestID: UUID?
  private var recordingPreparationID: UUID?
  private let session = RecordingSession()  // Thread-safe session for frame writing

  /// Called when ScreenCaptureKit ends the active stream on its own (display
  /// removed, permission revoked) so the owner can stop and save what was recorded.
  var onStreamStoppedUnexpectedly: (() -> Void)?
  /// Сведение микрофона и системного звука началось: владелец показывает
  /// Merging audio... и может отменить его флагом.
  var onAudioMergeWillBegin: ((RecordingAudioMergeCancellation) -> Void)?
  /// Сведение закончилось любым исходом.
  var onAudioMergeDidEnd: (() -> Void)?
  /// Почему последняя остановка оставила дорожки раздельными. nil – свели или сводить не нужно.
  private(set) var lastAudioMergeIssue: RecordingAudioMergeIssue?
  private var microphoneCapturer: MicrophoneAudioCapturer?

  /// Live 0...1 audio level derived read-only from capture buffers; drives the
  /// recording status-bar waveform. Observed directly by the status bar UI.
  let audioLevelMeter = RecordingAudioLevelMeter()

  // MARK: - Timing

  private var timer: Timer?
  private var startTime: Date?
  private var pausedDuration: TimeInterval = 0
  private var pauseStartTime: Date?

  // MARK: - Configuration

  private var recordingRect: CGRect = .zero
  private var videoFormat: VideoFormat = .mov
  private var videoQuality: VideoQuality = .high
  private var fps: Int = 30
  private var maxResolution: RecordingMaxResolution = .auto
  private var captureSystemAudio: Bool = true
  private var captureMicrophone: Bool = false
  private var recordMono = false
  private var separateAudioTracks = false
  private var scaleRetinaTo1x = false
  private var microphoneDeviceID: String?
  private var showCursorInRecording: Bool = true
  private var excludeOwnApplicationFromCapture: Bool = true
  private var excludeDesktopIconsFromCapture: Bool = false
  private var excludeDesktopWidgetsFromCapture: Bool = false
  private var captureWindowTarget: WindowCaptureTarget?
  private var excludedWindowIDs = Set<CGWindowID>()
  private var exceptedWindowIDs = Set<CGWindowID>()
  private var outputURL: URL?
  private var finalOutputURL: URL?
  private var recordingProcessingSession: RecordingProcessingSession?
  private var shouldPreserveProcessingOutputOnCleanup = false
  private var mouseTracker: RecordingMouseTracker?
  private var exportDirectoryAccess: SandboxFileAccessManager.ScopedAccess?
  private var registeredOutputTypes: Set<SCStreamOutputType> = []

  private struct CaptureGeometry {
    let sourceRect: CGRect
    let globalCaptureRect: CGRect
    let nativeOutputWidth: Int
    let nativeOutputHeight: Int
    let outputWidth: Int
    let outputHeight: Int
  }

  // Dedicated queues to avoid audio starvation behind video processing work.
  private let videoProcessingQueue = DispatchQueue(
    label: "com.trongduong.snapzy.recording.video",
    qos: .userInitiated
  )
  private let audioProcessingQueue = DispatchQueue(
    label: "com.trongduong.snapzy.recording.audio",
    qos: .userInteractive
  )
  private let microphoneProcessingQueue = DispatchQueue(
    label: "com.trongduong.snapzy.recording.microphone",
    qos: .userInteractive
  )

  private struct RecordingAudioNormalizationResult {
    let outputURL: URL
    let outputRevision: CaptureFilePublication.FileRevision
    let audioSourceURL: URL?
    let audioSourceRevision: CaptureFilePublication.FileRevision?
  }

  private override init() {
    super.init()
    CaptureChromeWindowRegistry.shared.onChange = { [weak self] in
      self?.scheduleCaptureChromeFilterUpdate()
    }
  }

  // MARK: - Public API

  /// Prepare recording with specified parameters
  func prepareRecording(
    rect: CGRect,
    windowTarget: WindowCaptureTarget? = nil,
    format: VideoFormat = .mov,
    quality: VideoQuality = .high,
    fps: Int = 30,
    maxResolution: RecordingMaxResolution,
    captureSystemAudio: Bool = true,
    captureMicrophone: Bool = false,
    microphoneDeviceID: String? = nil,
    showCursor: Bool = true,
    saveDirectory: URL,
    processingSession: RecordingProcessingSession? = nil,
    fileName: String? = nil,
    excludeDesktopIcons: Bool = false,
    excludeDesktopWidgets: Bool = false,
    excludeOwnApplication: Bool = true,
    excludedWindowIDs: [CGWindowID] = [],
    context: CaptureContext = .empty
  ) async throws {
    // До передачи активному сеансу каталог принадлежит попытке подготовки.
    var unclaimedProcessingSession = processingSession
    defer {
      if let unclaimedProcessingSession,
         unclaimedProcessingSession.directory != recordingProcessingSession?.directory {
        TempCaptureManager.shared.discardRecordingProcessingDirectory(unclaimedProcessingSession)
      }
    }

    guard state == .idle else {
      DiagnosticLogger.shared.log(.debug, .recording, "prepareRecording blocked: recorder busy", context: [
        "state": "\(state)"
      ])
      throw RecordingError.alreadyActive
    }
    let preparationID = UUID()
    recordingPreparationID = preparationID
    defer {
      if recordingPreparationID == preparationID { recordingPreparationID = nil }
    }
    state = .preparing
    error = nil
    session.sessionStarted = false
    session.setMicrophoneID(nil)

    DiagnosticLogger.shared.log(.info, .recording, "Recording prepare started", context: [
      "rect": "\(Int(rect.width))x\(Int(rect.height))",
      "origin": "\(Int(rect.origin.x)),\(Int(rect.origin.y))",
      "windowTarget": windowTarget.map { "\($0.windowID)" } ?? "none",
      "format": format.rawValue,
      "quality": quality.rawValue,
      "fps": "\(fps)",
      "systemAudio": "\(captureSystemAudio)",
      "microphone": "\(captureMicrophone)",
      "microphoneDevice": microphoneDeviceID ?? RecordingMicrophoneDevice.systemDefaultID,
      "showCursor": "\(showCursor)",
      "excludeOwnApp": "\(excludeOwnApplication)",
      "excludeDesktopIcons": "\(excludeDesktopIcons)",
      "excludeDesktopWidgets": "\(excludeDesktopWidgets)",
      "excludedWindows": "\(excludedWindowIDs.count)",
      "saveDirectory": saveDirectory.lastPathComponent,
      "processingDirectory": processingSession?.directory.lastPathComponent ?? "same-as-final",
    ])

    self.videoFormat = format
    self.videoQuality = quality
    self.fps = fps
    self.maxResolution = maxResolution
    self.captureSystemAudio = captureSystemAudio
    self.captureMicrophone = captureMicrophone
    self.recordMono = UserDefaults.standard.bool(forKey: OwnShotRecordingPreferenceKeys.mono)
    self.separateAudioTracks = UserDefaults.standard.bool(forKey: OwnShotRecordingPreferenceKeys.separateTracks)
    self.scaleRetinaTo1x = UserDefaults.standard.bool(forKey: OwnShotRecordingPreferenceKeys.scaleRetina)
    self.microphoneDeviceID = microphoneDeviceID
    self.showCursorInRecording = showCursor
    self.excludeOwnApplicationFromCapture = excludeOwnApplication
    self.excludeDesktopIconsFromCapture = excludeDesktopIcons
    self.excludeDesktopWidgetsFromCapture = excludeDesktopWidgets
    self.captureWindowTarget = windowTarget
    self.excludedWindowIDs = Set(excludedWindowIDs)
    self.exceptedWindowIDs.removeAll()

    let captureManager = ScreenCaptureManager.shared
    await captureManager.checkPermission()
    try validateRecordingPreparation(preparationID)

    if case .notGranted = captureManager.permissionStatus {
      _ = await captureManager.requestPermission()
      try validateRecordingPreparation(preparationID)
    }

    switch captureManager.permissionStatus {
    case .notGranted:
      DiagnosticLogger.shared.log(.warning, .recording, "Recording permission denied")
      state = .idle
      self.error = .permissionDenied
      throw RecordingError.permissionDenied
    case .grantedButUnavailableDueToAppIdentity(let reason):
      DiagnosticLogger.shared.log(.warning, .recording, "Recording permission unavailable for app identity", context: [
        "reason": reason
      ])
      state = .idle
      self.error = .setupFailed(reason)
      throw RecordingError.setupFailed(reason)
    case .granted:
      break
    }

    // Permission is available; now load shareable content for actual setup.
    let content: SCShareableContent
    do {
      content = try await loadShareableContentForCurrentFilters()
    } catch {
      try validateRecordingPreparation(preparationID)
      DiagnosticLogger.shared.logError(.recording, error, "Failed to load shareable content for recording")
      state = .idle
      let message = L10n.Recording.shareableContentLoadFailed(error.localizedDescription)
      self.error = .setupFailed(message)
      throw RecordingError.setupFailed(message)
    }
    try validateRecordingPreparation(preparationID)

    let requestedRect = windowTarget?.frame ?? rect

    let targets = ScreenCaptureManager.captureTargets(for: content.displays)
    guard let index = ScreenCaptureManager.indexOfLargestIntersectingFrame(
      frames: targets.map { $0.screen.frame }, rect: requestedRect
    ) else {
      let failure: RecordingError = targets.isEmpty
        ? .noDisplayFound
        : .setupFailed(L10n.Recording.selectionOutsideDisplayBounds)
      DiagnosticLogger.shared.log(.error, .recording, "Recording display resolution failed", context: [
        "availableDisplays": "\(content.displays.count)",
        "matchingScreens": "\(targets.count)",
      ])
      state = .idle
      self.error = failure
      throw failure
    }

    let (screen, display) = targets[index]
    let scaleFactor = screen.backingScaleFactor
    let overlap = screen.frame.intersection(requestedRect)
    DiagnosticLogger.shared.log(.debug, .recording, "Recording display resolved", context: [
      "targetDisplayID": "\(display.displayID)",
      "bestOverlap": String(format: "%.0f", overlap.width * overlap.height),
      "screenCount": "\(NSScreen.screens.count)",
      "requestedRect": "\(Int(requestedRect.origin.x)),\(Int(requestedRect.origin.y)) \(Int(requestedRect.width))x\(Int(requestedRect.height))",
    ])

    let captureGeometry: CaptureGeometry
    do {
      captureGeometry = try resolveCaptureGeometry(
        display: display,
        rect: requestedRect,
        scaleFactor: scaleFactor,
        maxResolution: maxResolution,
        fps: fps
      )
    } catch {
      DiagnosticLogger.shared.logError(.recording, error, "Recording geometry resolution failed", context: [
        "displayID": "\(display.displayID)",
        "scaleFactor": String(format: "%.2f", scaleFactor),
        "requestedRect": "\(Int(requestedRect.width))x\(Int(requestedRect.height))",
      ])
      cleanup()
      throw error
    }
    self.recordingRect = captureGeometry.globalCaptureRect
    DiagnosticLogger.shared.log(.debug, .recording, "Recording geometry resolved", context: [
      "displayID": "\(display.displayID)",
      "sourceRect": String(
        format: "%.2f,%.2f %.2fx%.2f",
        captureGeometry.sourceRect.origin.x,
        captureGeometry.sourceRect.origin.y,
        captureGeometry.sourceRect.size.width,
        captureGeometry.sourceRect.size.height
      ),
      "nativeSize": "\(captureGeometry.nativeOutputWidth)x\(captureGeometry.nativeOutputHeight)",
      "outputSize": "\(captureGeometry.outputWidth)x\(captureGeometry.outputHeight)",
      "maxResolution": self.maxResolution.rawValue,
      "fps": "\(fps)",
    ])

    // Generate output URL using user-configurable template (with legacy fallback).
    let resolvedFileName = CaptureOutputNaming.resolveBaseName(
      customName: fileName,
      kind: .recording,
      context: context
    )
    exportDirectoryAccess?.stop()
    let directoryAccess = SandboxFileAccessManager.shared.beginAccessingURL(saveDirectory)
    exportDirectoryAccess = directoryAccess

    let scopedSaveDirectory = directoryAccess.url
    let writerDirectory = processingSession?.directory ?? scopedSaveDirectory
    recordingProcessingSession = processingSession
    unclaimedProcessingSession = nil

    do {
      try FileManager.default.createDirectory(at: scopedSaveDirectory, withIntermediateDirectories: true)
      guard processingSession?.isCurrent != false else {
        throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: writerDirectory.path])
      }
    } catch {
      DiagnosticLogger.shared.logError(.recording, error, "Failed to create recording save directory")
      cleanupRecordingProcessingDirectoryIfNeeded()
      exportDirectoryAccess?.stop()
      exportDirectoryAccess = nil
      state = .idle
      self.error = .writeFailed(error.localizedDescription)
      throw RecordingError.writeFailed(error.localizedDescription)
    }

    finalOutputURL = CaptureOutputNaming.makeUniqueFileURL(
      in: scopedSaveDirectory,
      baseName: resolvedFileName,
      fileExtension: format.fileExtension
    )
    if let finalOutputURL {
      do {
        try FileManager.default.createDirectory(
          at: finalOutputURL.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
      } catch {
        DiagnosticLogger.shared.logError(.recording, error, "Failed to create recording output subdirectory")
        cleanupRecordingProcessingDirectoryIfNeeded()
        exportDirectoryAccess?.stop()
        exportDirectoryAccess = nil
        state = .idle
        self.error = .writeFailed(error.localizedDescription)
        throw RecordingError.writeFailed(error.localizedDescription)
      }
    }
    let writerBaseName = finalOutputURL?.deletingPathExtension().lastPathComponent ?? resolvedFileName
    outputURL = CaptureOutputNaming.makeUniqueFileURL(
      in: writerDirectory,
      baseName: writerBaseName,
      fileExtension: format.fileExtension
    )
    DiagnosticLogger.shared.log(.debug, .recording, "Recording output file prepared", context: [
      "file": finalOutputURL?.lastPathComponent ?? "nil",
      "writerFile": outputURL?.lastPathComponent ?? "nil",
      "processingDirectory": writerDirectory.lastPathComponent,
    ])

    do {
      // Setup AVAssetWriter
      try setupAssetWriter(
        width: captureGeometry.outputWidth,
        height: captureGeometry.outputHeight,
        captureSystemAudio: captureSystemAudio,
        captureMicrophone: captureMicrophone
      )

      try await setupStream(
        display: display,
        captureGeometry: captureGeometry,
        captureSystemAudio: captureSystemAudio,
        captureMicrophone: captureMicrophone,
        content: content,
        preparationID: preparationID
      )
      try validateRecordingPreparation(preparationID)

      // Setup independent microphone capture if requested
      if captureMicrophone {
        let capturer = MicrophoneAudioCapturer(preferredDeviceID: microphoneDeviceID)
        capturer.delegate = self
        microphoneCapturer = capturer
        session.setMicrophoneID(ObjectIdentifier(capturer))
      }

      mouseTracker = RecordingMouseTracker(recordingRect: captureGeometry.globalCaptureRect, fps: fps)
      DiagnosticLogger.shared.log(.info, .recording, "Recording prepare completed", context: [
        "file": outputURL?.lastPathComponent ?? "nil",
        "outputSize": "\(captureGeometry.outputWidth)x\(captureGeometry.outputHeight)",
      ])
    } catch {
      try validateRecordingPreparation(preparationID)
      DiagnosticLogger.shared.logError(.recording, error, "Recording preparation failed", context: [
        "stage": "writer-or-stream"
      ])
      cleanup(discardingRecording: true)
      throw error
    }
  }

  /// Start the recording
  func startRecording() async throws {
    guard state == .preparing, !session.isCapturing else {
      DiagnosticLogger.shared.log(.debug, .recording, "startRecording blocked: recorder not prepared", context: [
        "state": "\(state)"
      ])
      throw RecordingError.alreadyActive
    }

    guard let activeStream = stream else { throw RecordingError.cancelled }

    DiagnosticLogger.shared.log(.debug, .recording, "Recording writer start requested")
    session.startWriting()

    // Validate writer status
    guard session.assetWriter?.status == .writing else {
      let errorMsg = session.assetWriter?.error?.localizedDescription ?? L10n.Recording.failedToStartWriting
      if let writerError = session.assetWriter?.error {
        DiagnosticLogger.shared.logError(.recording, writerError, "Recording writer failed to start")
      } else {
        DiagnosticLogger.shared.log(.error, .recording, "Recording writer failed to start", context: [
          "writerStatus": "\(session.assetWriter?.status.rawValue ?? -1)"
        ])
      }
      await cleanUpFailedStart(of: activeStream, reason: errorMsg)
      throw RecordingError.setupFailed(errorMsg)
    }

    // Session will start lazily when first sample buffer arrives
    // This ensures timestamp synchronization with SCStream

    session.isCapturing = true
    let tracker = mouseTracker
    session.setOnFirstVideoFrame { [weak self, weak tracker] in
      Task { @MainActor [weak self, weak tracker] in
        guard let self, let tracker, self.mouseTracker === tracker,
              self.session.isCapturing else { return }
        tracker.start()
        if self.state == .paused { tracker.pause() }
      }
    }

    do {
      try await activeStream.startCapture()
    } catch {
      guard state == .preparing, stream === activeStream else { throw RecordingError.cancelled }
      DiagnosticLogger.shared.logError(.recording, error, "Failed to start stream capture")
      await cleanUpFailedStart(of: activeStream, reason: error.localizedDescription)
      throw RecordingError.setupFailed(error.localizedDescription)
    }

    guard state == .preparing, stream === activeStream else {
      try? await activeStream.stopCapture()
      throw RecordingError.cancelled
    }

    // Start independent microphone capture
    microphoneCapturer?.start()

    state = .recording
    DiagnosticLogger.shared.log(.info, .recording, "Recording started", context: [
      "rect": "\(Int(recordingRect.width))x\(Int(recordingRect.height))",
      "fps": "\(fps)",
      "format": videoFormat.rawValue,
      "systemAudio": "\(captureSystemAudio)",
      "microphone": "\(captureMicrophone)",
      "microphoneDevice": microphoneDeviceID ?? RecordingMicrophoneDevice.systemDefaultID,
    ])
    self.startTime = Date()
    elapsedSeconds = 0
    pausedDuration = 0
    startTimer()
  }

  private func cleanUpFailedStart(of activeStream: SCStream, reason: String) async {
    session.isCapturing = false
    session.setOnFirstVideoFrame(nil)
    error = .setupFailed(reason)
    state = .stopping
    await teardownStream(activeStream)
    session.cancelWriting()
    cleanup(discardingRecording: true)
  }

  /// Pause the recording
  func pauseRecording() {
    guard state == .recording else {
      DiagnosticLogger.shared.log(.debug, .recording, "pauseRecording ignored", context: ["state": "\(state)"])
      return
    }
    // Samples are cut by their own capture timestamps, so frames already in flight when the user
    // clicks pause still land, and frames captured during the pause are dropped even if late.
    session.pause(atHostTime: CMClockGetTime(CMClockGetHostTimeClock()))
    mouseTracker?.pause()
    audioLevelMeter.freeze()
    pauseStartTime = Date()
    state = .paused
    DiagnosticLogger.shared.log(.info, .recording, "Recording paused")
  }

  /// Resume the recording
  func resumeRecording() {
    guard state == .paused, let pauseStart = pauseStartTime else {
      DiagnosticLogger.shared.log(.debug, .recording, "resumeRecording ignored", context: ["state": "\(state)"])
      return
    }
    // Wall-clock duration only drives the elapsed-time label; the writer uses host-clock time.
    pausedDuration += Date().timeIntervalSince(pauseStart)
    pauseStartTime = nil

    let offset = session.resume(atHostTime: CMClockGetTime(CMClockGetHostTimeClock()))
    mouseTracker?.resume()
    audioLevelMeter.unfreeze()
    state = .recording
    DiagnosticLogger.shared.log(.info, .recording, "Recording resumed", context: [
      "pauseOffsetSeconds": String(format: "%.3f", offset.seconds)
    ])
  }

  /// Toggle pause/resume
  /// Здоровье системного звука текущей записи (для Audio Recording Failed).
  func systemAudioHealth() -> RecordingSystemAudioHealth {
    session.systemAudioHealth()
  }

  /// Пишется ли системный звук в текущей записи.
  var isCapturingSystemAudio: Bool { captureSystemAudio }

  func togglePause() {
    if state == .recording {
      pauseRecording()
    } else if state == .paused {
      resumeRecording()
    }
  }

  func addRuntimeExcludedWindow(windowID: CGWindowID) async {
    guard state != .idle else {
      DiagnosticLogger.shared.log(.debug, .recording, "Runtime window exclusion ignored: recorder idle", context: [
        "windowID": "\(windowID)"
      ])
      return
    }
    guard excludedWindowIDs.insert(windowID).inserted else {
      DiagnosticLogger.shared.log(.debug, .recording, "Runtime window exclusion already present", context: [
        "windowID": "\(windowID)"
      ])
      return
    }
    guard let activeStream = stream else {
      DiagnosticLogger.shared.log(.warning, .recording, "Runtime window exclusion skipped: no active stream", context: [
        "windowID": "\(windowID)",
        "state": "\(state)",
      ])
      return
    }
    DiagnosticLogger.shared.log(.debug, .recording, "Runtime window exclusion added", context: [
      "windowID": "\(windowID)",
      "excludedWindows": "\(excludedWindowIDs.count)",
    ])
    await updateContentFilter(for: activeStream)
  }

  func removeRuntimeExcludedWindow(windowID: CGWindowID) async {
    guard state != .idle else {
      DiagnosticLogger.shared.log(.debug, .recording, "Runtime window exclusion removal ignored: recorder idle", context: [
        "windowID": "\(windowID)"
      ])
      return
    }
    guard excludedWindowIDs.remove(windowID) != nil else {
      DiagnosticLogger.shared.log(.debug, .recording, "Runtime window exclusion removal skipped: unknown window", context: [
        "windowID": "\(windowID)"
      ])
      return
    }
    guard let activeStream = stream else {
      DiagnosticLogger.shared.log(.warning, .recording, "Runtime window exclusion removal skipped: no active stream", context: [
        "windowID": "\(windowID)",
        "state": "\(state)",
      ])
      return
    }
    DiagnosticLogger.shared.log(.debug, .recording, "Runtime window exclusion removed", context: [
      "windowID": "\(windowID)",
      "excludedWindows": "\(excludedWindowIDs.count)",
    ])
    await updateContentFilter(for: activeStream)
  }

  /// Stop the recording and save the file
  func stopRecording() async -> URL? {
    guard state == .recording || state == .paused else {
      DiagnosticLogger.shared.log(.debug, .recording, "stopRecording ignored", context: ["state": "\(state)"])
      return nil
    }
    DiagnosticLogger.shared.log(.info, .recording, "Recording stop requested", context: [
      "state": "\(state)",
      "elapsedSeconds": "\(elapsedSeconds)",
      "outputFile": outputURL?.lastPathComponent ?? "nil",
    ])

    session.isCapturing = false
    session.setOnFirstVideoFrame(nil)
    lastAudioMergeIssue = nil

    state = .stopping

    timer?.invalidate()
    timer = nil

    if let activeStream = stream {
      await teardownStream(activeStream)
    }

    microphoneCapturer?.stop()

    session.finishInputs()

    await session.finishWriting()

    let videoWriteStats = session.videoWriteStats()

    let mouseSamples = mouseTracker?.stop() ?? []
    guard let writerURL = outputURL, recordingProcessingSession?.isCurrent != false,
          let revision = session.revisionOfOutput(at: writerURL) else {
      DiagnosticLogger.shared.log(.warning, .recording, "Recording writer output lost before publication")
      cleanup(discardingRecording: true)
      return nil
    }
    await logRecordingFrameDiagnostics(outputURL: writerURL, stats: videoWriteStats)
    guard recordingProcessingSession?.isCurrent != false,
          CaptureFilePublication.FileRevision(at: writerURL) == revision else {
      DiagnosticLogger.shared.log(.warning, .recording, "Recording writer output changed during diagnostics")
      cleanup(discardingRecording: true)
      return nil
    }
    guard let audioNormalization = await normalizeRecordingAudioForCompatibilityIfNeeded(
      writerURL: writerURL, revision: revision
    ) else {
      cleanup(discardingRecording: true)
      return nil
    }
    let editorAudioSourceURL = storeRecordingAudioSourceIfNeeded(
      audioNormalization.audioSourceURL, revision: audioNormalization.audioSourceRevision
    )
    let url = finalizeRecordingOutput(writerURL: audioNormalization.outputURL, revision: audioNormalization.outputRevision)
    outputURL = url
    if let url = url {
      let audioSourceTrackRoles = editorAudioSourceURL == nil ? [] : RecordingAudioSourceTrackRole.roles(
        capturesSystemAudio: captureSystemAudio,
        capturesMicrophone: captureMicrophone
      )
      let audioSourceTracks = await recordingAudioSourceTracks(
        for: editorAudioSourceURL,
        roles: audioSourceTrackRoles
      )
      if mouseSamples.count >= 2 || editorAudioSourceURL != nil {
        do {
          let metadata = RecordingMetadata(
            coordinateSpace: .topLeftNormalized,
            captureSize: recordingRect.size,
            samplesPerSecond: mouseTracker?.samplesPerSecond ?? fps,
            mouseSamples: mouseSamples,
            audioSourceURL: editorAudioSourceURL,
            audioSourceTrackRoles: audioSourceTrackRoles,
            audioSourceTracks: audioSourceTracks
          )
          try RecordingMetadataStore.save(metadata, for: url)
          DiagnosticLogger.shared.log(.info, .recording, "Recording metadata saved", context: [
            "file": url.lastPathComponent,
            "samples": "\(mouseSamples.count)",
            "hasEditorAudioSource": editorAudioSourceURL == nil ? "false" : "true",
            "editorAudioSourceRoles": audioSourceTrackRoles.map(\.rawValue).joined(separator: ","),
            "editorAudioSourceTrackIDs": audioSourceTracks.map { "\($0.trackID):\($0.role.rawValue)" }.joined(separator: ","),
          ])
        } catch {
          DiagnosticLogger.shared.logError(.recording, error, "Failed to save recording metadata")
          deleteStoredRecordingAudioSourceIfUnused(editorAudioSourceURL)
        }
      } else {
        DiagnosticLogger.shared.log(.debug, .recording, "Recording metadata skipped", context: [
          "samples": "\(mouseSamples.count)"
        ])
      }
      if let diagnostics = mouseTracker?.diagnostics {
        DiagnosticLogger.shared.log(.info, .recording, "Mouse tracking diagnostics", context: [
          "samples": "\(diagnostics.sampleCount)",
          "durationSeconds": String(format: "%.3f", diagnostics.duration),
          "effectiveSamplesPerSecond": String(format: "%.2f", diagnostics.effectiveSamplesPerSecond),
          "averageIntervalMs": String(format: "%.2f", diagnostics.averageIntervalMs),
          "p95IntervalMs": String(format: "%.2f", diagnostics.p95IntervalMs),
        ])
      }
      DiagnosticLogger.shared.log(.info, .recording, "Recording stopped: \(url.lastPathComponent) (\(elapsedSeconds)s)")
    } else {
      deleteStoredRecordingAudioSourceIfUnused(editorAudioSourceURL)
      DiagnosticLogger.shared.log(.error, .recording, "Recording stopped without output URL")
    }

    // Reset state
    cleanup()

    return url
  }

  /// Cancel the recording without saving
  func cancelRecording() async {
    guard state != .idle, state != .stopping else {
      DiagnosticLogger.shared.log(.debug, .recording, "cancelRecording ignored", context: ["state": "\(state)"])
      return
    }
    DiagnosticLogger.shared.log(.info, .recording, "Recording cancel requested", context: [
      "state": "\(state)",
      "outputFile": outputURL?.lastPathComponent ?? "nil",
    ])

    state = .stopping
    session.isCapturing = false
    session.setOnFirstVideoFrame(nil)

    timer?.invalidate()
    timer = nil

    if let activeStream = stream {
      await teardownStream(activeStream)
    }

    microphoneCapturer?.stop()
    session.cancelWriting()
    mouseTracker?.reset()
    DiagnosticLogger.shared.log(.info, .recording, "Recording cancelled")
    cleanup(discardingRecording: true)
  }

  // MARK: - Private Methods

  private func validateRecordingPreparation(_ id: UUID) throws {
    guard state == .preparing, recordingPreparationID == id else { throw RecordingError.cancelled }
  }

  private func normalizeRecordingAudioForCompatibilityIfNeeded(
    writerURL: URL, revision: CaptureFilePublication.FileRevision
  ) async -> RecordingAudioNormalizationResult? {
    let original = RecordingAudioNormalizationResult(
      outputURL: writerURL, outputRevision: revision, audioSourceURL: nil, audioSourceRevision: nil
    )

    // Обе дорожки пишутся только при системном звуке и микрофоне вместе.
    let expectsMerge = !separateAudioTracks && captureSystemAudio && captureMicrophone
    if expectsMerge {
      let fileBytes = (try? writerURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
      let available = RecordingDiskSpace.availableBytes(at: writerURL.deletingLastPathComponent())
      guard RecordingAudioMergeDiskPolicy.hasEnoughSpace(sourceFileBytes: fileBytes, availableBytes: available) else {
        // Как audioMixer_disk_error у эталона: запись цела, дорожки остаются раздельными.
        DiagnosticLogger.shared.log(.warning, .recording, "Recording audio merge skipped: low disk space", context: [
          "file": writerURL.lastPathComponent,
          "fileBytes": "\(fileBytes)",
          "availableBytes": available.map { "\($0)" } ?? "nil",
        ])
        lastAudioMergeIssue = .lowDisk
        return original
      }
    }
    let cancellation = RecordingAudioMergeCancellation()
    if expectsMerge { onAudioMergeWillBegin?(cancellation) }
    defer { if expectsMerge { onAudioMergeDidEnd?() } }

    do {
      let result = try await RecordingAudioCompatibilityExporter.normalizeIfNeeded(
        at: writerURL,
        fileType: videoFormat.fileType,
        appliesMixdownHeadroom: true,
        separateTracks: separateAudioTracks,
        mono: recordMono,
        cancellation: cancellation,
        expectedSourceRevision: revision
      )
      guard let outputRevision = result.outputRevision else { return nil }
      if result.didNormalize {
        DiagnosticLogger.shared.log(.info, .recording, "Recording audio normalized for compatibility", context: [
          "file": writerURL.lastPathComponent,
          "sourceAudioTracks": "\(result.audioTrackCount)",
          "outputAudioTracks": "1",
          "audioCodec": "aac-lc",
          "sampleRate": "\(RecordingAudioEncodingSettings.sampleRate)",
          "channels": "\(recordMono ? 1 : RecordingAudioEncodingSettings.channelCount)",
          "mixdownInputVolume": String(
            format: "%.3f",
            RecordingAudioCompatibilityExporter.mixdownInputVolume(audioTrackCount: result.audioTrackCount)
          ),
          "editorAudioSource": result.audioSourceURL?.lastPathComponent ?? "nil",
        ])
      } else {
        DiagnosticLogger.shared.log(.debug, .recording, "Recording audio normalization skipped", context: [
          "file": writerURL.lastPathComponent,
          "audioTracks": "\(result.audioTrackCount)",
        ])
      }
      return RecordingAudioNormalizationResult(
        outputURL: result.outputURL,
        outputRevision: outputRevision,
        audioSourceURL: result.audioSourceURL,
        audioSourceRevision: result.audioSourceRevision
      )
    } catch {
      DiagnosticLogger.shared.log(.warning, .recording, "Recording audio normalization failed; preserving original file", context: [
        "file": writerURL.lastPathComponent,
        "error": error.localizedDescription,
      ])
      guard CaptureFilePublication.FileRevision(at: writerURL) == revision else { return nil }
      if case RecordingAudioCompatibilityExporter.ExportError.cancelled = error {
        lastAudioMergeIssue = .cancelled
      } else {
        lastAudioMergeIssue = .failed
      }
      return original
    }
  }

  private func storeRecordingAudioSourceIfNeeded(
    _ sourceURL: URL?, revision: CaptureFilePublication.FileRevision?
  ) -> URL? {
    guard let sourceURL else { return nil }
    var storedURL: URL?
    do {
      guard let revision, CaptureFilePublication.FileRevision(at: sourceURL) == revision else {
        throw POSIXError(.ESTALE)
      }
      let copy = try RecordingMetadataStore.storeAudioSource(from: sourceURL)
      storedURL = copy
      guard CaptureFilePublication.FileRevision(at: sourceURL) == revision else {
        throw POSIXError(.ESTALE)
      }
      try? revision.removeOriginal(at: sourceURL)
      DiagnosticLogger.shared.log(.info, .recording, "Stored editor audio source", context: [
        "file": copy.lastPathComponent
      ])
      return copy
    } catch {
      deleteStoredRecordingAudioSourceIfUnused(storedURL)
      try? revision?.removeOriginal(at: sourceURL)
      if CaptureFilePublication.SourceIdentity.at(sourceURL) != nil, let recordingProcessingSession {
        TempCaptureManager.shared.discardRecordingProcessingDirectory(recordingProcessingSession)
      }
      DiagnosticLogger.shared.log(.warning, .recording, "Failed to store editor audio source", context: [
        "file": sourceURL.lastPathComponent,
        "error": error.localizedDescription,
      ])
      return nil
    }
  }

  private func deleteStoredRecordingAudioSourceIfUnused(_ sourceURL: URL?) {
    guard let sourceURL else { return }
    do {
      try FileManager.default.removeItem(at: sourceURL)
      DiagnosticLogger.shared.log(.debug, .recording, "Removed unused editor audio source", context: [
        "file": sourceURL.lastPathComponent
      ])
    } catch {
      DiagnosticLogger.shared.log(.warning, .recording, "Failed to remove unused editor audio source", context: [
        "file": sourceURL.lastPathComponent,
        "error": error.localizedDescription,
      ])
    }
  }

  private func recordingAudioSourceTracks(
    for sourceURL: URL?,
    roles: [RecordingAudioSourceTrackRole]
  ) async -> [RecordingAudioSourceTrack] {
    guard let sourceURL, !roles.isEmpty else { return [] }

    do {
      let asset = AVURLAsset(url: sourceURL)
      let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        .sorted { $0.trackID < $1.trackID }
      guard audioTracks.count == roles.count else {
        DiagnosticLogger.shared.log(.warning, .recording, "Editor audio source role count mismatch", context: [
          "file": sourceURL.lastPathComponent,
          "audioTracks": "\(audioTracks.count)",
          "roles": "\(roles.count)",
        ])
        return []
      }

      return zip(audioTracks, roles).map { track, role in
        RecordingAudioSourceTrack(trackID: Int(track.trackID), role: role)
      }
    } catch {
      DiagnosticLogger.shared.log(.warning, .recording, "Failed to inspect editor audio source tracks", context: [
        "file": sourceURL.lastPathComponent,
        "error": error.localizedDescription,
      ])
      return []
    }
  }

  private func finalizeRecordingOutput(writerURL: URL, revision: CaptureFilePublication.FileRevision) -> URL? {
    guard isCurrentRecordingOutput(at: writerURL, revision: revision) else {
      DiagnosticLogger.shared.log(
        .warning,
        .recording,
        "Recording writer output changed before final move",
        context: ["file": writerURL.lastPathComponent]
      )
      cleanupRecordingProcessingDirectoryIfNeeded(preservingUnownedEntries: true)
      return nil
    }

    guard let proposedFinalURL = finalOutputURL else {
      cleanupRecordingProcessingDirectoryIfNeeded()
      return writerURL
    }

    if sameFilePath(writerURL, proposedFinalURL) {
      cleanupRecordingProcessingDirectoryIfNeeded()
      return writerURL
    }

    do {
      let movedURL = try moveRecordingOutput(from: writerURL, to: proposedFinalURL, revision: revision)
      cleanupRecordingProcessingDirectoryIfNeeded(preservingUnownedEntries: true)
      DiagnosticLogger.shared.log(.info, .recording, "Recording output moved to final directory", context: [
        "file": movedURL.lastPathComponent,
        "processingDirectory": writerURL.deletingLastPathComponent().lastPathComponent,
        "finalDirectory": movedURL.deletingLastPathComponent().lastPathComponent,
      ])
      return movedURL
    } catch {
      DiagnosticLogger.shared.logError(
        .recording,
        error,
        "Recording final move failed; attempting temp recovery",
        context: ["file": writerURL.lastPathComponent]
      )
    }

    guard isCurrentRecordingOutput(at: writerURL, revision: revision) else {
      cleanupRecordingProcessingDirectoryIfNeeded(preservingUnownedEntries: true)
      return nil
    }
    let recoveredURL = TempCaptureManager.shared.makeRecoveredRecordingURL(for: writerURL)
    do {
      let movedURL = try moveRecordingOutput(from: writerURL, to: recoveredURL, revision: revision)
      cleanupRecordingProcessingDirectoryIfNeeded(preservingUnownedEntries: true)
      DiagnosticLogger.shared.log(.info, .recording, "Recording output recovered to temp captures", context: [
        "file": movedURL.lastPathComponent
      ])
      return movedURL
    } catch {
      DiagnosticLogger.shared.logError(
        .recording,
        error,
        "Recording temp recovery failed",
        context: ["file": writerURL.lastPathComponent]
      )
      guard isCurrentRecordingOutput(at: writerURL, revision: revision) else {
        cleanupRecordingProcessingDirectoryIfNeeded(preservingUnownedEntries: true)
        return nil
      }
      shouldPreserveProcessingOutputOnCleanup = true
      return writerURL
    }
  }

  private func isCurrentRecordingOutput(at url: URL, revision: CaptureFilePublication.FileRevision) -> Bool {
    recordingProcessingSession?.isCurrent != false
      && CaptureFilePublication.FileRevision(at: url) == revision
  }

  private func moveRecordingOutput(
    from sourceURL: URL, to proposedDestinationURL: URL, revision: CaptureFilePublication.FileRevision
  ) throws -> URL {
    try FileManager.default.createDirectory(
      at: proposedDestinationURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    return try CaptureFilePublication.moveChoosingFreeName(at: sourceURL, to: proposedDestinationURL) { _ in
      guard isCurrentRecordingOutput(at: sourceURL, revision: revision) else {
        throw POSIXError(.ESTALE)
      }
    }
  }

  private func cleanupRecordingProcessingDirectoryIfNeeded(preservingUnownedEntries: Bool = false) {
    guard let processingSession = recordingProcessingSession else { return }
    let directory = processingSession.directory
    defer {
      recordingProcessingSession = nil
      shouldPreserveProcessingOutputOnCleanup = false
    }

    if preservingUnownedEntries {
      TempCaptureManager.shared.discardRecordingProcessingDirectory(processingSession)
      return
    }

    if shouldPreserveProcessingOutputOnCleanup,
       let outputURL,
       isURL(outputURL, inside: directory),
       FileManager.default.fileExists(atPath: outputURL.path)
    {
      DiagnosticLogger.shared.log(
        .warning,
        .recording,
        "Recording processing directory preserved because final output still lives there",
        context: ["file": outputURL.lastPathComponent]
      )
      return
    }

    TempCaptureManager.shared.deleteRecordingProcessingDirectory(processingSession)
  }

  private func sameFilePath(_ lhs: URL, _ rhs: URL) -> Bool {
    lhs.standardizedFileURL.resolvingSymlinksInPath().path
      == rhs.standardizedFileURL.resolvingSymlinksInPath().path
  }

  private func isURL(_ url: URL, inside directory: URL) -> Bool {
    let directoryPath = directory.standardizedFileURL.resolvingSymlinksInPath().path
    let urlPath = url.standardizedFileURL.resolvingSymlinksInPath().path
    return urlPath.hasPrefix(directoryPath + "/")
  }

  private func setupAssetWriter(width: Int, height: Int, captureSystemAudio: Bool, captureMicrophone: Bool) throws {
    guard let url = outputURL else {
      DiagnosticLogger.shared.log(.error, .recording, "Asset writer setup failed: missing output URL")
      throw RecordingError.setupFailed(L10n.Recording.noOutputURL)
    }

    guard !CaptureOutputNaming.isOutputNameTaken(url) else {
      throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: url.path])
    }

    let writer = try AVAssetWriter(outputURL: url, fileType: videoFormat.fileType)
    writer.shouldOptimizeForNetworkUse = videoFormat == .mp4
    if videoFormat == .mov {
      // Фрагменты держат недописанный файл открываемым после аварийного выхода
      // (RecordingCrashRecovery восстановит его при следующем запуске).
      writer.movieFragmentInterval = Self.recordingFragmentInterval
    }
    session.assetWriter = writer
    session.configureExpectedVideoDimensions(width: width, height: height)

    var selectedCodec = preferredVideoCodec()
    var selectedBitrate = calculatedVideoBitrate(width: width, height: height, codec: selectedCodec)
    var videoSettings = makeVideoSettings(
      width: width,
      height: height,
      codec: selectedCodec,
      bitrate: selectedBitrate
    )

    var videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    // If HEVC cannot be added (unsupported path), fallback to H.264.
    if !writer.canAdd(videoIn), selectedCodec == .hevc {
      DiagnosticLogger.shared.log(.warning, .recording, "HEVC writer input unavailable; falling back to H.264", context: [
        "outputSize": "\(width)x\(height)",
        "format": videoFormat.rawValue,
      ])
      selectedCodec = .h264
      selectedBitrate = calculatedVideoBitrate(width: width, height: height, codec: selectedCodec)
      videoSettings = makeVideoSettings(
        width: width,
        height: height,
        codec: selectedCodec,
        bitrate: selectedBitrate
      )
      videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    }

    guard writer.canAdd(videoIn) else {
      DiagnosticLogger.shared.log(.error, .recording, "Cannot add recording video writer input", context: [
        "outputSize": "\(width)x\(height)",
        "format": videoFormat.rawValue,
      ])
      throw RecordingError.setupFailed(L10n.Recording.cannotAddVideoWriterInput)
    }

    videoIn.expectsMediaDataInRealTime = true
    session.videoInput = videoIn
    writer.add(videoIn)
    DiagnosticLogger.shared.log(.info, .recording, "Video encoding settings", context: [
      "codec": selectedCodec == .hevc ? "hevc" : "h264",
      "qualityPreset": videoQuality.rawValue,
      "bitrateBps": "\(selectedBitrate)",
      "fps": "\(fps)",
      "outputSize": "\(width)x\(height)",
    ])

    // Create pixel buffer adaptor for BGRA input from ScreenCaptureKit
    let sourcePixelBufferAttributes: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: width,
      kCVPixelBufferHeightKey as String: height,
    ]
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: videoIn,
      sourcePixelBufferAttributes: sourcePixelBufferAttributes
    )
    session.pixelBufferAdaptor = adaptor

    // Audio settings (AAC) for system audio
    if captureSystemAudio {
      let audioSettings = RecordingAudioEncodingSettings.makeSystemAudioSettings(mono: recordMono)
      let audioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
      audioIn.expectsMediaDataInRealTime = true
      guard writer.canAdd(audioIn) else {
        DiagnosticLogger.shared.log(.error, .recording, "Cannot add system audio writer input")
        throw RecordingError.setupFailed(L10n.Recording.cannotAddSystemAudioWriterInput)
      }
      session.audioInput = audioIn
      writer.add(audioIn)
    }

    // Microphone audio settings (AAC) - separate track
    if captureMicrophone {
      let micSettings = RecordingAudioEncodingSettings.makeMicrophoneAudioSettings(mono: recordMono)
      let micIn = AVAssetWriterInput(mediaType: .audio, outputSettings: micSettings)
      micIn.expectsMediaDataInRealTime = true
      guard writer.canAdd(micIn) else {
        DiagnosticLogger.shared.log(.error, .recording, "Cannot add microphone writer input")
        throw RecordingError.setupFailed(L10n.Recording.cannotAddMicrophoneWriterInput)
      }
      session.microphoneInput = micIn
      writer.add(micIn)
    }
  }

  private func preferredVideoCodec() -> AVVideoCodecType {
    RecordingVideoEncodingSettings.preferredCodec(format: videoFormat, quality: videoQuality)
  }

  private func calculatedVideoBitrate(width: Int, height: Int, codec: AVVideoCodecType) -> Int {
    RecordingVideoEncodingSettings.calculatedBitrate(
      width: width,
      height: height,
      fps: fps,
      quality: videoQuality,
      codec: codec
    )
  }

  private func makeVideoSettings(
    width: Int,
    height: Int,
    codec: AVVideoCodecType,
    bitrate: Int
  ) -> [String: Any] {
    RecordingVideoEncodingSettings.makeVideoSettings(
      width: width,
      height: height,
      fps: fps,
      quality: videoQuality,
      codec: codec,
      bitrate: bitrate
    )
  }

  private func resolveCaptureGeometry(
    display: SCDisplay,
    rect: CGRect,
    scaleFactor: CGFloat,
    maxResolution: RecordingMaxResolution,
    fps: Int
  ) throws -> CaptureGeometry {
    guard let matchingScreen = NSScreen.screens.first(where: {
      Int($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0)
        == display.displayID
    }) else {
      DiagnosticLogger.shared.log(.error, .recording, "Recording geometry failed: no matching NSScreen", context: [
        "displayID": "\(display.displayID)",
        "screens": "\(NSScreen.screens.count)",
      ])
      throw RecordingError.noDisplayFound
    }

    let screenFrame = matchingScreen.frame
    let relativeRect = CGRect(
      x: rect.origin.x - screenFrame.origin.x,
      y: rect.origin.y - screenFrame.origin.y,
      width: rect.width,
      height: rect.height
    )

    let screenBounds = CGRect(x: 0, y: 0, width: screenFrame.width, height: screenFrame.height)
    let clampedRect = relativeRect.intersection(screenBounds)
    guard !clampedRect.isEmpty else {
      DiagnosticLogger.shared.log(.error, .recording, "Recording geometry failed: selection outside display bounds", context: [
        "displayID": "\(display.displayID)",
        "relativeRect": "\(Int(relativeRect.width))x\(Int(relativeRect.height))",
        "screenBounds": "\(Int(screenBounds.width))x\(Int(screenBounds.height))",
      ])
      throw RecordingError.setupFailed(L10n.Recording.selectionOutsideDisplayBounds)
    }

    let alignedRect = pixelAlignedRect(clampedRect, scaleFactor: scaleFactor, bounds: screenBounds)
    guard !alignedRect.isEmpty else {
      DiagnosticLogger.shared.log(.error, .recording, "Recording geometry failed: pixel-aligned rect empty", context: [
        "displayID": "\(display.displayID)",
        "scaleFactor": String(format: "%.2f", scaleFactor),
      ])
      throw RecordingError.setupFailed(L10n.Recording.selectionOutsideDisplayBounds)
    }

    // ScreenCaptureKit sourceRect uses top-left origin relative to display.
    let flippedY = screenFrame.height - alignedRect.origin.y - alignedRect.height
    let sourceRect = CGRect(
      x: alignedRect.origin.x,
      y: flippedY,
      width: alignedRect.width,
      height: alignedRect.height
    )
    let globalCaptureRect = CGRect(
      x: alignedRect.origin.x + screenFrame.origin.x,
      y: alignedRect.origin.y + screenFrame.origin.y,
      width: alignedRect.width,
      height: alignedRect.height
    )

    let nativeOutputWidth = max(1, Int((alignedRect.width * scaleFactor).rounded()))
    let nativeOutputHeight = max(1, Int((alignedRect.height * scaleFactor).rounded()))
    let outputScale = OwnShotRecordingPreferences.outputScale(backingScale: scaleFactor, scaleRetina: scaleRetinaTo1x)
    let outputSize = RecordingVideoCompatibilityLimiter.clampedOutputSize(
      width: max(1, Int((alignedRect.width * outputScale).rounded())),
      height: max(1, Int((alignedRect.height * outputScale).rounded())),
      resolution: maxResolution,
      fps: fps
    )

    return CaptureGeometry(
      sourceRect: sourceRect,
      globalCaptureRect: globalCaptureRect,
      nativeOutputWidth: nativeOutputWidth,
      nativeOutputHeight: nativeOutputHeight,
      outputWidth: outputSize.width,
      outputHeight: outputSize.height
    )
  }

  private func pixelAlignedRect(_ rect: CGRect, scaleFactor: CGFloat, bounds: CGRect) -> CGRect {
    guard scaleFactor > 0 else { return rect.intersection(bounds) }

    let minX = floor(rect.minX * scaleFactor) / scaleFactor
    let minY = floor(rect.minY * scaleFactor) / scaleFactor
    let maxX = ceil(rect.maxX * scaleFactor) / scaleFactor
    let maxY = ceil(rect.maxY * scaleFactor) / scaleFactor

    let aligned = CGRect(
      x: minX,
      y: minY,
      width: max(0, maxX - minX),
      height: max(0, maxY - minY)
    )

    return aligned.intersection(bounds)
  }

  private func setupStream(
    display: SCDisplay,
    captureGeometry: CaptureGeometry,
    captureSystemAudio: Bool,
    captureMicrophone: Bool,
    content: SCShareableContent,
    preparationID: UUID
  ) async throws {
    let filter = makeContentFilter(display: display, content: content)

    let config = SCStreamConfiguration()
    // Higher queue depth helps absorb transient encoder backpressure at 60 FPS.
    config.queueDepth = fps >= 60 ? 8 : 5
    config.width = captureGeometry.outputWidth
    config.height = captureGeometry.outputHeight
    config.scalesToFit = false
    config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
    config.pixelFormat = kCVPixelFormatType_32BGRA
    config.showsCursor = showCursorInRecording
    config.sourceRect = captureGeometry.sourceRect
    let captureResolutionMode: String
    if #available(macOS 14.2, *) {
      config.captureResolution = .best
      captureResolutionMode = "best"
    } else {
      // Fallback for macOS 13/14.0/14.1:
      // rely on explicit output dimensions + pixel-aligned sourceRect.
      captureResolutionMode = "fallback-explicit-dimensions"
    }

    // System audio configuration
    if captureSystemAudio {
      config.capturesAudio = true
      config.excludesCurrentProcessAudio = true
      config.sampleRate = 48000
      config.channelCount = recordMono ? 1 : 2
    }

    // Microphone permission check (captured independently via MicrophoneAudioCapturer)
    if captureMicrophone {
      let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
      switch micStatus {
      case .notDetermined:
        DiagnosticLogger.shared.log(.debug, .recording, "Requesting microphone permission for recording")
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        if !granted {
          DiagnosticLogger.shared.log(.warning, .recording, "Microphone permission denied during request")
          throw RecordingError.microphonePermissionDenied
        }
      case .denied, .restricted:
        DiagnosticLogger.shared.log(.warning, .recording, "Microphone permission unavailable", context: [
          "status": audioAuthorizationStatusLabel(micStatus)
        ])
        throw RecordingError.microphonePermissionDenied
      case .authorized:
        break
      @unknown default:
        DiagnosticLogger.shared.log(.warning, .recording, "Unknown microphone permission status")
        break
      }
    }

    try validateRecordingPreparation(preparationID)
    let captureStream = SCStream(filter: filter, configuration: config, delegate: self)
    var outputs: Set<SCStreamOutputType> = []
    do {
      try captureStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoProcessingQueue)
      outputs.insert(.screen)

      if captureSystemAudio {
        try captureStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioProcessingQueue)
        outputs.insert(.audio)
      }
    } catch {
      for output in outputs {
        try? captureStream.removeStreamOutput(self, type: output)
      }
      throw error
    }

    stream = captureStream
    streamDisplayID = Int(display.displayID)
    session.setStreamID(ObjectIdentifier(captureStream))
    registeredOutputTypes = outputs

    DiagnosticLogger.shared.log(.info, .recording, "Stream configuration", context: [
      "outputSize": "\(captureGeometry.outputWidth)x\(captureGeometry.outputHeight)",
      "fps": "\(fps)",
      "captureResolutionMode": captureResolutionMode,
      "sourceRect": String(
        format: "%.2f,%.2f %.2fx%.2f",
        captureGeometry.sourceRect.origin.x,
        captureGeometry.sourceRect.origin.y,
        captureGeometry.sourceRect.size.width,
        captureGeometry.sourceRect.size.height
      ),
      "systemAudio": "\(captureSystemAudio)",
      "microphone": "\(captureMicrophone)",
      "outputTypes": registeredOutputTypes.map { streamOutputTypeLabel($0) }.sorted().joined(separator: "+"),
    ])
  }

  private func makeContentFilter(display: SCDisplay, content: SCShareableContent) -> SCContentFilter {
    if let captureWindowTarget,
       let primaryWindow = content.windows.first(where: {
         $0.windowID == captureWindowTarget.windowID && $0.isOnScreen
       }) {
      var includedWindows = [primaryWindow]
      includedWindows += content.windows.filter { exceptedWindowIDs.contains($0.windowID) }
      return SCContentFilter(
        display: display,
        including: uniqueWindows(includedWindows)
      )
    }

    if let captureWindowTarget {
      DiagnosticLogger.shared.log(
        .warning,
        .recording,
        "Recording application window missing from shareable content; falling back to rect filter",
        context: ["windowID": "\(captureWindowTarget.windowID)"]
      )
    }

    let iconManager = DesktopIconManager.shared

    if excludeOwnApplicationFromCapture {
      var excludedApps: [SCRunningApplication] = []
      if let bundleID = Bundle.main.bundleIdentifier {
        excludedApps += content.applications.filter { $0.bundleIdentifier == bundleID }
      }

      // Capture overlays (area selection, HUDs, countdown) stay visible in the recording,
      // like CleanShot X. Hidden pooled overlays are listed too, so they are excepted
      // before they first appear and no frames are lost.
      let captureOverlayWindowIDs = CaptureChromeWindowRegistry.shared.windowIDs(roles: [.captureOverlay])
      var exceptedWindows = content.windows.filter {
        exceptedWindowIDs.contains($0.windowID) || captureOverlayWindowIDs.contains($0.windowID)
      }
      if excludeDesktopIconsFromCapture {
        excludedApps += iconManager.getFinderApps(from: content)
        exceptedWindows += iconManager.getVisibleFinderWindows(from: content)
      }
      if excludeDesktopWidgetsFromCapture {
        excludedApps += iconManager.getWidgetApps(from: content)
      }

      return SCContentFilter(
        display: display,
        excludingApplications: uniqueApplications(excludedApps),
        exceptingWindows: uniqueWindows(exceptedWindows)
      )
    }

    // When own-app capture is enabled, desktop icons/widgets still need app-level filtering.
    // Window-level filtering is unreliable for Finder desktop icons on some macOS setups.
    if excludeDesktopIconsFromCapture || excludeDesktopWidgetsFromCapture {
      var excludedApps: [SCRunningApplication] = []
      var exceptedWindows: [SCWindow] = []

      if excludeDesktopIconsFromCapture {
        excludedApps += iconManager.getFinderApps(from: content)
        exceptedWindows += iconManager.getVisibleFinderWindows(from: content)
      }
      if excludeDesktopWidgetsFromCapture {
        excludedApps += iconManager.getWidgetApps(from: content)
      }

      if !excludedApps.isEmpty {
        return SCContentFilter(
          display: display,
          excludingApplications: uniqueApplications(excludedApps),
          exceptingWindows: uniqueWindows(exceptedWindows)
        )
      }
    }

    var excludedWindows = content.windows.filter { excludedWindowIDs.contains($0.windowID) }
    if excludeDesktopIconsFromCapture {
      excludedWindows += iconManager.getDesktopIconWindows(from: content)
    }
    if excludeDesktopWidgetsFromCapture {
      excludedWindows += iconManager.getWidgetWindows(from: content)
    }

    return SCContentFilter(
      display: display,
      excludingWindows: uniqueWindows(excludedWindows)
    )
  }

  private func uniqueWindows(_ windows: [SCWindow]) -> [SCWindow] {
    var seenWindowIDs = Set<CGWindowID>()
    return windows.filter { seenWindowIDs.insert($0.windowID).inserted }
  }

  private func uniqueApplications(_ applications: [SCRunningApplication]) -> [SCRunningApplication] {
    var seenBundleIDs = Set<String>()
    var uniqueApps: [SCRunningApplication] = []

    for application in applications {
      let bundleID = application.bundleIdentifier
      guard seenBundleIDs.insert(bundleID).inserted else { continue }
      uniqueApps.append(application)
    }

    return uniqueApps
  }

  private func loadShareableContentForCurrentFilters() async throws -> SCShareableContent {
    let requiresDesktopWindowEnumeration = excludeDesktopIconsFromCapture || excludeDesktopWidgetsFromCapture
    if requiresDesktopWindowEnumeration {
      // Finder/widget exclusion needs desktop windows in the shareable snapshot. Off-screen
      // windows are listed so hidden capture overlays can be excepted up front; the
      // desktop icon/widget helpers only pick on-screen windows.
      return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    }

    return try await SCShareableContent.current
  }

  private func updateContentFilter(for activeStream: SCStream) async {
    guard state != .idle, state != .stopping,
          stream === activeStream, let displayID = streamDisplayID else { return }
    let requestID = UUID()
    contentFilterRequestID = requestID
    do {
      let content = try await loadShareableContentForCurrentFilters()
      guard state != .idle, state != .stopping,
            stream === activeStream, contentFilterRequestID == requestID else { return }
      guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
        DiagnosticLogger.shared.log(.warning, .recording, "Recording content filter update skipped: no current display", context: [
          "displayID": "\(displayID)",
          "displays": "\(content.displays.count)",
          "windows": "\(content.windows.count)",
        ])
        return
      }
      let filter = makeContentFilter(display: display, content: content)
      try await activeStream.updateContentFilter(filter)
      DiagnosticLogger.shared.log(.debug, .recording, "Recording content filter updated", context: [
        "displayID": "\(display.displayID)",
        "excludedWindows": "\(excludedWindowIDs.count)",
        "exceptedWindows": "\(exceptedWindowIDs.count)",
      ])
    } catch {
      DiagnosticLogger.shared.logError(.recording, error, "Failed to update recording content filter")
    }
  }

  private func startTimer() {
    timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.updateElapsedTime()
      }
    }
  }

  private func updateElapsedTime() {
    guard let start = startTime, state == .recording else { return }
    elapsedSeconds = Int(Date().timeIntervalSince(start) - pausedDuration)
  }

  private func logRecordingFrameDiagnostics(outputURL: URL?, stats: RecordingSession.VideoWriteStats) async {
    guard stats.receivedFrames > 0 || outputURL != nil else { return }

    let droppedFrames = stats.droppedFramesDueToBackpressure + stats.failedAppendFrames
    let dropRate = stats.receivedFrames > 0
      ? (Double(droppedFrames) / Double(stats.receivedFrames)) * 100
      : 0

    var context: [String: String] = [
      "configuredFPS": "\(fps)",
      "receivedFrames": "\(stats.receivedFrames)",
      "appendedFrames": "\(stats.appendedFrames)",
      "droppedBackpressure": "\(stats.droppedFramesDueToBackpressure)",
      "failedAppend": "\(stats.failedAppendFrames)",
      "dropRatePercent": String(format: "%.2f", dropRate),
      "microphoneSamplesReceived": "\(stats.microphoneSamplesReceived)",
      "microphoneSamplesAppended": "\(stats.microphoneSamplesAppended)",
    ]

    if let outputURL {
      context["outputFile"] = outputURL.lastPathComponent
      context["outputExists"] = "\(FileManager.default.fileExists(atPath: outputURL.path))"
      if let size = try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int {
        context["outputSizeBytes"] = "\(size)"
      }
      let asset = AVURLAsset(url: outputURL)
      if let track = try? await asset.loadTracks(withMediaType: .video).first {
        let nominalFrameRate = (try? await track.load(.nominalFrameRate)) ?? 0
        if nominalFrameRate > 0 {
          context["outputNominalFPS"] = String(format: "%.2f", nominalFrameRate)
        }

        let minFrameDuration = try? await track.load(.minFrameDuration)
        if let minFrameDuration,
           minFrameDuration.isValid,
           minFrameDuration.seconds > 0 {
          context["outputFrameDurationMs"] = String(format: "%.2f", minFrameDuration.seconds * 1000)
        }
      }
      if let audioTracks = try? await asset.loadTracks(withMediaType: .audio) {
        context["outputAudioTracks"] = "\(audioTracks.count)"
      }
    }

    DiagnosticLogger.shared.log(.info, .recording, "Recording frame diagnostics", context: context)
  }

  private func cleanup(discardingRecording: Bool = false) {
    recordingPreparationID = nil
    timer?.invalidate()
    timer = nil
    startTime = nil
    pauseStartTime = nil
    pausedDuration = 0
    exportDirectoryAccess?.stop()
    exportDirectoryAccess = nil
    registeredOutputTypes.removeAll()
    excludedWindowIDs.removeAll()
    exceptedWindowIDs.removeAll()
    captureWindowTarget = nil
    session.setOnFirstVideoFrame(nil)
    microphoneDeviceID = nil
    showCursorInRecording = true
    excludeOwnApplicationFromCapture = true
    excludeDesktopIconsFromCapture = false
    excludeDesktopWidgetsFromCapture = false
    mouseTracker = nil
    microphoneCapturer = nil
    audioLevelMeter.reset()
    session.reset()
    cleanupRecordingProcessingDirectoryIfNeeded(preservingUnownedEntries: discardingRecording)
    finalOutputURL = nil
    outputURL = nil
    state = .idle
    elapsedSeconds = 0
  }

  private func teardownStream(_ activeStream: SCStream) async {
    // Remove outputs first so SCStream can release pipeline buffers immediately.
    for outputType in registeredOutputTypes {
      do {
        try activeStream.removeStreamOutput(self, type: outputType)
      } catch {
        DiagnosticLogger.shared.logError(.recording, error, "Failed to remove recording stream output", context: [
          "type": streamOutputTypeLabel(outputType)
        ])
      }
    }
    registeredOutputTypes.removeAll()

    do {
      try await activeStream.stopCapture()
    } catch {
      DiagnosticLogger.shared.logError(.recording, error, "Failed to stop recording stream during teardown")
    }

    stream = nil
    streamDisplayID = nil
    contentFilterRequestID = nil
  }

  private var isCaptureChromeFilterUpdatePending = false

  /// Coalesces capture chrome registrations (e.g. a smart element overlay created mid-recording)
  /// into one content filter update so the new overlay shows up in the recording.
  private func scheduleCaptureChromeFilterUpdate() {
    guard state != .idle, stream != nil, !isCaptureChromeFilterUpdatePending else { return }
    isCaptureChromeFilterUpdatePending = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      self.isCaptureChromeFilterUpdatePending = false
      guard self.state != .idle, let activeStream = self.stream else { return }
      await self.updateContentFilter(for: activeStream)
    }
  }

  /// Add a window to the active recording filter.
  /// In display capture this behaves as an "excepted" window. In application capture
  /// it becomes an extra included overlay window so annotation/click effects stay visible.
  func addExceptedWindow(windowID: CGWindowID) async {
    guard let activeStream = stream else {
      DiagnosticLogger.shared.log(.warning, .recording, "Excepted recording window skipped: no active stream", context: [
        "windowID": "\(windowID)"
      ])
      return
    }
    guard captureWindowTarget != nil || excludeOwnApplicationFromCapture else {
      DiagnosticLogger.shared.log(.debug, .recording, "Excepted recording window skipped: own app is included", context: [
        "windowID": "\(windowID)"
      ])
      return
    }

    exceptedWindowIDs.insert(windowID)
    DiagnosticLogger.shared.log(.debug, .recording, "Excepted recording window added", context: [
      "windowID": "\(windowID)",
      "exceptedWindows": "\(exceptedWindowIDs.count)",
    ])
    await updateContentFilter(for: activeStream)
  }

  private func audioAuthorizationStatusLabel(_ status: AVAuthorizationStatus) -> String {
    switch status {
    case .notDetermined: return "notDetermined"
    case .restricted: return "restricted"
    case .denied: return "denied"
    case .authorized: return "authorized"
    @unknown default: return "unknown"
    }
  }

  private func streamOutputTypeLabel(_ type: SCStreamOutputType) -> String {
    switch type {
    case .screen: return "screen"
    case .audio: return "audio"
    case .microphone: return "microphone"
    @unknown default: return "unknown"
    }
  }
}

// MARK: - MicrophoneAudioCapturerDelegate

extension ScreenRecordingManager: MicrophoneAudioCapturerDelegate {
  nonisolated func microphoneCapturer(_ capturer: MicrophoneAudioCapturer, didOutput sampleBuffer: CMSampleBuffer) {
    let source = RecordingSession.Source.microphone(ObjectIdentifier(capturer))
    guard sampleBuffer.isValid, session.acceptsSamples(from: source) else { return }
    session.appendMicrophoneSample(sampleBuffer, from: source)
    audioLevelMeter.ingest(sampleBuffer, source: .microphone)
  }
}

// MARK: - SCStreamOutput

extension ScreenRecordingManager: SCStreamOutput {
  nonisolated func stream(
    _ stream: SCStream,
    didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    autoreleasepool {
      let source = RecordingSession.Source.stream(ObjectIdentifier(stream))
      guard sampleBuffer.isValid, session.acceptsSamples(from: source) else { return }

      // Write frames using the thread-safe session (no @MainActor crossing)
      switch type {
      case .screen:
        session.appendVideoSample(sampleBuffer, from: source)
      case .audio:
        session.appendAudioSample(sampleBuffer, from: source)
        audioLevelMeter.ingest(sampleBuffer, source: .system)
      case .microphone:
        session.appendMicrophoneSample(sampleBuffer, from: source)
        audioLevelMeter.ingest(sampleBuffer, source: .microphone)
      @unknown default:
        break
      }
    }
  }
}

// MARK: - SCStreamDelegate

extension ScreenRecordingManager: SCStreamDelegate {
  nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
    DiagnosticLogger.shared.logError(.recording, error, "Screen recording stream stopped unexpectedly")
    // No more frames will arrive: stop instead of showing a live recording
    // that silently writes nothing.
    let stoppedStreamID = ObjectIdentifier(stream)
    Task { @MainActor [weak self] in
      guard let self,
            let activeStream = self.stream,
            ObjectIdentifier(activeStream) == stoppedStreamID,
            self.state.isPauseResumeEligible else { return }
      self.onStreamStoppedUnexpectedly?()
    }
  }
}
