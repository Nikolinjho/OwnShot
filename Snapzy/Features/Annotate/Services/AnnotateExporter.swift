//
//  AnnotateExporter.swift
//  Snapzy
//
//  Export functionality for annotated images
//

import AppKit
import CoreImage
import Darwin
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Handles exporting annotated images
@MainActor
final class AnnotateExporter {

  // MARK: - Project

  /// Данные сессии для записи проекта. Для редактора, открытого из проекта,
  /// sourceURL указывает на ZIP, поэтому его байты исходником не считаются.
  static func projectSessionData(state: AnnotateState, originalImageData: Data?) -> AnnotationSessionData? {
    let isSourceProject = state.sourceURL.map(OwnShotProjectFormat.isProjectURL) ?? false
    if originalImageData != nil || !isSourceProject {
      if let sessionData = AnnotateManager.shared.makeSessionData(for: state, originalImageData: originalImageData) {
        return sessionData
      }
    }
    guard let pngData = state.transformedSourceImageData() else { return nil }
    return AnnotationSessionData.snapshot(from: state, originalImageData: pngData)
  }

  /// Записывает редактируемый проект OwnShot: исходник байт-в-байт, объекты и превью.
  @discardableResult
  static func saveProject(state: AnnotateState, to url: URL, originalImageData: Data? = nil) -> Bool {
    DiagnosticLogger.shared.log(.info, .annotate, "Project save started", context: [
      "file": url.lastPathComponent,
      "annotations": "\(state.annotations.count)"
    ])
    guard let sessionData = projectSessionData(state: state, originalImageData: originalImageData) else {
      DiagnosticLogger.shared.log(.error, .annotate, "Project save failed: no source image data")
      return false
    }
    let preview = renderFinalImage(state: state)
    do {
      try SandboxFileAccessManager.shared.withScopedAccess(to: url.deletingLastPathComponent()) {
        try OwnShotProjectStore.write(sessionData, preview: preview, to: url)
      }
      SoundManager.play("Pop")
      return true
    } catch {
      SoundManager.play("Basso")
      DiagnosticLogger.shared.logError(.annotate, error, "Project save failed")
      return false
    }
  }

  // MARK: - Print

  /// Печать итогового изображения через системную панель (⌘P).
  static func printImage(state: AnnotateState, in window: NSWindow?) {
    DiagnosticLogger.shared.log(.info, .annotate, "Print requested")
    guard state.hasImage, let image = renderFinalImage(state: state) else {
      DiagnosticLogger.shared.log(.error, .annotate, "Print failed: render returned nil")
      NSSound.beep()
      return
    }

    let imageView = NSImageView(frame: NSRect(origin: .zero, size: image.size))
    imageView.image = image
    imageView.imageScaling = .scaleProportionallyUpOrDown

    let printInfo = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
    printInfo.orientation = image.size.width > image.size.height ? .landscape : .portrait
    // Длинный скриншот идёт на несколько страниц; флажок панели вписывает его в одну.
    let accessory = AnnotatePrintAccessoryController(printInfo: printInfo)

    let operation = NSPrintOperation(view: imageView, printInfo: printInfo)
    operation.showsPrintPanel = true
    operation.printPanel.addAccessoryController(accessory)
    operation.showsProgressPanel = true
    operation.jobTitle = state.sourceURL?.deletingPathExtension().lastPathComponent
      ?? L10n.AnnotateUI.defaultAnnotatedFileName
    if let window {
      operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    } else {
      operation.run()
    }
  }

  /// Save annotated image to original file location (overwrite)
  @discardableResult
  static func saveToOriginal(state: AnnotateState) -> Bool {
    guard let sourceURL = state.sourceURL else { return false }
    guard confirmTransparencyLossIfNeeded(state: state, targetURL: sourceURL) else { return false }
    DiagnosticLogger.shared.log(.info, .annotate, "Save to original", context: ["file": sourceURL.lastPathComponent])
    return save(state: state, to: sourceURL)
  }

  @discardableResult
  static func save(state: AnnotateState, to url: URL, originalImageData: Data? = nil) -> Bool {
    if OwnShotProjectFormat.isProjectURL(url) {
      return saveProject(state: state, to: url, originalImageData: originalImageData)
    }
    DiagnosticLogger.shared.log(.info, .annotate, "Save started", context: [
      "file": url.lastPathComponent,
      "format": url.pathExtension,
      "annotations": "\(state.annotations.count)"
    ])
    guard let image = renderFinalImage(state: state) else {
      DiagnosticLogger.shared.log(.error, .annotate, "Save failed: render returned nil")
      return false
    }

    guard let data = imageData(from: image, for: url.pathExtension) else { return false }
    return writeRaster(data, to: url)
  }

  @concurrent nonisolated static func saveRasterOffMain(
    snapshot: AnnotateRenderSnapshot,
    to url: URL,
    encode: @Sendable (NSImage, String) -> Data? = imageData
  ) async -> CaptureFilePublication.FileRevision? {
    let access = await SandboxFileAccessManager.shared.beginAccessingURL(url.deletingLastPathComponent())
    defer { access.stop() }
    let directory = access.url.standardizedFileURL
    let destination = directory.appendingPathComponent(url.lastPathComponent)

    do {
      let directoryDescriptor = directory.withUnsafeFileSystemRepresentation { path in
        path.map { Darwin.open($0, O_SEARCH | O_DIRECTORY | O_CLOEXEC) } ?? -1
      }
      guard directoryDescriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
      defer { Darwin.close(directoryDescriptor) }
      let original = try CaptureFilePublication.destinationSnapshot(named: destination.lastPathComponent,
        in: directoryDescriptor)

      guard let image = await renderFinalImage(snapshot: snapshot),
            let data = encode(image, url.pathExtension) else { return nil }
      try Task.checkCancellation()
      guard CaptureFilePublication.isDirectory(directory, representedBy: directoryDescriptor) else {
        throw POSIXError(.ESTALE)
      }

      let publishedRevision = try CaptureFilePublication.replaceFile(with: data, to: destination,
        in: directoryDescriptor, expecting: original.revision, permissions: original.permissions)
      await didWriteRaster(to: url)
      return publishedRevision
    } catch {
      await SoundManager.play("Basso")
      DiagnosticLogger.shared.logError(.annotate, error, "Save failed")
      return nil
    }
  }

  private static func writeRaster(_ data: Data, to url: URL) -> Bool {
    do {
      try SandboxFileAccessManager.shared.withScopedAccess(to: url.deletingLastPathComponent()) {
        try data.write(to: url, options: .atomic)
      }
      didWriteRaster(to: url)
      return true
    } catch {
      SoundManager.play("Basso")
      DiagnosticLogger.shared.logError(.annotate, error, "Save failed")
      return false
    }
  }

  private static func didWriteRaster(to url: URL) {
    CaptureHistoryStore.shared.markFileChanged(at: url)
    SoundManager.play("Pop")
  }

  /// Write a pre-rendered image to the source URL (for background save after instant close)
  @MainActor
  @discardableResult
  static func saveToFile(image: NSImage?, state: AnnotateState) -> Bool {
    guard let image = image, let sourceURL = state.sourceURL else { return false }
    // Проект пишется только через saveProject: растр поверх ZIP испортил бы документ.
    guard !OwnShotProjectFormat.isProjectURL(sourceURL) else { return false }
    DiagnosticLogger.shared.log(.info, .annotate, "Background save", context: ["file": sourceURL.lastPathComponent])

    guard let data = imageData(from: image, for: sourceURL.pathExtension) else { return false }

    do {
      try SandboxFileAccessManager.shared.withScopedAccess(to: sourceURL.deletingLastPathComponent()) {
        try data.write(to: sourceURL, options: .atomic)
      }
      CaptureHistoryStore.shared.markFileChanged(at: sourceURL)
      return true
    } catch {
      DiagnosticLogger.shared.logError(.annotate, error, "Background save failed")
      return false
    }
  }

  /// Encode and atomically replace the existing raster on the calling worker.
  @concurrent nonisolated static func saveToFileOffMain(image: NSImage, sourceURL: URL) async -> Bool {
    guard !OwnShotProjectFormat.isProjectURL(sourceURL) else { return false }
    DiagnosticLogger.shared.log(.info, .annotate, "Background save", context: ["file": sourceURL.lastPathComponent])

    guard let data = imageData(from: image, for: sourceURL.pathExtension) else { return false }

    let access = await SandboxFileAccessManager.shared.beginAccessingURL(sourceURL.deletingLastPathComponent())
    defer { access.stop() }
    do {
      try data.write(to: sourceURL, options: .atomic)
      await CaptureHistoryStore.shared.markFileChanged(at: sourceURL)
      return true
    } catch {
      DiagnosticLogger.shared.logError(.annotate, error, "Background save failed")
      return false
    }
  }

  static func copyToClipboard(state: AnnotateState) {
    DiagnosticLogger.shared.log(.info, .annotate, "Copy to clipboard", context: ["annotations": "\(state.annotations.count)"])
    guard let image = renderFinalImage(state: state) else {
      DiagnosticLogger.shared.log(.error, .annotate, "Copy failed: render returned nil")
      return
    }

    ClipboardHelper.copyImage(image)
    SoundManager.play("Pop")
  }

  static func share(state: AnnotateState, from view: NSView) {
    DiagnosticLogger.shared.log(.info, .annotate, "Share started")
    guard let image = renderFinalImage(state: state) else {
      DiagnosticLogger.shared.log(.error, .annotate, "Share failed: render returned nil")
      return
    }

    let picker = NSSharingServicePicker(items: [image])
    picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
  }


  // MARK: - Private

  /// JPEG does not support alpha. Confirm before flattening a cutout result.
  static func confirmTransparencyLossIfNeeded(state: AnnotateState, targetURL: URL) -> Bool {
    guard state.isCutoutApplied else { return true }

    let ext = targetURL.pathExtension.lowercased()
    guard ext == "jpg" || ext == "jpeg" else { return true }

    let alert = NSAlert()
    alert.messageText = L10n.AnnotateUI.jpegRemovesTransparencyTitle
    alert.informativeText = L10n.AnnotateUI.jpegRemovesTransparencyMessage
    alert.alertStyle = .warning
    alert.addButton(withTitle: L10n.AnnotateUI.saveAsJPEG)
    alert.addButton(withTitle: L10n.Common.cancel)
    return alert.runModal() == .alertFirstButtonReturn
  }

  /// Сторона экспорта в пикселях – до ближайшего целого, как подпись Image size
  /// (AnnotateState.cropPixelSize): рамка 600×257,14 даёт 600×257, а не 258 (ANN-617).
  nonisolated static func exportPixelLength(_ points: CGFloat, scale: CGFloat) -> Int {
    max(1, Int((points * scale).rounded()))
  }

  /// Determine the pixel-to-point scale factor from the source image.
  /// Falls back to 1.0 when bitmap metadata is unavailable.
  nonisolated static func sourceImageScale(_ sourceImage: NSImage) -> CGFloat {
    let pointWidth = sourceImage.size.width
    let pointHeight = sourceImage.size.height
    guard pointWidth > 0, pointHeight > 0 else { return 1.0 }

    if let rep = bestBitmapRepresentation(in: sourceImage) {
      let pixelWidth = CGFloat(rep.pixelsWide)
      let pixelHeight = CGFloat(rep.pixelsHigh)
      if pixelWidth > 0 && pixelHeight > 0 {
        let widthScale = pixelWidth / pointWidth
        let heightScale = pixelHeight / pointHeight
        return max(widthScale, heightScale, 1.0)
      }
    }

    if let cgImage = sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
      let widthScale = CGFloat(cgImage.width) / pointWidth
      let heightScale = CGFloat(cgImage.height) / pointHeight
      return max(widthScale, heightScale, 1.0)
    }

    return 1.0
  }

  nonisolated private static func bestBitmapRepresentation(in image: NSImage) -> NSBitmapImageRep? {
    image.representations
      .compactMap { $0 as? NSBitmapImageRep }
      .max { lhs, rhs in
        lhs.pixelsWide * lhs.pixelsHigh < rhs.pixelsWide * rhs.pixelsHigh
      }
  }

  nonisolated static func bestCGImage(from image: NSImage) -> CGImage? {
    if let cgImage = bestBitmapRepresentation(in: image)?.cgImage {
      return cgImage
    }
    return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
  }

  /// Convert NSImage to Data for any supported format (PNG, JPEG, HEIC, WebP)
  nonisolated static func imageData(from image: NSImage, for fileExtension: String) -> Data? {
    guard let cgImage = bestCGImage(from: image) else {
      return nil
    }

    let scale = sourceImageScale(image)
    let ext = fileExtension.lowercased()

    // WebP: ImageIO не кодирует WebP, поэтому libwebp. Без потерь (VP8L), как у эталона:
    // экспорт WebP совпадает с PNG попиксельно.
    if ext == "webp" {
      return WebPEncoderService.encode(cgImage, lossless: true)
    }

    // PNG/JPEG/HEIC: use CGImageDestination
    let utType: CFString
    switch ext {
    case "jpg", "jpeg":
      utType = "public.jpeg" as CFString
    case "heic", "heif":
      utType = "public.heic" as CFString
    default:
      utType = "public.png" as CFString
    }

    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, utType, 1, nil) else {
      return nil
    }
    CGImageDestinationAddImage(destination, cgImage, imageDestinationProperties(for: ext, scaleFactor: scale))
    guard CGImageDestinationFinalize(destination) else {
      return nil
    }
    return data as Data
  }

  nonisolated private static func imageDestinationProperties(
    for fileExtension: String,
    scaleFactor: CGFloat
  ) -> CFDictionary? {
    let resolvedScale = max(Double(scaleFactor), 1.0)
    let dpi = resolvedScale * 72.0
    var properties: [CFString: Any] = [
      kCGImagePropertyDPIWidth: dpi,
      kCGImagePropertyDPIHeight: dpi
    ]

    switch fileExtension {
    case "png":
      let pixelsPerMeter = Int((dpi / 0.0254).rounded())
      properties[kCGImagePropertyPNGDictionary] = [
        kCGImagePropertyPNGXPixelsPerMeter: pixelsPerMeter,
        kCGImagePropertyPNGYPixelsPerMeter: pixelsPerMeter
      ] as CFDictionary
    case "jpg", "jpeg":
      properties[kCGImageDestinationLossyCompressionQuality] = 0.9
    case "heic", "heif":
      // Качество эталона неизвестно; берём то же, что у JPEG.
      properties[kCGImageDestinationLossyCompressionQuality] = 0.9
    default:
      break
    }

    return properties as CFDictionary
  }

  /// Generate unique copy URL from original file path
  static func generateCopyURL(from originalURL: URL) -> URL {
    let directory = originalURL.deletingLastPathComponent()
    let baseName = originalURL.deletingPathExtension().lastPathComponent
    let ext = originalURL.pathExtension

    var copyNumber = 1
    var newURL = directory.appendingPathComponent("\(baseName)_copy.\(ext)")

    while FileManager.default.fileExists(atPath: newURL.path) {
      copyNumber += 1
      newURL = directory.appendingPathComponent("\(baseName)_copy\(copyNumber).\(ext)")
    }

    return newURL
  }

  static func renderCanvasEffects(
    sourceImage: NSImage,
    effects: AnnotationCanvasEffects
  ) -> NSImage? {
    let startedAt = CFAbsoluteTimeGetCurrent()
    var outputSizeDescription = "nil"
    defer {
      let durationMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1_000)
      DiagnosticLogger.shared.log(.debug, .annotate, "Render canvas effects completed", context: [
        "background": "\(effects.backgroundStyle)",
        "outputSize": outputSizeDescription,
        "durationMs": "\(durationMs)"
      ])
    }

    let effectiveBounds = CGRect(origin: .zero, size: sourceImage.size)
    let padding = effects.backgroundStyle != .none ? effects.padding : 0
    let alignmentSpace: CGFloat = effects.imageAlignment != .center ? 40 : 0
    let insetLayout: AnnotateBackgroundInsetLayout
    if effects.backgroundStyle != .none, effects.inset > 0 || effects.autoBalance {
      insetLayout = AnnotateBackgroundInset.layout(
        inset: effects.inset,
        autoBalance: effects.autoBalance,
        analysis: AnnotateBackgroundInset.analyze(image: sourceImage, visibleBounds: effectiveBounds)
      )
    } else {
      insetLayout = .none
    }
    let cardSize = insetLayout.edges.expandedSize(effectiveBounds.size)

    let totalSize: NSSize = effects.aspectRatio.canvasSize(
      for: cardSize,
      padding: padding,
      alignmentSpace: alignmentSpace,
      orientation: effects.aspectRatioOrientation
    )
    outputSizeDescription = "\(Int(totalSize.width))x\(Int(totalSize.height))"

    let scale = sourceImageScale(sourceImage)
    let pixelWidth = exportPixelLength(totalSize.width, scale: scale)
    let pixelHeight = exportPixelLength(totalSize.height, scale: scale)

    guard let bitmapRep = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: pixelWidth,
      pixelsHigh: pixelHeight,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    ) else { return nil }
    bitmapRep.size = totalSize

    guard let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmapRep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = graphicsContext

    let context = graphicsContext.cgContext
    drawBackground(effects: effects, in: context, size: totalSize)

    let cardOrigin = destinationOrigin(
      imageSize: cardSize,
      totalSize: totalSize,
      alignment: effects.imageAlignment
    )
    let imageOrigin = CGPoint(
      x: cardOrigin.x + insetLayout.edges.left,
      y: cardOrigin.y + insetLayout.edges.bottom
    )
    let imageRect = CGRect(origin: imageOrigin, size: effectiveBounds.size)

    drawCanvasCard(
      layout: insetLayout,
      imageRect: imageRect,
      cardRect: CGRect(origin: cardOrigin, size: cardSize),
      canvasRect: CGRect(origin: .zero, size: totalSize),
      cornerRadius: AnnotateBackgroundCorners.radius(forSlider: effects.cornerRadius),
      shadowIntensity: effects.backgroundStyle != .none ? effects.shadowIntensity : 0,
      in: context
    )

    drawSourceImage(
      sourceImage,
      effectiveBounds: effectiveBounds,
      destinationOrigin: imageOrigin,
      in: context
    )
    context.resetClip()

    let image = NSImage(size: totalSize)
    image.addRepresentation(bitmapRep)
    return image
  }

  /// Main-actor render entry point (Save As / Copy / Share). Freezes state into a
  /// snapshot first so every render path shares one implementation.
  static func renderFinalImage(state: AnnotateState) -> NSImage? {
    guard let snapshot = state.makeRenderSnapshot() else { return nil }
    if snapshot.editorMode == .mockup {
      DiagnosticLogger.shared.log(.debug, .annotate, "Rendering mockup image")
      guard let flatImage = renderMockupFlatImage(snapshot: snapshot) else { return nil }
      return compositeMockupImage(flatImage: flatImage, snapshot: snapshot)
    }
    return renderFlatFinalImage(snapshot: snapshot)
  }

  /// Off-main render entry point for the save-and-close background path.
  /// Mockup mode renders the flat image off-main, then composites 3D transforms on main
  /// (SwiftUI `ImageRenderer` is a main-only API).
  nonisolated static func renderFinalImage(snapshot: AnnotateRenderSnapshot) async -> NSImage? {
    if snapshot.editorMode == .mockup {
      DiagnosticLogger.shared.log(.debug, .annotate, "Rendering mockup image")
      guard let flatImage = renderMockupFlatImage(snapshot: snapshot) else { return nil }
      return await compositeMockupImage(flatImage: flatImage, snapshot: snapshot)
    }
    return renderFlatFinalImage(snapshot: snapshot)
  }

  /// Flat render pipeline (no mockup transforms). Pure CoreGraphics/AppKit drawing into a
  /// private bitmap context — safe on any queue, reads only the frozen snapshot.
  nonisolated static func renderFlatFinalImage(snapshot: AnnotateRenderSnapshot) -> NSImage? {
    let startedAt = CFAbsoluteTimeGetCurrent()
    let embeddedLayerCount = snapshot.annotations.reduce(into: 0) { count, annotation in
      if case .embeddedImage = annotation.type {
        count += 1
      }
    }
    var outputSizeDescription = "nil"
    defer {
      let durationMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1_000)
      DiagnosticLogger.shared.log(.debug, .annotate, "Render final image completed", context: [
        "mode": snapshot.editorMode.rawValue,
        "annotations": "\(snapshot.annotations.count)",
        "embeddedLayers": "\(embeddedLayerCount)",
        "outputSize": outputSizeDescription,
        "durationMs": "\(durationMs)"
      ])
    }

    let sourceImage = snapshot.sourceImage

    DiagnosticLogger.shared.log(.debug, .annotate, "Rendering final image", context: [
      "annotations": "\(snapshot.annotations.count)",
      "hasCrop": "\(snapshot.cropRect != nil)",
      "background": "\(snapshot.backgroundStyle)"
    ])

    // Determine effective bounds (crop or full image)
    let effectiveBounds: CGRect
    if snapshot.isCombineMode {
      effectiveBounds = snapshot.effectiveContentBounds
    } else if let cropRect = snapshot.cropRect {
      effectiveBounds = cropRect
    } else {
      effectiveBounds = snapshot.effectiveContentBounds
    }

    let padding = snapshot.isCombineMode ? snapshot.padding : (snapshot.backgroundStyle != .none ? snapshot.padding : 0)

    // Add alignment space for non-center alignments (matches preview)
    let alignmentSpace: CGFloat = snapshot.imageAlignment != .center ? 40 : 0

    // Inset: карточка изображения = изображение + отступы по сторонам (в combine их нет).
    let insetLayout = snapshot.isCombineMode ? AnnotateBackgroundInsetLayout.none : snapshot.backgroundInset
    let insetEdges = insetLayout.edges
    let cardSize = insetEdges.expandedSize(effectiveBounds.size)

    let totalSize: NSSize = snapshot.isCombineMode
      ? NSSize(width: effectiveBounds.width + padding * 2, height: effectiveBounds.height + padding * 2)
      : snapshot.aspectRatio.canvasSize(
        for: cardSize,
        padding: padding,
        alignmentSpace: alignmentSpace,
        orientation: snapshot.aspectRatioOrientation
      )
    outputSizeDescription = "\(Int(totalSize.width))x\(Int(totalSize.height))"

    // Render at pixel resolution using NSBitmapImageRep for Retina quality
    let scale = sourceImageScale(sourceImage)
    let pixelWidth = exportPixelLength(totalSize.width, scale: scale)
    let pixelHeight = exportPixelLength(totalSize.height, scale: scale)

    let graphicsContext: NSGraphicsContext
    let standardBitmap: NSBitmapImageRep?
    if let profile = bestCGImage(from: sourceImage)?.colorSpace, profile.name == CGColorSpace.displayP3 {
      // Композит в Device RGB обрезает исходные цвета за пределами sRGB до кодирования PNG.
      guard let bitmap = CGContext(data: nil, width: pixelWidth, height: pixelHeight,
        bitsPerComponent: 8, bytesPerRow: 0, space: profile,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
      bitmap.scaleBy(x: CGFloat(pixelWidth) / totalSize.width, y: CGFloat(pixelHeight) / totalSize.height)
      graphicsContext = NSGraphicsContext(cgContext: bitmap, flipped: false)
      standardBitmap = nil
    } else {
      guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelWidth,
        pixelsHigh: pixelHeight,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      ) else { return nil }
      bitmap.size = totalSize
      guard let standardContext = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
      graphicsContext = standardContext
      standardBitmap = bitmap
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext

    let context = graphicsContext.cgContext

    // Draw background
    drawBackground(snapshot: snapshot, in: context, size: totalSize)

    // Calculate card position based on alignment
    let totalExtraWidth = totalSize.width - cardSize.width
    let totalExtraHeight = totalSize.height - cardSize.height

    // Calculate destRect origin based on alignment
    // Note: CoreGraphics Y=0 is at bottom, so top alignment needs higher Y value
    let destX: CGFloat
    let destY: CGFloat

    switch snapshot.isCombineMode ? ImageAlignment.center : snapshot.imageAlignment {
    case .center:
      destX = totalExtraWidth / 2
      destY = totalExtraHeight / 2
    case .topLeft:
      destX = 0
      destY = totalExtraHeight  // Top in CG = max Y
    case .top:
      destX = totalExtraWidth / 2
      destY = totalExtraHeight
    case .topRight:
      destX = totalExtraWidth
      destY = totalExtraHeight
    case .left:
      destX = 0
      destY = totalExtraHeight / 2
    case .right:
      destX = totalExtraWidth
      destY = totalExtraHeight / 2
    case .bottomLeft:
      destX = 0
      destY = 0  // Bottom in CG = Y=0
    case .bottom:
      destX = totalExtraWidth / 2
      destY = 0
    case .bottomRight:
      destX = totalExtraWidth
      destY = 0
    }

    // Ось Y в CoreGraphics направлена вверх: снизу от изображения отступ bottom.
    let imageX = destX + insetEdges.left
    let imageY = destY + insetEdges.bottom
    let imageRect = CGRect(
      x: imageX,
      y: imageY,
      width: effectiveBounds.width,
      height: effectiveBounds.height
    )
    let cardRect = CGRect(origin: CGPoint(x: destX, y: destY), size: cardSize)
    drawCanvasCard(
      layout: insetLayout,
      imageRect: imageRect,
      cardRect: cardRect,
      canvasRect: CGRect(origin: .zero, size: totalSize),
      cornerRadius: AnnotateBackgroundCorners.radius(forSlider: snapshot.cornerRadius),
      shadowIntensity: snapshot.backgroundStyle != .none ? snapshot.shadowIntensity : 0,
      in: context
    )

    if !snapshot.isCombineMode {
      drawCropFill(snapshot.cropFillColor, in: imageRect, context: context)
    }

    drawSourceImage(
      sourceImage,
      effectiveBounds: effectiveBounds,
      destinationOrigin: CGPoint(x: imageX, y: imageY),
      in: context
    )

    if !snapshot.isCombineMode {
      context.resetClip()
    }

    // Unified Spotlight overlay pass (drawn below other annotations, above base image).
    // Opacity sourced from per-item properties so exported image matches the on-screen appearance.
    let spotlightRegions: [SpotlightRegion] = snapshot.annotations.compactMap { a in
      guard case .spotlight = a.type else { return nil }
      let offset = offsetAnnotationForExport(
        a,
        cropOrigin: effectiveBounds.origin,
        imageX: imageX,
        imageY: imageY
      )
      return SpotlightRegion(
        rect: offset.bounds,
        cornerRadius: offset.properties.cornerRadius,
        opacity: offset.properties.spotlightOpacity,
        strokeColor: NSColor(offset.properties.strokeColor).cgColor,
        strokeWidth: offset.properties.strokeWidth,
        lineStyle: offset.properties.lineStyle,
        shape: offset.properties.spotlightShape
      )
    }
    SpotlightCompositor.drawOverlay(
      regions: spotlightRegions,
      previewRegion: nil,
      canvasRect: imageRect,
      in: context
    )

    // Рендер аннотаций в исходных координатах.
    let renderer = AnnotationRenderer(
      context: context,
      drawsObjectShadow: snapshot.drawObjectShadow,
      sourceImage: sourceImage,
      embeddedImageProvider: { assetId in
        snapshot.embeddedImages[assetId]
      },
      embeddedCGImageProvider: { assetId in
        snapshot.embeddedCGImages[assetId]
      },
      secureExportSalt: snapshot.secureExportSalt ?? BlurEffectRenderer.makeSecureExportSalt()
    )
    // Координаты аннотаций остаются исходными для выборки пикселей и сетки размытия.
    // Обрезка и положение на холсте меняют только преобразование контекста.
    context.saveGState()
    context.translateBy(x: imageX - effectiveBounds.minX, y: imageY - effectiveBounds.minY)
    for annotation in snapshot.annotations.renderOrdered {
      if case .spotlight = annotation.type { continue }
      // Only include annotations that intersect with crop bounds
      if let cropRect = snapshot.cropRect {
        guard annotation.renderBounds.intersects(cropRect) else { continue }
      }
      renderer.draw(annotation)
    }
    context.restoreGState()

    if snapshot.isCombineMode {
      context.resetClip()
    }

    NSGraphicsContext.restoreGraphicsState()

    if let standardBitmap {
      let image = NSImage(size: totalSize)
      image.addRepresentation(standardBitmap)
      return image
    }
    guard let rendered = context.makeImage() else { return nil }
    return NSImage(cgImage: rendered, size: totalSize)
  }

  /// Тень, заливка отступа Inset и клип скругления под исходное изображение.
  /// Без карточки тень и скругление у самого изображения, как раньше.
  /// С карточкой – у карточки, а изображение скруглено концентрично внутри неё.
  /// Клип остаётся активным для drawSourceImage, его снимает вызывающий код.
  nonisolated private static func drawCanvasCard(
    layout: AnnotateBackgroundInsetLayout,
    imageRect: CGRect,
    cardRect: CGRect,
    canvasRect: CGRect,
    cornerRadius: CGFloat,
    shadowIntensity: CGFloat,
    in context: CGContext
  ) {
    let silhouetteRect = layout.drawsCard ? cardRect : imageRect
    drawCanvasShadow(
      imageRect: silhouetteRect,
      canvasRect: canvasRect,
      cornerRadius: cornerRadius,
      intensity: shadowIntensity,
      in: context
    )

    // Угол непрерывный, как RoundedRectangle(.continuous) превью и угол эталона (ANN-289).
    if cornerRadius > 0 {
      context.addPath(AnnotateBackgroundCorners.path(in: silhouetteRect, radius: cornerRadius))
      context.clip()
    }

    guard layout.drawsCard, let fillColor = layout.fillColor else { return }
    context.setFillColor(fillColor.cgColor)
    context.fill(cardRect)

    let innerRadius = layout.innerCornerRadius(outer: cornerRadius)
    if innerRadius > 0 {
      context.addPath(AnnotateBackgroundCorners.path(in: imageRect, radius: innerRadius))
      context.clip()
    }
  }

  /// Draw the flat-canvas screenshot shadow without painting beneath the source image.
  /// The even-odd clip keeps only the blurred pixels outside the rounded silhouette,
  /// so transparent source pixels and native-resolution screenshot pixels stay untouched.
  nonisolated private static func drawCanvasShadow(
    imageRect: CGRect,
    canvasRect: CGRect,
    cornerRadius: CGFloat,
    intensity: CGFloat,
    in context: CGContext
  ) {
    let opacity = min(max(intensity, 0), 1)
    guard opacity > 0, imageRect.width > 0, imageRect.height > 0 else { return }

    let silhouette = AnnotateBackgroundCorners.path(in: imageRect, radius: cornerRadius)

    context.saveGState()
    let outsideSilhouette = CGMutablePath()
    outsideSilhouette.addRect(canvasRect)
    outsideSilhouette.addPath(silhouette)
    context.addPath(outsideSilhouette)
    context.clip(using: .evenOdd)

    // Размытие и смещение тени Core Graphics не масштабирует матрицей, поэтому
    // пункты снимка переводятся в пиксели растра (2x-снимок – вдвое больше пикселей).
    let deviceTransform = context.userSpaceToDeviceSpaceTransform
    let deviceScale = max(hypot(deviceTransform.a, deviceTransform.b), 0.0001)
    // Два слоя эталона (ANN-288): широкий мягкий и узкий у края, оба смещены вниз.
    for layer in AnnotateCanvasShadowProfile.layers {
      let offsetY = layer.offsetY * deviceScale
      context.setShadow(
        // Базовое пространство растра направлено вверх: минус – вниз по снимку.
        offset: CGSize(width: 0, height: -offsetY),
        blur: layer.sigma * AnnotateCanvasShadowProfile.coreGraphicsBlurPerSigma * deviceScale,
        color: NSColor.black.withAlphaComponent(min(1, layer.opacity * opacity)).cgColor
      )
      context.addPath(silhouette)
      context.setFillColor(NSColor.black.cgColor)
      context.fillPath()
    }
    context.restoreGState()
  }

  /// Draw only the source-image portion that intersects the requested canvas bounds.
  /// Expanded crop areas outside the source image intentionally stay transparent/background-filled.
  /// Background color рамки Crop: заливка под изображением на всю рамку,
  /// поэтому видна там, где рамка выходит за изображение.
  nonisolated static func drawCropFill(_ color: CGColor?, in rect: CGRect, context: CGContext) {
    guard let color, color.alpha > 0, !rect.isEmpty else { return }
    context.saveGState()
    context.setFillColor(color)
    context.fill(rect)
    context.restoreGState()
  }

  nonisolated private static func drawSourceImage(
    _ sourceImage: NSImage,
    effectiveBounds: CGRect,
    destinationOrigin: CGPoint,
    in context: CGContext
  ) {
    let sourceImageBounds = CGRect(origin: .zero, size: sourceImage.size)
    let visibleSourceBounds = effectiveBounds.intersection(sourceImageBounds)
    guard !visibleSourceBounds.isNull, !visibleSourceBounds.isEmpty else { return }

    let destinationRect = NSRect(
      x: destinationOrigin.x + visibleSourceBounds.minX - effectiveBounds.minX,
      y: destinationOrigin.y + visibleSourceBounds.minY - effectiveBounds.minY,
      width: visibleSourceBounds.width,
      height: visibleSourceBounds.height
    )
    guard
      let sourceCGImage = bestCGImage(from: sourceImage),
      let sourcePixelRect = sourcePixelCropRect(
        for: visibleSourceBounds,
        imageSize: sourceImage.size,
        pixelSize: CGSize(width: sourceCGImage.width, height: sourceCGImage.height)
      ),
      let croppedImage = sourceCGImage.cropping(to: sourcePixelRect)
    else {
      let sourceRect = NSRect(
        x: visibleSourceBounds.minX,
        y: visibleSourceBounds.minY,
        width: visibleSourceBounds.width,
        height: visibleSourceBounds.height
      )
      sourceImage.draw(in: destinationRect, from: sourceRect, operation: .sourceOver, fraction: 1.0)
      return
    }

    let sourceScale = sourceImageScale(sourceImage)
    let destinationPixelSize = CGSize(
      width: destinationRect.width * sourceScale,
      height: destinationRect.height * sourceScale
    )
    let drawsOneToOne = abs(destinationPixelSize.width - CGFloat(croppedImage.width)) < 0.5
      && abs(destinationPixelSize.height - CGFloat(croppedImage.height)) < 0.5

    context.saveGState()
    context.interpolationQuality = drawsOneToOne ? .none : .high
    context.draw(croppedImage, in: destinationRect)
    context.restoreGState()
  }

  nonisolated private static func sourcePixelCropRect(
    for bounds: CGRect,
    imageSize: CGSize,
    pixelSize: CGSize
  ) -> CGRect? {
    guard imageSize.width > 0, imageSize.height > 0, pixelSize.width > 0, pixelSize.height > 0 else {
      return nil
    }

    let scaleX = pixelSize.width / imageSize.width
    let scaleY = pixelSize.height / imageSize.height
    let minX = floor(bounds.minX * scaleX)
    let maxX = ceil(bounds.maxX * scaleX)
    let minY = floor((imageSize.height - bounds.maxY) * scaleY)
    let maxY = ceil((imageSize.height - bounds.minY) * scaleY)
    let imagePixelBounds = CGRect(origin: .zero, size: pixelSize)
    let cropRect = CGRect(
      x: minX,
      y: minY,
      width: maxX - minX,
      height: maxY - minY
    )
    .intersection(imagePixelBounds)
    .integral

    guard !cropRect.isNull, !cropRect.isEmpty else { return nil }
    return cropRect
  }

  /// Offset annotation for export, accounting for crop origin and alignment-based image position
  nonisolated private static func offsetAnnotationForExport(
    _ annotation: AnnotationItem,
    cropOrigin: CGPoint,
    imageX: CGFloat,
    imageY: CGFloat
  ) -> AnnotationItem {
    annotation.translatedBy(dx: -cropOrigin.x + imageX, dy: -cropOrigin.y + imageY)
  }

  /// Offset an annotation and all of its embedded points by padding.
  nonisolated private static func offsetAnnotation(_ annotation: AnnotationItem, by padding: CGFloat) -> AnnotationItem {
    annotation.translatedBy(dx: padding, dy: padding)
  }

  /// Snapshot-based background draw. The wallpaper/blurred image arrives pre-resolved
  /// (main-bound sandbox access + CI blur happen when the snapshot is built).
  nonisolated private static func drawBackground(snapshot: AnnotateRenderSnapshot, in context: CGContext, size: NSSize) {
    let rect = CGRect(origin: .zero, size: size)

    switch snapshot.backgroundStyle {
    case .none:
      break

    case .gradient(let preset):
      GradientPresetRasterizer.draw(preset, in: context, rect: rect)

    case .solidColor(let color):
      context.setFillColor(NSColor(color).cgColor)
      context.fill(rect)
      if snapshot.isBlurredBackgroundEffectActive {
        drawBlurredBackgroundTint(effect: snapshot.blurredBackgroundEffect, in: context, rect: rect)
      }

    case .wallpaper(let url):
      if url.scheme == "preset",
         let presetName = url.host,
         let preset = WallpaperPreset(rawValue: presetName) {
        drawLinearGradient(colors: preset.colors, in: context, size: size)
        return
      }
      if let wallpaper = snapshot.resolvedBackgroundImage {
        wallpaper.draw(in: rect)
        if snapshot.isBlurredBackgroundEffectActive {
          drawBlurredBackgroundTint(effect: snapshot.blurredBackgroundEffect, in: context, rect: rect)
        }
      }

    case .blurred:
      if let wallpaper = snapshot.resolvedBackgroundImage {
        wallpaper.draw(in: rect)
        drawBlurredBackgroundTint(effect: snapshot.blurredBackgroundEffect, in: context, rect: rect)
      }
    }
  }

  private static func drawBackground(effects: AnnotationCanvasEffects, in context: CGContext, size: NSSize) {
    let rect = CGRect(origin: .zero, size: size)

    switch effects.backgroundStyle {
    case .none:
      break

    case .gradient(let preset):
      GradientPresetRasterizer.draw(preset, in: context, rect: rect)

    case .solidColor(let color):
      context.setFillColor(NSColor(color).cgColor)
      context.fill(rect)
      if isBlurredBackgroundEffectActive(effects) {
        drawBlurredBackgroundTint(effect: effects.blurredBackgroundEffect, in: context, rect: rect)
      }

    case .wallpaper(let url):
      if url.scheme == "preset",
         let presetName = url.host,
         let preset = WallpaperPreset(rawValue: presetName) {
        drawLinearGradient(colors: preset.colors, in: context, size: size)
        return
      }
      let preferBlurred = isBlurredBackgroundEffectActive(effects)
      if let wallpaper = resolveWallpaperImage(
        for: url,
        blurredEffect: effects.blurredBackgroundEffect,
        preferBlurred: preferBlurred
      ) {
        wallpaper.draw(in: rect)
        if preferBlurred {
          drawBlurredBackgroundTint(effect: effects.blurredBackgroundEffect, in: context, rect: rect)
        }
      }

    case .blurred(let url):
      if let wallpaper = resolveWallpaperImage(
        for: url,
        blurredEffect: effects.blurredBackgroundEffect,
        preferBlurred: true
      ) {
        wallpaper.draw(in: rect)
        drawBlurredBackgroundTint(effect: effects.blurredBackgroundEffect, in: context, rect: rect)
      }
    }
  }

  private static func isBlurredBackgroundEffectActive(_ effects: AnnotationCanvasEffects) -> Bool {
    guard effects.backgroundStyle.supportsBlurredBackgroundEffect else { return false }
    if case .blurred = effects.backgroundStyle {
      return true
    }
    return effects.isBlurredBackgroundEnabled
  }

  nonisolated private static func drawLinearGradient(colors: [Color], in context: CGContext, size: NSSize) {
    let cgColors = colors.map { NSColor($0).cgColor }
    let gradient = CGGradient(
      colorsSpace: CGColorSpaceCreateDeviceRGB(),
      colors: cgColors as CFArray,
      locations: nil
    )
    if let gradient = gradient {
      context.drawLinearGradient(
        gradient,
        start: .zero,
        end: CGPoint(x: size.width, y: size.height),
        options: []
      )
    }
  }

  private static func resolveWallpaperImage(
    for url: URL,
    blurredEffect: BlurredBackgroundEffect,
    preferBlurred: Bool
  ) -> NSImage? {
    let image = SandboxFileAccessManager.shared.withScopedAccess(to: url) {
      NSImage(contentsOf: url)
    }
    guard preferBlurred else { return image }
    return makeBlurredBackgroundImage(from: image, effect: blurredEffect)
  }

  nonisolated private static func drawBlurredBackgroundTint(
    effect: BlurredBackgroundEffect,
    in context: CGContext,
    rect: CGRect
  ) {
    guard effect.tintOpacity > 0 else { return }

    context.saveGState()
    context.setFillColor(NSColor(effect.tintColor).withAlphaComponent(CGFloat(effect.tintOpacity)).cgColor)
    context.fill(rect)
    context.restoreGState()
  }

  nonisolated private static func makeBlurredBackgroundImage(
    from image: NSImage?,
    effect: BlurredBackgroundEffect
  ) -> NSImage? {
    guard let image,
          let tiffData = image.tiffRepresentation,
          let ciImage = CIImage(data: tiffData) else { return nil }

    let blurFilter = CIFilter(name: "CIGaussianBlur")
    blurFilter?.setValue(ciImage.clampedToExtent(), forKey: kCIInputImageKey)
    blurFilter?.setValue(effect.blurRadius, forKey: kCIInputRadiusKey)

    guard let blurredOutput = blurFilter?.outputImage else { return nil }

    let colorFilter = CIFilter(name: "CIColorControls")
    colorFilter?.setValue(blurredOutput, forKey: kCIInputImageKey)
    colorFilter?.setValue(effect.saturation, forKey: kCIInputSaturationKey)
    colorFilter?.setValue(effect.brightness, forKey: kCIInputBrightnessKey)

    guard let output = colorFilter?.outputImage else { return nil }

    let croppedOutput = output.cropped(to: ciImage.extent)
    let rep = NSCIImageRep(ciImage: croppedOutput)
    let blurred = NSImage(size: rep.size)
    blurred.addRepresentation(rep)
    return blurred
  }

  nonisolated private static func destinationOrigin(
    imageSize: CGSize,
    totalSize: CGSize,
    alignment: ImageAlignment
  ) -> CGPoint {
    let totalExtraWidth = totalSize.width - imageSize.width
    let totalExtraHeight = totalSize.height - imageSize.height

    switch alignment {
    case .center:
      return CGPoint(x: totalExtraWidth / 2, y: totalExtraHeight / 2)
    case .topLeft:
      return CGPoint(x: 0, y: totalExtraHeight)
    case .top:
      return CGPoint(x: totalExtraWidth / 2, y: totalExtraHeight)
    case .topRight:
      return CGPoint(x: totalExtraWidth, y: totalExtraHeight)
    case .left:
      return CGPoint(x: 0, y: totalExtraHeight / 2)
    case .right:
      return CGPoint(x: totalExtraWidth, y: totalExtraHeight / 2)
    case .bottomLeft:
      return .zero
    case .bottom:
      return CGPoint(x: totalExtraWidth / 2, y: 0)
    case .bottomRight:
      return CGPoint(x: totalExtraWidth, y: 0)
    }
  }



  // MARK: - Mockup Rendering

  /// Render the flattened image + annotations that mockup transforms are applied to.
  /// Pure bitmap drawing from the frozen snapshot — safe on any queue.
  nonisolated static func renderMockupFlatImage(snapshot: AnnotateRenderSnapshot) -> NSImage? {
    let sourceImage = snapshot.sourceImage

    // Determine effective bounds (crop or full image)
    let effectiveBounds: CGRect
    if let cropRect = snapshot.cropRect {
      effectiveBounds = cropRect
    } else {
      effectiveBounds = snapshot.effectiveContentBounds
    }

    // Render at pixel resolution using NSBitmapImageRep for Retina quality
    let scale = sourceImageScale(sourceImage)
    let pixelWidth = exportPixelLength(effectiveBounds.width, scale: scale)
    let pixelHeight = exportPixelLength(effectiveBounds.height, scale: scale)

    guard let bitmapRep = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: pixelWidth,
      pixelsHigh: pixelHeight,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    ) else { return nil }
    bitmapRep.size = effectiveBounds.size  // Point size

    guard let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmapRep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext

    let context = graphicsContext.cgContext

    drawCropFill(snapshot.cropFillColor, in: CGRect(origin: .zero, size: effectiveBounds.size), context: context)
    drawSourceImage(sourceImage, effectiveBounds: effectiveBounds, destinationOrigin: .zero, in: context)

    // Рендер аннотаций в исходных координатах.
    let renderer = AnnotationRenderer(
      context: context,
      drawsObjectShadow: snapshot.drawObjectShadow,
      sourceImage: sourceImage,
      embeddedImageProvider: { assetId in
        snapshot.embeddedImages[assetId]
      },
      embeddedCGImageProvider: { assetId in
        snapshot.embeddedCGImages[assetId]
      },
      secureExportSalt: snapshot.secureExportSalt ?? BlurEffectRenderer.makeSecureExportSalt()
    )
    context.saveGState()
    context.translateBy(x: -effectiveBounds.minX, y: -effectiveBounds.minY)
    for annotation in snapshot.annotations.renderOrdered {
      if let cropRect = snapshot.cropRect {
        guard annotation.renderBounds.intersects(cropRect) else { continue }
      }
      renderer.draw(annotation)
    }
    context.restoreGState()

    NSGraphicsContext.restoreGraphicsState()

    let image = NSImage(size: effectiveBounds.size)
    image.addRepresentation(bitmapRep)
    return image
  }

  /// Apply mockup 3D transforms to the flattened image via SwiftUI ImageRenderer.
  /// ImageRenderer is main-only — this is the sole main-actor step of mockup export.
  @MainActor static func compositeMockupImage(flatImage: NSImage, snapshot: AnnotateRenderSnapshot) -> NSImage? {
    let mockupView = MockupExportViewForAnnotate(flatImage: flatImage, snapshot: snapshot)
    let renderer = ImageRenderer(content: mockupView)
    renderer.scale = 2.0

    return renderer.nsImage
  }
}

// MARK: - Mockup Export View for Annotate

/// SwiftUI view for exporting mockup with 3D transforms
struct MockupExportViewForAnnotate: View {
  let flatImage: NSImage  // Pre-rendered image with annotations
  let snapshot: AnnotateRenderSnapshot

  var body: some View {
    ZStack {
      backgroundLayer
        .frame(width: canvasSize.width, height: canvasSize.height)

      Image(nsImage: flatImage)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(maxWidth: imageSize.width, maxHeight: imageSize.height)
        .clipShape(RoundedRectangle(cornerRadius: snapshot.cornerRadius, style: .continuous))
        .rotation3DEffect(
          .degrees(snapshot.mockupRotationY),
          axis: (x: 0, y: 1, z: 0),
          anchor: .center,
          anchorZ: 0,
          perspective: snapshot.mockupPerspective
        )
        .rotation3DEffect(
          .degrees(snapshot.mockupRotationX),
          axis: (x: 1, y: 0, z: 0),
          anchor: .center,
          anchorZ: 0,
          perspective: snapshot.mockupPerspective
        )
        .rotation3DEffect(
          .degrees(snapshot.mockupRotationZ),
          axis: (x: 0, y: 0, z: 1),
          anchor: .center
        )
        .shadow(
          color: .black.opacity(snapshot.shadowIntensity),
          radius: snapshot.mockupShadowRadius,
          x: snapshot.mockupShadowOffsetX,
          y: snapshot.mockupShadowOffsetY
        )
    }
  }

  // MARK: - Size Calculations

  private var imageSize: CGSize {
    flatImage.size
  }

  private var canvasSize: CGSize {
    let padding = snapshot.backgroundStyle != .none ? snapshot.padding : 0
    let extraSpace = padding * 2 + 100 // Extra for shadow and rotation
    return CGSize(
      width: imageSize.width + extraSpace,
      height: imageSize.height + extraSpace
    )
  }

  // MARK: - Background

  @ViewBuilder
  private var backgroundLayer: some View {
    switch snapshot.backgroundStyle {
    case .none:
      Color.clear
    case .gradient(let preset):
      GradientPresetFill(preset: preset)
    case .solidColor(let color):
      color
        .brightness(snapshot.isBlurredBackgroundEffectActive ? snapshot.blurredBackgroundEffect.brightness : 0)
        .overlay(
          (snapshot.isBlurredBackgroundEffectActive ? snapshot.blurredBackgroundEffect.tintColor : .clear)
            .opacity(snapshot.isBlurredBackgroundEffectActive ? snapshot.blurredBackgroundEffect.tintOpacity : 0)
        )
    case .wallpaper(let url):
      // Check if this is a preset wallpaper
      if url.scheme == "preset", let presetName = url.host,
         let preset = WallpaperPreset(rawValue: presetName) {
        preset.gradient
      } else if let image = snapshot.resolvedBackgroundImage {
        Image(nsImage: image)
          .resizable()
          .aspectRatio(contentMode: .fill)
          .overlay(
            snapshot.isBlurredBackgroundEffectActive
              ? snapshot.blurredBackgroundEffect.tintColor.opacity(snapshot.blurredBackgroundEffect.tintOpacity)
              : .clear
          )
      } else {
        Color.gray.opacity(0.3)
      }
    case .blurred:
      if let image = snapshot.resolvedBackgroundImage {
        Image(nsImage: image)
          .resizable()
          .aspectRatio(contentMode: .fill)
          .overlay(snapshot.blurredBackgroundEffect.tintColor.opacity(snapshot.blurredBackgroundEffect.tintOpacity))
      } else {
        Color.gray.opacity(0.3)
      }
    }
  }
}
