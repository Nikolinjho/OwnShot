//
//  PostCaptureActionHandler.swift
//  Snapzy
//
//  Executes post-capture actions based on user preferences
//

import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import os.log

private let logger = Logger(subsystem: "Snapzy", category: "PostCaptureActionHandler")

/// Handles execution of post-capture actions based on user preferences
@MainActor
final class PostCaptureActionHandler {

  static let shared = PostCaptureActionHandler(
    preferences: PreferencesManager.shared,
    quickAccess: QuickAccessManager.shared,
    fileAccess: SandboxFileAccessManager.shared,
    screenshotPresetAutoApplier: ScreenshotPresetAutoApplier.shared
  )

  private let preferences: PreferencesProviding
  private let quickAccess: QuickAccessManaging
  private let fileAccess: SandboxFileAccessing
  private let screenshotPresetAutoApplier: ScreenshotPresetAutoApplier
  private let history: CaptureHistoryStore

  init(
    preferences: PreferencesProviding,
    quickAccess: QuickAccessManaging,
    fileAccess: SandboxFileAccessing,
    screenshotPresetAutoApplier: ScreenshotPresetAutoApplier,
    history: CaptureHistoryStore = .shared
  ) {
    self.preferences = preferences
    self.quickAccess = quickAccess
    self.fileAccess = fileAccess
    self.screenshotPresetAutoApplier = screenshotPresetAutoApplier
    self.history = history
  }

  // MARK: - Public API

  /// Execute all enabled post-capture actions for a screenshot
  @discardableResult
  func handleScreenshotCapture(url: URL, pinToScreen: Bool = false) async -> QuickAccessItem? {
    let metadata = OwnShotScreenshotCaptureMetadata.shared
    let requestedPin = metadata.consumePin(for: url)
    let copyOnly = metadata.consumeCopyOnly(for: url)
    let sourceAppBundleID = metadata.consumeSourceAppBundleID(for: url)
    let quickAccessItem = await executeActions(
      for: .screenshot,
      url: url,
      pinToScreen: pinToScreen || requestedPin,
      copyOnly: copyOnly
    )

    // Add to capture history
    addScreenshotToHistory(url: url, sourceAppBundleID: sourceAppBundleID)

    return quickAccessItem
  }

  /// Execute post-capture actions for a batch of screenshots, such as
  /// fullscreen capture across multiple displays.
  func handleScreenshotCaptures(urls: [URL]) async {
    let validURLs = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    guard !validURLs.isEmpty else {
      DiagnosticLogger.shared.log(
        .warning,
        .action,
        "Screenshot batch post-capture skipped; no files",
        context: ["requestedCount": "\(urls.count)"]
      )
      return
    }

    guard validURLs.count > 1 else {
      await handleScreenshotCapture(url: validURLs[0])
      return
    }

    DiagnosticLogger.shared.log(
      .info,
      .action,
      "Screenshot batch post-capture started",
      context: ["count": "\(validURLs.count)"]
    )

    let captures = validURLs.map { url in
      let metadata = OwnShotScreenshotCaptureMetadata.shared
      return (url: url, sourceAppBundleID: metadata.consumeSourceAppBundleID(for: url),
        opensInAnnotate: metadata.consumeAnnotation(for: url))
    }
    var sessionDataByURL: [URL: AnnotationSessionData] = [:]
    for url in validURLs {
      if let sessionData = screenshotPresetAutoApplier.applyDefaultPresetIfNeeded(to: url,
        bypassDefaultPreset: OwnShotScreenshotCaptureMetadata.shared.consumeBypass(for: url)) {
        sessionDataByURL[url] = sessionData
        persistAnnotationSessionIfNeeded(sessionData, for: url)
      }
    }

    let requestedCopy = validURLs.map { OwnShotScreenshotCaptureMetadata.shared.consumeClipboardCopy(for: $0) }.contains(true)
    if requestedCopy || preferences.isActionEnabled(.copyFile, for: .screenshot) {
      ClipboardHelper.copyFileURLs(validURLs)
      DiagnosticLogger.shared.log(
        .info,
        .clipboard,
        "Screenshot batch file URLs copied to clipboard",
        context: ["count": "\(validURLs.count)"]
      )
    }

    let showsQuickAccess = preferences.isActionEnabled(.showQuickAccess, for: .screenshot)
    let pinsToScreen = preferences.isActionEnabled(.pinToScreen, for: .screenshot)
    for url in validURLs {
      if showsQuickAccess {
        let item = await quickAccess.addScreenshot(url: url)
        if let item, let sessionData = sessionDataByURL[url] {
          AnnotateManager.shared.saveSessionData(sessionData, for: item.id)
        }
        if pinsToScreen {
          if let item { quickAccess.pinScreenshot(id: item.id) }
          else { _ = await quickAccess.pinScreenshot(url: url) }
        }
      } else if pinsToScreen {
        _ = await quickAccess.pinScreenshot(url: url)
      }
    }

    let requestedAnnotationURL = captures.first(where: \.opensInAnnotate)?.url
    let autoAnnotationURL = preferences.isActionEnabled(.openAnnotate, for: .screenshot) ? validURLs.first : nil
    if let annotationURL = requestedAnnotationURL ?? autoAnnotationURL {
      AnnotateManager.shared.openAnnotation(url: annotationURL, sessionData: sessionDataByURL[annotationURL])
      DiagnosticLogger.shared.log(
        .info,
        .annotate,
        "Screenshot batch opened capture in Annotate",
        context: [
          "fileName": annotationURL.lastPathComponent,
          "skippedCount": "\(max(0, validURLs.count - 1))",
        ]
      )
    }

    for capture in captures {
      addScreenshotToHistory(url: capture.url, sourceAppBundleID: capture.sourceAppBundleID)
    }
  }

  /// Add a screenshot to capture history
  private func addScreenshotToHistory(url: URL, sourceAppBundleID: String?) {
    guard FileManager.default.fileExists(atPath: url.path) else {
      DiagnosticLogger.shared.log(
        .warning,
        .history,
        "Screenshot history add skipped; file missing",
        context: ["fileName": url.lastPathComponent]
      )
      return
    }

    let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil)
    var width: Int?
    var height: Int?
    if let source = imageSource {
      if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
        if let pixelWidth = properties[kCGImagePropertyPixelWidth as String] as? Int {
          width = pixelWidth
        }
        if let pixelHeight = properties[kCGImagePropertyPixelHeight as String] as? Int {
          height = pixelHeight
        }
      }
    }

    history.addCapture(
      url: url,
      captureType: .screenshot,
      width: width,
      height: height,
      sourceAppBundleID: sourceAppBundleID
    )
    DiagnosticLogger.shared.log(
      .debug,
      .history,
      "Screenshot queued for history",
      context: [
        "fileName": url.lastPathComponent,
        "width": width.map { "\($0)" } ?? "unknown",
        "height": height.map { "\($0)" } ?? "unknown",
      ]
    )
  }

  /// Execute all enabled post-capture actions for a video recording
  /// - Parameter skipQuickAccess: When true, skip adding to QuickAccess (e.g. GIF flow already added it)
  func handleVideoCapture(url: URL, skipQuickAccess: Bool = false) async {
    await executeActions(for: .recording, url: url, skipQuickAccess: skipQuickAccess)

    // Add to capture history
    await addVideoToHistory(url: url)
  }

  /// Add a video or GIF to capture history
  private func addVideoToHistory(url: URL) async {
    guard FileManager.default.fileExists(atPath: url.path) else {
      DiagnosticLogger.shared.log(
        .warning,
        .history,
        "Video history add skipped; file missing",
        context: ["fileName": url.lastPathComponent]
      )
      return
    }

    let isGIF = url.pathExtension.lowercased() == "gif"
    let captureType: CaptureHistoryType = isGIF ? .gif : .video

    var duration: TimeInterval?
    var width: Int?
    var height: Int?

    if !isGIF {
      let asset = AVURLAsset(url: url)
      let assetDuration = (try? await asset.load(.duration)) ?? .invalid
      let seconds = CMTimeGetSeconds(assetDuration)
      if seconds.isFinite && seconds > 0 {
        duration = seconds
      }

      let videoTrack = try? await asset.loadTracks(withMediaType: .video).first
      if let track = videoTrack {
        let naturalSize = (try? await track.load(.naturalSize)) ?? .zero
        width = Int(naturalSize.width)
        height = Int(naturalSize.height)
      }
    }

    history.addCapture(
      url: url,
      captureType: captureType,
      duration: duration,
      width: width,
      height: height,
      sourceAppBundleID: CaptureSourceApplication.currentBundleID
    )
    DiagnosticLogger.shared.log(
      .debug,
      .history,
      "Video queued for history",
      context: [
        "fileName": url.lastPathComponent,
        "type": captureType.rawValue,
        "duration": duration.map { "\($0)" } ?? "unknown",
        "width": width.map { "\($0)" } ?? "unknown",
        "height": height.map { "\($0)" } ?? "unknown",
      ]
    )
  }

  /// Re-run clipboard automation after an in-place edit save succeeds.
  /// Screenshots: decode/encode run off-main (serialized so rapid successive
  /// saves keep last-save-wins clipboard order); only the pasteboard write
  /// hops back to main. Videos stay on the cheap file-URL path.
  func copyEditedCaptureToClipboardIfEnabled(
    for captureType: CaptureType, url: URL, movedRecordingFrom sourceURL: URL? = nil
  ) {
    guard preferences.isActionEnabled(.copyFile, for: captureType) else {
      if captureType == .recording, let sourceURL {
        ClipboardHelper.copyMediaFile(from: url, replacingReferenceTo: sourceURL)
      }
      DiagnosticLogger.shared.log(
        .debug,
        .clipboard,
        "Automatic edited capture clipboard copy skipped by preference",
        context: ["captureType": captureType.rawValue, "fileName": url.lastPathComponent]
      )
      return
    }

    if captureType == .recording {
      copyToClipboard(url: url, isVideo: true)
    } else {
      let previous = editedClipboardTask
      editedClipboardTask = Task.detached(priority: .userInitiated) {
        await previous?.value
        await ClipboardHelper.copyImageOffMain(from: url)
      }
    }

    let label = captureType == .screenshot ? "screenshot" : "recording"
    logger.debug("Clipboard re-copy executed for edited \(url.lastPathComponent)")
    DiagnosticLogger.shared.log(
      .info,
      .clipboard,
      "Edited capture copied to clipboard",
      context: ["captureType": label, "fileName": url.lastPathComponent]
    )
  }

  /// Chained task serializing off-main edited-capture clipboard writes.
  private var editedClipboardTask: Task<Void, Never>?

  // MARK: - Private

  @discardableResult
  private func executeActions(
    for captureType: CaptureType,
    url: URL,
    skipQuickAccess: Bool = false,
    pinToScreen: Bool = false,
    copyOnly: Bool = false
  ) async -> QuickAccessItem? {
    let scopedAccess = fileAccess.beginAccessingURL(url)
    defer { scopedAccess.stop() }

    // Validate file exists before processing
    guard FileManager.default.fileExists(atPath: url.path) else {
      logger.error("Capture file missing at \(url.lastPathComponent), skipping post-capture actions")
      DiagnosticLogger.shared.log(
        .error,
        .action,
        "Post-capture actions skipped; file missing",
        context: ["captureType": captureType.rawValue, "fileName": url.lastPathComponent]
      )
      return nil
    }

    logger.info("Executing post-capture actions for \(captureType == .screenshot ? "screenshot" : "recording"): \(url.lastPathComponent)")
    let screenshotSessionData = captureType == .screenshot
      ? screenshotPresetAutoApplier.applyDefaultPresetIfNeeded(to: url,
          bypassDefaultPreset: OwnShotScreenshotCaptureMetadata.shared.consumeBypass(for: url))
      : nil
    if let screenshotSessionData {
      persistAnnotationSessionIfNeeded(screenshotSessionData, for: url)
    }
    let isTempCapture = TempCaptureManager.shared.isTempFile(url)
    let locationLabel = isTempCapture ? "temp" : "export"
    let typeLabel = captureType == .screenshot ? "screenshot" : "recording"
    DiagnosticLogger.shared.log(
      .info,
      .action,
      "Post-capture actions started",
      context: [
        "captureType": typeLabel,
        "fileName": url.lastPathComponent,
        "location": locationLabel,
        "skipQuickAccess": skipQuickAccess ? "true" : "false",
      ]
    )

    // Copy file to clipboard before slower UI actions. Auto-copy is expected
    // to update immediately after capture; it must not depend on thumbnail
    // generation, Quick Access animations, or editor opening.
    // Явный Copy и Ctrl при захвате используют тот же проход, что и Auto Copy.
    let requestedCopy = captureType == .screenshot
      && OwnShotScreenshotCaptureMetadata.shared.consumeClipboardCopy(for: url)
    if copyOnly || requestedCopy || preferences.isActionEnabled(.copyFile, for: captureType) {
      copyToClipboard(url: url, isVideo: captureType == .recording)
      let label = captureType == .screenshot ? "screenshot" : "recording"
      logger.debug("Clipboard copy executed for \(url.lastPathComponent)")
      DiagnosticLogger.shared.log(
        .info,
        .clipboard,
        "Post-capture clipboard action executed",
        context: ["captureType": label, "fileName": url.lastPathComponent]
      )
    }

    if copyOnly { return nil }

    // Show Quick Access Overlay
    var quickAccessItem: QuickAccessItem?
    if !skipQuickAccess && preferences.isActionEnabled(.showQuickAccess, for: captureType) {
      switch captureType {
      case .screenshot:
        quickAccessItem = await quickAccess.addScreenshot(url: url)
        if let quickAccessItem, let screenshotSessionData {
          AnnotateManager.shared.saveSessionData(screenshotSessionData, for: quickAccessItem.id)
        }
      case .recording:
        quickAccessItem = await quickAccess.addVideo(url: url)
      }
      logger.debug("Quick access overlay shown for \(url.lastPathComponent)")
      DiagnosticLogger.shared.log(
        .info,
        .action,
        "Post-capture quick access action executed",
        context: ["captureType": typeLabel, "fileName": url.lastPathComponent]
      )
    } else {
      DiagnosticLogger.shared.log(
        .debug,
        .action,
        "Post-capture quick access action skipped",
        context: [
          "captureType": typeLabel,
          "fileName": url.lastPathComponent,
          "skipQuickAccess": skipQuickAccess ? "true" : "false",
        ]
      )
    }

    // Временное окно Pin не получает сессию, записанную в кеш карточки.
    let cardForAnnotation = quickAccessItem
    if captureType == .screenshot && (pinToScreen || preferences.isActionEnabled(.pinToScreen, for: .screenshot)) {
      if let quickAccessItem {
        quickAccess.pinScreenshot(id: quickAccessItem.id)
      } else {
        quickAccessItem = await quickAccess.pinScreenshot(url: url)
      }
      DiagnosticLogger.shared.log(
        .info,
        .action,
        "Post-capture pin action executed",
        context: ["fileName": url.lastPathComponent]
      )
    }

    // Open Annotate Editor (screenshots only)
    let requestedAnnotation = captureType == .screenshot
      && OwnShotScreenshotCaptureMetadata.shared.consumeAnnotation(for: url)
    if captureType == .screenshot && (requestedAnnotation || preferences.isActionEnabled(.openAnnotate, for: captureType)) {
      if let cardForAnnotation {
        AnnotateManager.shared.openAnnotation(for: cardForAnnotation)
      } else {
        AnnotateManager.shared.openAnnotation(url: url, sessionData: screenshotSessionData)
      }
      logger.debug("Annotate editor opened for \(url.lastPathComponent)")
      DiagnosticLogger.shared.log(
        .info,
        .annotate,
        "Post-capture annotate action executed",
        context: ["fileName": url.lastPathComponent]
      )
    }

    if captureType == .recording && preferences.isActionEnabled(.openVideoEditor, for: .recording) {
      if let quickAccessItem {
        VideoEditorManager.shared.openEditor(for: quickAccessItem)
      } else {
        VideoEditorManager.shared.openEditor(for: url)
      }
    }

    return quickAccessItem
  }

  /// Copy file to clipboard (format-aware image data for screenshots, file URL for videos)
  private func copyToClipboard(url: URL, isVideo: Bool) {
    if isVideo {
      ClipboardHelper.copyMediaFile(from: url)
      DiagnosticLogger.shared.log(
        .debug,
        .clipboard,
        "File URL written to clipboard",
        context: ["fileName": url.lastPathComponent, "kind": "video"]
      )
    } else {
      ClipboardHelper.copyImage(from: url)
      DiagnosticLogger.shared.log(
        .debug,
        .clipboard,
        "Image written to clipboard",
        context: ["fileName": url.lastPathComponent]
      )
    }
  }

  private func persistAnnotationSessionIfNeeded(_ sessionData: AnnotationSessionData, for url: URL) {
    guard AnnotationSessionStore.shared.shouldPersist(for: url) else { return }
    AnnotationSessionStore.shared.persist(sessionData, for: url)
  }
}
