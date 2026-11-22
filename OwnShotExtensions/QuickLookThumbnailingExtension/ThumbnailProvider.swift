//
//  ThumbnailProvider.swift
//  QuickLookThumbnailingExtension
//
//  Миниатюра проекта .ownshot в Finder: thumbnail.png из ZIP, для крупных иконок preview.png.
//

import CoreGraphics
import Foundation
import QuickLookThumbnailing

final class ThumbnailProvider: QLThumbnailProvider {
  override func provideThumbnail(
    for request: QLFileThumbnailRequest,
    _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
  ) {
    do {
      let archive = try Data(contentsOf: request.fileURL, options: .mappedIfSafe)
      let maximumPixelSide = max(request.maximumSize.width, request.maximumSize.height) * max(request.scale, 1)
      let data = try OwnShotProjectPreviewReader.thumbnailData(
        fromArchive: archive,
        maximumPixelSide: maximumPixelSide
      )
      let image = try OwnShotProjectPreviewReader.cgImage(from: data)
      // contextSize задаётся в точках, а битмап контекста Quick Look создаёт в пикселях (× request.scale).
      // Поэтому рисуем на весь битмап, иначе картинка занимает 1/scale в левом нижнем углу на белом поле.
      let contextSize = OwnShotProjectPreviewReader.thumbnailContextSize(
        imagePixelSize: CGSize(width: image.width, height: image.height),
        maximumSize: request.maximumSize,
        scale: request.scale
      )
      let reply = QLThumbnailReply(contextSize: contextSize) { context in
        let rect = OwnShotProjectPreviewReader.thumbnailDrawRect(
          contextPixelSize: CGSize(width: context.width, height: context.height),
          userSpaceToDevice: context.userSpaceToDeviceSpaceTransform
        )
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        return true
      }
      handler(reply, nil)
    } catch {
      handler(nil, error)
    }
  }
}
