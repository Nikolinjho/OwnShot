//
//  OwnShotProjectPreviewReader.swift
//  Snapzy
//
//  Превью проекта .ownshot для Quick Look: preview.png и thumbnail.png из ZIP без разбора аннотаций.
//  Файл собирается в приложение и в оба Quick Look-расширения вместе с ZipArchiveReader,
//  поэтому не ссылается на модели редактора. Пути совпадают с OwnShotProjectFormat.
//

import CoreGraphics
import Foundation
import ImageIO

enum OwnShotProjectPreviewReader {
  enum PreviewError: Error, Equatable {
    case missingPreview
    case unreadableImage
  }

  static let previewEntry = "document/previews/preview.png"
  static let thumbnailEntry = "document/previews/thumbnail.png"

  /// Итоговый рендер проекта для Quick Look Preview.
  static func previewData(fromArchive archive: Data) throws -> Data {
    let files = try ZipArchiveReader.entries(in: archive)
    guard let data = files[previewEntry], !data.isEmpty else { throw PreviewError.missingPreview }
    return data
  }

  /// Картинка для миниатюры: thumbnail.png, если её хватает на запрошенный размер, иначе preview.png.
  static func thumbnailData(fromArchive archive: Data, maximumPixelSide: CGFloat) throws -> Data {
    let files = try ZipArchiveReader.entries(in: archive)
    let preview = files[previewEntry].flatMap { $0.isEmpty ? nil : $0 }
    let thumbnail = files[thumbnailEntry].flatMap { $0.isEmpty ? nil : $0 }
    if let thumbnail {
      let side = pixelSize(of: thumbnail).map { max($0.width, $0.height) } ?? 0
      if side >= maximumPixelSide || preview == nil { return thumbnail }
    }
    guard let preview else { throw PreviewError.missingPreview }
    return preview
  }

  /// Размер картинки в пикселях без полного декодирования.
  static func pixelSize(of data: Data) -> CGSize? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
          let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
          width > 0, height > 0 else { return nil }
    return CGSize(width: width, height: height)
  }

  static func cgImage(from data: Data) throws -> CGImage {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw PreviewError.unreadableImage }
    return image
  }

  /// Размер контекста миниатюры в точках: картинка вписывается в maximumSize с сохранением пропорций.
  /// Пиксели картинки переводятся в точки через scale, поэтому на Retina она не растягивается сверх своих пикселей.
  static func thumbnailContextSize(imagePixelSize: CGSize, maximumSize: CGSize, scale: CGFloat) -> CGSize {
    let scale = max(scale, 1)
    return aspectFitSize(
      CGSize(width: imagePixelSize.width / scale, height: imagePixelSize.height / scale),
      in: maximumSize
    )
  }

  /// Прямоугольник отрисовки в пользовательских координатах контекста QLThumbnailReply.
  /// Quick Look отдаёт битмап в пикселях (contextSize × scale), а масштаб в CTM может и не заложить,
  /// поэтому весь битмап переводится из координат устройства обратно в пользовательские.
  static func thumbnailDrawRect(contextPixelSize: CGSize, userSpaceToDevice: CGAffineTransform) -> CGRect {
    CGRect(origin: .zero, size: contextPixelSize).applying(userSpaceToDevice.inverted())
  }

  /// Вписывает картинку в рамку с сохранением пропорций. Меньшая картинка не растягивается.
  static func aspectFitSize(_ size: CGSize, in maximum: CGSize) -> CGSize {
    guard size.width > 0, size.height > 0, maximum.width > 0, maximum.height > 0 else { return .zero }
    let scale = min(1, maximum.width / size.width, maximum.height / size.height)
    return CGSize(
      width: max(1, (size.width * scale).rounded()),
      height: max(1, (size.height * scale).rounded())
    )
  }
}
