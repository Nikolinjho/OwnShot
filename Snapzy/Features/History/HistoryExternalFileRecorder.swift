//
//  HistoryExternalFileRecorder.swift
//  Snapzy
//
//  Открытые извне файлы попадают в History, как в эталоне (Popup.Mode.openedFromExternalFile)
//

import Foundation
import ImageIO
import UniformTypeIdentifiers

enum HistoryExternalFileRecorder {
  /// Проекты и остальные файлы вне изображений не попадают в историю захватов.
  static func captureType(for url: URL) -> CaptureHistoryType? {
    guard url.isFileURL, !url.hasDirectoryPath,
          let type = UTType(filenameExtension: url.pathExtension.lowercased()),
          type.conforms(to: .image) else { return nil }
    return type == .gif ? .gif : .screenshot
  }

  /// Добавляет запись, если такого файла в истории ещё нет. При выключенной истории
  /// CaptureHistoryStore сам ничего не пишет.
  static func record(_ url: URL) {
    guard let captureType = captureType(for: url) else { return }
    let store = CaptureHistoryStore.shared
    guard !store.hasRecord(forFilePath: url.path) else { return }
    let access = SandboxFileAccessManager.shared.beginAccessingURL(url)
    defer { access.stop() }

    // ImageIO может прочитать размеры даже у обрезанного файла. Проверяем первый
    // кадр без кеширования пикселей, чтобы не создавать запись для битого изображения.
    guard let source = CGImageSourceCreateWithURL(access.url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(
            source, 0, [kCGImageSourceShouldCache: false] as CFDictionary
          ) else { return }
    store.addCapture(url: url, captureType: captureType, width: image.width, height: image.height)
  }
}
