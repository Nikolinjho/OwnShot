//
//  CaptureParity060Tests.swift
//  SnapzyTests
//
//  Паритет волны 060: захват, History и карточка Quick Access.
//

import AppKit
import XCTest
@testable import Snapzy

@MainActor
final class CaptureParity060Tests: XCTestCase {

  // MARK: - QA-221: Option при Copy

  func testCopyСOptionОставляетКарточку() {
    XCTAssertTrue(QuickAccessCompletionPolicy.shouldDismissAfterCopy(optionHeld: false))
    XCTAssertFalse(QuickAccessCompletionPolicy.shouldDismissAfterCopy(optionHeld: true))
  }

  // MARK: - REC-061: отмена GIF с карточки

  func testОтменаОбработкиНедоступнаБезКонвертацииGIF() {
    let id = UUID()
    XCTAssertFalse(QuickAccessManager.shared.canCancelProcessing(id: id))
    // Без конвертации вызов ничего не делает и не показывает вопрос.
    QuickAccessManager.shared.cancelProcessing(id: id)
  }

  // MARK: - QA-053: приложение-источник

  func testВнешнийBundleIDНеСчитаетСамOwnShot() {
    XCTAssertEqual(
      CaptureSourceApplication.externalBundleID("com.google.Chrome", ownBundleID: "dev.nikoko.ownshot"),
      "com.google.Chrome"
    )
    XCTAssertNil(CaptureSourceApplication.externalBundleID("dev.nikoko.ownshot", ownBundleID: "dev.nikoko.ownshot"))
    XCTAssertNil(CaptureSourceApplication.externalBundleID("  ", ownBundleID: "dev.nikoko.ownshot"))
    XCTAssertNil(CaptureSourceApplication.externalBundleID(nil, ownBundleID: "dev.nikoko.ownshot"))
  }

  func testИсточникЗахватаЗапоминаетсяИСбрасывается() {
    defer { CaptureSourceApplication.reset() }
    CaptureSourceApplication.note(bundleID: "com.tinyspeck.slackmacgap", ownBundleID: "dev.nikoko.ownshot")
    XCTAssertEqual(CaptureSourceApplication.currentBundleID, "com.tinyspeck.slackmacgap")
    CaptureSourceApplication.note(bundleID: "dev.nikoko.ownshot", ownBundleID: "dev.nikoko.ownshot")
    XCTAssertNil(CaptureSourceApplication.currentBundleID)
  }

  func testСтараяЗаписьHistoryЧитаетсяБезПриложенияИсточника() throws {
    let legacy = """
    {"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","filePath":"/tmp/a.png","fileName":"a.png",
     "captureType":"screenshot","fileSize":1,"capturedAt":0,"isDeleted":false}
    """
    let record = try JSONDecoder().decode(CaptureHistoryRecord.self, from: Data(legacy.utf8))
    XCTAssertNil(record.sourceAppBundleID)

    var withSource = record
    withSource.sourceAppBundleID = "com.google.Chrome"
    let decoded = try JSONDecoder().decode(CaptureHistoryRecord.self, from: JSONEncoder().encode(withSource))
    XCTAssertEqual(decoded.sourceAppBundleID, "com.google.Chrome")
  }

  func testБейджБезУстановленногоПриложенияНеСтроитИконку() {
    defer { HistorySourceAppIconCache.removeAll() }
    XCTAssertNil(HistorySourceAppIconCache.icon(for: nil))
    XCTAssertNil(HistorySourceAppIconCache.icon(for: "invalid.ownshot.missing", resolveURL: { _ in nil }))
    let finder = HistorySourceAppIconCache.icon(
      for: "com.apple.finder",
      resolveURL: { _ in URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app") }
    )
    XCTAssertNotNil(finder)
  }

  // MARK: - CAP-168: Ctrl копирует в буфер

  func testCtrlПриЗахватеКопируетСнимок() {
    let url = URL(fileURLWithPath: "/tmp/ownshot-ctrl-\(UUID().uuidString).png")
    let metadata = OwnShotScreenshotCaptureMetadata.shared
    metadata.register(url: url, bypassesDefaultPreset: false, copiesToClipboard: true)
    XCTAssertTrue(metadata.consumeClipboardCopy(for: url))
    XCTAssertFalse(metadata.consumeClipboardCopy(for: url))

    metadata.register(url: url, bypassesDefaultPreset: true)
    XCTAssertFalse(metadata.consumeClipboardCopy(for: url))
    XCTAssertTrue(metadata.consumeBypass(for: url))
  }

  func testНеинтерактивныйЗахватНеКопируетПоCtrl() {
    var context = CaptureContext.empty
    XCTAssertFalse(context.copiesToClipboard)
    context.copiesToClipboard = true
    XCTAssertFalse(context.capturingModifiers(isInteractive: false).copiesToClipboard)
    XCTAssertTrue(context.capturingModifiers(isInteractive: true).copiesToClipboard)
  }

  // MARK: - CAP-173: обрезка выреза

  func testПолосаПодВырезомОбрезаетсяТолькоДляПолноэкранногоОкна() {
    let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let fullscreen = CGRect(x: 0, y: 38, width: 1512, height: 944)
    XCTAssertEqual(OwnShotNotchCrop.topInset(displayBounds: display, safeAreaTop: 38, windowBounds: [fullscreen]), 38)
    XCTAssertEqual(
      OwnShotNotchCrop.topInset(displayBounds: display, safeAreaTop: 38, windowBounds: [CGRect(x: 0, y: 38, width: 900, height: 600)]),
      0
    )
    XCTAssertEqual(OwnShotNotchCrop.topInset(displayBounds: display, safeAreaTop: 0, windowBounds: [display]), 0)
    // Второй дисплей слева от основного.
    let external = CGRect(x: -1512, y: 0, width: 1512, height: 982)
    XCTAssertEqual(
      OwnShotNotchCrop.topInset(
        displayBounds: external,
        safeAreaTop: 38,
        windowBounds: [CGRect(x: -1512, y: 38, width: 1512, height: 944)]
      ),
      38
    )
  }

  func testОбрезкаСнимаетВерхнююПолосуВПикселях() throws {
    let context = try XCTUnwrap(CGContext(
      data: nil, width: 100, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    let image = try XCTUnwrap(context.makeImage())
    let cropped = try XCTUnwrap(OwnShotNotchCrop.crop(image, topPoints: 10, scale: 2))
    XCTAssertEqual(cropped.width, 100)
    XCTAssertEqual(cropped.height, 60)
    XCTAssertNil(OwnShotNotchCrop.crop(image, topPoints: 0, scale: 2))
    XCTAssertNil(OwnShotNotchCrop.crop(image, topPoints: 40, scale: 2))
  }

  // MARK: - R27: рамка выделения записи и All-In-One – только белые скобки

  func testРамкаВыделенияТолькоСкобкиИМеткиСередин() {
    // audit-020/reference-recording-panel-desktop.png и spec-039-live/all-in-one-overlay-initial.png:
    // толщина 8 px = 4 pt по центру края, плечо угла 35 px = 17,5 pt, метка 34×8 px = 17×4 pt.
    // Прежнее CAP-157 (в AIO только углы, в записи ещё и контур 1,5 pt) этим правилом заменено.
    let rect = CGRect(x: 100, y: 100, width: 300, height: 200)
    let rects = RecordingSelectionBrackets.rects(for: rect)
    XCTAssertEqual(rects.count, 12, "4 угла по два плеча и 4 метки середин")
    XCTAssertEqual(RecordingSelectionBrackets.thickness, 4)
    XCTAssertEqual(RecordingSelectionBrackets.outerCornerRadius, 1)
    // Левый нижний угол: плечи от внешнего края, 2 pt наружу и 2 pt внутрь.
    XCTAssertTrue(rects.contains(CGRect(x: 98, y: 98, width: 17.5, height: 4)))
    XCTAssertTrue(rects.contains(CGRect(x: 98, y: 98, width: 4, height: 17.5)))
    // Правый верхний угол.
    XCTAssertTrue(rects.contains(CGRect(x: 402 - 17.5, y: 298, width: 17.5, height: 4)))
    XCTAssertTrue(rects.contains(CGRect(x: 398, y: 302 - 17.5, width: 4, height: 17.5)))
    // Метки середин сторон 17×4 pt.
    XCTAssertTrue(rects.contains(CGRect(x: 241.5, y: 298, width: 17, height: 4)))
    XCTAssertTrue(rects.contains(CGRect(x: 98, y: 191.5, width: 4, height: 17)))
    // Сплошного контура нет: ни один прямоугольник не тянется вдоль всей стороны.
    XCTAssertTrue(rects.allSatisfy { max($0.width, $0.height) <= 17.5 })
  }

  func testЗатемнениеЗаписиЧёрный50() {
    // R24: яркость за выделением падает вдвое, 38 → 19 (reference-recording-panel-desktop.png).
    XCTAssertEqual(RecordingSelectionBrackets.dimAlpha, 0.5)
    XCTAssertEqual(OwnShotCrosshairStyle.dimAlpha, 0.5)
  }
}
