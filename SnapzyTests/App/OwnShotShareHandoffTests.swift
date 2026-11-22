//
//  OwnShotShareHandoffTests.swift
//  SnapzyTests
//
//  Передача картинки из Share-расширений Annotate и Pin: URL ownshot:// и копия в inbox.
//

import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import Snapzy

@MainActor
final class OwnShotShareHandoffTests: XCTestCase {
  private var tempDirectory: URL!

  override func setUp() {
    super.setUp()
    tempDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("SnapzyTests_ShareHandoff_\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: tempDirectory)
    tempDirectory = nil
    super.tearDown()
  }

  func testURLUsesExistingAutomationCommands() throws {
    let file = URL(fileURLWithPath: "/tmp/OwnShot/shot.png")
    XCTAssertEqual(
      OwnShotShareHandoff.url(for: .annotate, fileURL: file)?.absoluteString,
      "ownshot://open-annotate?filepath=/tmp/OwnShot/shot.png"
    )
    XCTAssertEqual(
      OwnShotShareHandoff.url(for: .pin, fileURL: file)?.absoluteString,
      "ownshot://pin?filepath=/tmp/OwnShot/shot.png"
    )
  }

  func testURLRoundTripsThroughDeepLinkParserForEveryCommand() throws {
    // Пробелы, кириллица и служебные символы query не должны ломать путь.
    let path = "/Users/nikoko/Library/Caches/dev.nikoko.ownshot/ShareInbox/A&B=C+D #1/Скрин 50%?.png"
    let file = URL(fileURLWithPath: path)
    for command in OwnShotShareHandoff.Command.allCases {
      let url = try XCTUnwrap(OwnShotShareHandoff.url(for: command, fileURL: file))
      guard case .automation(let request) = try XCTUnwrap(SnapzyDeepLinkAction(url: url)) else {
        return XCTFail("\(command.rawValue) не разобран как automation: \(url)")
      }
      XCTAssertEqual(request.command, command.rawValue)
      XCTAssertEqual(request.fileURL?.path, path)
    }
  }

  func testURLRejectsNonFileURL() throws {
    XCTAssertNil(OwnShotShareHandoff.url(for: .pin, fileURL: try XCTUnwrap(URL(string: "https://example.com/a.png"))))
  }

  func testImageTypePrefersPNGThenJPEGThenAnyImage() {
    XCTAssertEqual(
      OwnShotShareHandoff.imageTypeIdentifier(in: ["public.file-url", "public.jpeg", "public.png"]),
      UTType.png.identifier
    )
    XCTAssertEqual(OwnShotShareHandoff.imageTypeIdentifier(in: ["public.tiff", "public.jpeg"]), UTType.jpeg.identifier)
    XCTAssertEqual(OwnShotShareHandoff.imageTypeIdentifier(in: ["public.heic"]), "public.heic")
    XCTAssertNil(OwnShotShareHandoff.imageTypeIdentifier(in: ["public.plain-text", "public.url"]))
  }

  func testInboxDirectoryUsesAppCachesAndFallsBackToTemporary() throws {
    let home = URL(fileURLWithPath: "/Users/nikoko", isDirectory: true)
    let temporary = URL(fileURLWithPath: "/tmp/ext-tmp", isDirectory: true)
    XCTAssertEqual(
      OwnShotShareHandoff.inboxDirectory(homeDirectory: home, temporaryDirectory: temporary).path,
      "/Users/nikoko/Library/Caches/dev.nikoko.ownshot/ShareInbox"
    )
    XCTAssertEqual(
      OwnShotShareHandoff.inboxDirectory(homeDirectory: nil, temporaryDirectory: temporary).path,
      "/tmp/ext-tmp/ShareInbox"
    )
    XCTAssertEqual(OwnShotShareHandoff.realHomeDirectory()?.path, NSHomeDirectoryForUser(NSUserName()))
  }

  func testSandboxExceptionInEntitlementsMatchesInboxPath() throws {
    // Исключение песочницы и путь inbox должны совпадать, иначе расширение молча уйдёт во временный каталог.
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    for name in ["AnnotateShareExtension", "PinShareExtension"] {
      let url = root.appendingPathComponent("OwnShotExtensions/\(name)/\(name).entitlements")
      let plist = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: Any], name)
      XCTAssertEqual(plist["com.apple.security.app-sandbox"] as? Bool, true, name)
      let paths = try XCTUnwrap(plist["com.apple.security.temporary-exception.files.home-relative-path.read-write"] as? [String], name)
      XCTAssertEqual(paths, ["/\(OwnShotShareHandoff.sharedInboxHomeRelativePath)/"], name)
    }
  }

  func testStagedFileNameKeepsNameAndUsesTypeExtension() {
    XCTAssertEqual(OwnShotShareHandoff.stagedFileName(suggestedName: "Screenshot 1", typeIdentifier: "public.png"), "Screenshot 1.png")
    XCTAssertEqual(OwnShotShareHandoff.stagedFileName(suggestedName: "photo.JPG", typeIdentifier: "public.jpeg"), "photo.jpeg")
    XCTAssertEqual(OwnShotShareHandoff.stagedFileName(suggestedName: "a/b:c", typeIdentifier: "public.png"), "a-b-c.png")
    XCTAssertEqual(OwnShotShareHandoff.stagedFileName(suggestedName: nil, typeIdentifier: "public.png"), "Shared Image.png")
    XCTAssertEqual(OwnShotShareHandoff.stagedFileName(suggestedName: ".hidden", typeIdentifier: "public.png"), "Shared Image.png")
  }

  func testExpiredEntriesKeepFilesYoungerThanLifetime() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let fresh = URL(fileURLWithPath: "/tmp/fresh")
    let old = URL(fileURLWithPath: "/tmp/old")
    let expired = OwnShotShareHandoff.expiredEntries(
      [(fresh, now.addingTimeInterval(-60)), (old, now.addingTimeInterval(-OwnShotShareHandoff.stagedFileLifetime - 1))],
      now: now
    )
    XCTAssertEqual(expired, [old])
  }

  func testStageFileCopiesIntoUniqueSubdirectoryAndRemovesExpiredEntries() throws {
    let source = tempDirectory.appendingPathComponent("source.png")
    try Data("png".utf8).write(to: source)
    let inbox = tempDirectory.appendingPathComponent("ShareInbox", isDirectory: true)
    let stale = inbox.appendingPathComponent("stale", isDirectory: true)
    try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(-OwnShotShareHandoff.stagedFileLifetime * 2)],
      ofItemAtPath: stale.path
    )

    let first = try OwnShotShareHandoff.stageFile(at: source, suggestedName: "Shot", typeIdentifier: "public.png", in: inbox)
    let second = try OwnShotShareHandoff.stageFile(at: source, suggestedName: "Shot", typeIdentifier: "public.png", in: inbox)

    XCTAssertEqual(first.lastPathComponent, "Shot.png")
    XCTAssertNotEqual(first, second)
    XCTAssertEqual(first.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL, inbox.standardizedFileURL)
    XCTAssertEqual(try Data(contentsOf: first), Data("png".utf8))
    XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
  }

  func testStageProviderWritesImageDataAndURLOpensItInAutomation() async throws {
    let cgImage = try XCTUnwrap(TestImageFactory.solidColor(width: 4, height: 4))
    let pngData = try XCTUnwrap(AnnotateExporter.imageData(from: NSImage(cgImage: cgImage, size: CGSize(width: 4, height: 4)), for: "png"))
    let provider = NSItemProvider(item: pngData as NSData, typeIdentifier: UTType.png.identifier)
    provider.suggestedName = "Shared"
    let inbox = tempDirectory.appendingPathComponent("ShareInbox", isDirectory: true)

    let staged = try await OwnShotShareHandoff.stage(provider, in: inbox)

    XCTAssertEqual(staged.lastPathComponent, "Shared.png")
    XCTAssertEqual(try Data(contentsOf: staged), pngData)
    let url = try XCTUnwrap(OwnShotShareHandoff.url(for: .annotate, fileURL: staged))
    guard case .automation(let request) = SnapzyDeepLinkAction(url: url) else { return XCTFail("open-annotate не разобран") }
    XCTAssertEqual(request.fileURL?.standardizedFileURL, staged.standardizedFileURL)
  }

  func testStageProviderWithoutImageThrows() async {
    let provider = NSItemProvider(item: "text" as NSString, typeIdentifier: UTType.plainText.identifier)
    do {
      _ = try await OwnShotShareHandoff.stage(provider, in: tempDirectory)
      XCTFail("Ожидалась ошибка noImageAttachment")
    } catch {
      XCTAssertEqual(error as? OwnShotShareHandoff.HandoffError, .noImageAttachment)
    }
  }
}
