//
//  ClipboardOpenRouteTests.swift
//  SnapzyTests
//

import AppKit
import XCTest
@testable import Snapzy

final class ClipboardOpenRouteTests: XCTestCase {
  private var pasteboard: NSPasteboard!
  private var directory: URL!

  override func setUpWithError() throws {
    pasteboard = NSPasteboard.withUniqueName()
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("clipboard-open-route-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    pasteboard.releaseGlobally()
    try? FileManager.default.removeItem(at: directory)
  }

  func testВидеоФайлИзFinderОткрываетсяКарточкойЗаписи() throws {
    for name in ["clip.mp4", "clip.mov", "clip.m4v", "CLIP.MP4", "anim.gif"] {
      let url = try makeFile(name)
      pasteboard.clearContents()
      // Finder кладёт рядом со ссылкой значок файла. Значок не должен уводить в редактор.
      XCTAssertTrue(pasteboard.writeObjects([url as NSURL, NSImage(size: NSSize(width: 16, height: 16))]))
      XCTAssertEqual(ClipboardOpenRoute.resolve(pasteboard: pasteboard), .quickAccessRecording(url),
        "\(name) должен открываться карточкой Quick Access, а не редактором изображений")
    }
  }

  func testУдалённаяЗаписьИзБуфераНеСтановитсяКарточкой() throws {
    let url = try makeFile("moved.mp4")
    let item = NSPasteboardItem()
    let icon = try XCTUnwrap(TestImageFactory.solidColor(width: 16, height: 16))
    let png = try XCTUnwrap(NSBitmapImageRep(cgImage: icon).representation(using: .png, properties: [:]))
    XCTAssertTrue(item.setString(url.absoluteString, forType: .fileURL))
    XCTAssertTrue(item.setData(png, forType: .png))
    XCTAssertTrue(pasteboard.writeObjects([item]))

    XCTAssertEqual(ClipboardOpenRoute.resolve(pasteboard: pasteboard), .quickAccessRecording(url))
    try FileManager.default.removeItem(at: url)
    XCTAssertEqual(ClipboardOpenRoute.resolve(pasteboard: pasteboard), .unsupported)
  }

  func testКарточкаЗаписиИзБуфераПолучаетБейджВидеоИлиGIF() throws {
    let mp4 = try makeFile("clip.mp4")
    let gif = try makeFile("anim.gif")
    XCTAssertEqual(QuickAccessCardChrome.infoBadges(isVideo: true, url: mp4, hasSound: false), [.video])
    XCTAssertEqual(QuickAccessCardChrome.infoBadges(isVideo: true, url: gif, hasSound: false), [.gif])
  }

  func testКартинкаФайломОткрываетсяВРедакторе() throws {
    let url = try makeFile("shot.png")
    pasteboard.clearContents()
    XCTAssertTrue(pasteboard.writeObjects([url as NSURL]))
    XCTAssertEqual(ClipboardOpenRoute.resolve(pasteboard: pasteboard), .annotateFile(url))
  }

  func testСсылкаНаУдалённыйСнимокУступаетПикселямИзТогоЖеОбъекта() throws {
    let image = try XCTUnwrap(TestImageFactory.solidColor(width: 28, height: 19))
    let bitmap = NSBitmapImageRep(cgImage: image)
    let formats: [(NSPasteboard.PasteboardType, NSBitmapImageRep.FileType, String)] =
      [(.png, .png, "png"), (.tiff, .tiff, "tiff")]
    for (type, format, fileExtension) in formats {
      pasteboard.clearContents()
      let url = try makeFile("moved.\(fileExtension)")
      let data = try XCTUnwrap(bitmap.representation(using: format, properties: [:]))
      let item = NSPasteboardItem()
      XCTAssertTrue(item.setString(url.absoluteString, forType: .fileURL))
      XCTAssertTrue(item.setData(data, forType: type))
      XCTAssertTrue(pasteboard.writeObjects([item]))

      XCTAssertEqual(ClipboardOpenRoute.resolve(pasteboard: pasteboard), .annotateFile(url))
      try FileManager.default.removeItem(at: url)
      XCTAssertEqual(ClipboardOpenRoute.resolve(pasteboard: pasteboard),
        .annotateCopiedImage(data, fileExtension: fileExtension))
    }
  }

  func testУстаревшаяСсылкаНеЗабираетПикселиИзДругогоОбъекта() throws {
    let url = try makeFile("moved.png")
    let image = try XCTUnwrap(TestImageFactory.solidColor(width: 12, height: 8))
    let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    let item = NSPasteboardItem()
    XCTAssertTrue(item.setData(png, forType: .png))
    XCTAssertTrue(pasteboard.writeObjects([url as NSURL, item]))

    try FileManager.default.removeItem(at: url)
    XCTAssertEqual(ClipboardOpenRoute.resolve(pasteboard: pasteboard), .annotateFile(url))
  }

  func testКартинкаБезФайлаОткрываетсяВРедакторе() {
    pasteboard.clearContents()
    XCTAssertTrue(pasteboard.writeObjects([NSImage(size: NSSize(width: 8, height: 8))]))
    XCTAssertEqual(ClipboardOpenRoute.resolve(pasteboard: pasteboard), .annotateImage)
  }

  func testПервоеИзображениеTIFFСохраняетПриоритетПередPNG() throws {
    let image = try XCTUnwrap(TestImageFactory.solidColor(width: 14, height: 12))
    let bitmap = NSBitmapImageRep(cgImage: image)
    let tiff = try XCTUnwrap(bitmap.representation(using: .tiff, properties: [:]))
    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    let first = NSPasteboardItem()
    let second = NSPasteboardItem()
    XCTAssertTrue(first.setData(tiff, forType: .tiff))
    XCTAssertTrue(second.setData(png, forType: .png))
    XCTAssertTrue(pasteboard.writeObjects([first, second]))

    XCTAssertEqual(ClipboardOpenRoute.resolve(pasteboard: pasteboard), .annotateImage)
  }

  func testНеподдержанноеВидеоИПустойБуферНеОткрываютРедактор() throws {
    let url = try makeFile("clip.avi")
    pasteboard.clearContents()
    XCTAssertTrue(pasteboard.writeObjects([url as NSURL]))
    XCTAssertEqual(ClipboardOpenRoute.resolve(pasteboard: pasteboard), .unsupported,
      "Видео, которое не покажет Quick Access, не должно открываться пустым холстом")
    pasteboard.clearContents()
    XCTAssertEqual(ClipboardOpenRoute.resolve(pasteboard: pasteboard), .unsupported)
  }

  private func makeFile(_ name: String) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try Data([0]).write(to: url)
    return url
  }
}
