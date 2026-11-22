//
//  GIFResizer.swift
//  Snapzy
//
//  Resizes and trims animated GIF files using ImageIO
//  Preserves frame delays, loop count, and animation metadata
//

import CoreGraphics
import Foundation
import ImageIO
import os.log
import UniformTypeIdentifiers

private nonisolated let logger = Logger(subsystem: "Snapzy", category: "GIFResizer")

/// Resizes and trims an animated GIF using ImageIO
@MainActor
final class GIFResizer {
  /// Export a GIF at the specified dimensions, optionally trimming its timeline.
  /// Frames are decoded and redrawn off the main actor.
  /// - Parameters:
  ///   - sourceURL: URL of the source GIF
  ///   - targetSize: Desired output dimensions
  ///   - outputURL: URL for the resized GIF output
  ///   - trimRange: Optional half-open selection in seconds
  ///   - onProgress: Progress callback (0.0 - 1.0), called off the main actor
  static func resize(
    sourceURL: URL,
    targetSize: CGSize,
    outputURL: URL,
    trimRange: Range<Double>? = nil,
    onProgress: @escaping @Sendable (Double) -> Void
  ) async throws {
    let sourceAccess = SandboxFileAccessManager.shared.beginAccessingURL(sourceURL)
    let outputDirAccess = SandboxFileAccessManager.shared.beginAccessingURL(
      outputURL.deletingLastPathComponent()
    )
    defer {
      sourceAccess.stop()
      outputDirAccess.stop()
    }

    let destination = try CaptureFilePublication.DestinationRevision(at: outputURL)
    try await Task.detached(priority: .userInitiated) {
      try resizeFrames(
        sourceURL: sourceURL,
        targetSize: targetSize,
        outputURL: outputURL,
        trimRange: trimRange,
        expectedOutput: destination,
        onProgress: onProgress
      )
    }.value
  }

  private nonisolated static func resizeFrames(
    sourceURL: URL,
    targetSize: CGSize,
    outputURL: URL,
    trimRange: Range<Double>?,
    expectedOutput: CaptureFilePublication.DestinationRevision,
    onProgress: (Double) -> Void
  ) throws {
    guard let source = openGIF(at: sourceURL) else {
      throw GIFResizeError.cannotReadSource
    }

    let frames = framesToExport(durations: frameDurations(in: source), trimRange: trimRange)
    guard !frames.isEmpty else {
      throw GIFResizeError.noFrames
    }

    let gifDimensions = 1 ... Int(UInt16.max)
    guard let targetWidth = Int(exactly: targetSize.width.rounded(.towardZero)),
          let targetHeight = Int(exactly: targetSize.height.rounded(.towardZero)),
          gifDimensions.contains(targetWidth), gifDimensions.contains(targetHeight)
    else {
      throw GIFResizeError.cannotCreateDestination
    }

    let files = FileManager.default
    let outputDirectory = outputURL.deletingLastPathComponent()
    try files.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    let stagingDirectory = outputDirectory
      .appendingPathComponent(".ownshot-gif-export-\(UUID().uuidString)", isDirectory: true)
    try files.createDirectory(at: stagingDirectory, withIntermediateDirectories: false)
    defer { try? files.removeItem(at: stagingDirectory) }
    let stagedURL = stagingDirectory.appendingPathComponent(outputURL.lastPathComponent)

    guard let destination = CGImageDestinationCreateWithURL(
      stagedURL as CFURL,
      UTType.gif.identifier as CFString,
      frames.count,
      nil
    ) else {
      throw GIFResizeError.cannotCreateDestination
    }

    let sourceProperties = CGImageSourceCopyProperties(source, nil) as? [String: Any]
    let gifProperties = sourceProperties?[kCGImagePropertyGIFDictionary as String] as? [String: Any]
    let loopKey = kCGImagePropertyGIFLoopCount as String
    var outputGIFProperties: [String: Any] = [kCGImagePropertyGIFHasGlobalColorMap as String: true]
    outputGIFProperties[loopKey] = gifProperties?[loopKey]
    CGImageDestinationSetProperties(destination, [
      kCGImagePropertyGIFDictionary as String: outputGIFProperties,
    ] as CFDictionary)

    // The pool releases each decoded and resized frame before the next.
    for (outputIndex, frame) in frames.enumerated() {
      try autoreleasepool {
        try addResizedFrame(
          at: frame.index,
          delay: frame.delay,
          from: source,
          to: destination,
          targetWidth: targetWidth,
          targetHeight: targetHeight
        )
      }

      onProgress(Double(outputIndex + 1) / Double(frames.count) * 0.95)
    }

    guard CGImageDestinationFinalize(destination),
          let stagedSource = openGIF(at: stagedURL),
          CGImageSourceGetCount(stagedSource) == frames.count
    else {
      throw GIFResizeError.finalizationFailed
    }

    try CaptureFilePublication.replaceFile(from: stagedURL, to: outputURL, expecting: expectedOutput)

    onProgress(1.0)

    // Log result
    let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int) ?? 0
    let fileSizeMB = String(format: "%.1f", Double(fileSize) / 1_048_576.0)
    logger.info(
      "GIF resized: \(outputURL.lastPathComponent) — \(frames.count) frames, \(targetWidth)×\(targetHeight), \(fileSizeMB)MB"
    )
  }

  private nonisolated static func openGIF(at url: URL) -> CGImageSource? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          CGImageSourceGetType(source) as String? == UTType.gif.identifier,
          CGImageSourceGetStatus(source) == .statusComplete
    else { return nil }
    return source
  }

  private nonisolated static func frameDurations(in source: CGImageSource) -> [Double] {
    (0 ..< CGImageSourceGetCount(source)).map { index in
      let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any]
      let gif = properties?[kCGImagePropertyGIFDictionary as String] as? [String: Any]
      let delay = gif?[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double
        ?? gif?[kCGImagePropertyGIFDelayTime as String] as? Double
        ?? 0.1
      return delay.isFinite && delay > 0 ? delay : 0.1
    }
  }

  private nonisolated static func framesToExport(
    durations: [Double], trimRange: Range<Double>?
  ) -> [(index: Int, delay: Double)] {
    guard let trimRange else { return durations.enumerated().map { ($0.offset, $0.element) } }
    guard trimRange.lowerBound.isFinite, trimRange.upperBound.isFinite,
          trimRange.lowerBound >= 0, !trimRange.isEmpty
    else { return [] }

    // GIF delays are whole centiseconds. A small allowance for accumulating
    // floating-point error keeps a selection at a frame edge from adding a frame.
    let centisecondsPerSecond = 100.0
    let trimStart = trimRange.lowerBound * centisecondsPerSecond
    let trimEnd = trimRange.upperBound * centisecondsPerSecond
    var frameStart = 0.0
    return durations.enumerated().compactMap { index, delay in
      let frameEnd = frameStart + (delay * centisecondsPerSecond).rounded()
      defer { frameStart = frameEnd }
      let overlap = min(trimEnd, frameEnd) - max(trimStart, frameStart)
      guard overlap > frameEnd.ulp * Double(durations.count) else { return nil }
      return (index, max(1, overlap.rounded()) / centisecondsPerSecond)
    }
  }

  private nonisolated static func addResizedFrame(
    at index: Int,
    delay: Double,
    from source: CGImageSource,
    to destination: CGImageDestination,
    targetWidth: Int,
    targetHeight: Int
  ) throws {
    guard let sourceImage = CGImageSourceCreateImageAtIndex(source, index, nil),
          CGImageSourceGetStatusAtIndex(source, index) == .statusComplete
    else {
      throw GIFResizeError.cannotReadSource
    }

    let frame = try resizedImage(sourceImage, width: targetWidth, height: targetHeight)
    let outputFrameProperties: [String: Any] = [
      kCGImagePropertyGIFDictionary as String: [
        kCGImagePropertyGIFDelayTime as String: delay,
        kCGImagePropertyGIFUnclampedDelayTime as String: delay,
      ],
    ]
    CGImageDestinationAddImage(destination, frame, outputFrameProperties as CFDictionary)
  }

  private nonisolated static func resizedImage(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
    guard image.width != width || image.height != height else { return image }

    let colorSpace = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
      ?? CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
      throw GIFResizeError.cannotCreateDestination
    }

    let canvasSize = CGSize(width: width, height: height)
    let fittedRect = VideoEditorExportLayout.aspectFitRect(
      sourceSize: CGSize(width: image.width, height: image.height),
      in: canvasSize
    )

    context.interpolationQuality = .high
    // Keep the letterbox black and preserve transparency inside the image.
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.addRect(CGRect(origin: .zero, size: canvasSize))
    context.addRect(fittedRect)
    context.drawPath(using: .eoFill)
    context.draw(image, in: fittedRect)

    guard let resizedImage = context.makeImage() else {
      throw GIFResizeError.finalizationFailed
    }
    return resizedImage
  }

  /// Get metadata from a GIF file
  static func metadata(for url: URL) -> GIFMetadata? {
    let access = SandboxFileAccessManager.shared.beginAccessingURL(url)
    defer { access.stop() }

    guard let source = openGIF(at: url),
          let firstFrame = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { return nil }

    return GIFMetadata(
      width: firstFrame.width,
      height: firstFrame.height,
      frameDurations: frameDurations(in: source)
    )
  }
}

// MARK: - GIF Metadata

struct GIFMetadata {
  let width: Int
  let height: Int
  let frameDurations: [Double]

  var frameCount: Int { frameDurations.count }
  var duration: Double { frameDurations.reduce(0, +) }

  var size: CGSize {
    CGSize(width: width, height: height)
  }

  var fps: Double {
    guard duration > 0 else { return 0 }
    return Double(frameCount) / duration
  }
}

// MARK: - Errors

nonisolated enum GIFResizeError: Error, LocalizedError {
  case cannotReadSource
  case noFrames
  case cannotCreateDestination
  case finalizationFailed

  var errorDescription: String? {
    switch self {
    case .cannotReadSource: L10n.GIF.cannotReadSource
    case .noFrames: L10n.GIF.noFramesInGIF
    case .cannotCreateDestination: L10n.GIF.cannotCreateOutputFile
    case .finalizationFailed: L10n.GIF.finalizeResizedFailed
    }
  }
}
