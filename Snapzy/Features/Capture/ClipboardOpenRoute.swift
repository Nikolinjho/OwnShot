//
//  ClipboardOpenRoute.swift
//  Snapzy
//
//  Выбор пути для Open from Clipboard: запись в Quick Access или редактор изображений.
//

import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Куда отправить содержимое буфера по команде Open from Clipboard.
/// Видео из буфера (changelog 4.6 эталона) открывается карточкой записи Quick Access,
/// а не пустым холстом редактора изображений. Видеоредактор Studio вне объёма.
nonisolated enum ClipboardOpenRoute: Equatable {
  /// Файл записи: карточка Quick Access с бейджем видео или GIF.
  case quickAccessRecording(URL)
  /// Прочий файл открывается в редакторе изображений, как раньше.
  case annotateFile(URL)
  /// В буфере картинка без файла.
  case annotateImage
  /// Исходные байты снимка из буфера.
  case annotateCopiedImage(Data, fileExtension: String)
  /// Видео, которое Quick Access не покажет, или пустой буфер.
  case unsupported

  /// Те же расширения, что ThumbnailGenerator считает видео, и GIF как анимация.
  /// GIF-запись Quick Access тоже показывает карточкой записи с бейджем GIF.
  static let recordingExtensions: Set<String> = ["mov", "mp4", "m4v", "gif"]

  static func isRecordingFile(_ url: URL) -> Bool {
    recordingExtensions.contains(url.pathExtension.lowercased())
  }

  /// Видео другого формата (avi, webm) не открывается ни картинкой, ни карточкой.
  static func isUnsupportedMovie(_ url: URL) -> Bool {
    guard !isRecordingFile(url), let type = UTType(filenameExtension: url.pathExtension) else { return false }
    return type.conforms(to: .movie) || type.conforms(to: .video)
  }

  static func resolve(fileURL: URL?, hasImage: Bool) -> ClipboardOpenRoute {
    if let fileURL {
      if isRecordingFile(fileURL) { return .quickAccessRecording(fileURL) }
      if isUnsupportedMovie(fileURL) { return .unsupported }
      return .annotateFile(fileURL)
    }
    return hasImage ? .annotateImage : .unsupported
  }

  /// Finder кладёт в буфер и ссылку на файл, и его значок, поэтому файл проверяется первым.
  static func resolve(pasteboard: NSPasteboard) -> ClipboardOpenRoute {
    let urls = pasteboard.readObjects(forClasses: [NSURL.self],
      options: [.urlReadingFileURLsOnly: true]) as? [URL]
    let fileURL = urls?.first
    if fileURL == nil {
      let imageTypes = Set(NSImage.readableTypes(for: pasteboard))
      if let item = pasteboard.pasteboardItems?.first(where: { !imageTypes.isDisjoint(with: $0.types) }),
         let png = item.data(forType: .png),
         let source = CGImageSourceCreateWithData(png as CFData, nil),
         CGImageSourceGetStatus(source) == .statusComplete {
        return .annotateCopiedImage(png, fileExtension: "png")
      }
    }
    if let fileURL, !FileManager.default.isReadableFile(atPath: fileURL.path) {
      if isRecordingFile(fileURL) { return .unsupported }
      if UTType(filenameExtension: fileURL.pathExtension)?.conforms(to: .image) == true,
         let item = pasteboard.pasteboardItems?.first(where: {
           $0.string(forType: .fileURL).flatMap(URL.init(string:)) == fileURL
         }) {
        if let png = item.data(forType: .png) { return .annotateCopiedImage(png, fileExtension: "png") }
        if let tiff = item.data(forType: .tiff) { return .annotateCopiedImage(tiff, fileExtension: "tiff") }
      }
    }
    return resolve(fileURL: fileURL, hasImage: pasteboard.canReadObject(forClasses: [NSImage.self], options: nil))
  }
}
