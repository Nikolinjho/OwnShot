//
//  OwnShotProjectStore.swift
//  Snapzy
//
//  Запись и чтение проекта OwnShot (.ownshot): один переносимый ZIP-файл.
//

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum OwnShotProjectStore {
  enum ProjectError: Error, Equatable {
    case missingDocument
    case missingSourceImage
    case unreadableDocument
  }

  // MARK: - Запись

  /// Собирает entries проекта. `preview` — итоговый рендер редактора, без него превью не пишутся.
  static func entries(
    for sessionData: AnnotationSessionData,
    preview: NSImage?,
    createdAt: Date? = nil,
    now: Date = Date()
  ) throws -> [ZipArchiveWriter.Entry] {
    let sourceData = sessionData.originalImageData
    let sourceInfo = imageInfo(for: sourceData)
    let sourceFileType = sourceInfo?.fileExtension ?? "png"
    let sourceFileName = "\(randomIdentifier()).\(sourceFileType)"
    let documentSize = sessionData.sourceLogicalSize
      ?? sourceInfo.map { CGSize(width: $0.pixelSize.width, height: $0.pixelSize.height) }
      ?? .zero
    let retinaFactor: CGFloat = {
      guard let pixelWidth = sourceInfo?.pixelSize.width, documentSize.width > 0 else { return 1 }
      return max(pixelWidth / documentSize.width, 1)
    }()

    let embeddedAssetFileNames = Dictionary(uniqueKeysWithValues: sessionData.embeddedImageAssetsData.keys.map {
      ($0.uuidString, "\($0.uuidString).bin")
    })
    let cutoutFileName = sessionData.cutoutImageData == nil ? nil : "cutout.png"

    let document = OwnShotProjectDocument(
      mainImage: .init(name: sourceFileName, fileType: sourceFileType),
      imageRetinaFactor: retinaFactor,
      documentSize: documentSize,
      objects: sessionData.annotations.map(PersistedAnnotationItem.init),
      canvasEffects: PersistedCanvasEffects(effects: sessionData.canvasEffects),
      selectedCanvasPresetId: sessionData.selectedCanvasPresetId,
      isSelectedCanvasPresetDirty: sessionData.isSelectedCanvasPresetDirty,
      cropRect: sessionData.cropRect,
      isCutoutApplied: sessionData.isCutoutApplied,
      cutoutFileName: cutoutFileName,
      didCutoutAutoApplyCrop: sessionData.didCutoutAutoApplyCrop,
      cutoutAutoAppliedCropRect: sessionData.cutoutAutoAppliedCropRect,
      embeddedAssetFileNames: embeddedAssetFileNames,
      combineSession: sessionData.combineSession.map { snapshot in
        PersistedCombineSession(
          modeRawValue: snapshot.mode.rawValue,
          directionRawValue: snapshot.direction.rawValue,
          gap: Double(snapshot.gap),
          freeBoundsByAnnotationID: Dictionary(uniqueKeysWithValues:
            snapshot.freeBoundsByAnnotationID.map { ($0.key.uuidString, $0.value) })
        )
      },
      createdAt: createdAt ?? now,
      updatedAt: now,
      originalCropSourceSize: sessionData.originalCropSourceSize
    )

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]

    var entries: [ZipArchiveWriter.Entry] = [
      .init(name: OwnShotProjectFormat.documentEntry, data: try encoder.encode(document), modificationDate: now),
      // Исходник кладётся без перекодирования.
      .init(name: OwnShotProjectFormat.filesDirectory + sourceFileName, data: sourceData, modificationDate: now)
    ]
    if let cutoutFileName, let cutoutData = sessionData.cutoutImageData {
      entries.append(.init(name: OwnShotProjectFormat.filesDirectory + cutoutFileName, data: cutoutData, modificationDate: now))
    }
    for (assetId, data) in sessionData.embeddedImageAssetsData.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
      guard let fileName = embeddedAssetFileNames[assetId.uuidString] else { continue }
      entries.append(.init(name: OwnShotProjectFormat.assetsDirectory + fileName, data: data, modificationDate: now))
    }
    if let preview,
       let previewData = AnnotateExporter.imageData(from: preview, for: "png") {
      entries.append(.init(name: OwnShotProjectFormat.previewEntry, data: previewData, modificationDate: now))
      if let thumbnailData = thumbnailPNGData(from: preview) {
        entries.append(.init(name: OwnShotProjectFormat.thumbnailEntry, data: thumbnailData, modificationDate: now))
      }
    }
    entries.append(.init(
      name: OwnShotProjectFormat.metaEntry,
      data: try encoder.encode(OwnShotProjectMeta.current()),
      modificationDate: now
    ))
    return entries
  }

  static func write(_ sessionData: AnnotationSessionData, preview: NSImage?, to url: URL) throws {
    // Повторное сохранение сохраняет дату создания исходного проекта.
    let createdAt = (try? readDocument(from: url))?.createdAt
    let entries = try entries(for: sessionData, preview: preview, createdAt: createdAt)
    try ZipArchiveWriter.write(entries: entries, to: url)
  }

  // MARK: - Чтение

  static func read(from url: URL) throws -> AnnotationSessionData {
    try sessionData(fromArchive: Data(contentsOf: url))
  }

  static func sessionData(fromArchive archive: Data) throws -> AnnotationSessionData {
    let files = try ZipArchiveReader.entries(in: archive)
    let document = try document(from: files)
    guard let sourceData = files[OwnShotProjectFormat.filesDirectory + document.mainImage.name] else {
      throw ProjectError.missingSourceImage
    }
    let cutoutData = document.cutoutFileName.flatMap { files[OwnShotProjectFormat.filesDirectory + $0] }
    var embeddedAssets: [UUID: Data] = [:]
    for (assetIdString, fileName) in document.embeddedAssetFileNames {
      guard let assetId = UUID(uuidString: assetIdString),
            let data = files[OwnShotProjectFormat.assetsDirectory + fileName] else { continue }
      embeddedAssets[assetId] = data
    }

    return AnnotationSessionData(
      originalImageData: sourceData,
      annotations: document.objects.compactMap(\.annotationItem),
      canvasEffects: document.canvasEffects?.annotationCanvasEffects ?? AnnotationCanvasEffects(),
      selectedCanvasPresetId: document.selectedCanvasPresetId,
      isSelectedCanvasPresetDirty: document.isSelectedCanvasPresetDirty,
      cropRect: document.cropRect,
      isCutoutApplied: document.isCutoutApplied && cutoutData != nil,
      cutoutImageData: cutoutData,
      didCutoutAutoApplyCrop: document.didCutoutAutoApplyCrop,
      cutoutAutoAppliedCropRect: document.cutoutAutoAppliedCropRect,
      embeddedImageAssetsData: embeddedAssets,
      combineSession: document.combineSession?.toSnapshot(),
      sourceLogicalSize: document.documentSize.width > 0 && document.documentSize.height > 0
        ? document.documentSize
        : nil,
      originalCropSourceSize: document.originalCropSourceSize
    )
  }

  static func readDocument(from url: URL) throws -> OwnShotProjectDocument {
    try document(from: ZipArchiveReader.entries(in: Data(contentsOf: url)))
  }

  /// Превью проекта без разбора аннотаций — для иконок и списков.
  static func previewImage(from url: URL) -> NSImage? {
    guard let files = try? ZipArchiveReader.entries(in: Data(contentsOf: url)),
          let data = files[OwnShotProjectFormat.previewEntry] else { return nil }
    return NSImage(data: data)
  }

  private static func document(from files: [String: Data]) throws -> OwnShotProjectDocument {
    guard let data = files[OwnShotProjectFormat.documentEntry] else { throw ProjectError.missingDocument }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    do {
      return try decoder.decode(OwnShotProjectDocument.self, from: data)
    } catch {
      throw ProjectError.unreadableDocument
    }
  }

  // MARK: - Вспомогательное

  private struct ImageInfo {
    let fileExtension: String
    let pixelSize: CGSize
  }

  private static func imageInfo(for data: Data) -> ImageInfo? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let typeIdentifier = CGImageSourceGetType(source) as String? else { return nil }
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
    let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
    let fileExtension = UTType(typeIdentifier)?.preferredFilenameExtension ?? "png"
    return ImageInfo(fileExtension: fileExtension, pixelSize: CGSize(width: width, height: height))
  }

  private static func thumbnailPNGData(from image: NSImage) -> Data? {
    guard let cgImage = AnnotateExporter.bestCGImage(from: image) else { return nil }
    let maxSide = OwnShotProjectFormat.thumbnailMaxPixelSize
    let scale = min(1, maxSide / CGFloat(max(cgImage.width, cgImage.height)))
    let width = max(1, Int((CGFloat(cgImage.width) * scale).rounded()))
    let height = max(1, Int((CGFloat(cgImage.height) * scale).rounded()))
    guard let context = CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.interpolationQuality = .high
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let thumbnail = context.makeImage() else { return nil }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
      return nil
    }
    CGImageDestinationAddImage(destination, thumbnail, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
  }

  private static func randomIdentifier() -> String {
    let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
    return String((0..<32).map { _ in alphabet.randomElement()! })
  }
}
