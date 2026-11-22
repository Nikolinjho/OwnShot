import Darwin
import Foundation

nonisolated enum QuickAccessImportedFileSave {
  /// Импорт сохраняется копией. Исходник и существующие файлы не перезаписываются.
  static func copy(source: URL, to directory: URL) throws -> URL {
    let fileManager = FileManager.default
    let source = source.standardizedFileURL
    let directory = directory.standardizedFileURL
    try validate(source: source)
    if source.deletingLastPathComponent() == directory { return source }
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let base = source.deletingPathExtension().lastPathComponent
    let ext = source.pathExtension
    var index = 0
    while true {
      let name = index == 0 ? source.lastPathComponent : "\(base) \(index)" + (ext.isEmpty ? "" : ".\(ext)")
      let destination = directory.appendingPathComponent(name)
      do {
        try fileManager.copyItem(at: source, to: destination)
        return destination
      } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
        index += 1
      }
    }
  }

  static func validate(source: URL) throws {
    let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey])
    guard values.isRegularFile == true, values.isReadable == true else {
      throw CocoaError(.fileReadNoPermission)
    }
  }
}

/// Captured before the native Save panel checks for an existing destination.
nonisolated struct QuickAccessSaveDestinationSnapshot {
  private let candidates: [String: QuickAccessSaveDestination.FileIdentity]

  init(directory: URL? = nil, enteredName: String = "", extensions: [String] = []) {
    guard let directory, !enteredName.isEmpty else {
      candidates = [:]
      return
    }
    let enteredURL = directory.appendingPathComponent(enteredName)
    var urls = [enteredURL]
    for ext in Set(extensions) where !ext.isEmpty {
      if enteredURL.pathExtension.caseInsensitiveCompare(ext) != .orderedSame {
        urls.append(enteredURL.appendingPathExtension(ext))
        if !enteredURL.pathExtension.isEmpty {
          urls.append(enteredURL.deletingPathExtension().appendingPathExtension(ext))
        }
      }
    }
    var recorded: [String: QuickAccessSaveDestination.FileIdentity] = [:]
    for url in urls {
      if let identity = QuickAccessSaveDestination.FileIdentity(at: url) {
        recorded[QuickAccessSaveDestination.directoryEntryKey(for: url)] = identity
      }
    }
    candidates = recorded
  }

  func destination(at url: URL) -> QuickAccessSaveDestination {
    let key = QuickAccessSaveDestination.directoryEntryKey(for: url)
    return QuickAccessSaveDestination(url: url, replacement: candidates[key])
  }
}

nonisolated struct QuickAccessSaveDestination {
  typealias FileIdentity = CaptureFilePublication.FileRevision

  let url: URL
  fileprivate let replacement: FileIdentity?

  fileprivate static func directoryEntryKey(for url: URL) -> String {
    let path = SandboxFileAccessManager.directoryEntryPath(for: url)
    let entry = URL(fileURLWithPath: path)
    // Use the filesystem's spelling while preserving distinct hard links and leaf symlinks.
    guard let values = try? entry.resourceValues(forKeys: [.nameKey, .isRegularFileKey, .isSymbolicLinkKey]),
          values.isRegularFile == true,
          values.isSymbolicLink == false,
          let name = values.name else { return path }
    return entry.deletingLastPathComponent().appendingPathComponent(name).path
  }

  func save(
    source: URL,
    sourceIsTemporary: Bool,
    volumesAreEqual: (dev_t, dev_t) -> Bool = (==)
  ) throws -> URL {
    let isSameEntry = Self.directoryEntryKey(for: source) == Self.directoryEntryKey(for: url)
    if sourceIsTemporary, let link = try? FileManager.default.destinationOfSymbolicLink(atPath: source.path) {
      let originalTarget = source.resolvingSymlinksInPath()
      try QuickAccessImportedFileSave.validate(source: originalTarget)
      if !isSameEntry {
        try validateMovedSourceLink(link, originalTarget: originalTarget)
      }
    } else {
      try QuickAccessImportedFileSave.validate(source: source)
    }
    if isSameEntry {
      return source
    }
    if !sourceIsTemporary {
      try writeStagedCopy(of: source)
    } else if let replacement, FileIdentity(at: url) == replacement,
              let original = FileIdentity(at: source),
              !volumesAreEqual(original.device, replacement.device) {
      // Foundation replacement requires both entries to be on the same volume.
      try writeStagedCopy(of: source, removingOriginal: original)
    } else {
      try write(source)
    }
    return url
  }

  private func validateMovedSourceLink(_ link: String, originalTarget: URL) throws {
    let destinationPath = Self.directoryEntryKey(for: url)
    let parent = URL(fileURLWithPath: destinationPath).deletingLastPathComponent()
    let linkTarget = link.hasPrefix("/") ? URL(fileURLWithPath: link) : parent.appendingPathComponent(link)
    let targetAfterMove = linkTarget.resolvingSymlinksInPath()
    guard Self.directoryEntryKey(for: targetAfterMove) != destinationPath,
          let original = FileIdentity(at: originalTarget),
          FileIdentity(at: targetAfterMove) == original else {
      throw POSIXError(.ESTALE)
    }
  }

  private func writeStagedCopy(of source: URL, removingOriginal original: FileIdentity? = nil) throws {
    let staged = url.deletingLastPathComponent().appendingPathComponent(".ownshot-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: staged) }
    try FileManager.default.copyItem(at: source, to: staged)
    if let original, FileIdentity(at: source) != original {
      throw POSIXError(.ESTALE)
    }
    try write(staged)
    if let original {
      try CaptureFilePublication.SourceIdentity(device: original.device, inode: original.inode).removeOriginal(at: source)
    }
  }

  @MainActor
  static func copyRecordingMetadata(
    from source: URL,
    to destination: URL,
    removingOriginal: Bool,
    applicationSupportDirectory: URL? = nil
  ) {
    guard source != destination,
          let metadata = RecordingMetadataStore.load(
            for: source, applicationSupportDirectory: applicationSupportDirectory
          ) else { return }

    do {
      try RecordingMetadataStore.save(metadata, for: destination, applicationSupportDirectory: applicationSupportDirectory)
    } catch {
      return
    }
    if removingOriginal {
      try? RecordingMetadataStore.delete(for: source, applicationSupportDirectory: applicationSupportDirectory)
    }
  }

  private func write(_ source: URL) throws {
    if let replacement, FileIdentity(at: url) == replacement {
      _ = try FileManager.default.replaceItemAt(url, withItemAt: source)
      return
    }

    switch CaptureFilePublication.publish(source, to: url, copyFlags: copyfile_flags_t(COPYFILE_ALL)) {
    case .moved:
      break
    case .copied(let sourceRevision):
      try sourceRevision.removeOriginal(at: source)
    case .failed(let error):
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(error), userInfo: [NSFilePathErrorKey: url.path])
    }
  }
}

nonisolated enum QuickAccessCompletionPolicy {
  /// Option инвертирует Close after dragging: при включённой настройке оставляет карточку,
  /// при выключенной закрывает её, как в эталоне.
  static func shouldCloseAfterDrag(success: Bool, closeAfterDragging: Bool, optionHeld: Bool) -> Bool {
    success && (closeAfterDragging != optionHeld)
  }

  /// Pin не прячет исходную карточку: у эталона после Pin to the Screen карточка остаётся
  /// (spec-039 quickaccess-after-pin-run). Редактор прячет её по настройке.
  static func hidesCardWhenOpening(pin: Bool, hideCardWhenWindowOpen: Bool) -> Bool {
    !pin && hideCardWhenWindowOpen
  }

  /// Закрытие несохранённой записи требует подтверждения (ScreenRecordingPopup.mediaDidSave у эталона).
  static func shouldConfirmClose(isVideo: Bool, isTempFile: Bool) -> Bool {
    isVideo && isTempFile
  }

  static func chooseDestination(behavior: String?, optionHeld: Bool) -> Bool {
    (behavior == "chooseDestination") != optionHeld
  }

  /// Copy закрывает карточку, а с Option оставляет её на месте (changelog 4.8 эталона).
  static func shouldDismissAfterCopy(optionHeld: Bool) -> Bool {
    !optionHeld
  }
}

nonisolated enum PinWindowKeyboardMovement {
  static func offset(keyCode: UInt16, shift: Bool) -> CGPoint? {
    let step: CGFloat = shift ? 10 : 1
    switch keyCode {
    case 123: return CGPoint(x: -step, y: 0)
    case 124: return CGPoint(x: step, y: 0)
    case 125: return CGPoint(x: 0, y: -step)
    case 126: return CGPoint(x: 0, y: step)
    default: return nil
    }
  }
}
