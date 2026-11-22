//
//  CaptureOutputNamingTests.swift
//  SnapzyTests
//
//  Unit tests for CaptureOutputNaming filename generation and sanitization.
//

import ImageIO
import XCTest
@testable import Snapzy

final class CaptureOutputNamingTests: XCTestCase {

  // Fixed date: 2026-01-15 14:30:45.123 UTC
  private let fixedDate = Date(timeIntervalSince1970: 1_768_512_645.123)
  private var tempDirectory: URL!
  private var defaults: UserDefaults!

  override func setUp() {
    super.setUp()
    tempDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("SnapzyTests_CaptureOutputNaming_\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    defaults = UserDefaultsFactory.make()
  }

  override func tearDown() {
    if let tempDirectory {
      try? FileManager.default.removeItem(at: tempDirectory)
    }
    super.tearDown()
  }

  // MARK: - resolveBaseName with custom name

  func testResolveBaseName_withCustomName_returnsSanitizedName() {
    let result = CaptureOutputNaming.resolveBaseName(
      customName: "My Screenshot",
      kind: .screenshot,
      date: fixedDate,
      defaults: defaults
    )
    XCTAssertEqual(result, "My Screenshot")
  }

  func testResolveBaseName_withNilCustomName_fallsBackToTemplate() {
    let result = CaptureOutputNaming.resolveBaseName(
      customName: nil,
      kind: .screenshot,
      date: fixedDate,
      defaults: defaults
    )
    // Шаблон по умолчанию: "OwnShot_{datetime}_{ms}"
    XCTAssertTrue(result.hasPrefix("OwnShot_"), "Expected template-based name, got: \(result)")
    XCTAssertTrue(result.contains("_"), "Expected datetime separators")
  }

  func testResolveBaseName_withEmptyCustomName_fallsBackToTemplate() {
    let result = CaptureOutputNaming.resolveBaseName(
      customName: "",
      kind: .screenshot,
      date: fixedDate,
      defaults: defaults
    )
    XCTAssertTrue(result.hasPrefix("OwnShot_"), "Expected template-based name, got: \(result)")
  }

  func testResolveBaseName_withWhitespaceOnlyCustomName_fallsBackToTemplate() {
    let result = CaptureOutputNaming.resolveBaseName(
      customName: "   ",
      kind: .screenshot,
      date: fixedDate,
      defaults: defaults
    )
    XCTAssertTrue(result.hasPrefix("OwnShot_"))
  }

  func testПользовательскийШаблонSnapzyСохраняется() {
    defaults.set("Snapzy_custom_{ms}", forKey: PreferencesKeys.screenshotFileNameTemplate)
    XCTAssertEqual(CaptureOutputNaming.resolveBaseName(customName: nil, kind: .screenshot, date: fixedDate, defaults: defaults), "Snapzy_custom_123")
  }

  // MARK: - Template Token Expansion

  func testResolveBaseName_typeToken_screenshot() {
    defaults.set("{type}_capture", forKey: PreferencesKeys.screenshotFileNameTemplate)

    let result = CaptureOutputNaming.resolveBaseName(
      customName: nil,
      kind: .screenshot,
      date: fixedDate,
      defaults: defaults
    )
    XCTAssertEqual(result, "screenshot_capture")
  }

  func testResolveBaseName_typeToken_recording() {
    defaults.set("{type}_file", forKey: PreferencesKeys.recordingFileNameTemplate)

    let result = CaptureOutputNaming.resolveBaseName(
      customName: nil,
      kind: .recording,
      date: fixedDate,
      defaults: defaults
    )
    XCTAssertEqual(result, "recording_file")
  }

  func testResolveBaseName_datetimeToken() {
    defaults.set("Snap_{datetime}", forKey: PreferencesKeys.screenshotFileNameTemplate)

    let result = CaptureOutputNaming.resolveBaseName(
      customName: nil,
      kind: .screenshot,
      date: fixedDate,
      defaults: defaults
    )

    // datetime format: yyyy-MM-dd_HH-mm-ss
    // Verify it contains a date-like pattern
    let datePattern = #"\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}"#
    XCTAssertNotNil(
      result.range(of: datePattern, options: .regularExpression),
      "Expected datetime pattern in: \(result)"
    )
  }

  func testResolveBaseName_msToken() {
    defaults.set("file_{ms}", forKey: PreferencesKeys.screenshotFileNameTemplate)

    let result = CaptureOutputNaming.resolveBaseName(
      customName: nil,
      kind: .screenshot,
      date: fixedDate,
      defaults: defaults
    )

    // ms token should be 3 digits
    let msPattern = #"file_\d{3}"#
    XCTAssertNotNil(
      result.range(of: msPattern, options: .regularExpression),
      "Expected ms pattern in: \(result)"
    )
  }

  func testResolveBaseName_timestampToken() {
    defaults.set("ts_{timestamp}", forKey: PreferencesKeys.screenshotFileNameTemplate)

    let result = CaptureOutputNaming.resolveBaseName(
      customName: nil,
      kind: .screenshot,
      date: fixedDate,
      defaults: defaults
    )

    let expected = "ts_\(Int(fixedDate.timeIntervalSince1970))"
    XCTAssertEqual(result, expected)
  }

  func testResolveBaseName_yearMonthDayTokens() {
    defaults.set("{year}/{month}/{day}/shot", forKey: PreferencesKeys.screenshotFileNameTemplate)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let localDate = calendar.date(from: DateComponents(
      year: 2026,
      month: 1,
      day: 15,
      hour: 14,
      minute: 30,
      second: 45
    ))!

    let result = CaptureOutputNaming.resolveBaseName(
      customName: nil,
      kind: .screenshot,
      date: localDate,
      defaults: defaults
    )

    XCTAssertEqual(result, "2026/01/15/shot")
  }

  func testResolveBaseName_yearShortTokens() {
    defaults.set("{year}/{yearShort}/{year_short}/{yy}/shot", forKey: PreferencesKeys.screenshotFileNameTemplate)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let localDate = calendar.date(from: DateComponents(
      year: 2026,
      month: 1,
      day: 15,
      hour: 14,
      minute: 30,
      second: 45
    ))!

    let result = CaptureOutputNaming.resolveBaseName(
      customName: nil,
      kind: .screenshot,
      date: localDate,
      defaults: defaults
    )

    XCTAssertEqual(result, "2026/26/26/26/shot")
  }

  func testResolveBaseName_monthNameTokens() {
    defaults.set(
      "{year}/{monthName}/{monthShort}/{month_name}/{month_short}/shot",
      forKey: PreferencesKeys.screenshotFileNameTemplate
    )
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let localDate = calendar.date(from: DateComponents(
      year: 2026,
      month: 1,
      day: 15,
      hour: 14,
      minute: 30,
      second: 45
    ))!
    let monthName = CaptureOutputNaming.resolveBaseName(
      customName: Self.format(localDate, style: "MMMM"),
      kind: .screenshot,
      date: localDate,
      defaults: defaults
    )
    let monthShort = CaptureOutputNaming.resolveBaseName(
      customName: Self.format(localDate, style: "MMM"),
      kind: .screenshot,
      date: localDate,
      defaults: defaults
    )

    let result = CaptureOutputNaming.resolveBaseName(
      customName: nil,
      kind: .screenshot,
      date: localDate,
      defaults: defaults
    )

    XCTAssertEqual(result, "2026/\(monthName)/\(monthShort)/\(monthName)/\(monthShort)/shot")
  }

  func testResolveBaseName_templateWithSlash_returnsRelativeSubpath() {
    defaults.set("{type}/{timestamp}/shot_{ms}", forKey: PreferencesKeys.screenshotFileNameTemplate)

    let result = CaptureOutputNaming.resolveBaseName(
      customName: nil,
      kind: .screenshot,
      date: fixedDate,
      defaults: defaults
    )

    XCTAssertEqual(result, "screenshot/\(Int(fixedDate.timeIntervalSince1970))/shot_123")
  }

  func testResolveTemplateBaseName_returnsPreviewSubpath() {
    let result = CaptureOutputNaming.resolveTemplateBaseName(
      "Shots/{timestamp}/Snapzy_{ms}",
      kind: .screenshot,
      date: fixedDate
    )

    XCTAssertEqual(result, "Shots/\(Int(fixedDate.timeIntervalSince1970))/Snapzy_123")
  }

  /// Mirror of the production formatter in `CaptureOutputNaming`: Gregorian
  /// calendar so the year is Gregorian, locale left to the system so expected
  /// month names track what production emits on the machine running the tests.
  private static func format(_ date: Date, style: String) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = style
    return formatter.string(from: date)
  }

  // MARK: - Sanitization

  func testSanitize_slashCreatesSubpathAndInvalidFilenameCharactersUseUnderscore() {
    let result = CaptureOutputNaming.resolveBaseName(
      customName: "file/with\\bad:chars?test",
      kind: .screenshot,
      date: fixedDate,
      defaults: defaults
    )
    XCTAssertEqual(result, "file/with_bad_chars_test")
    XCTAssertTrue(result.contains("/"))
    XCTAssertFalse(result.contains("\\"))
    XCTAssertFalse(result.contains(":"))
    XCTAssertFalse(result.contains("?"))
  }

  func testSanitize_pathTraversalComponents_areDropped() {
    let result = CaptureOutputNaming.resolveBaseName(
      customName: "../Shots//./2026:May/final.png",
      kind: .screenshot,
      date: fixedDate,
      defaults: defaults
    )
    XCTAssertEqual(result, "Shots/2026_May/final")
    XCTAssertFalse(result.contains(".."))
  }

  func testSanitize_consecutiveUnderscores_collapsed() {
    let result = CaptureOutputNaming.resolveBaseName(
      customName: "file___name",
      kind: .screenshot,
      date: fixedDate,
      defaults: defaults
    )
    XCTAssertFalse(result.contains("___"))
    XCTAssertTrue(result.contains("_"))
  }

  func testSanitize_knownExtension_stripped() {
    let result = CaptureOutputNaming.resolveBaseName(
      customName: "myfile.png",
      kind: .screenshot,
      date: fixedDate,
      defaults: defaults
    )
    XCTAssertEqual(result, "myfile")
  }

  func testSanitize_knownExtension_jpegStripped() {
    let result = CaptureOutputNaming.resolveBaseName(
      customName: "capture.jpeg",
      kind: .screenshot,
      date: fixedDate,
      defaults: defaults
    )
    XCTAssertEqual(result, "capture")
  }

  func testSanitize_knownExtension_strippedFromLeafOnly() {
    let result = CaptureOutputNaming.resolveBaseName(
      customName: "Screenshots.png/capture.jpeg",
      kind: .screenshot,
      date: fixedDate,
      defaults: defaults
    )
    XCTAssertEqual(result, "Screenshots.png/capture")
  }

  func testSanitize_unknownExtension_preserved() {
    let result = CaptureOutputNaming.resolveBaseName(
      customName: "document.pdf",
      kind: .screenshot,
      date: fixedDate,
      defaults: defaults
    )
    XCTAssertEqual(result, "document.pdf")
  }

  func testSanitize_trimmingDotsAndSpaces() {
    let result = CaptureOutputNaming.resolveBaseName(
      customName: "  .file. ",
      kind: .screenshot,
      date: fixedDate,
      defaults: defaults
    )
    XCTAssertEqual(result, "file")
  }

  // MARK: - makeUniqueFileURL

  func testMakeUniqueFileURL_noCollision_returnsBaseURL() {
    let result = CaptureOutputNaming.makeUniqueFileURL(
      in: tempDirectory,
      baseName: "test_capture",
      fileExtension: "png"
    )
    XCTAssertEqual(result.lastPathComponent, "test_capture.png")
  }

  func testMakeUniqueFileURL_withCollision_appendsSuffix() throws {
    // Create first file
    let firstFile = tempDirectory.appendingPathComponent("test_capture.png")
    try Data("test".utf8).write(to: firstFile)

    let result = CaptureOutputNaming.makeUniqueFileURL(
      in: tempDirectory,
      baseName: "test_capture",
      fileExtension: "png"
    )
    XCTAssertEqual(result.lastPathComponent, "test_capture_2.png")
  }

  func testMakeUniqueFileURL_withMultipleCollisions_incrementsSuffix() throws {
    // Create first two files
    try Data("test".utf8).write(to: tempDirectory.appendingPathComponent("shot.png"))
    try Data("test".utf8).write(to: tempDirectory.appendingPathComponent("shot_2.png"))

    let result = CaptureOutputNaming.makeUniqueFileURL(
      in: tempDirectory,
      baseName: "shot",
      fileExtension: "png"
    )
    XCTAssertEqual(result.lastPathComponent, "shot_3.png")
  }

  func testСвободноеИмяПропускаетСсылкиБезЦели() throws {
    let files = FileManager.default
    let first = tempDirectory.appendingPathComponent("shot.mov")
    let second = tempDirectory.appendingPathComponent("shot_2.mov")
    let missing = tempDirectory.appendingPathComponent("missing.mov")
    try files.createSymbolicLink(at: first, withDestinationURL: missing)
    try files.createSymbolicLink(at: second, withDestinationURL: missing)

    let result = CaptureOutputNaming.makeUniqueFileURL(
      in: tempDirectory, baseName: "shot", fileExtension: "mov"
    )

    XCTAssertEqual(result.lastPathComponent, "shot_3.mov")
    XCTAssertEqual(try files.destinationOfSymbolicLink(atPath: first.path), missing.path)
    XCTAssertEqual(try files.destinationOfSymbolicLink(atPath: second.path), missing.path)
  }

  func testMakeUniqueFileURL_withNestedBaseName_returnsSubfolderURL() {
    let result = CaptureOutputNaming.makeUniqueFileURL(
      in: tempDirectory,
      baseName: "Shots/May/shot",
      fileExtension: "png"
    )

    let expected = tempDirectory
      .appendingPathComponent("Shots/May/shot.png")
    XCTAssertEqual(result.path, expected.path)
  }

  func testMakeUniqueFileURL_withNestedCollision_appendsSuffixToLeaf() throws {
    let nestedDirectory = tempDirectory
      .appendingPathComponent("Shots/May", isDirectory: true)
    try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
    try Data("test".utf8).write(to: nestedDirectory.appendingPathComponent("shot.png"))
    try Data("test".utf8).write(to: nestedDirectory.appendingPathComponent("shot_2.png"))

    let result = CaptureOutputNaming.makeUniqueFileURL(
      in: tempDirectory,
      baseName: "Shots/May/shot",
      fileExtension: "png"
    )

    XCTAssertEqual(result.lastPathComponent, "shot_3.png")
    XCTAssertEqual(result.deletingLastPathComponent().lastPathComponent, "May")
  }

  @MainActor
  func testSaveProcessedImage_withNestedFileName_createsParentDirectory() async throws {
    let image = try XCTUnwrap(TestImageFactory.solidColor(width: 2, height: 2))
    let baseName = CaptureOutputNaming.resolveBaseName(
      customName: "Runtime/Subfolder/shot",
      kind: .screenshot,
      date: fixedDate,
      defaults: defaults
    )

    let result = await ScreenCaptureManager.shared.saveProcessedImage(
      image,
      to: tempDirectory,
      fileName: baseName,
      format: .png
    )

    guard case .success(let url) = result else {
      XCTFail("Expected nested screenshot save to succeed, got \(result)")
      return
    }

    let expectedURL = tempDirectory.appendingPathComponent("Runtime/Subfolder/shot.png")
    XCTAssertEqual(url.path, expectedURL.path)
    XCTAssertTrue(FileManager.default.fileExists(atPath: expectedURL.path))
  }

  @MainActor
  func testConcurrentScreenshotSavesPublishSeparateImages() async throws {
    try await assertConcurrentScreenshotSaves(
      baseName: "shot", expectedSecondName: "shot_2.png"
    )
  }

  @MainActor
  func testConcurrentScreenshotSavesKeepTheExtensionWithAMaximumLengthName() async throws {
    let baseName = String(repeating: "s", count: 251)
    try await assertConcurrentScreenshotSaves(
      baseName: baseName,
      expectedSecondName: String(repeating: "s", count: 249) + "_2.png"
    )
  }

  @MainActor
  func testConcurrentWebPScreenshotSavesPublishSeparateImages() async throws {
    try await assertConcurrentScreenshotSaves(
      baseName: "shot", expectedSecondName: "shot_2.webp", format: .webp
    )
  }

  @MainActor
  private func assertConcurrentScreenshotSaves(
    baseName: String, expectedSecondName: String, format: ImageFormat = .png
  ) async throws {
    let firstImage = try XCTUnwrap(TestImageFactory.solidColor(width: 3, height: 2))
    let secondImage = try XCTUnwrap(TestImageFactory.solidColor(width: 7, height: 5))
    let directory = try XCTUnwrap(tempDirectory)
    let (firstEntered, firstReady) = AsyncStream<Void>.makeStream()
    let (secondEntered, secondReady) = AsyncStream<Void>.makeStream()
    let (firstGate, releaseFirst) = AsyncStream<Void>.makeStream()
    let (secondGate, releaseSecond) = AsyncStream<Void>.makeStream()
    defer {
      releaseFirst.finish()
      releaseSecond.finish()
    }

    let first = Task {
      defer { firstReady.finish() }
      return await ScreenCaptureManager.shared.saveProcessedImage(
        firstImage, to: directory, fileName: "Runtime/Subfolder/" + baseName, format: format,
        emitCompletion: false, context: .empty.withoutNamePrompt(), outputAlreadyProcessed: true,
        beforeEncoding: {
          firstReady.finish()
          for await _ in firstGate {}
        }
      )
    }
    let second = Task {
      defer { secondReady.finish() }
      return await ScreenCaptureManager.shared.saveProcessedImage(
        secondImage, to: directory, fileName: "Runtime/Subfolder/" + baseName, format: format,
        emitCompletion: false, context: .empty.withoutNamePrompt(), outputAlreadyProcessed: true,
        beforeEncoding: {
          secondReady.finish()
          for await _ in secondGate {}
        }
      )
    }

    for await _ in firstEntered {}
    for await _ in secondEntered {}
    releaseFirst.finish()
    let firstResult = await first.value
    releaseSecond.finish()
    let secondResult = await second.value

    guard case let .success(firstURL) = firstResult, case let .success(secondURL) = secondResult else {
      XCTFail("Both screenshot encodes must publish: \(firstResult), \(secondResult)")
      return
    }
    let firstName = baseName + "." + format.fileExtension
    XCTAssertEqual(firstURL.lastPathComponent, firstName)
    XCTAssertEqual(secondURL.lastPathComponent, expectedSecondName)
    XCTAssertEqual(try screenshotPixelSize(at: firstURL), CGSize(width: 3, height: 2))
    XCTAssertEqual(try screenshotPixelSize(at: secondURL), CGSize(width: 7, height: 5))
    XCTAssertEqual(
      Set(try FileManager.default.contentsOfDirectory(atPath: firstURL.deletingLastPathComponent().path)),
      [firstName, expectedSecondName]
    )
  }

  @MainActor
  func testScreenshotSaveDoesNotReplaceFileInRelocatedParentReplacement() async throws {
    let image = try XCTUnwrap(TestImageFactory.solidColor(width: 3, height: 2))
    let directory = tempDirectory.appendingPathComponent("original", isDirectory: true)
    let relocated = tempDirectory.appendingPathComponent("relocated", isDirectory: true)
    let replacement = directory.appendingPathComponent("shot.png")
    let bytes = Data("Replacement directory file".utf8)

    let result = await ScreenCaptureManager.shared.saveProcessedImage(
      image, to: directory, fileName: "shot",
      emitCompletion: false, context: .empty.withoutNamePrompt(), outputAlreadyProcessed: true,
      beforeEncoding: {
        do {
          // Model bytes encoded into the private stage before the parent moved.
          let stagedDirectory = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
          ).first { $0.lastPathComponent.hasPrefix(".os-") }
          if let stagedDirectory {
            try Data("Staged image bytes".utf8).write(to: stagedDirectory.appendingPathComponent("image.png"))
          }
          try FileManager.default.moveItem(at: directory, to: relocated)
          try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
          try bytes.write(to: replacement)
        } catch {
          XCTFail("Could not replace scratch directory: \(error)")
        }
      }
    )

    if case .success = result { XCTFail("A moved export directory must not publish into its replacement") }
    XCTAssertEqual(try Data(contentsOf: replacement), bytes)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["shot.png"])
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: relocated.path).isEmpty)
  }

  @MainActor
  func testScreenshotCancelledBeforeEncodingDoesNotPublish() async throws {
    let image = try XCTUnwrap(TestImageFactory.solidColor(width: 3, height: 2))
    let directory = try XCTUnwrap(tempDirectory)
    let (entered, ready) = AsyncStream<Void>.makeStream()
    let (gate, release) = AsyncStream<Void>.makeStream()
    defer { release.finish() }

    let save = Task {
      defer { ready.finish() }
      return await ScreenCaptureManager.shared.saveProcessedImage(
        image, to: directory, fileName: "shot",
        emitCompletion: false, context: .empty.withoutNamePrompt(), outputAlreadyProcessed: true,
        beforeEncoding: {
          ready.finish()
          for await _ in gate {}
        }
      )
    }
    for await _ in entered {}
    save.cancel()
    release.finish()
    let result = await save.value

    guard case .failure(.cancelled) = result else {
      XCTFail("Expected cancelled save without publication, got \(result)")
      return
    }
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
  }

  private func screenshotPixelSize(at url: URL) throws -> CGSize {
    let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
    let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    return CGSize(width: image.width, height: image.height)
  }

  // MARK: - resolvedTemplate

  func testResolvedTemplate_withSavedValue_returnsSavedValue() {
    defaults.set("Custom_{date}", forKey: PreferencesKeys.screenshotFileNameTemplate)

    let result = CaptureOutputNaming.resolvedTemplate(for: .screenshot, defaults: defaults)
    XCTAssertEqual(result, "Custom_{date}")
  }

  func testResolvedTemplate_withEmptyValue_returnsDefault() {
    defaults.set("", forKey: PreferencesKeys.screenshotFileNameTemplate)

    let result = CaptureOutputNaming.resolvedTemplate(for: .screenshot, defaults: defaults)
    XCTAssertEqual(result, CaptureOutputKind.screenshot.defaultTemplate)
  }

  func testResolvedTemplate_withMissingKey_returnsDefault() {
    defaults.removeObject(forKey: PreferencesKeys.screenshotFileNameTemplate)

    let result = CaptureOutputNaming.resolvedTemplate(for: .screenshot, defaults: defaults)
    XCTAssertEqual(result, CaptureOutputKind.screenshot.defaultTemplate)
  }

  func testResolvedTemplate_recording_returnsRecordingDefault() {
    defaults.removeObject(forKey: PreferencesKeys.recordingFileNameTemplate)

    let result = CaptureOutputNaming.resolvedTemplate(for: .recording, defaults: defaults)
    XCTAssertEqual(result, CaptureOutputKind.recording.defaultTemplate)
  }

  // MARK: - CaptureOutputKind Properties

  func testCaptureOutputKind_defaultTemplates() {
    XCTAssertEqual(CaptureOutputKind.screenshot.defaultTemplate, "OwnShot_{datetime}_{ms}")
    XCTAssertEqual(CaptureOutputKind.recording.defaultTemplate, "OwnShot_Recording_{datetime}")
  }

  func testCaptureOutputKind_typeTokenValues() {
    XCTAssertEqual(CaptureOutputKind.screenshot.typeTokenValue, "screenshot")
    XCTAssertEqual(CaptureOutputKind.recording.typeTokenValue, "recording")
  }

  // MARK: - Fallback Name

  func testResolveBaseName_invalidTemplate_usesFallbackName() {
    // Template that resolves to empty after sanitization
    defaults.set("...", forKey: PreferencesKeys.screenshotFileNameTemplate)

    let result = CaptureOutputNaming.resolveBaseName(
      customName: nil,
      kind: .screenshot,
      date: fixedDate,
      defaults: defaults
    )

    // Резервный формат: "OwnShot_{yyyy-MM-dd_HH-mm-ss-SSS}" — also pin the Gregorian
    // year so the fallback path (which routes through `format`) is covered too.
    XCTAssertTrue(result.hasPrefix("OwnShot_2026"), "Expected fallback name with Gregorian year 2026, got: \(result)")
  }

  // MARK: - App Name Tokens

  func testResolveBaseName_appNameTokens() {
    defaults.set("App_{appName}", forKey: PreferencesKeys.screenshotFileNameTemplate)
    let context = CaptureContext(appName: "Safari", windowTitle: nil)

    let result = CaptureOutputNaming.resolveBaseName(
      customName: nil,
      kind: .screenshot,
      date: fixedDate,
      context: context,
      defaults: defaults
    )
    XCTAssertEqual(result, "App_Safari")
  }

  func testResolveBaseName_appNameTokens_aliases() {
    defaults.set("App_{app_name}", forKey: PreferencesKeys.screenshotFileNameTemplate)
    let context = CaptureContext(appName: "Finder", windowTitle: nil)

    let result = CaptureOutputNaming.resolveBaseName(
      customName: nil,
      kind: .screenshot,
      date: fixedDate,
      context: context,
      defaults: defaults
    )
    XCTAssertEqual(result, "App_Finder")
  }

  func testResolveBaseName_appNameTokens_missing() {
    defaults.set("App_{appName}", forKey: PreferencesKeys.screenshotFileNameTemplate)
    let context = CaptureContext(appName: nil, windowTitle: nil)

    let result = CaptureOutputNaming.resolveBaseName(
      customName: nil,
      kind: .screenshot,
      date: fixedDate,
      context: context,
      defaults: defaults
    )
    // When appName is missing, it should resolve to empty string
    // Resulting in App_
    XCTAssertEqual(result, "App_")
  }

  // MARK: - Locale / Gregorian Calendar

  /// Regression test for the system-calendar locale bug: a `DateFormatter` that
  /// adopts the user's locale renders the Buddhist year under a Thai (`th_TH`)
  /// locale (e.g. 2569 for the Gregorian year 2026). Snapzy must always emit the
  /// Gregorian year in filenames regardless of the user's system calendar.
  ///
  /// Note: the process locale cannot be swapped at runtime (`Locale.current` is
  /// cached for the XCTest host process), so this test cannot deterministically
  /// fail pre-fix on a Gregorian CI runner. Instead it (1) proves the Buddhist
  /// calendar actually shifts the year for the reference date, and (2) pins the
  /// Gregorian contract for Snapzy's output. It WILL fail on a Buddhist-locale
  /// machine if the Gregorian calendar override on the internal formatter is
  /// reverted.
  func testYearToken_alwaysGregorian_notBuddhistCalendarYear() {
    var gregorian = Calendar(identifier: .gregorian)
    gregorian.timeZone = TimeZone(secondsFromGMT: 0)!
    let date = gregorian.date(from: DateComponents(year: 2026, month: 1, day: 15))!

    // Premise guard (not a regression guard): under a Thai (Buddhist) locale the
    // bare `yyyy` year differs from the Gregorian year for this date. This only
    // protects the test's assumption against future Foundation locale-data drift;
    // it cannot detect a fix regression on its own (see the note above).
    let buddhist = DateFormatter()
    buddhist.locale = Locale(identifier: "th_TH")
    buddhist.dateFormat = "yyyy"
    let buddhistYear = buddhist.string(from: date)
    let gregorianYear = String(gregorian.component(.year, from: date))
    XCTAssertNotEqual(
      buddhistYear, gregorianYear,
      "Precondition: th_TH must render a Buddhist year (\(buddhistYear)) that differs " +
      "from the Gregorian year (\(gregorianYear)) for this date."
    )

    defaults.set("{year}", forKey: PreferencesKeys.screenshotFileNameTemplate)

    let result = CaptureOutputNaming.resolveBaseName(
      customName: nil,
      kind: .screenshot,
      date: date,
      defaults: defaults
    )

    XCTAssertEqual(
      result, "2026",
      "Filename year must be Gregorian (2026), not the Buddhist year (\(buddhistYear))."
    )
  }

  /// End-to-end guard over the default screenshot template: the generated name
  /// must start with the Gregorian year, never a Buddhist-calendar year, even on
  /// systems whose calendar is non-Gregorian.
  ///
  /// Same runtime-locale caveat as `testYearToken_alwaysGregorian_notBuddhistCalendarYear`:
  /// this cannot deterministically fail pre-fix on a Gregorian CI runner (the
  /// process locale is cached), but it pins the Gregorian contract and will fail
  /// on a Buddhist-locale machine if the Gregorian calendar override is reverted.
  func testDefaultTemplate_startsGregorianYear_notBuddhistYear() {
    var gregorian = Calendar(identifier: .gregorian)
    gregorian.timeZone = TimeZone(secondsFromGMT: 0)!
    let date = gregorian.date(from: DateComponents(year: 2026, month: 1, day: 15))!

    // Reference: Buddhist year for this date.
    let buddhist = DateFormatter()
    buddhist.locale = Locale(identifier: "th_TH")
    buddhist.dateFormat = "yyyy"
    let buddhistYear = buddhist.string(from: date)

    // Шаблон по умолчанию: "OwnShot_{datetime}_{ms}"
    let result = CaptureOutputNaming.resolveBaseName(
      customName: nil,
      kind: .screenshot,
      date: date,
      defaults: defaults
    )

    XCTAssertTrue(result.hasPrefix("OwnShot_2026-"), "Default name must start with Gregorian year, got: \(result)")
    XCTAssertFalse(
      result.hasPrefix("OwnShot_\(buddhistYear)-"),
      "Default name must not use the Buddhist year \(buddhistYear), got: \(result)"
    )
  }

  /// Pins the narrower contract of the calendar-only fix: a Gregorian calendar
  /// keeps the year Gregorian under non-Gregorian system calendars while the
  /// locale stays untouched, so `{monthName}`/`{monthShort}` remain localized.
  ///
  /// The production formatter is private and adopts the process locale, which
  /// XCTest cannot swap at runtime, so this test rebuilds the production
  /// configuration (`DateFormatter` + `Calendar(identifier: .gregorian)`) with
  /// an explicit `th_TH` locale — the harshest case, where the bare formatter
  /// emits the Buddhist year — and asserts both halves of the contract.
  func testGregorianCalendarOverride_keepsLocalizedMonthNames() {
    var gregorian = Calendar(identifier: .gregorian)
    gregorian.timeZone = TimeZone(secondsFromGMT: 0)!
    let date = gregorian.date(from: DateComponents(year: 2026, month: 1, day: 15))!

    // Premise: without the calendar override a th_TH formatter emits the
    // Buddhist year, not the Gregorian one.
    let bare = DateFormatter()
    bare.locale = Locale(identifier: "th_TH")
    bare.dateFormat = "yyyy"
    let bareYear = bare.string(from: date)
    XCTAssertNotEqual(
      bareYear, "2026",
      "Precondition: th_TH must render the Buddhist year (\(bareYear)), not the Gregorian year."
    )

    // Production configuration with an explicit th_TH locale: Gregorian year
    // plus the localized (Thai) month name.
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "th_TH")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = "yyyy MMMM"
    XCTAssertEqual(
      formatter.string(from: date), "2026 มกราคม",
      "Gregorian calendar + th_TH locale must yield the Gregorian year with the localized month name."
    )
  }
}
