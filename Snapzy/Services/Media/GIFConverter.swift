//
//  GIFConverter.swift
//  Snapzy
//
//  Converts video files to animated GIF using AVFoundation + ImageIO
//  Optimizes for visual quality while keeping file size reasonable
//  No FFmpeg dependency — pure Apple frameworks
//

import AVFoundation
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Converts a video file to an animated GIF
@MainActor
final class GIFConverter {

  /// GIF generation parameters
  nonisolated struct Options {
    /// Frame rate for the GIF (higher = smoother but larger)
    var fps: Int = 15

    /// Max output width in pixels (source width used if smaller)
    var maxWidth: CGFloat = 800

    /// Infinite loop by default
    var loopCount: Int = 0
    var optimize: Bool = true
    var quality: Double = 1

    /// Ширина пункта Original: больше любого исходника, поэтому масштаб всегда 1.
    nonisolated static let originalWidth: CGFloat = 1_000_000

    /// По умолчанию: 15 кадров/с и ширина не более 800 px.
    nonisolated static let `default` = Options()
  }

  /// Convert a video file to animated GIF
  /// - Parameters:
  ///   - videoURL: URL of the source video
  ///   - options: GIF generation options
  ///   - onProgress: Progress callback (0.0 - 1.0), called on MainActor
  /// - Returns: URL of the generated GIF file
  static func convert(
    videoURL: URL,
    options: Options = .default,
    onProgress: @escaping (Double) -> Void
  ) async throws -> URL {
    let sourceAccess = SandboxFileAccessManager.shared.beginAccessingURL(videoURL)
    let outputDirectoryAccess = SandboxFileAccessManager.shared.beginAccessingURL(
      videoURL.deletingLastPathComponent())
    defer {
      sourceAccess.stop()
      outputDirectoryAccess.stop()
    }
    DiagnosticLogger.shared.log(.info, .recording, "GIF conversion pipeline started", context: [
      "file": videoURL.lastPathComponent,
      "fps": "\(options.fps)",
      "maxWidth": "\(Int(options.maxWidth))",
    ])

    let asset = AVURLAsset(url: videoURL)

    // Get video duration through AVFoundation's async loading API.
    let duration = try await asset.load(.duration)
    let durationSeconds = CMTimeGetSeconds(duration)

    guard durationSeconds > 0, durationSeconds.isFinite else {
      DiagnosticLogger.shared.log(.error, .recording, "GIF conversion invalid video duration", context: [
        "file": videoURL.lastPathComponent,
        "durationSeconds": "\(durationSeconds)",
      ])
      throw GIFConversionError.invalidVideo
    }

    // Get video dimensions for scaling
    let videoTrack = try? await asset.loadTracks(withMediaType: .video).first

    let naturalSize: CGSize
    if let track = videoTrack {
      naturalSize = (try? await track.load(.naturalSize)) ?? CGSize(width: 640, height: 480)
    } else {
      DiagnosticLogger.shared.log(.warning, .recording, "GIF conversion found no video track; using fallback size", context: [
        "file": videoURL.lastPathComponent
      ])
      naturalSize = CGSize(width: 640, height: 480)
    }

    // Ограничение относится к изображению после поворота дорожки.
    let transform = if let track = videoTrack {
      (try? await track.load(.preferredTransform)) ?? .identity
    } else {
      CGAffineTransform.identity
    }
    let displayedSize = CGRect(origin: .zero, size: naturalSize)
      .applying(transform).standardized.size
    // Не увеличиваем исходник. Усечение высоты дополнительно уменьшало ширину
    // генератора: 840×468 превращалось в 798×445 вместо 800×446.
    let scale = min(1.0, options.maxWidth / displayedSize.width)
    let outputWidth = max(1, Int((displayedSize.width * scale).rounded()))
    let outputHeight = max(1, Int((displayedSize.height * scale).rounded()))

    // Calculate frame times
    let totalFrames = Int(ceil(durationSeconds * Double(options.fps)))
    guard totalFrames > 0 else {
      DiagnosticLogger.shared.log(.error, .recording, "GIF conversion has no frame times", context: [
        "durationSeconds": String(format: "%.3f", durationSeconds),
        "fps": "\(options.fps)",
      ])
      throw GIFConversionError.noFrames
    }
    DiagnosticLogger.shared.log(.debug, .recording, "GIF conversion plan", context: [
      "durationSeconds": String(format: "%.3f", durationSeconds),
      "sourceSize": "\(Int(naturalSize.width))x\(Int(naturalSize.height))",
      "outputSize": "\(outputWidth)x\(outputHeight)",
      "expectedFrames": "\(totalFrames)",
    ])

    var frameTimes: [NSValue] = []
    for i in 0..<totalFrames {
      let time = CMTime(
        seconds: Double(i) / Double(options.fps),
        preferredTimescale: 9600  // High timescale for sub-frame precision
      )
      frameTimes.append(NSValue(time: time))
    }

    // Setup image generator with quality-focused settings
    let generator = AVAssetImageGenerator(asset: asset)
    // Запас до ceil не даёт второй стороне преждевременно ограничить масштаб.
    generator.maximumSize = CGSize(width: ceil(displayedSize.width * scale),
                                   height: ceil(displayedSize.height * scale))
    generator.appliesPreferredTrackTransform = true

    // Tight tolerance for accurate frame extraction (reduces ghosting)
    generator.requestedTimeToleranceBefore = CMTime(seconds: 0.02, preferredTimescale: 9600)
    generator.requestedTimeToleranceAfter = CMTime(seconds: 0.02, preferredTimescale: 9600)

    try Task.checkCancellation()
    let outputDirectory = videoURL.deletingLastPathComponent()
    let stagingDirectory = outputDirectory.appendingPathComponent(".ownshot-gif-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: stagingDirectory) }
    let stagedGIF = stagingDirectory.appendingPathComponent("capture.gif")

    // Create GIF destination
    guard let destination = CGImageDestinationCreateWithURL(
      stagedGIF as CFURL,
      UTType.gif.identifier as CFString,
      totalFrames,
      nil
    ) else {
      DiagnosticLogger.shared.log(.error, .recording, "GIF conversion destination creation failed", context: [
        "file": videoURL.lastPathComponent,
        "expectedFrames": "\(totalFrames)",
      ])
      throw GIFConversionError.destinationCreationFailed
    }

    // Set GIF-level properties (loop count + color model)
    let gifProperties: [String: Any] = [
      kCGImagePropertyGIFDictionary as String: [
        kCGImagePropertyGIFLoopCount as String: options.loopCount,
        kCGImagePropertyGIFHasGlobalColorMap as String: true,
      ]
    ]
    CGImageDestinationSetProperties(destination, gifProperties as CFDictionary)

    // Frames are encoded as soon as they arrive, in order, so only a handful of decoded
    // frames are alive at once (ImageIO encodes on add once destination properties are set).
    let framesEqual: ((CGImage, CGImage) -> Bool)?
    if options.optimize {
      framesEqual = { lhs, rhs in
        guard lhs.width == rhs.width, lhs.height == rhs.height else { return false }
        let left = lhs.dataProvider?.data as Data?
        let right = rhs.dataProvider?.data as Data?
        return left != nil && left == right
      }
    } else {
      framesEqual = nil
    }
    let sequencer = GIFFrameSequencer<CGImage>(
      frameDelay: 1.0 / Double(options.fps), framesEqual: framesEqual
    )
    let writer = GIFFrameWriter(destination: destination, sequencer: sequencer, quality: options.quality)
    let expectedCount = frameTimes.count

    // Отмена задачи (вопрос Are you sure you want to stop the conversion?) обрывает
    // генерацию кадров: оставшиеся кадры приходят с результатом cancelled.
    try await withTaskCancellationHandler {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in

      generator.generateCGImagesAsynchronously(forTimes: frameTimes) {
        requestedTime, image, actualTime, result, error in

        // Map frame to its index by matching requested time
        let requestedSeconds = CMTimeGetSeconds(requestedTime)
        let frameIndex = Int(round(requestedSeconds * Double(options.fps)))
        let outputImage = result == .succeeded ? image.flatMap {
          GIFFrameProcessing.resized($0, width: outputWidth, height: outputHeight)
        } : nil
        let completedCount = writer.resolve(index: frameIndex, image: outputImage)

        // Report progress on main thread
        let progress = Double(completedCount) / Double(expectedCount)
        Task { @MainActor in
          onProgress(progress * 0.98)  // Reserve the rest for finalization
        }

        if completedCount == expectedCount {
          writer.finish(frameCount: expectedCount)
          continuation.resume()
        }
      }
    }
    } onCancel: {
      generator.cancelAllCGImageGeneration()
    }

    try Task.checkCancellation()

    let writtenFrames = writer.writtenFrames
    guard writtenFrames > 0 else {
      DiagnosticLogger.shared.log(.error, .recording, "GIF conversion generated no frames", context: [
        "file": videoURL.lastPathComponent,
        "expectedFrames": "\(expectedCount)",
      ])
      throw GIFConversionError.noFrames
    }
    if writtenFrames < totalFrames && !options.optimize {
      DiagnosticLogger.shared.log(.warning, .recording, "GIF conversion generated fewer frames than expected", context: [
        "expectedFrames": "\(totalFrames)",
        "generatedFrames": "\(writtenFrames)",
      ])
    }

    // Finalize GIF
    guard CGImageDestinationFinalize(destination) else {
      DiagnosticLogger.shared.log(.error, .recording, "GIF conversion finalization failed", context: [
        "file": videoURL.lastPathComponent,
        "frames": "\(writtenFrames)",
      ])
      throw GIFConversionError.finalizationFailed
    }

    try Task.checkCancellation()
    let gifURL = try await publishGIF(stagedGIF, beside: videoURL)
    onProgress(1.0)

    let fileSize = (try? FileManager.default.attributesOfItem(atPath: gifURL.path)[.size] as? Int) ?? 0
    let fileSizeMB = String(format: "%.1f", Double(fileSize) / 1_048_576.0)
    DiagnosticLogger.shared.log(.info, .recording, "GIF conversion completed", context: [
      "file": gifURL.lastPathComponent,
      "frames": "\(writtenFrames)",
      "fileSizeMB": fileSizeMB,
    ])

    return gifURL
  }

  /// Publish the complete GIF without replacing any existing directory entry.
  @concurrent nonisolated private static func publishGIF(_ stagedGIF: URL, beside videoURL: URL) async throws -> URL {
    let directory = videoURL.deletingLastPathComponent()
    let baseName = videoURL.deletingPathExtension().lastPathComponent
    var suffix = 1

    while true {
      try Task.checkCancellation()
      let name = suffix == 1 ? baseName : "\(baseName)_\(suffix)"
      let destination = directory.appendingPathComponent("\(name).gif")
      switch CaptureFilePublication.publish(stagedGIF, to: destination, copyFlags: copyfile_flags_t(COPYFILE_DATA)) {
      case .moved, .copied:
        return destination
      case .failed(EEXIST):
        suffix += 1
      case .failed(let error):
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(error), userInfo: [NSFilePathErrorKey: destination.path])
      }
    }
  }
}

// MARK: - Frame Sequencing

/// Orders frames that may arrive out of order and assigns GIF delays. A frame that fails to
/// decode does not shorten the animation: its time is folded into the previous frame's delay.
nonisolated struct GIFFrameSequencer<Frame> {
  struct Output {
    let frame: Frame
    let delay: Double
  }

  let frameDelay: Double
  private let framesEqual: ((Frame, Frame) -> Bool)?
  private var nextIndex = 0
  private var pendingResults: [Int: Frame?] = [:]
  private var held: Output?
  private var leadingMissingDelay = 0.0

  init(frameDelay: Double, framesEqual: ((Frame, Frame) -> Bool)? = nil) {
    self.frameDelay = frameDelay
    self.framesEqual = framesEqual
  }

  /// Records the result for `index` (nil = failed) and returns frames now ready to encode.
  mutating func resolve(index: Int, frame: Frame?) -> [Output] {
    guard index >= nextIndex, pendingResults[index] == nil else { return [] }
    pendingResults[index] = .some(frame)

    var ready: [Output] = []
    while let result = pendingResults.removeValue(forKey: nextIndex) {
      // GIF хранит задержки в сотых секунды. Округляем границы исходной
      // шкалы времени до объединения кадров, чтобы оптимизация не меняла длительность.
      let startCentiseconds = (Double(nextIndex) * frameDelay * 100).rounded()
      let endCentiseconds = (Double(nextIndex + 1) * frameDelay * 100).rounded()
      let encodedDelay = (endCentiseconds - startCentiseconds) / 100
      nextIndex += 1
      guard let frame = result else {
        if let current = held {
          held = Output(frame: current.frame, delay: current.delay + encodedDelay)
        } else {
          leadingMissingDelay += encodedDelay
        }
        continue
      }
      if let current = held {
        if framesEqual?(current.frame, frame) == true {
          held = Output(frame: current.frame, delay: current.delay + encodedDelay)
          continue
        }
        ready.append(current)
      }
      // A run of failures before the first frame stretches the first frame instead.
      held = Output(frame: frame, delay: encodedDelay + leadingMissingDelay)
      leadingMissingDelay = 0
    }
    return ready
  }

  /// Flushes the last held frame. Indices below `frameCount` never resolved count as missing.
  mutating func finish(frameCount: Int) -> [Output] {
    var ready: [Output] = []
    while nextIndex < frameCount {
      ready += resolve(index: nextIndex, frame: nil)
    }
    pendingResults.removeAll()
    if let current = held {
      ready.append(current)
      held = nil
    }
    return ready
  }
}

/// Feeds generator callbacks into a GIF destination; callbacks may come from any thread.
private nonisolated final class GIFFrameWriter: @unchecked Sendable {
  private let lock = NSLock()
  private let destination: CGImageDestination
  private var sequencer: GIFFrameSequencer<CGImage>
  private var completedCount = 0
  private var _writtenFrames = 0
  private let quality: Double

  init(destination: CGImageDestination, sequencer: GIFFrameSequencer<CGImage>, quality: Double) {
    self.destination = destination
    self.sequencer = sequencer
    self.quality = quality
  }

  var writtenFrames: Int {
    lock.withLock { _writtenFrames }
  }

  /// Returns the number of generator results received so far.
  func resolve(index: Int, image: CGImage?) -> Int {
    lock.withLock {
      completedCount += 1
      write(sequencer.resolve(index: index, frame: image.flatMap { GIFFrameProcessing.quantized($0, quality: quality) }))
      return completedCount
    }
  }

  func finish(frameCount: Int) {
    lock.withLock {
      write(sequencer.finish(frameCount: frameCount))
    }
  }

  private func write(_ outputs: [GIFFrameSequencer<CGImage>.Output]) {
    for output in outputs {
      let frameProperties: [String: Any] = [
        kCGImagePropertyGIFDictionary as String: [
          kCGImagePropertyGIFDelayTime as String: output.delay,
          kCGImagePropertyGIFUnclampedDelayTime as String: output.delay,
        ]
      ]
      CGImageDestinationAddImage(destination, output.frame, frameProperties as CFDictionary)
      _writtenFrames += 1
    }
  }
}

// MARK: - Errors

enum GIFConversionError: Error, LocalizedError {
  case invalidVideo
  case noFrames
  case destinationCreationFailed
  case finalizationFailed

  var errorDescription: String? {
    switch self {
    case .invalidVideo: return L10n.GIF.invalidVideo
    case .noFrames: return L10n.GIF.noFramesFromVideo
    case .destinationCreationFailed: return L10n.GIF.cannotCreateOutputFile
    case .finalizationFailed: return L10n.GIF.finalizeFailed
    }
  }
}


nonisolated enum GIFFrameProcessing {
  /// AVAssetImageGenerator округляет размеры самостоятельно. Финальный растр
  /// фиксирует округлённый размер GIF; уже подходящие кадры не перерисовываются.
  static func resized(_ image: CGImage, width: Int, height: Int) -> CGImage? {
    guard image.width != width || image.height != height else { return image }
    let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
      ?? CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(data: nil, width: width, height: height,
      bitsPerComponent: 8, bytesPerRow: 0, space: space,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()
  }

  static func quantized(_ image: CGImage, quality: Double) -> CGImage? {
    guard quality < 1 else { return image }
    guard let context = CGContext(data: nil, width: image.width, height: image.height,
                                  bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let levels = Double(2 + Int(min(1, max(0, quality)) * 14))
    for pixel in 0..<(image.width * image.height) {
      for channel in 0..<3 {
        let offset = pixel * 4 + channel
        bytes[offset] = min(bytes[pixel * 4 + 3], UInt8((Double(bytes[offset]) / 255 * (levels - 1)).rounded() / (levels - 1) * 255))
      }
    }
    return context.makeImage()
  }
}
