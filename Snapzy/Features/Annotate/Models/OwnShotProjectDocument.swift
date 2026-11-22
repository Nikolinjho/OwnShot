//
//  OwnShotProjectDocument.swift
//  Snapzy
//
//  Модель документа проекта OwnShot (.ownshot): редактируемый исходник с аннотациями.
//

import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// Формат проекта OwnShot. Контейнер — ZIP со структурой, близкой к эталонному .cleanshot:
///
///     document/document.json          — объекты и параметры холста
///     document/files/<id>.<ext>       — исходник байт-в-байт
///     document/files/cutout.png       — вырезанный фон, если применён
///     document/files/assets/<id>.bin  — вставленные картинки
///     document/previews/preview.png   — итоговый рендер
///     document/previews/thumbnail.png — миниатюра до 256 px
///     document/meta.json              — версия формата и приложения
enum OwnShotProjectFormat {
  static let fileExtension = "ownshot"
  static let typeIdentifier = "dev.nikoko.ownshot.project"
  /// Версия схемы document.json. Новые поля добавляются опционально без смены версии.
  static let currentDocumentFormatVersion = 1

  static let contentType = UTType(exportedAs: typeIdentifier, conformingTo: .data)

  static let documentEntry = "document/document.json"
  static let metaEntry = "document/meta.json"
  static let filesDirectory = "document/files/"
  static let assetsDirectory = "document/files/assets/"
  static let previewEntry = "document/previews/preview.png"
  static let thumbnailEntry = "document/previews/thumbnail.png"
  static let thumbnailMaxPixelSize: CGFloat = 256

  nonisolated static func isProjectURL(_ url: URL) -> Bool {
    url.pathExtension.lowercased() == fileExtension
  }
}

struct OwnShotProjectMeta: Codable, Equatable {
  var documentFormatVersion: Int
  var appVersion: String?
  var appBuild: String?
  var systemVersion: String?

  static func current() -> OwnShotProjectMeta {
    let info = Bundle.main.infoDictionary
    let os = ProcessInfo.processInfo.operatingSystemVersion
    return OwnShotProjectMeta(
      documentFormatVersion: OwnShotProjectFormat.currentDocumentFormatVersion,
      appVersion: info?["CFBundleShortVersionString"] as? String,
      appBuild: info?["CFBundleVersion"] as? String,
      systemVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
    )
  }
}

/// document.json. Декодирование терпимо к неизвестным и отсутствующим полям:
/// новые свойства аннотаций и холста от более свежих сборок не ломают открытие,
/// а объект, который эта сборка не умеет прочитать, пропускается.
struct OwnShotProjectDocument: Codable {
  struct MainImage: Codable, Equatable {
    /// Имя файла внутри document/files/.
    var name: String
    /// Расширение исходника: png, jpeg, heic, webp, tiff…
    var fileType: String
  }

  var documentFormatVersion: Int
  var mainImage: MainImage
  /// Пиксели исходника на один пункт documentSize.
  var imageRetinaFactor: CGFloat
  /// Логический размер исходника в пунктах — система координат объектов.
  var documentSize: CGSize
  var originalCropSourceSize: OriginalCropSourceSize?
  var objects: [PersistedAnnotationItem]
  var canvasEffects: PersistedCanvasEffects?
  var selectedCanvasPresetId: UUID?
  var isSelectedCanvasPresetDirty: Bool
  var cropRect: CGRect?
  var isCutoutApplied: Bool
  var cutoutFileName: String?
  var didCutoutAutoApplyCrop: Bool
  var cutoutAutoAppliedCropRect: CGRect?
  /// UUID вставленной картинки → имя файла в document/files/assets/.
  var embeddedAssetFileNames: [String: String]
  var combineSession: PersistedCombineSession?
  var createdAt: Date?
  var updatedAt: Date?

  init(
    documentFormatVersion: Int = OwnShotProjectFormat.currentDocumentFormatVersion,
    mainImage: MainImage,
    imageRetinaFactor: CGFloat,
    documentSize: CGSize,
    objects: [PersistedAnnotationItem],
    canvasEffects: PersistedCanvasEffects?,
    selectedCanvasPresetId: UUID?,
    isSelectedCanvasPresetDirty: Bool,
    cropRect: CGRect?,
    isCutoutApplied: Bool,
    cutoutFileName: String?,
    didCutoutAutoApplyCrop: Bool,
    cutoutAutoAppliedCropRect: CGRect?,
    embeddedAssetFileNames: [String: String],
    combineSession: PersistedCombineSession?,
    createdAt: Date?,
    updatedAt: Date?,
    originalCropSourceSize: OriginalCropSourceSize? = nil
  ) {
    self.documentFormatVersion = documentFormatVersion
    self.mainImage = mainImage
    self.imageRetinaFactor = imageRetinaFactor
    self.documentSize = documentSize
    self.originalCropSourceSize = originalCropSourceSize
    self.objects = objects
    self.canvasEffects = canvasEffects
    self.selectedCanvasPresetId = selectedCanvasPresetId
    self.isSelectedCanvasPresetDirty = isSelectedCanvasPresetDirty
    self.cropRect = cropRect
    self.isCutoutApplied = isCutoutApplied
    self.cutoutFileName = cutoutFileName
    self.didCutoutAutoApplyCrop = didCutoutAutoApplyCrop
    self.cutoutAutoAppliedCropRect = cutoutAutoAppliedCropRect
    self.embeddedAssetFileNames = embeddedAssetFileNames
    self.combineSession = combineSession
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  private enum CodingKeys: String, CodingKey {
    case documentFormatVersion, mainImage, imageRetinaFactor, documentSize, objects, canvasEffects
    case selectedCanvasPresetId, isSelectedCanvasPresetDirty, cropRect, isCutoutApplied, cutoutFileName
    case didCutoutAutoApplyCrop, cutoutAutoAppliedCropRect, embeddedAssetFileNames, combineSession
    case createdAt, updatedAt, originalCropSourceSize
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    // Без исходника проект открыть нельзя, остальное восстанавливается по умолчанию.
    mainImage = try container.decode(MainImage.self, forKey: .mainImage)
    documentFormatVersion = (try? container.decodeIfPresent(Int.self, forKey: .documentFormatVersion))
      ?? OwnShotProjectFormat.currentDocumentFormatVersion
    imageRetinaFactor = (try? container.decodeIfPresent(CGFloat.self, forKey: .imageRetinaFactor)) ?? 1
    // Пишется как [w, h] (Codable CGSize); форму {"width", "height"} тоже принимаем.
    documentSize = (try? container.decodeIfPresent(CGSize.self, forKey: .documentSize))
      ?? (try? container.decodeIfPresent(NamedSize.self, forKey: .documentSize))?.size
      ?? .zero
    originalCropSourceSize = try? container.decodeIfPresent(OriginalCropSourceSize.self, forKey: .originalCropSourceSize)
    objects = ((try? container.decodeIfPresent([LossyDecodable<PersistedAnnotationItem>].self, forKey: .objects)) ?? [])
      .compactMap(\.value)
    canvasEffects = try? container.decodeIfPresent(PersistedCanvasEffects.self, forKey: .canvasEffects)
    selectedCanvasPresetId = try? container.decodeIfPresent(UUID.self, forKey: .selectedCanvasPresetId)
    isSelectedCanvasPresetDirty = (try? container.decodeIfPresent(Bool.self, forKey: .isSelectedCanvasPresetDirty)) ?? false
    cropRect = try? container.decodeIfPresent(CGRect.self, forKey: .cropRect)
    isCutoutApplied = (try? container.decodeIfPresent(Bool.self, forKey: .isCutoutApplied)) ?? false
    cutoutFileName = try? container.decodeIfPresent(String.self, forKey: .cutoutFileName)
    didCutoutAutoApplyCrop = (try? container.decodeIfPresent(Bool.self, forKey: .didCutoutAutoApplyCrop)) ?? false
    cutoutAutoAppliedCropRect = try? container.decodeIfPresent(CGRect.self, forKey: .cutoutAutoAppliedCropRect)
    embeddedAssetFileNames = (try? container.decodeIfPresent([String: String].self, forKey: .embeddedAssetFileNames)) ?? [:]
    combineSession = try? container.decodeIfPresent(PersistedCombineSession.self, forKey: .combineSession)
    createdAt = try? container.decodeIfPresent(Date.self, forKey: .createdAt)
    updatedAt = try? container.decodeIfPresent(Date.self, forKey: .updatedAt)
  }
}

/// Размер в форме {"width": …, "height": …}.
private struct NamedSize: Decodable {
  let width: CGFloat
  let height: CGFloat
  var size: CGSize { CGSize(width: width, height: height) }
}

/// Элемент массива, который при ошибке декодирования превращается в nil, а не роняет весь массив.
struct LossyDecodable<Value: Decodable>: Decodable {
  let value: Value?

  init(from decoder: Decoder) throws {
    value = try? Value(from: decoder)
  }
}
