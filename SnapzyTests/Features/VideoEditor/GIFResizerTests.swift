//
//  GIFResizerTests.swift
//  SnapzyTests
//
//  Unit tests for resizing animated GIFs off the main actor.
//

import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import Snapzy

@MainActor
final class GIFResizerTests: XCTestCase {

  private var directory: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("GIFResizerTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
    directory = nil
    try super.tearDownWithError()
  }

  func testResize_preservesFramesDelaysAndLoopCount() async throws {
    let delays = [0.1, 0.2, 0.3]
    let sourceURL = try makeGIF(size: CGSize(width: 80, height: 40), delays: delays, loopCount: 2)
    let outputURL = directory.appendingPathComponent("out/resized.gif")

    try await GIFResizer.resize(
      sourceURL: sourceURL,
      targetSize: CGSize(width: 40, height: 20),
      outputURL: outputURL
    ) { _ in }

    let source = try XCTUnwrap(CGImageSourceCreateWithURL(outputURL as CFURL, nil))
    XCTAssertEqual(CGImageSourceGetCount(source), delays.count)

    let firstFrame = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    XCTAssertEqual(firstFrame.width, 40)
    XCTAssertEqual(firstFrame.height, 20)

    for (index, expectedDelay) in delays.enumerated() {
      let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
      let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
      let delay = try XCTUnwrap(gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
      XCTAssertEqual(delay, expectedDelay, accuracy: 0.001)
    }

    let fileProperties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
    let gif = fileProperties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
    XCTAssertEqual(gif?[kCGImagePropertyGIFLoopCount] as? Int, 2)
  }

  func testTrim_keepsOverlappingFramesWithClippedDelays() async throws {
    let delays = [0.11, 0.17, 0.19, 0.23, 0.29]
    let size = CGSize(width: 8, height: 4)
    let sourceURL = try makeGIF(size: size, delays: delays, loopCount: 3, transparent: true)
    let outputURL = directory.appendingPathComponent("trimmed.gif")
    let inputMetadata = try XCTUnwrap(GIFResizer.metadata(for: sourceURL))
    XCTAssertEqual(inputMetadata.frameDurations.count, delays.count)
    for (actual, expected) in zip(inputMetadata.frameDurations, delays) {
      XCTAssertEqual(actual, expected, accuracy: 0.001)
    }

    try await GIFResizer.resize(
      sourceURL: sourceURL,
      targetSize: size,
      outputURL: outputURL,
      trimRange: 0.13 ..< 0.55
    ) { _ in }

    let input = try XCTUnwrap(CGImageSourceCreateWithURL(sourceURL as CFURL, nil))
    let output = try XCTUnwrap(CGImageSourceCreateWithURL(outputURL as CFURL, nil))
    XCTAssertEqual(CGImageSourceGetCount(output), 3)

    let outputMetadata = try XCTUnwrap(GIFResizer.metadata(for: outputURL))
    XCTAssertEqual(outputMetadata.size, size)
    XCTAssertEqual(outputMetadata.duration, 0.42, accuracy: 0.001)

    for (index, expectedDelay) in [0.15, 0.19, 0.08].enumerated() {
      let properties = CGImageSourceCopyPropertiesAtIndex(output, index, nil) as? [CFString: Any]
      let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
      let delay = try XCTUnwrap(gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
      XCTAssertEqual(delay, expectedDelay, accuracy: 0.001)

      let originalFrame = try XCTUnwrap(CGImageSourceCreateImageAtIndex(input, index + 1, nil))
      let retainedFrame = try XCTUnwrap(CGImageSourceCreateImageAtIndex(output, index, nil))
      let opaquePixel = try pixel(in: originalFrame, x: 1)
      let transparentPixel = try pixel(in: originalFrame, x: 6)
      XCTAssertEqual(opaquePixel[3], 255)
      XCTAssertEqual(transparentPixel[3], 0)
      XCTAssertEqual(try pixel(in: retainedFrame, x: 1), opaquePixel)
      XCTAssertEqual(try pixel(in: retainedFrame, x: 6), transparentPixel)
    }

    let properties = CGImageSourceCopyProperties(output, nil) as? [CFString: Any]
    let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
    XCTAssertEqual(gif?[kCGImagePropertyGIFLoopCount] as? Int, 3)
  }

  func testTrim_preservesSingleFrameAndRoundsToCentiseconds() async throws {
    let size = CGSize(width: 8, height: 4)
    let sourceURL = try makeGIF(size: size, delays: [0.17, 0.19, 0.23], loopCount: 5)
    let outputURL = directory.appendingPathComponent("single.gif")

    try await GIFResizer.resize(
      sourceURL: sourceURL,
      targetSize: size,
      outputURL: outputURL,
      trimRange: 0.181 ..< 0.194
    ) { _ in }

    let input = try XCTUnwrap(CGImageSourceCreateWithURL(sourceURL as CFURL, nil))
    let output = try XCTUnwrap(CGImageSourceCreateWithURL(outputURL as CFURL, nil))
    XCTAssertEqual(CGImageSourceGetCount(output), 1)
    let originalFrame = try XCTUnwrap(CGImageSourceCreateImageAtIndex(input, 1, nil))
    let retainedFrame = try XCTUnwrap(CGImageSourceCreateImageAtIndex(output, 0, nil))
    XCTAssertEqual(try pixel(in: retainedFrame, x: 1), try pixel(in: originalFrame, x: 1))

    let properties = CGImageSourceCopyPropertiesAtIndex(output, 0, nil) as? [CFString: Any]
    let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
    let delay = try XCTUnwrap(gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
    XCTAssertEqual(delay, 0.01, accuracy: 0.001)

    let outputProperties = CGImageSourceCopyProperties(output, nil) as? [CFString: Any]
    let outputGIF = outputProperties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
    XCTAssertEqual(outputGIF?[kCGImagePropertyGIFLoopCount] as? Int, 5)
  }

  func testTrim_rejectsEmptyAndMalformedSelectionsWithoutPublishing() async throws {
    let size = CGSize(width: 8, height: 4)
    let sourceURL = try makeGIF(size: size, delays: [0.17, 0.19], loopCount: 0)
    let outputURL = directory.appendingPathComponent("existing.gif")
    let sourceData = try Data(contentsOf: sourceURL)
    let outputData = Data("прежняя версия".utf8)
    try outputData.write(to: outputURL)

    for range in [0.17 ..< 0.17, 0.5 ..< 0.7, 0.17 ..< Double.infinity] {
      do {
        try await GIFResizer.resize(
          sourceURL: sourceURL, targetSize: size, outputURL: outputURL, trimRange: range
        ) { _ in }
        XCTFail("Экспорт должен отклонить диапазон \(range)")
      } catch {
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceData)
        XCTAssertEqual(try Data(contentsOf: outputURL), outputData)
      }
    }
  }

  func testReplaceOriginal_preservesExistingBackupFile() async throws {
    let url = try makeGIF(size: CGSize(width: 80, height: 40), delays: [0.1, 0.2], loopCount: 0)
    let backupContents = Data("чужой файл".utf8)
    let backupURL = directory.appendingPathComponent(".\(url.lastPathComponent).backup")
    try backupContents.write(to: backupURL)

    let preferences = PreferencesManager.shared
    let copiesRecording = preferences.isActionEnabled(.copyFile, for: .recording)
    preferences.setAction(.copyFile, for: .recording, enabled: false)
    defer { preferences.setAction(.copyFile, for: .recording, enabled: copiesRecording) }

    let controller = VideoEditorWindowController(url: url)
    let window = try XCTUnwrap(controller.window)
    let hostingView = try XCTUnwrap(window.contentView as? NSHostingView<VideoEditorMainView>)
    let state = hostingView.rootView.state
    await state.loadMetadata()
    state.exportSettings.dimensionPreset = .percent50

    window.orderFront(nil)
    defer {
      if let sheet = window.attachedSheet {
        window.endSheet(sheet, returnCode: .abort)
      }
      window.close()
    }
    let onSave = try XCTUnwrap(hostingView.rootView.onSave)
    onSave()
    let confirmation = try XCTUnwrap(window.attachedSheet)
    window.endSheet(confirmation, returnCode: .alertFirstButtonReturn)

    let deadline = ContinuousClock.now + .seconds(5)
    while window.isVisible, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertFalse(window.isVisible, "Редактор должен закрыться после успешной записи GIF")
    XCTAssertEqual(GIFResizer.metadata(for: url)?.size, CGSize(width: 40, height: 20))
    XCTAssertEqual(try? Data(contentsOf: backupURL), backupContents)
  }

  func testResize_preservesDirectoryAtDestination() async throws {
    let source = try makeGIF(size: CGSize(width: 80, height: 40), delays: [0.1, 0.2], loopCount: 0)
    let output = directory.appendingPathComponent("selected.gif", isDirectory: true)
    let note = output.appendingPathComponent("note.txt")
    let contents = Data("сохранить".utf8)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
    try contents.write(to: note)

    do {
      try await GIFResizer.resize(
        sourceURL: source, targetSize: CGSize(width: 40, height: 20), outputURL: output
      ) { _ in }
      XCTFail("Экспорт не должен заменять каталог")
    } catch {}

    XCTAssertEqual(try? Data(contentsOf: note), contents)
  }

  func testResize_preservesExistingFileIfEncodingFails() async throws {
    let source = try makeGIF(size: CGSize(width: 80, height: 40), delays: [0.1, 0.2], loopCount: 0)
    let output = directory.appendingPathComponent("selected.gif")
    let contents = Data("прежняя версия".utf8)
    try contents.write(to: output)

    do {
      try await GIFResizer.resize(sourceURL: source, targetSize: .zero, outputURL: output) { _ in }
      XCTFail("Кодирование GIF без размеров должно вернуть ошибку")
    } catch {}

    XCTAssertEqual(try? Data(contentsOf: output), contents)
  }

  func testResize_preservesDestinationChangedDuringEncoding() async throws {
    let source = try makeGIF(size: CGSize(width: 80, height: 40), delays: [0.1, 0.2], loopCount: 0)
    let initial = Data("прежняя версия".utf8)
    let added = Data("новые данные".utf8)

    for destinationExists in [false, true] {
      let output = directory.appendingPathComponent("selected-\(destinationExists).gif")
      if destinationExists { try initial.write(to: output) }

      do {
        try await GIFResizer.resize(
          sourceURL: source, targetSize: CGSize(width: 40, height: 20), outputURL: output
        ) { progress in
          guard progress == 0.95 else { return }
          do {
            if destinationExists {
              let handle = try FileHandle(forWritingTo: output)
              defer { try? handle.close() }
              _ = try handle.seekToEnd()
              try handle.write(contentsOf: added)
            } else {
              try added.write(to: output)
            }
          } catch {
            XCTFail("Не удалось изменить назначение: \(error)")
          }
        }
        XCTFail("Кодирование не должно заменять изменившееся назначение")
      } catch {}

      XCTAssertEqual(try? Data(contentsOf: output), destinationExists ? initial + added : added)
    }
  }

  func testResize_replacesExistingUnchangedFile() async throws {
    let source = try makeGIF(size: CGSize(width: 80, height: 40), delays: [0.1, 0.2], loopCount: 0)
    let output = directory.appendingPathComponent("selected.gif")
    try Data("прежняя версия".utf8).write(to: output)

    try await GIFResizer.resize(
      sourceURL: source, targetSize: CGSize(width: 40, height: 20), outputURL: output
    ) { _ in }

    XCTAssertEqual(GIFResizer.metadata(for: output)?.size, CGSize(width: 40, height: 20))
  }

  func testResize_runsFrameWorkOffTheMainThread() async throws {
    let sourceURL = try makeGIF(size: CGSize(width: 20, height: 20), delays: [0.1, 0.1], loopCount: 0)
    let progressThreads = ProgressRecorder()

    try await GIFResizer.resize(
      sourceURL: sourceURL,
      targetSize: CGSize(width: 10, height: 10),
      outputURL: directory.appendingPathComponent("resized.gif")
    ) { progress in
      progressThreads.record(progress: progress, isMainThread: Thread.isMainThread)
    }

    let samples = progressThreads.samples
    XCTAssertFalse(samples.isEmpty)
    XCTAssertTrue(samples.allSatisfy { !$0.isMainThread })
    XCTAssertEqual(samples.last?.progress, 1.0)
  }

  func testResize_missingSourceThrows() async {
    do {
      try await GIFResizer.resize(
        sourceURL: directory.appendingPathComponent("missing.gif"),
        targetSize: CGSize(width: 10, height: 10),
        outputURL: directory.appendingPathComponent("resized.gif")
      ) { _ in }
      XCTFail("Expected cannotReadSource")
    } catch {
      XCTAssertEqual(error as? GIFResizeError, .cannotReadSource)
    }
  }

  // MARK: - Helpers

  private func pixel(in image: CGImage, x: Int) throws -> [UInt8] {
    var pixel = [UInt8](repeating: 0, count: 4)
    try pixel.withUnsafeMutableBytes { bytes in
      let context = try XCTUnwrap(CGContext(
        data: bytes.baseAddress,
        width: 1,
        height: 1,
        bitsPerComponent: 8,
        bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
      ))
      context.draw(image, in: CGRect(x: -x, y: 0, width: image.width, height: image.height))
    }
    return pixel
  }

  private func makeGIF(
    size: CGSize,
    delays: [Double],
    loopCount: Int,
    transparent: Bool = false
  ) throws -> URL {
    let url = directory.appendingPathComponent("source-\(UUID().uuidString).gif")
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, delays.count, nil)
    )
    CGImageDestinationSetProperties(destination, [
      kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loopCount],
    ] as CFDictionary)

    for (index, delay) in delays.enumerated() {
      let context = try XCTUnwrap(CGContext(
        data: nil,
        width: Int(size.width),
        height: Int(size.height),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ))
      context.setFillColor(CGColor(red: CGFloat(index) / CGFloat(delays.count), green: 0.5, blue: 0.2, alpha: 1))
      let fillWidth = transparent ? size.width / 2 : size.width
      context.fill(CGRect(x: 0, y: 0, width: fillWidth, height: size.height))
      let image = try XCTUnwrap(context.makeImage())
      CGImageDestinationAddImage(destination, image, [
        kCGImagePropertyGIFDictionary: [
          kCGImagePropertyGIFDelayTime: delay,
          kCGImagePropertyGIFUnclampedDelayTime: delay,
        ],
      ] as CFDictionary)
    }
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return url
  }
}

private nonisolated final class ProgressRecorder: @unchecked Sendable {
  struct Sample {
    let progress: Double
    let isMainThread: Bool
  }

  private let lock = NSLock()
  private var _samples: [Sample] = []

  var samples: [Sample] {
    lock.withLock { _samples }
  }

  func record(progress: Double, isMainThread: Bool) {
    lock.withLock { _samples.append(Sample(progress: progress, isMainThread: isMainThread)) }
  }
}
