import AVFoundation
import ImageIO
import XCTest
@testable import Snapzy

@MainActor
final class OwnShotRecordingGIFIntegrationTests: XCTestCase {
  func testОптимизацияСохраняетДлительностьСтатичногоВидеоВМеньшемЧислеКадров() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let video = directory.appendingPathComponent("static.mov")
    try await makeStaticVideo(at: video)
    for fps in [15, 30, 60] {
      var options = GIFConverter.Options()
      options.fps = fps
      options.optimize = false
      let plainURL = try await GIFConverter.convert(videoURL: video, options: options) { _ in }
      let plain = try XCTUnwrap(CGImageSourceCreateWithData(try Data(contentsOf: plainURL) as CFData, nil))
      options.optimize = true
      let optimizedURL = try await GIFConverter.convert(videoURL: video, options: options) { _ in }
      let optimized = try XCTUnwrap(CGImageSourceCreateWithURL(optimizedURL as CFURL, nil))
      XCTAssertGreaterThan(CGImageSourceGetCount(plain), CGImageSourceGetCount(optimized), "fps=\(fps)")
      XCTAssertEqual(totalDuration(plain), 1, accuracy: 0.005, "fps=\(fps), без оптимизации")
      XCTAssertEqual(totalDuration(optimized), 1, accuracy: 0.005, "fps=\(fps), с оптимизацией")
      XCTAssertEqual(totalDuration(plain), totalDuration(optimized), accuracy: 0.005, "fps=\(fps)")
    }
  }

  func testРазрешениеGIFПрименяетсяВГотовомФайлеБезУвеличенияИсходника() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let video = directory.appendingPathComponent("size.mov")
    try await makeStaticVideo(at: video)
    for (width, expected) in [(16, 16), (800, 32)] {
      var options = GIFConverter.Options()
      options.maxWidth = CGFloat(width)
      options.quality = 0
      let gifURL = try await GIFConverter.convert(videoURL: video, options: options) { _ in }
      let source = try XCTUnwrap(CGImageSourceCreateWithURL(gifURL as CFURL, nil))
      let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
      XCTAssertEqual(image.width, expected)
      XCTAssertEqual(image.height, expected)
    }
  }

  private func totalDuration(_ source: CGImageSource) -> Double {
    (0..<CGImageSourceGetCount(source)).reduce(0) { total, index in
      let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
      let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
      return total + (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double ?? 0)
    }
  }

  private func makeStaticVideo(at url: URL) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: 32,
      AVVideoHeightKey: 32
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: 32,
      kCVPixelBufferHeightKey as String: 32
    ])
    writer.add(input)
    XCTAssertTrue(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    for index in 0..<10 {
      while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
      var pixel: CVPixelBuffer?
      XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 32, 32, kCVPixelFormatType_32BGRA, nil, &pixel), kCVReturnSuccess)
      let buffer = try XCTUnwrap(pixel)
      CVPixelBufferLockBaseAddress(buffer, [])
      memset(CVPixelBufferGetBaseAddress(buffer), 255, CVPixelBufferGetDataSize(buffer))
      CVPixelBufferUnlockBaseAddress(buffer, [])
      XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 10)))
    }
    input.markAsFinished()
    writer.endSession(atSourceTime: CMTime(value: 1, timescale: 1))
    await writer.finishWriting()
    XCTAssertEqual(writer.status, .completed)
  }
}
