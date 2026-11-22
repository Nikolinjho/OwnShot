import AVFoundation
import ImageIO
import UniformTypeIdentifiers

@MainActor
enum VideoEditorFrameExport {
  enum ExportError: LocalizedError {
    case noFrame, renderFailed, encodeFailed

    var errorDescription: String? {
      switch self {
      case .noFrame:
        L10n.string("video-editor.frame-export.no-frame",
          defaultValue: "There is no video frame at the playhead.", comment: "Still export with no active clip")
      case .renderFailed, .encodeFailed:
        L10n.string("video-editor.frame-export.failed",
          defaultValue: "The video frame could not be saved.", comment: "Failed to save a video still")
      }
    }
  }

  static func render(
    from sourceURL: URL,
    at sourceTime: TimeInterval,
    camera: VideoEditorCameraState,
    renderSize: CGSize,
    backgroundStyle: BackgroundStyle,
    backgroundPadding: CGFloat,
    cornerRadius: CGFloat
  ) async throws -> CGImage {
    let sourceAccess = SandboxFileAccessManager.shared.beginAccessingURL(sourceURL)
    defer { sourceAccess.stop() }

    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: sourceAccess.url))
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    let time = CMTime(seconds: sourceTime, preferredTimescale: 60_000)
    let image = try await generator.image(at: time).image
    try Task.checkCancellation()

    let size = renderSize.width > 0 && renderSize.height > 0
      ? renderSize
      : CGSize(width: image.width, height: image.height)
    guard camera != .identity || backgroundStyle != .none
      || size != CGSize(width: image.width, height: image.height) else { return image }
    guard let rendered = ZoomVideoCompositorClass.renderStillFrame(
      image, camera: camera, renderSize: size, backgroundStyle: backgroundStyle,
      backgroundPadding: backgroundPadding, cornerRadius: cornerRadius
    ) else { throw ExportError.renderFailed }
    return rendered
  }

  static func writePNG(
    _ image: CGImage,
    to outputURL: URL,
    expecting revision: CaptureFilePublication.DestinationRevision? = nil
  ) throws {
    let access = SandboxFileAccessManager.shared.beginAccessingURL(outputURL.deletingLastPathComponent())
    defer { access.stop() }
    let output = access.url.appendingPathComponent(outputURL.lastPathComponent)
    let expected = try revision ?? CaptureFilePublication.DestinationRevision(at: output)
    let staging = access.url.appendingPathComponent(".ownshot-still-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: staging) }

    guard let destination = CGImageDestinationCreateWithURL(
      staging as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else { throw ExportError.encodeFailed }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw ExportError.encodeFailed }
    try CaptureFilePublication.replaceFile(from: staging, to: output, expecting: expected)
  }
}
