//
//  OwnShotProjectStoreTests.swift
//  SnapzyTests
//
//  Round-trip проекта OwnShot (.ownshot) и экспорт HEIC/WebP из редактора.
//

import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import Snapzy

@MainActor
final class OwnShotProjectStoreTests: XCTestCase {
  private static var retainedAnnotateStates: [AnnotateState] = []

  private var tempDirectory: URL!

  override func setUp() {
    super.setUp()
    tempDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("SnapzyTests_OwnShotProject_\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: tempDirectory)
    tempDirectory = nil
    super.tearDown()
  }

  // MARK: - Round-trip

  func testWriteAndRead_roundTripsEditableProject() throws {
    let url = tempDirectory.appendingPathComponent("capture.ownshot")
    let assetId = UUID()
    let sessionData = try makeSessionData(assetId: assetId)
    let preview = NSImage(cgImage: try XCTUnwrap(TestImageFactory.solidColor(width: 80, height: 40)), size: CGSize(width: 40, height: 20))

    try OwnShotProjectStore.write(sessionData, preview: preview, to: url)
    let loaded = try OwnShotProjectStore.read(from: url)

    // Исходник вложен без изменения байтов.
    XCTAssertEqual(loaded.originalImageData, sessionData.originalImageData)
    XCTAssertEqual(loaded.annotations.map(\.id), sessionData.annotations.map(\.id))
    XCTAssertEqual(loaded.annotations.map(\.bounds), sessionData.annotations.map(\.bounds))
    XCTAssertEqual(loaded.canvasEffects.padding, 18)
    XCTAssertEqual(loaded.canvasEffects.aspectRatio, .ratio16x9)
    XCTAssertEqual(loaded.selectedCanvasPresetId, sessionData.selectedCanvasPresetId)
    XCTAssertEqual(loaded.cropRect, sessionData.cropRect)
    XCTAssertTrue(loaded.isCutoutApplied)
    XCTAssertEqual(loaded.cutoutImageData, sessionData.cutoutImageData)
    XCTAssertEqual(loaded.embeddedImageAssetsData[assetId], Data("embedded-asset".utf8))
    XCTAssertEqual(loaded.sourceLogicalSize, CGSize(width: 40, height: 20))
    XCTAssertNil(loaded.originalCropSourceSize)

    guard case .text("OwnShot 043\nСтрока 2") = loaded.annotations[0].type else {
      return XCTFail("Многострочный Unicode-текст должен сохраниться точно")
    }
    XCTAssertEqual(loaded.annotations[0].properties.fontSize, 30)
    guard case .arrow(let geometry) = loaded.annotations[1].type else {
      return XCTFail("Ожидалась стрелка")
    }
    XCTAssertEqual(geometry.start, CGPoint(x: 5, y: 6))
    XCTAssertEqual(geometry.end, CGPoint(x: 30, y: 14))
    guard case .counter(2) = loaded.annotations[2].type else {
      return XCTFail("Ожидался счётчик")
    }
    guard case .embeddedImage(let loadedAssetId) = loaded.annotations[3].type else {
      return XCTFail("Ожидалась вставленная картинка")
    }
    XCTAssertEqual(loadedAssetId, assetId)
  }

  func testOriginalRatioПослеПовторногоОткрытияПовёрнутогоПроекта() throws {
    let source = try XCTUnwrap(TestImageFactory.solidColor(width: 338, height: 190))
    let state = AnnotateState(defaults: UserDefaultsFactory.make(), appliesDefaultCanvasPresetOnNewImages: false)
    Self.retainedAnnotateStates.append(state)
    state.loadImage(NSImage(cgImage: source, size: CGSize(width: 169, height: 95)))
    state.rotateImage(clockwise: true)
    XCTAssertEqual(state.sourceImage?.size, CGSize(width: 95, height: 169))

    let url = tempDirectory.appendingPathComponent("rotated.ownshot")
    XCTAssertTrue(AnnotateExporter.save(state: state, to: url))
    let reopenedSession = try OwnShotProjectStore.read(from: url)
    let controller = AnnotateWindowController(url: url, sessionData: reopenedSession)
    let window = try XCTUnwrap(controller.window as? AnnotateWindow)
    defer { window.close() }
    let reopened = try XCTUnwrap(window.interactionState)
    XCTAssertEqual(reopened.sourceImage?.size, CGSize(width: 95, height: 169))
    XCTAssertEqual(reopened.sourceImage?.backingPixelSize, CGSize(width: 190, height: 338))

    reopened.beginCropInteraction()
    reopened.applyOriginalCropRatio()
    XCTAssertEqual(try XCTUnwrap(reopened.effectiveCropRatio), 169.0 / 95, accuracy: 0.0001)
    XCTAssertEqual(reopened.cropRatioFieldValues?.width, 169)
    XCTAssertEqual(reopened.cropRatioFieldValues?.height, 95)
    let crop = try XCTUnwrap(reopened.cropRect)
    XCTAssertEqual(crop.width / crop.height, 169.0 / 95, accuracy: 0.0001)
    reopened.cancelCrop()

    let secondSave = tempDirectory.appendingPathComponent("rotated-copy.ownshot")
    XCTAssertTrue(AnnotateExporter.save(state: reopened, to: secondSave))
    let secondSession = try OwnShotProjectStore.read(from: secondSave)
    XCTAssertEqual(secondSession.originalCropSourceSize?.logicalSize, CGSize(width: 169, height: 95))
    XCTAssertEqual(secondSession.sourceLogicalSize, CGSize(width: 95, height: 169))
  }

  func testOriginalRatioПослеИзмененияОбластиInlineБерётПоследнийИсходник() throws {
    let source = try XCTUnwrap(TestImageFactory.solidColor(width: 338, height: 190))
    let resized = try XCTUnwrap(TestImageFactory.solidColor(width: 300, height: 200))
    let state = AnnotateState(defaults: UserDefaultsFactory.make(), appliesDefaultCanvasPresetOnNewImages: false)
    Self.retainedAnnotateStates.append(state)
    state.loadImage(NSImage(cgImage: source, size: CGSize(width: 169, height: 95)))
    let finalImage = NSImage(cgImage: resized, size: CGSize(width: 150, height: 100))
    state.replaceSourceImagePreservingAnnotations(finalImage)
    XCTAssertTrue(state.isSourceImageTransformed)

    let data = try XCTUnwrap(AnnotateExporter.imageData(from: finalImage, for: "png"))
    let session = AnnotationSessionData.snapshot(from: state, originalImageData: data)
    XCTAssertEqual(session.sourceLogicalSize, CGSize(width: 150, height: 100))
    XCTAssertEqual(session.originalCropSourceSize?.logicalSize, CGSize(width: 150, height: 100))
    state.beginCropInteraction()
    state.applyOriginalCropRatio()
    XCTAssertEqual(state.cropRatioFieldValues?.width, 3)
    XCTAssertEqual(state.cropRatioFieldValues?.height, 2)
  }

  func testWrite_producesSingleZipContainerWithSourcePreviewAndMeta() throws {
    let url = tempDirectory.appendingPathComponent("capture.ownshot")
    let sessionData = try makeSessionData()
    let preview = NSImage(cgImage: try XCTUnwrap(TestImageFactory.solidColor(width: 800, height: 400)), size: CGSize(width: 400, height: 200))

    try OwnShotProjectStore.write(sessionData, preview: preview, to: url)
    let files = try ZipArchiveReader.entries(in: Data(contentsOf: url))

    XCTAssertNotNil(files["document/document.json"])
    XCTAssertNotNil(files["document/meta.json"])
    let sourceEntries = files.keys.filter { $0.hasPrefix("document/files/") && $0.hasSuffix(".png") && !$0.contains("cutout") }
    XCTAssertEqual(sourceEntries.count, 1)
    XCTAssertEqual(files[try XCTUnwrap(sourceEntries.first)], sessionData.originalImageData)

    let previewSize = try pixelSize(of: XCTUnwrap(files["document/previews/preview.png"]))
    XCTAssertEqual(previewSize, CGSize(width: 800, height: 400))
    let thumbnailSize = try pixelSize(of: XCTUnwrap(files["document/previews/thumbnail.png"]))
    XCTAssertEqual(thumbnailSize, CGSize(width: 256, height: 128))

    let document = try JSONSerialization.jsonObject(with: XCTUnwrap(files["document/document.json"])) as? [String: Any]
    XCTAssertEqual(document?["documentFormatVersion"] as? Int, OwnShotProjectFormat.currentDocumentFormatVersion)
    XCTAssertEqual(document?["imageRetinaFactor"] as? Double, 2)
    XCTAssertEqual((document?["mainImage"] as? [String: Any])?["fileType"] as? String, "png")
    XCTAssertEqual((document?["objects"] as? [Any])?.count, 4)

    let meta = try JSONDecoder().decode(OwnShotProjectMeta.self, from: XCTUnwrap(files["document/meta.json"]))
    XCTAssertEqual(meta.documentFormatVersion, OwnShotProjectFormat.currentDocumentFormatVersion)
    XCTAssertNotNil(meta.systemVersion)
  }

  func testRead_toleratesUnknownFieldsObjectsAndMissingOptionalKeys() throws {
    let sourceData = try makeImageData(width: 20, height: 10)
    // Документ от «будущей» сборки: лишние поля, неизвестный тип объекта, нет canvasEffects.
    let documentJSON = """
    {
      "documentFormatVersion": 7,
      "mainImage": {"name": "source.png", "fileType": "png", "futureField": true},
      "documentSize": {"width": 20, "height": 10},
      "futureGlobal": {"anything": [1, 2, 3]},
      "objects": [
        {"id": "11111111-1111-1111-1111-111111111111",
         "type": {"kind": "hologram"},
         "bounds": [[0, 0], [5, 5]],
         "properties": {}},
        {"id": "22222222-2222-2222-2222-222222222222",
         "type": {"kind": "rectangle"},
         "bounds": [[1, 2], [3, 4]],
         "properties": \(try propertiesJSON())},
        "garbage"
      ]
    }
    """
    let archiveURL = tempDirectory.appendingPathComponent("future.ownshot")
    try ZipArchiveWriter.write(entries: [
      .init(name: "document/document.json", data: Data(documentJSON.utf8), modificationDate: Date()),
      .init(name: "document/files/source.png", data: sourceData, modificationDate: Date())
    ], to: archiveURL)

    let loaded = try OwnShotProjectStore.read(from: archiveURL)

    XCTAssertEqual(loaded.originalImageData, sourceData)
    XCTAssertEqual(loaded.annotations.count, 1)
    XCTAssertEqual(loaded.annotations.first?.bounds, CGRect(x: 1, y: 2, width: 3, height: 4))
    XCTAssertEqual(loaded.canvasEffects.padding, AnnotationCanvasEffects().padding)
    XCTAssertEqual(loaded.sourceLogicalSize, CGSize(width: 20, height: 10))
  }

  func testRead_rejectsArchiveWithoutSourceImage() throws {
    let url = tempDirectory.appendingPathComponent("broken.ownshot")
    try ZipArchiveWriter.write(entries: [
      .init(
        name: "document/document.json",
        data: Data(#"{"mainImage": {"name": "missing.png", "fileType": "png"}}"#.utf8),
        modificationDate: Date()
      )
    ], to: url)

    XCTAssertThrowsError(try OwnShotProjectStore.read(from: url)) { error in
      XCTAssertEqual(error as? OwnShotProjectStore.ProjectError, .missingSourceImage)
    }
  }

  func testRead_rejectsNonArchive() throws {
    let url = tempDirectory.appendingPathComponent("plain.ownshot")
    try makeImageData(width: 4, height: 4).write(to: url)
    XCTAssertThrowsError(try OwnShotProjectStore.read(from: url))
  }

  func testExporterSave_projectURLWritesReopenableProjectAndKeepsSourceBytes() throws {
    let sourceData = try makeImageData(width: 60, height: 40)
    let state = AnnotateState()
    Self.retainedAnnotateStates.append(state)
    state.loadImage(try XCTUnwrap(NSImage(data: sourceData)))
    state.annotations = [
      AnnotationItem(type: .rectangle, bounds: CGRect(x: 4, y: 4, width: 20, height: 10), properties: AnnotationProperties())
    ]
    let url = tempDirectory.appendingPathComponent("edited.ownshot")

    XCTAssertTrue(AnnotateExporter.save(state: state, to: url, originalImageData: sourceData))

    let loaded = try OwnShotProjectStore.read(from: url)
    XCTAssertEqual(loaded.originalImageData, sourceData)
    XCTAssertEqual(loaded.annotations.count, 1)
    XCTAssertNotNil(OwnShotProjectStore.previewImage(from: url))
  }

  func testSaveToFile_neverOverwritesProjectWithRaster() async throws {
    let url = tempDirectory.appendingPathComponent("keep.ownshot")
    try OwnShotProjectStore.write(try makeSessionData(), preview: nil, to: url)
    let before = try Data(contentsOf: url)
    let image = NSImage(cgImage: try XCTUnwrap(TestImageFactory.solidColor(width: 10, height: 10)), size: CGSize(width: 10, height: 10))

    let saved = await AnnotateExporter.saveToFileOffMain(image: image, sourceURL: url)

    XCTAssertFalse(saved)
    XCTAssertEqual(try Data(contentsOf: url), before)
  }

  // MARK: - Форматы Save As

  func testSaveFormat_mapsExtensionsAndOffersProjectAndHEIC() {
    XCTAssertEqual(AnnotateSaveFormat.allCases, [.project, .jpeg, .png, .heic, .webp])
    XCTAssertEqual(AnnotateSaveFormat(fileExtension: "JPG"), .jpeg)
    XCTAssertEqual(AnnotateSaveFormat(fileExtension: "heif"), .heic)
    XCTAssertEqual(AnnotateSaveFormat(fileExtension: "ownshot"), .project)
    XCTAssertNil(AnnotateSaveFormat(fileExtension: "gif"))
    XCTAssertEqual(AnnotateSaveFormat.project.contentType.identifier, "dev.nikoko.ownshot.project")
    XCTAssertEqual(AnnotateSaveFormat.project.contentType.preferredFilenameExtension, "ownshot")
  }

  func testSavePanel_matchesReferenceMenuAndDefaults() {
    let controller = AnnotateSavePanelController(
      baseFileName: "shot",
      directoryURL: tempDirectory
    )

    // Меню Format: Project, разделитель, JPEG, PNG, HEIC, WebP.
    let items = controller.popUpButton.itemArray
    XCTAssertEqual(items.map(\.isSeparatorItem), [false, true, false, false, false, false])
    XCTAssertEqual(
      items.filter { !$0.isSeparatorItem }.map(\.title),
      [AnnotateSaveFormat.project, .jpeg, .png, .heic, .webp].map(\.title)
    )
    // По умолчанию PNG, с тегами, папкой исходника и подсказкой про Project.
    XCTAssertEqual(controller.selectedFormat, .png)
    XCTAssertEqual(controller.popUpButton.titleOfSelectedItem, AnnotateSaveFormat.png.title)
    XCTAssertEqual(controller.panel.allowedContentTypes, [.png])
    XCTAssertEqual(controller.panel.nameFieldStringValue, "shot.png")
    // Как у эталона, поле Save As показывает имя без расширения.
    XCTAssertTrue(controller.panel.isExtensionHidden)
    XCTAssertTrue(controller.panel.showsTagField)
    XCTAssertEqual(controller.panel.directoryURL?.standardizedFileURL.path, tempDirectory.standardizedFileURL.path)
    XCTAssertTrue(controller.hintLabel.stringValue.contains("OwnShot Project"))
    XCTAssertNotNil(controller.panel.accessoryView)
  }

  func testSavePanel_accessoryМеткиИПопапВКоординатахЭталона() throws {
    let controller = AnnotateSavePanelController(baseFileName: "shot")
    let accessory = try XCTUnwrap(controller.panel.accessoryView)
    // Контейнер во весь лист 370 pt: панель ставит accessory к левому краю листа.
    XCTAssertEqual(accessory.frame.width, 370)
    let label = try XCTUnwrap(accessory.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == "Format:" })
    let popUp = controller.popUpButton
    // Кадры на 1 pt уже AX с каждой стороны: AX эталона – подпись 57 в 49, попап 207 в 114,
    // подсказка 272 в 49 от левого края листа.
    XCTAssertEqual(label.frame.minX, 50)
    XCTAssertEqual(label.frame.width, 55)
    XCTAssertEqual(popUp.frame.minX, 115)
    XCTAssertEqual(popUp.frame.width, 205)
    XCTAssertEqual(controller.hintLabel.frame.minX, 50)
    XCTAssertEqual(controller.hintLabel.frame.width, 270)
    // Блок по центру листа: поля слева и справа равны.
    XCTAssertEqual(popUp.frame.maxX, accessory.frame.width - 50)
    // Подпись по центру строки попапа, подсказка под попапом через 15 pt.
    XCTAssertEqual(label.frame.midY, popUp.frame.midY, accuracy: 0.5)
    XCTAssertEqual(popUp.frame.minY - controller.hintLabel.frame.maxY, 15, accuracy: 0.5)
    XCTAssertEqual(accessory.frame.height - popUp.frame.maxY, 26, accuracy: 0.5)
    // Попап не сжимается по содержимому после раскладки.
    accessory.layoutSubtreeIfNeeded()
    XCTAssertEqual(popUp.frame.width, 205)
  }

  func testSavePanel_destinationKeepsFormatExtension() {
    let directory = URL(fileURLWithPath: "/tmp/shots")
    XCTAssertEqual(
      AnnotateSavePanelController.url(directory.appendingPathComponent("shot.png"), withExtensionOf: .png).lastPathComponent,
      "shot.png"
    )
    XCTAssertEqual(
      AnnotateSavePanelController.url(directory.appendingPathComponent("shot.jpg"), withExtensionOf: .jpeg).lastPathComponent,
      "shot.jpg"
    )
    XCTAssertEqual(
      AnnotateSavePanelController.url(directory.appendingPathComponent("shot"), withExtensionOf: .webp).lastPathComponent,
      "shot.webp"
    )
  }

  func testSavePanel_switchesAllowedTypeWithFormat() {
    let controller = AnnotateSavePanelController(baseFileName: "shot")
    XCTAssertEqual(controller.panel.allowedContentTypes, [.png])

    controller.select(.heic)
    XCTAssertEqual(controller.selectedFormat, .heic)
    XCTAssertEqual(controller.popUpButton.titleOfSelectedItem, AnnotateSaveFormat.heic.title)
    XCTAssertEqual(controller.panel.allowedContentTypes, [.heic])

    controller.select(.project)
    XCTAssertEqual(controller.selectedFormat, .project)
    XCTAssertEqual(controller.panel.allowedContentTypes, [OwnShotProjectFormat.contentType])

    controller.select(.jpeg)
    XCTAssertEqual(controller.panel.allowedContentTypes, [.jpeg])
  }

  func testSavePanelDefaults_useSourceNameWithoutExtensionAndSourceFolder() {
    let source = URL(fileURLWithPath: "/Users/test/Shots/CleanShot 2026-11-14.jpg")
    XCTAssertEqual(AnnotateSavePanelController.baseFileName(for: source), "CleanShot 2026-11-14")
    XCTAssertEqual(AnnotateSavePanelController.directoryURL(for: source)?.path, "/Users/test/Shots")
    XCTAssertEqual(
      AnnotateSavePanelController.baseFileName(for: URL(fileURLWithPath: "/tmp/edit.ownshot")),
      "edit"
    )
    XCTAssertNil(AnnotateSavePanelController.directoryURL(for: nil))
  }

  // MARK: - Text style

  func testWriteAndRead_textStyleLandsInDocumentJSONAndRoundTrips() throws {
    let url = tempDirectory.appendingPathComponent("styles.ownshot")
    var sessionData = try makeSessionData()
    let styles = AnnotationTextStyle.allCases
    sessionData.annotations = styles.enumerated().map { index, style in
      var properties = AnnotationProperties()
      properties.textStyle = style
      return AnnotationItem(
        type: .text("Style \(index)"),
        bounds: CGRect(x: 0, y: CGFloat(index) * 20, width: 80, height: 20),
        properties: properties
      )
    }

    try OwnShotProjectStore.write(sessionData, preview: nil, to: url)

    let files = try ZipArchiveReader.entries(in: Data(contentsOf: url))
    let document = try JSONSerialization.jsonObject(with: XCTUnwrap(files["document/document.json"])) as? [String: Any]
    let objects = try XCTUnwrap(document?["objects"] as? [[String: Any]])
    let storedStyles = objects.map { ($0["properties"] as? [String: Any])?["textStyle"] as? Int }
    XCTAssertEqual(storedStyles, styles.map(\.rawValue))
    XCTAssertEqual(styles.map(\.rawValue), Array(0...6))

    let loaded = try OwnShotProjectStore.read(from: url)
    XCTAssertEqual(loaded.annotations.map(\.properties.textStyle), styles)
  }

  func testRead_missingTextStyleFallsBackToStandard() throws {
    var properties = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(try propertiesJSON().utf8)) as? [String: Any]
    )
    properties.removeValue(forKey: "textStyle")
    let propertiesData = try JSONSerialization.data(withJSONObject: properties)
    let documentJSON = """
    {
      "mainImage": {"name": "source.png", "fileType": "png"},
      "objects": [
        {"id": "11111111-1111-1111-1111-111111111111",
         "type": {"kind": "rectangle"},
         "bounds": [[1, 2], [3, 4]],
         "properties": \(String(decoding: propertiesData, as: UTF8.self))}
      ]
    }
    """
    let url = tempDirectory.appendingPathComponent("legacy.ownshot")
    try ZipArchiveWriter.write(entries: [
      .init(name: "document/document.json", data: Data(documentJSON.utf8), modificationDate: Date()),
      .init(name: "document/files/source.png", data: try makeImageData(width: 4, height: 4), modificationDate: Date())
    ], to: url)

    let loaded = try OwnShotProjectStore.read(from: url)
    XCTAssertEqual(loaded.annotations.first?.properties.textStyle, .standard)
  }

  // MARK: - In-place raster save

  func testRasterDone_keepsEditsWhenSourceDirectoryMoves() async throws {
    try await assertRasterSaveSurvivesMovedDirectory(fromCloseConfirmation: false)
  }

  func testRasterSaveOnClose_keepsEditsWhenSourceDirectoryMoves() async throws {
    try await assertRasterSaveSurvivesMovedDirectory(fromCloseConfirmation: true)
  }

  func testRasterSave_keepsLaterEditsAndReleasesQuickAccessReservation() async throws {
    guard !NSScreen.screens.isEmpty else { throw XCTSkip("Тесту нужен оконный сервер") }
    let input = tempDirectory.appendingPathComponent("linked.png")
    let originalBytes = try makeImageData(width: 80, height: 40)
    try originalBytes.write(to: input)
    let item = QuickAccessItem(url: input, thumbnail: try XCTUnwrap(NSImage(data: originalBytes)))
    let controller = AnnotateWindowController(item: item)
    let window = try XCTUnwrap(controller.window as? AnnotateWindow)
    let state = try XCTUnwrap(window.interactionState)
    let quickAccess = QuickAccessManager.shared
    window.orderFront(nil)
    defer {
      if let sheet = window.attachedSheet {
        window.endSheet(sheet, returnCode: .abort)
        sheet.orderOut(nil)
      }
      window.close()
      quickAccess.finishSavingItem(id: item.id)
      AnnotateManager.shared.clearSessionData(for: item.id)
      AnnotationSessionStore.shared.deleteSession(for: input)
    }

    // Keep the fixture off the system pasteboard even if the save regresses.
    let preferences = PreferencesManager.shared
    let previousActions = preferences.afterCaptureActions
    preferences.afterCaptureActions[.copyFile, default: [:]][.screenshot] = false
    defer { preferences.afterCaptureActions = previousActions }

    var properties = AnnotationProperties()
    properties.fillColor = Color(red: 1, green: 0, blue: 0)
    let beforeSave = AnnotationItem(
      type: .filledRectangle,
      bounds: CGRect(x: 5, y: 6, width: 25, height: 8),
      properties: properties
    )
    state.saveState()
    state.annotations.append(beforeSave)
    NotificationCenter.default.post(name: .annotateSave, object: window)
    XCTAssertNotNil(window.attachedSheet)
    XCTAssertFalse(quickAccess.beginSavingItem(id: item.id))

    let laterEdit = AnnotationItem(
      type: .rectangle,
      bounds: CGRect(x: 35, y: 25, width: 10, height: 8),
      properties: AnnotationProperties()
    )
    // Commands run synchronously before the save task first resumes on main.
    state.saveState()
    state.annotations.append(laterEdit)
    NotificationCenter.default.post(name: .annotateSave, object: window)
    XCTAssertFalse(controller.windowShouldClose(window))

    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline && window.attachedSheet != nil {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertNil(window.attachedSheet)
    XCTAssertTrue(window.isVisible)
    XCTAssertTrue(state.hasUnsavedChanges)
    XCTAssertEqual(state.annotations.map(\.id), [beforeSave.id, laterEdit.id])
    XCTAssertEqual(AnnotateManager.shared.getSessionData(for: item.id)?.annotations.map(\.id), [beforeSave.id])
    XCTAssertNotEqual(try Data(contentsOf: input), originalBytes)
    XCTAssertTrue(quickAccess.beginSavingItem(id: item.id))
  }

  // MARK: - Save As

  func testSaveAsToPNG_keepsOriginalProjectDirty() throws {
    let (controller, window, state, input) = try openEditedProject()
    defer { window.close() }
    let originalBytes = try Data(contentsOf: input)
    let output = tempDirectory.appendingPathComponent("export.png")
    defer { AnnotationSessionStore.shared.deleteSession(for: output) }

    controller.saveAs(to: output, keepsWindowOpen: true)

    let image = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
    XCTAssertEqual(CGImageSourceGetType(image) as String?, UTType.png.identifier)
    XCTAssertEqual(try Data(contentsOf: input), originalBytes)
    XCTAssertEqual(state.sourceURL, input)
    XCTAssertTrue(state.hasUnsavedChanges, "PNG export must leave original project dirty")
  }

  func testSaveAsToProjectCopy_keepsOriginalProjectDirty() throws {
    let (controller, window, state, input) = try openEditedProject()
    defer { window.close() }
    let originalBytes = try Data(contentsOf: input)
    let output = tempDirectory.appendingPathComponent("copy.ownshot")

    controller.saveAs(to: output, keepsWindowOpen: true)

    XCTAssertTrue(try OwnShotProjectStore.read(from: output).annotations.isEmpty)
    XCTAssertEqual(try Data(contentsOf: input), originalBytes)
    XCTAssertEqual(state.sourceURL, input)
    XCTAssertTrue(state.hasUnsavedChanges, "Project copy must leave original project dirty")
  }

  func testSaveAsToOriginalProject_marksSaved() throws {
    let (controller, window, state, input) = try openEditedProject()
    defer { window.close() }
    let folderAlias = tempDirectory.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: folderAlias, withDestinationURL: tempDirectory)
    let destination = folderAlias.appendingPathComponent(input.lastPathComponent)

    controller.saveAs(to: destination, keepsWindowOpen: true)

    XCTAssertTrue(try OwnShotProjectStore.read(from: input).annotations.isEmpty)
    XCTAssertEqual(state.sourceURL, input)
    XCTAssertFalse(state.hasUnsavedChanges)
  }

  // MARK: - HEIC / WebP

  func testImageData_heicEncodesHEVCWithSourceSize() throws {
    let cgImage = try XCTUnwrap(TestImageFactory.verticalGradient(width: 80, height: 40))
    let image = NSImage(cgImage: cgImage, size: CGSize(width: 40, height: 20))

    let data = try XCTUnwrap(AnnotateExporter.imageData(from: image, for: "heic"))

    let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
    XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.heic.identifier)
    let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    XCTAssertEqual(decoded.width, 80)
    XCTAssertEqual(decoded.height, 40)
  }

  func testExporterSave_heicURLWritesHEICFile() throws {
    let state = AnnotateState()
    Self.retainedAnnotateStates.append(state)
    state.loadImage(NSImage(cgImage: try XCTUnwrap(TestImageFactory.solidColor(width: 30, height: 20)), size: CGSize(width: 30, height: 20)))
    let url = tempDirectory.appendingPathComponent("export.heic")

    XCTAssertTrue(AnnotateExporter.save(state: state, to: url))

    let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
    XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.heic.identifier)
  }

  func testSaveRasterOffMain_кодируетНаРабочемПотокеИПишетHEIC() async throws {
    let state = AnnotateState()
    Self.retainedAnnotateStates.append(state)
    let bitmap = try XCTUnwrap(TestImageFactory.verticalGradient(width: 80, height: 40))
    state.loadImage(NSImage(cgImage: bitmap, size: CGSize(width: 40, height: 20)))
    let snapshot = try XCTUnwrap(state.makeRenderSnapshot())
    let url = tempDirectory.appendingPathComponent("background.heic")
    try Data("Прежняя версия".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)

    let saved = await AnnotateExporter.saveRasterOffMain(snapshot: snapshot, to: url) { image, fileExtension in
      XCTAssertFalse(Thread.isMainThread)
      return AnnotateExporter.imageData(from: image, for: fileExtension)
    }

    XCTAssertEqual(try XCTUnwrap(saved), CaptureFilePublication.FileRevision(at: url))
    let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
    XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.heic.identifier)
    let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    XCTAssertEqual(decoded.width, 80)
    XCTAssertEqual(decoded.height, 40)
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o444)
  }

  func testSaveRasterOffMain_сохраняетСуществующийФайлПриОшибкеКодирования() async throws {
    let state = AnnotateState()
    Self.retainedAnnotateStates.append(state)
    let bitmap = try XCTUnwrap(TestImageFactory.solidColor(width: 36, height: 24))
    state.loadImage(NSImage(cgImage: bitmap, size: CGSize(width: 36, height: 24)))
    let snapshot = try XCTUnwrap(state.makeRenderSnapshot())
    let url = tempDirectory.appendingPathComponent("existing.heic")
    let original = Data("existing".utf8)
    try original.write(to: url)

    let saved = await AnnotateExporter.saveRasterOffMain(snapshot: snapshot, to: url) { _, _ in nil }

    XCTAssertNil(saved)
    XCTAssertEqual(try Data(contentsOf: url), original)
  }

  func testSaveRasterOffMainСохраняетФайлПоявившийсяИлиИзменившийсяВоВремяКодирования() async throws {
    let state = AnnotateState(defaults: UserDefaultsFactory.make(), appliesDefaultCanvasPresetOnNewImages: false)
    Self.retainedAnnotateStates.append(state)
    state.loadImage(NSImage(cgImage: try XCTUnwrap(TestImageFactory.solidColor(width: 40, height: 30)),
      size: CGSize(width: 40, height: 30)))
    let snapshot = try XCTUnwrap(state.makeRenderSnapshot())
    let incoming = Data("Данные другого процесса".utf8)

    for originallyExists in [false, true] {
      let destination = tempDirectory.appendingPathComponent("changed-\(originallyExists).heic")
      if originallyExists { try Data("Прежняя версия".utf8).write(to: destination) }
      let saved = await AnnotateExporter.saveRasterOffMain(snapshot: snapshot, to: destination) { image, ext in
        do {
          if originallyExists {
            let file = try FileHandle(forWritingTo: destination)
            defer { try? file.close() }
            try file.truncate(atOffset: 0)
            try file.write(contentsOf: incoming)
          } else {
            try incoming.write(to: destination)
          }
          return AnnotateExporter.imageData(from: image, for: ext)
        } catch {
          XCTFail("Не удалось изменить назначение: \(error)")
          return nil
        }
      }
      XCTAssertNil(saved)
      XCTAssertEqual(try Data(contentsOf: destination), incoming)
    }
    XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: tempDirectory.path)
      .contains { $0.hasPrefix(".ownshot-annotate-") })
  }

  func testSaveRasterOffMainОтклоняетЗаменуПапкиВоВремяКодирования() async throws {
    let state = AnnotateState(defaults: UserDefaultsFactory.make(), appliesDefaultCanvasPresetOnNewImages: false)
    Self.retainedAnnotateStates.append(state)
    state.loadImage(NSImage(cgImage: try XCTUnwrap(TestImageFactory.solidColor(width: 40, height: 30)),
      size: CGSize(width: 40, height: 30)))
    let snapshot = try XCTUnwrap(state.makeRenderSnapshot())
    let directory = tempDirectory.appendingPathComponent("export", isDirectory: true)
    let movedDirectory = tempDirectory.appendingPathComponent("previous-export", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let destination = directory.appendingPathComponent("result.heic")

    let saved = await AnnotateExporter.saveRasterOffMain(snapshot: snapshot, to: destination) { image, ext in
      do {
        try FileManager.default.moveItem(at: directory, to: movedDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return AnnotateExporter.imageData(from: image, for: ext)
      } catch {
        XCTFail("Не удалось заменить папку: \(error)")
        return nil
      }
    }
    XCTAssertNil(saved)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: movedDirectory.path), [])
  }

  func testSaveRasterOffMainСохраняетВКаталогСПравамиПоискаИЗаписи() async throws {
    let state = AnnotateState(defaults: UserDefaultsFactory.make(), appliesDefaultCanvasPresetOnNewImages: false)
    Self.retainedAnnotateStates.append(state)
    state.loadImage(NSImage(cgImage: try XCTUnwrap(TestImageFactory.solidColor(width: 40, height: 30)),
      size: CGSize(width: 40, height: 30)))
    let snapshot = try XCTUnwrap(state.makeRenderSnapshot())
    let directory = tempDirectory.appendingPathComponent("write-only", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o300], ofItemAtPath: directory.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
    let destination = directory.appendingPathComponent("result.heic")

    let saved = await AnnotateExporter.saveRasterOffMain(snapshot: snapshot, to: destination)

    XCTAssertEqual(try XCTUnwrap(saved), CaptureFilePublication.FileRevision(at: destination))
    let source = try XCTUnwrap(CGImageSourceCreateWithURL(destination as CFURL, nil))
    XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.heic.identifier)
  }

  func testЭкспортHEIC_показываетИндикаторИЗакрываетРедактор() async throws {
    guard !NSScreen.screens.isEmpty else { throw XCTSkip("Тесту нужен оконный сервер") }
    let input = tempDirectory.appendingPathComponent("input.png")
    try makeImageData(width: 512, height: 2048).write(to: input)
    let output = tempDirectory.appendingPathComponent("result.heic")
    let duplicate = tempDirectory.appendingPathComponent("duplicate.heic")

    let controller = AnnotateWindowController(url: input)
    let window = try XCTUnwrap(controller.window)
    window.orderFront(nil)
    defer { window.close() }

    controller.exportHEIC(to: output)
    let progress = try XCTUnwrap(window.attachedSheet)
    let content = try XCTUnwrap(progress.contentView)
    XCTAssertNotNil(content.firstDescendant(ofType: NSProgressIndicator.self))
    let originalAppearance = content.appearance
    for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
      content.appearance = NSAppearance(named: appearance)
      content.layoutSubtreeIfNeeded()
      let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
      content.cacheDisplay(in: content.bounds, to: bitmap)
      let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      let attachment = XCTAttachment(data: png, uniformTypeIdentifier: UTType.png.identifier)
      attachment.name = "heic-progress-\(name)"
      attachment.lifetime = .keepAlways
      add(attachment)
    }
    content.appearance = originalAppearance
    XCTAssertFalse(controller.windowShouldClose(window))
    controller.exportHEIC(to: duplicate)
    XCTAssertTrue(window.attachedSheet === progress)

    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline, window.isVisible || window.attachedSheet != nil {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertFalse(window.isVisible)
    XCTAssertNil(window.attachedSheet)
    XCTAssertFalse(FileManager.default.fileExists(atPath: duplicate.path))
    let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
    XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.heic.identifier)
  }

  func testЭкспортHEICОставляетРедакторОткрытымПриПодменеГотовогоФайла() async throws {
    guard !NSScreen.screens.isEmpty else { throw XCTSkip("Тесту нужен оконный сервер") }
    let input = tempDirectory.appendingPathComponent("input.png")
    try makeImageData(width: 80, height: 60).write(to: input)
    let output = tempDirectory.appendingPathComponent("result.heic")
    let replacementImage = try XCTUnwrap(
      NSImage(data: makeImageData(width: 17, height: 11))
    )
    let replacement = try XCTUnwrap(AnnotateExporter.imageData(from: replacementImage, for: "heic"))
    try replacement.write(to: output)
    let history = CaptureHistoryStore.shared
    let previousDefaults = history.userDefaults
    let defaults = UserDefaultsFactory.make()
    defaults.set(true, forKey: PreferencesKeys.historyEnabled)
    history.userDefaults = defaults
    history.addCapture(url: output, captureType: .screenshot)
    defer {
      history.removeByFilePath(output.path)
      history.userDefaults = previousDefaults
      AnnotationSessionStore.shared.deleteSession(for: output)
    }
    XCTAssertTrue(history.hasRecord(forFilePath: output.path))
    let replaced = expectation(description: "HEIC заменён после публикации")
    let observer = NotificationCenter.default.addObserver(
      forName: .captureHistoryFileDidChange, object: CaptureHistoryStore.shared, queue: nil
    ) { event in
      guard event.userInfo?["filePath"] as? String == output.path else { return }
      do {
        try replacement.write(to: output, options: .atomic)
        replaced.fulfill()
      } catch {
        XCTFail("Не удалось заменить HEIC: \(error)")
      }
    }
    defer { NotificationCenter.default.removeObserver(observer) }

    let controller = AnnotateWindowController(url: input)
    let window = try XCTUnwrap(controller.window as? AnnotateWindow)
    let state = try XCTUnwrap(window.interactionState)
    window.orderFront(nil)
    defer {
      if let sheet = window.attachedSheet {
        window.endSheet(sheet, returnCode: .abort)
        sheet.orderOut(nil)
      }
      window.close()
    }
    state.saveState()

    controller.exportHEIC(to: output)
    let progress = try XCTUnwrap(window.attachedSheet)
    await fulfillment(of: [replaced], timeout: 10)
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline, window.attachedSheet === progress {
      try await Task.sleep(for: .milliseconds(10))
    }

    XCTAssertTrue(window.isVisible)
    XCTAssertTrue(state.hasUnsavedChanges)
    XCTAssertNotNil(window.attachedSheet)
    XCTAssertEqual(try Data(contentsOf: output), replacement)
    XCTAssertNil(AnnotationSessionStore.shared.load(for: output))
  }

  func testSaveAsToHEIC_keepsOriginalProjectDirty() async throws {
    let (controller, window, state, input) = try openEditedProject()
    window.orderFront(nil)
    defer { window.close() }
    let originalBytes = try Data(contentsOf: input)
    let output = tempDirectory.appendingPathComponent("export.heic")
    defer { AnnotationSessionStore.shared.deleteSession(for: output) }

    controller.saveAs(to: output, keepsWindowOpen: true)
    XCTAssertNotNil(window.attachedSheet)
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline, window.attachedSheet != nil {
      try await Task.sleep(for: .milliseconds(10))
    }

    XCTAssertNil(window.attachedSheet)
    let image = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
    XCTAssertEqual(CGImageSourceGetType(image) as String?, UTType.heic.identifier)
    XCTAssertEqual(try Data(contentsOf: input), originalBytes)
    XCTAssertEqual(state.sourceURL, input)
    XCTAssertTrue(window.isVisible)
    XCTAssertTrue(state.hasUnsavedChanges, "HEIC export must leave original project dirty")
  }

  func testЭкспортHEIC_оставляетПравкиПоявившиесяВоВремяЗаписи() async throws {
    guard !NSScreen.screens.isEmpty else { throw XCTSkip("Тесту нужен оконный сервер") }
    let input = tempDirectory.appendingPathComponent("input.png")
    try makeImageData(width: 512, height: 2048).write(to: input)
    let output = tempDirectory.appendingPathComponent("result.heic")
    let controller = AnnotateWindowController(url: input)
    let window = try XCTUnwrap(controller.window as? AnnotateWindow)
    let state = try XCTUnwrap(window.interactionState)
    window.orderFront(nil)
    defer { window.close() }

    controller.exportHEIC(to: output)
    // Фоновые инструменты могут применить правку, пока лист блокирует ввод.
    state.saveState()

    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline, window.attachedSheet != nil {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertNil(window.attachedSheet)
    XCTAssertTrue(window.isVisible)
    XCTAssertTrue(state.hasUnsavedChanges)
    XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
  }

  func testЭкспортHEIC_отклоняетОдновременнуюЗаписьВТотЖеФайл() async throws {
    guard !NSScreen.screens.isEmpty else { throw XCTSkip("Тесту нужен оконный сервер") }
    let input = tempDirectory.appendingPathComponent("input.png")
    try makeImageData(width: 512, height: 2048).write(to: input)
    let output = tempDirectory.appendingPathComponent("result.heic")
    let firstEditor = AnnotateWindowController(url: input)
    let secondEditor = AnnotateWindowController(url: input)
    let firstWindow = try XCTUnwrap(firstEditor.window)
    let secondWindow = try XCTUnwrap(secondEditor.window)
    firstWindow.orderFront(nil)
    secondWindow.orderFront(nil)
    defer {
      if let sheet = secondWindow.attachedSheet { secondWindow.endSheet(sheet) }
      secondWindow.close()
      firstWindow.close()
    }

    firstEditor.exportHEIC(to: output)
    secondEditor.exportHEIC(to: output)
    let secondSheet = try XCTUnwrap(secondWindow.attachedSheet)
    XCTAssertNil(secondSheet.contentView?.firstDescendant(ofType: NSProgressIndicator.self))

    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline, firstWindow.attachedSheet != nil {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertFalse(firstWindow.isVisible)
    XCTAssertTrue(secondWindow.isVisible)
    XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
  }

  func testImageData_webpIsLosslessAndMatchesSourcePixels() throws {
    let cgImage = try XCTUnwrap(TestImageFactory.verticalGradient(width: 64, height: 32))
    let image = NSImage(cgImage: cgImage, size: CGSize(width: 64, height: 32))

    let data = try XCTUnwrap(AnnotateExporter.imageData(from: image, for: "webp"))

    // RIFF....WEBPVP8L — чанк lossless-битстрима.
    XCTAssertEqual(String(decoding: data[12..<16], as: UTF8.self), "VP8L")
    let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
    let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    XCTAssertEqual(try rgbaBytes(from: decoded), try rgbaBytes(from: cgImage))
  }

  // MARK: - Helpers

  private func assertRasterSaveSurvivesMovedDirectory(fromCloseConfirmation: Bool) async throws {
    guard !NSScreen.screens.isEmpty else { throw XCTSkip("Тесту нужен оконный сервер") }
    let directory = tempDirectory.appendingPathComponent("original-directory", isDirectory: true)
    let movedDirectory = tempDirectory.appendingPathComponent("moved-directory", isDirectory: true)
    let input = directory.appendingPathComponent("source.png")
    let originalBytes = try makeImageData(width: 80, height: 40)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    try originalBytes.write(to: input)

    let controller = AnnotateWindowController(url: input)
    let window = try XCTUnwrap(controller.window as? AnnotateWindow)
    let state = try XCTUnwrap(window.interactionState)
    window.orderFront(nil)
    defer {
      if let sheet = window.attachedSheet {
        window.endSheet(sheet, returnCode: .abort)
        sheet.orderOut(nil)
      }
      window.close()
    }
    state.saveState()
    var properties = AnnotationProperties()
    properties.fillColor = Color(red: 1, green: 0, blue: 0)
    let annotation = AnnotationItem(
      type: .filledRectangle,
      bounds: CGRect(x: 5, y: 6, width: 25, height: 8),
      properties: properties
    )
    state.annotations.append(annotation)
    XCTAssertTrue(state.hasUnsavedChanges)

    try FileManager.default.moveItem(at: directory, to: movedDirectory)
    var confirmation: NSWindow?
    if fromCloseConfirmation {
      XCTAssertFalse(controller.windowShouldClose(window))
      let sheet = try XCTUnwrap(window.attachedSheet)
      confirmation = sheet
      window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
      sheet.orderOut(nil)
    } else {
      NotificationCenter.default.post(name: .annotateSave, object: window)
    }

    func showsSaveError(in view: NSView) -> Bool {
      if let label = view as? NSTextField, label.stringValue == L10n.AnnotateUI.saveFailedTitle {
        return true
      }
      return view.subviews.contains { showsSaveError(in: $0) }
    }

    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline && window.isVisible &&
      window.attachedSheet?.contentView.map({ showsSaveError(in: $0) }) != true {
      try await Task.sleep(for: .milliseconds(10))
    }

    XCTAssertTrue(window.isVisible, "Failed raster save must leave the editor open")
    XCTAssertTrue(state.hasUnsavedChanges, "Failed raster save must preserve unsaved edits")
    XCTAssertEqual(state.annotations.map(\.id), [annotation.id])
    XCTAssertEqual(try Data(contentsOf: movedDirectory.appendingPathComponent(input.lastPathComponent)), originalBytes)
    XCTAssertFalse(FileManager.default.fileExists(atPath: input.path))
    XCTAssertTrue(
      window.attachedSheet?.contentView.map { showsSaveError(in: $0) } == true,
      "Failed raster save must show a save error"
    )
    if let confirmation {
      XCTAssertFalse(window.attachedSheet === confirmation)
    }

    guard !fromCloseConfirmation, let error = window.attachedSheet,
          error.contentView.map({ showsSaveError(in: $0) }) == true else { return }
    window.endSheet(error, returnCode: .alertFirstButtonReturn)
    error.orderOut(nil)
    try FileManager.default.moveItem(at: movedDirectory, to: directory)
    defer { AnnotationSessionStore.shared.deleteSession(for: input) }

    // Suppress the real pasteboard action in memory without writing preferences.
    let preferences = PreferencesManager.shared
    let previousActions = preferences.afterCaptureActions
    preferences.afterCaptureActions[.copyFile, default: [:]][.screenshot] = false
    defer { preferences.afterCaptureActions = previousActions }
    NotificationCenter.default.post(name: .annotateSave, object: window)
    let retryDeadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < retryDeadline && window.isVisible {
      try await Task.sleep(for: .milliseconds(10))
    }

    XCTAssertFalse(window.isVisible, "The editor should close after the retry succeeds")
    XCTAssertFalse(state.hasUnsavedChanges)
    XCTAssertNil(window.attachedSheet)
    let image = try XCTUnwrap(CGImageSourceCreateWithURL(input as CFURL, nil))
    let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(image, 0, nil))
    let pixels = try rgbaBytes(from: decoded)
    XCTAssertTrue(stride(from: 0, to: pixels.count, by: 4).contains { offset in
      pixels[offset] > 230 && pixels[offset + 1] < 30 && pixels[offset + 2] < 30 && pixels[offset + 3] == 255
    }, "The written PNG should contain the red annotation")
  }

  private func openEditedProject() throws -> (AnnotateWindowController, AnnotateWindow, AnnotateState, URL) {
    guard !NSScreen.screens.isEmpty else { throw XCTSkip("Тесту нужен оконный сервер") }
    let project = tempDirectory.appendingPathComponent("original.ownshot")
    let session = AnnotationSessionData(
      originalImageData: try makeImageData(width: 80, height: 40),
      annotations: [
        AnnotationItem(
          type: .rectangle,
          bounds: CGRect(x: 5, y: 6, width: 25, height: 8),
          properties: AnnotationProperties()
        )
      ],
      canvasEffects: AnnotationCanvasEffects(),
      sourceLogicalSize: CGSize(width: 80, height: 40)
    )
    try OwnShotProjectStore.write(session, preview: nil, to: project)
    let controller = AnnotateWindowController(url: project, sessionData: try OwnShotProjectStore.read(from: project))
    let window = try XCTUnwrap(controller.window as? AnnotateWindow)
    let state = try XCTUnwrap(window.interactionState)
    XCTAssertFalse(state.hasUnsavedChanges)
    state.selectedAnnotationId = try XCTUnwrap(state.annotations.first).id
    state.deleteSelectedAnnotation()
    XCTAssertTrue(state.annotations.isEmpty)
    XCTAssertTrue(state.hasUnsavedChanges)
    return (controller, window, state, project)
  }

  private func makeSessionData(assetId: UUID = UUID()) throws -> AnnotationSessionData {
    let originalData = try makeImageData(width: 80, height: 40)
    let cutoutData = try makeImageData(width: 80, height: 40)
    var textProperties = AnnotationProperties()
    textProperties.fontSize = 30
    return AnnotationSessionData(
      originalImageData: originalData,
      annotations: [
        AnnotationItem(
          id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
          type: .text("OwnShot 043\nСтрока 2"),
          bounds: CGRect(x: 40, y: 57.5, width: 227.12060546875, height: 40),
          properties: textProperties
        ),
        AnnotationItem(
          id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
          type: .arrow(ArrowGeometry(start: CGPoint(x: 5, y: 6), end: CGPoint(x: 30, y: 14), style: .straight)),
          bounds: CGRect(x: 5, y: 6, width: 25, height: 8),
          properties: AnnotationProperties()
        ),
        AnnotationItem(
          id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
          type: .counter(2),
          bounds: CGRect(x: 10, y: 10, width: 8, height: 8),
          properties: AnnotationProperties()
        ),
        AnnotationItem(
          id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
          type: .embeddedImage(assetId),
          bounds: CGRect(x: 2, y: 3, width: 12, height: 9),
          properties: AnnotationProperties()
        )
      ],
      canvasEffects: AnnotationCanvasEffects(
        backgroundStyle: .gradient(.blueGreen),
        padding: 18,
        aspectRatio: .ratio16x9
      ),
      selectedCanvasPresetId: UUID(),
      isSelectedCanvasPresetDirty: true,
      cropRect: CGRect(x: 1, y: 1, width: 20, height: 12),
      isCutoutApplied: true,
      cutoutImageData: cutoutData,
      embeddedImageAssetsData: [assetId: Data("embedded-asset".utf8)],
      sourceLogicalSize: CGSize(width: 40, height: 20)
    )
  }

  private func propertiesJSON() throws -> String {
    let encoder = JSONEncoder()
    let data = try encoder.encode(PersistedAnnotationProperties(properties: AnnotationProperties()))
    return String(decoding: data, as: UTF8.self)
  }

  private func makeImageData(width: Int, height: Int) throws -> Data {
    let cgImage = try XCTUnwrap(TestImageFactory.solidColor(width: width, height: height))
    let image = NSImage(cgImage: cgImage, size: CGSize(width: width, height: height))
    return try XCTUnwrap(AnnotateExporter.imageData(from: image, for: "png"))
  }

  private func pixelSize(of data: Data) throws -> CGSize {
    let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
    let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    return CGSize(width: image.width, height: image.height)
  }

  private func rgbaBytes(from image: CGImage) throws -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let context = try XCTUnwrap(CGContext(
      data: &bytes,
      width: image.width,
      height: image.height,
      bitsPerComponent: 8,
      bytesPerRow: image.width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return bytes
  }
}
