import AVFoundation
import CoreVideo
import ImageIO
import Testing
@testable import Snapzy

@MainActor
struct GIFConversionGeometryParityTests {
  @Test("Готовый GIF сохраняет геометрию эталона и полную длительность записи",
    arguments: [false, true])
  func encodedGeometryAndDuration(original: Bool) async throws {
    // REC-084: конечный файл эталона 800×446 из записи 840×468.
    try await checkConversion(sourceWidth: 840, sourceHeight: 468,
      maxWidth: original ? GIFConverter.Options.originalWidth : 800,
      expectedWidth: original ? 840 : 800, expectedHeight: original ? 468 : 446)
  }

  @Test("Портретный исходник масштабируется по ширине с округлением высоты")
  func portraitGeometryAndDuration() async throws {
    try await checkConversion(sourceWidth: 468, sourceHeight: 840,
      maxWidth: 320, expectedWidth: 320, expectedHeight: 574)
  }

  @Test("Небольшой исходник не увеличивается до ограничения ширины")
  func smallerSourceIsNotUpscaled() async throws {
    try await checkConversion(sourceWidth: 320, sourceHeight: 180,
      maxWidth: 800, expectedWidth: 320, expectedHeight: 180)
  }

  @Test("Поворот дорожки учитывается до ограничения ширины готового GIF",
    arguments: [false, true])
  func rotatedTrackGeometryAndDuration(original: Bool) async throws {
    try await checkConversion(sourceWidth: 840, sourceHeight: 468, rotated: true,
      maxWidth: original ? GIFConverter.Options.originalWidth : 320,
      expectedWidth: original ? 468 : 320, expectedHeight: original ? 840 : 574)
  }

  nonisolated enum ExistingOutput {
    case file
    case directory
    case danglingLink
  }

  @Test("Конвертация записи сохраняет прежний файл при совпадении имён",
    arguments: [ExistingOutput.file, .directory, .danglingLink])
  func collisionKeepsPriorOutput(_ existing: ExistingOutput) async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("GIFConversionCollision-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let videoURL = directory.appendingPathComponent("fixture.mov")
    try await makeVideo(at: videoURL, width: 80, height: 40, rotated: false)

    let existingOutput = directory.appendingPathComponent("fixture.gif")
    let existingBytes = Data("previous output".utf8)
    let sentinel = existingOutput.appendingPathComponent("preserve.txt")
    let missing = directory.appendingPathComponent("missing.gif")
    switch existing {
    case .file:
      try existingBytes.write(to: existingOutput)
    case .directory:
      try FileManager.default.createDirectory(at: existingOutput, withIntermediateDirectories: false)
      try existingBytes.write(to: sentinel)
    case .danglingLink:
      try FileManager.default.createSymbolicLink(at: existingOutput, withDestinationURL: missing)
    }

    var options = GIFConverter.Options()
    options.fps = 10
    options.optimize = false
    let gifURL = try await GIFConverter.convert(videoURL: videoURL, options: options) { _ in }

    #expect(gifURL.lastPathComponent == "fixture_2.gif")
    switch existing {
    case .file:
      #expect((try? Data(contentsOf: existingOutput)) == existingBytes)
    case .directory:
      #expect((try? Data(contentsOf: sentinel)) == existingBytes)
    case .danglingLink:
      #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: existingOutput.path)) == missing.path)
      #expect(!FileManager.default.fileExists(atPath: missing.path))
    }
    let remainingEntries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(Set(remainingEntries) == ["fixture.mov", "fixture.gif", "fixture_2.gif"])
    let source = try #require(CGImageSourceCreateWithURL(gifURL as CFURL, nil))
    #expect(CGImageSourceGetCount(source) == 10)
    let frame = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(frame.width == 80)
    #expect(frame.height == 40)
  }

  private func checkConversion(sourceWidth: Int, sourceHeight: Int, rotated: Bool = false,
    maxWidth: CGFloat, expectedWidth: Int, expectedHeight: Int) async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("GIFConversionGeometryParity-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let videoURL = directory.appendingPathComponent("fixture.mov")
    try await makeVideo(at: videoURL, width: sourceWidth, height: sourceHeight, rotated: rotated)

    let asset = AVURLAsset(url: videoURL)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    let track = try #require(tracks.first)
    let inputSize = try await track.load(.naturalSize)
    #expect(inputSize == CGSize(width: sourceWidth, height: sourceHeight))
    let transform = try await track.load(.preferredTransform)
    let displayedSize = CGRect(origin: .zero, size: inputSize).applying(transform).standardized.size
    #expect(abs(displayedSize.width - CGFloat(rotated ? sourceHeight : sourceWidth)) < 0.001)
    #expect(abs(displayedSize.height - CGFloat(rotated ? sourceWidth : sourceHeight)) < 0.001)

    var options = GIFConverter.Options()
    options.fps = 10
    options.maxWidth = maxWidth
    options.optimize = false
    let gifURL = try await GIFConverter.convert(videoURL: videoURL, options: options) { _ in }
    let source = try #require(CGImageSourceCreateWithURL(gifURL as CFURL, nil))
    let count = CGImageSourceGetCount(source)
    #expect(count == 10)
    // Проверяем декодированные кадры, а не maximumSize генератора: AVFoundation
    // может округлить его ограничения при реальной конвертации.
    var totalDuration = 0.0
    for index in 0..<count {
      let frame = try #require(CGImageSourceCreateImageAtIndex(source, index, nil))
      #expect(frame.width == expectedWidth)
      #expect(frame.height == expectedHeight)
      let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any])
      let gif = try #require(properties[kCGImagePropertyGIFDictionary] as? [CFString: Any])
      let delay = try #require((gif[kCGImagePropertyGIFUnclampedDelayTime]
        ?? gif[kCGImagePropertyGIFDelayTime]) as? Double)
      totalDuration += delay
    }
    // Не переносим наблюдавшуюся у эталона потерю времени: секунду записи сохраняем.
    #expect(abs(totalDuration - 1) < 0.005)
  }

  private func makeVideo(at url: URL, width: Int, height: Int, rotated: Bool) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: width,
      AVVideoHeightKey: height
    ])
    input.expectsMediaDataInRealTime = false
    if rotated {
      input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: CGFloat(height), ty: 0)
    }
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
      kCVPixelBufferWidthKey as String: width,
      kCVPixelBufferHeightKey as String: height
    ])
    writer.add(input)
    try #require(writer.startWriting(), "Не удалось запустить writer: \(String(describing: writer.error))")
    writer.startSession(atSourceTime: .zero)
    defer { if writer.status == .writing { writer.cancelWriting() } }
    for index in 0..<10 {
      while !input.isReadyForMoreMediaData {
        try #require(writer.status == .writing, "Writer остановился при подготовке кадра")
        try await Task.sleep(for: .milliseconds(1))
      }
      var buffer: CVPixelBuffer?
      let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
        kCVPixelFormatType_32BGRA, nil, &buffer)
      try #require(status == kCVReturnSuccess)
      let pixel = try #require(buffer)
      CVPixelBufferLockBaseAddress(pixel, [])
      if let base = CVPixelBufferGetBaseAddress(pixel) {
        memset(base, 255, CVPixelBufferGetDataSize(pixel))
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixel)
        for y in 0..<height {
          for x in 0..<width {
            bytes[y * stride + x * 4] = UInt8(20 + index * 20)
          }
        }
      }
      CVPixelBufferUnlockBaseAddress(pixel, [])
      try #require(adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(index), timescale: 10)),
        "Не удалось записать кадр: \(String(describing: writer.error))")
    }
    input.markAsFinished()
    writer.endSession(atSourceTime: CMTime(value: 1, timescale: 1))
    await writer.finishWriting()
    try #require(writer.status == .completed, "Writer не завершён: \(String(describing: writer.error))")
  }
}
