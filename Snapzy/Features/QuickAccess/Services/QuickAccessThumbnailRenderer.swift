import AppKit

/// Кадрирование выполняется до уменьшения, чтобы длинный снимок не терял ширину.
nonisolated enum QuickAccessThumbnailRenderer {
  static func render(_ image: NSImage, width: CGFloat) -> NSImage {
    guard width.isFinite, width > 0, image.size.width > 0, image.size.height > 0 else { return image }
    var proposed = CGRect(origin: .zero, size: image.size)
    guard let source = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else { return image }

    let aspect = QuickAccessLayout.cardWidth / QuickAccessLayout.cardHeight
    let logicalSize = CGSize(width: width, height: width / aspect)
    // Retina при максимальном размере карточки 150%, без зависимости от текущего экрана.
    let backingScale = 2 * CGFloat(QuickAccessOverlaySizeScale.range.upperBound)
    let targetWidth = logicalSize.width * backingScale
    let targetHeight = logicalSize.height * backingScale
    if max(image.size.width, image.size.height) <= width,
       CGFloat(source.width) <= targetWidth, CGFloat(source.height) <= targetHeight {
      return image
    }

    let cropWidth = min(CGFloat(source.width), CGFloat(source.height) * aspect)
    let cropHeight = cropWidth / aspect
    let crop = CGRect(x: (CGFloat(source.width) - cropWidth) / 2,
      y: (CGFloat(source.height) - cropHeight) / 2, width: cropWidth, height: cropHeight)
    guard let cropped = source.cropping(to: crop) else { return image }
    let scale = min(1, targetWidth / CGFloat(cropped.width), targetHeight / CGFloat(cropped.height))
    let pixelWidth = max(1, Int((CGFloat(cropped.width) * scale).rounded()))
    let pixelHeight = max(1, Int((CGFloat(cropped.height) * scale).rounded()))
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight,
            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
    context.interpolationQuality = .high
    context.draw(cropped, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
    guard let result = context.makeImage() else { return image }
    return NSImage(cgImage: result, size: logicalSize)
  }
}
