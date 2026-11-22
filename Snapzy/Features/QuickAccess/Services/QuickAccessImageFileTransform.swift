//
//  QuickAccessImageFileTransform.swift
//  Snapzy
//
//  Поворот, отражение и изменение размера файла картинки на месте
//  для пунктов Rotate Left, Flip Horizontal и Resize... карточки Quick Access.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum QuickAccessImageFileTransform: Equatable {
  case rotateLeft
  case flipHorizontal
  case resize(CGSize)
  /// Scale Retina to 1x: уменьшает Retina-снимок до размера в точках и ставит 72 dpi
  case scaleRetinaTo1x(CGFloat)

  enum TransformError: Error {
    case unreadable
    case renderFailed
    case writeFailed
  }

  /// Размер исходника в пикселях без декодирования всей картинки.
  static func pixelSize(of url: URL) -> CGSize? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int else {
      return nil
    }
    return CGSize(width: width, height: height)
  }

  /// Множитель Retina по DPI файла (144 dpi → 2). nil у снимков 1x: пункт меню у эталона условный.
  static func retinaScale(of url: URL) -> CGFloat? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
      return nil
    }
    return retinaScale(dpi: (properties[kCGImagePropertyDPIWidth] as? NSNumber).map { CGFloat($0.doubleValue) })
  }

  static func retinaScale(dpi: CGFloat?) -> CGFloat? {
    guard let dpi, dpi.isFinite else { return nil }
    let scale = (dpi / 72).rounded()
    return scale > 1 ? scale : nil
  }

  func apply(to image: CGImage) throws -> CGImage {
    let sourceSize = CGSize(width: image.width, height: image.height)
    let outputSize: CGSize
    switch self {
    case .rotateLeft:
      outputSize = CGSize(width: sourceSize.height, height: sourceSize.width)
    case .flipHorizontal:
      outputSize = sourceSize
    case .resize(let size):
      outputSize = CGSize(width: max(1, size.width.rounded()), height: max(1, size.height.rounded()))
    case .scaleRetinaTo1x(let scale):
      let factor = max(scale, 1)
      outputSize = CGSize(
        width: max(1, (sourceSize.width / factor).rounded()),
        height: max(1, (sourceSize.height / factor).rounded())
      )
    }

    let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(
      data: nil,
      width: Int(outputSize.width),
      height: Int(outputSize.height),
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: colorSpace.model == .rgb ? colorSpace : CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
      throw TransformError.renderFailed
    }
    context.interpolationQuality = .high

    switch self {
    case .rotateLeft:
      // Против часовой стрелки: в координатах CoreGraphics (ось Y вверх)
      // сдвиг на ширину результата и поворот на +90°.
      context.translateBy(x: outputSize.width, y: 0)
      context.rotate(by: .pi / 2)
      context.draw(image, in: CGRect(origin: .zero, size: sourceSize))
    case .flipHorizontal:
      context.translateBy(x: outputSize.width, y: 0)
      context.scaleBy(x: -1, y: 1)
      context.draw(image, in: CGRect(origin: .zero, size: sourceSize))
    case .resize, .scaleRetinaTo1x:
      context.draw(image, in: CGRect(origin: .zero, size: outputSize))
    }

    guard let result = context.makeImage() else { throw TransformError.renderFailed }
    return result
  }

  /// Перезаписывает файл в том же формате. Как в эталоне, отмены нет.
  func apply(toFileAt url: URL) throws {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
      throw TransformError.unreadable
    }
    let type = CGImageSourceGetType(source) ?? (UTType.png.identifier as CFString)
    var properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
    // Ориентация и размеры пересчитываются заново.
    properties[kCGImagePropertyOrientation] = nil
    properties[kCGImagePropertyPixelWidth] = nil
    properties[kCGImagePropertyPixelHeight] = nil
    if case .scaleRetinaTo1x = self {
      properties[kCGImagePropertyDPIWidth] = 72
      properties[kCGImagePropertyDPIHeight] = 72
    }

    let output = try apply(to: image)

    let staging = url.deletingLastPathComponent()
      .appendingPathComponent(".ownshot-transform-\(UUID().uuidString)")
      .appendingPathExtension(url.pathExtension)
    defer { try? FileManager.default.removeItem(at: staging) }
    guard let destination = CGImageDestinationCreateWithURL(staging as CFURL, type, 1, nil) else {
      throw TransformError.writeFailed
    }
    CGImageDestinationAddImage(destination, output, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw TransformError.writeFailed }
    _ = try FileManager.default.replaceItemAt(url, withItemAt: staging)
  }
}
