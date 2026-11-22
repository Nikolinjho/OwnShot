//
//  PreviewProvider.swift
//  QuickLookExtension
//
//  Quick Look Preview для проекта .ownshot: показывает итоговый рендер document/previews/preview.png.
//

import Foundation
import QuickLook
import QuickLookUI
import UniformTypeIdentifiers

final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
  func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
    let archive = try Data(contentsOf: request.fileURL, options: .mappedIfSafe)
    let data = try OwnShotProjectPreviewReader.previewData(fromArchive: archive)
    // Размер окна Quick Look берётся из картинки, без него окно открывается квадратом.
    let size = OwnShotProjectPreviewReader.pixelSize(of: data) ?? CGSize(width: 800, height: 600)
    return QLPreviewReply(dataOfContentType: .png, contentSize: size) { _ in data }
  }
}
