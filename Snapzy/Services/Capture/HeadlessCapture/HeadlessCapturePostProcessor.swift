//
//  HeadlessCapturePostProcessor.swift
//  Snapzy
//
//  Applies `maxDimension` to a written capture and reads back what agents
//  need to know about the file: pixel size, density and byte count.
//

import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum HeadlessCapturePostProcessor {
  struct FileInfo: Equatable {
    let pixelWidth: Int
    let pixelHeight: Int
    /// Pixels per point, from the DPI Snapzy writes (72 dpi = 1×).
    let scale: Double
    let byteCount: Int
  }

  enum Format: Equatable {
    case png
    case jpeg(quality: Double)
    case webp
  }

  /// Рамка добавляется после окончательного изменения размера.
  /// WebP не хранит DPI, поэтому плотность берётся из результата захвата.
  static func process(
    fileAt url: URL,
    format: Format,
    maxDimension: Int?,
    displayScale: Double,
    captureScale: Double? = nil,
    addPixelBorder: Bool = false
  ) throws -> FileInfo {
    let original = try fileInfo(at: url)
    if let maxDimension {
      guard maxDimension > 0 else {
        throw HeadlessCaptureError.captureFailed("Maximum dimension must be greater than zero")
      }
      // Внутренняя рамка не требует резерва пикселей за пределами изображения.
      try downscale(fileAt: url, format: format, maxDimension: maxDimension)
    }
    let resized = try fileInfo(at: url)
    var scale = format == .webp
      ? (captureScale ?? displayScale) * Double(resized.pixelWidth) / Double(max(original.pixelWidth, 1))
      : resized.scale
    if addPixelBorder {
      guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
            let bordered = OwnShotCaptureOutput.process(image, scaleFactor: scale,
              options: .init(addPixelBorder: true)) else {
        throw HeadlessCaptureError.captureFailed("Could not add the screenshot border")
      }
      scale = Double(bordered.scaleFactor ?? CGFloat(scale))
      try write(bordered.image, to: url, format: format, scale: scale)
    }
    let final = try fileInfo(at: url)
    return FileInfo(pixelWidth: final.pixelWidth, pixelHeight: final.pixelHeight,
      scale: scale, byteCount: final.byteCount)
  }

  /// Downscales in place so the longest edge is at most `maxDimension`,
  /// keeping format and adjusting DPI so `scale` stays truthful.
  static func downscale(fileAt url: URL, format: Format, maxDimension: Int) throws {
    let info = try fileInfo(at: url)
    let longestEdge = max(info.pixelWidth, info.pixelHeight)
    guard maxDimension > 0, longestEdge > maxDimension else { return }

    guard
      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxDimension,
      ] as CFDictionary)
    else {
      throw HeadlessCaptureError.captureFailed("Could not downscale \(url.lastPathComponent)")
    }

    let scale = info.scale * Double(thumbnail.width) / Double(info.pixelWidth)
    try write(thumbnail, to: url, format: format, scale: scale)
  }

  static func fileInfo(at url: URL) throws -> FileInfo {
    guard
      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
      let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
    else {
      throw HeadlessCaptureError.captureFailed("Could not read \(url.lastPathComponent)")
    }

    let dpi = (properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
    let byteCount = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    return FileInfo(pixelWidth: width, pixelHeight: height, scale: max(dpi, 1) / 72, byteCount: byteCount)
  }

  private static func write(_ image: CGImage, to url: URL, format: Format, scale: Double) throws {
    let temporary = url.deletingLastPathComponent()
      .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temporary) }

    switch format {
    case .webp:
      // ImageIO cannot encode WebP; Snapzy's encoder does not carry DPI.
      guard WebPEncoderService.write(image, to: temporary) else {
        throw HeadlessCaptureError.captureFailed("Could not encode the downscaled WebP")
      }
    case .png, .jpeg:
      let type: UTType = format == .png ? .png : .jpeg
      let dpi = scale * 72
      var properties: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
      if case .jpeg(let quality) = format {
        properties[kCGImageDestinationLossyCompressionQuality] = quality
      }
      guard
        let destination = CGImageDestinationCreateWithURL(temporary as CFURL, type.identifier as CFString, 1, nil)
      else {
        throw HeadlessCaptureError.captureFailed("Could not create the downscaled image")
      }
      CGImageDestinationAddImage(destination, image, properties as CFDictionary)
      guard CGImageDestinationFinalize(destination) else {
        throw HeadlessCaptureError.captureFailed("Could not write the downscaled image")
      }
    }

    _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
  }
}
