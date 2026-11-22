//
//  OwnShotShareHandoff.swift
//  Snapzy
//
//  Передача картинки из Share-расширений Annotate и Pin в приложение.
//  Расширение копирует картинку в общий inbox и открывает ownshot://<команда>?filepath=<путь>.
//  App Group без provisioning profile не подписать, поэтому inbox лежит в кэше приложения
//  (~/Library/Caches/dev.nikoko.ownshot/ShareInbox), а песочница расширения открывает его
//  исключением home-relative-path в entitlements.
//  Файл собирается в приложение (ради тестов) и в оба Share-расширения, поэтому зависит
//  только от системных фреймворков.
//

import AppKit
import Darwin
import Foundation
import UniformTypeIdentifiers

/// Без привязки к MainActor: копирование идёт в обработчике NSItemProvider на фоновой очереди.
nonisolated enum OwnShotShareHandoff {
  /// Команда схемы ownshot://, которую выполняет приложение.
  enum Command: String, CaseIterable {
    case annotate = "open-annotate"
    case pin
  }

  enum HandoffError: Error, Equatable {
    case noImageAttachment
    case unreadableAttachment
    case invalidFileURL
    case applicationDidNotOpenURL
  }

  /// Путь inbox от домашнего каталога. Совпадает с исключением песочницы в entitlements расширений.
  static let sharedInboxHomeRelativePath = "Library/Caches/dev.nikoko.ownshot/ShareInbox"
  static let inboxDirectoryName = "ShareInbox"
  static let fallbackFileName = "Shared Image"
  /// Сколько хранятся переданные картинки. Старые удаляются при следующей передаче.
  static let stagedFileLifetime: TimeInterval = 24 * 60 * 60

  /// Символы, которые нельзя оставлять в значении query: иначе путь с `&` или `+` разрежется.
  private static let queryValueAllowed: CharacterSet = {
    var set = CharacterSet.urlQueryAllowed
    set.remove(charactersIn: "&=+?#")
    return set
  }()

  // MARK: - URL

  /// ownshot://<команда>?filepath=<путь>. Тот же формат разбирает OwnShotAutomationRequest.
  static func url(for command: Command, fileURL: URL) -> URL? {
    guard fileURL.isFileURL else { return nil }
    let path = fileURL.standardizedFileURL.path
    guard !path.isEmpty,
          let encodedPath = path.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) else { return nil }
    var components = URLComponents()
    components.scheme = "ownshot"
    components.host = command.rawValue
    components.percentEncodedQuery = "filepath=\(encodedPath)"
    return components.url
  }

  // MARK: - Выбор вложения

  /// Тип, в котором берётся картинка: сначала конкретные форматы из правила активации, затем любой public.image.
  static func imageTypeIdentifier(in registeredTypeIdentifiers: [String]) -> String? {
    let types = registeredTypeIdentifiers.compactMap(UTType.init)
    for preferred in [UTType.png, .jpeg] {
      if let match = types.first(where: { $0.conforms(to: preferred) }) { return match.identifier }
    }
    return types.first(where: { $0.conforms(to: .image) })?.identifier
  }

  // MARK: - Каталог передачи

  /// Общий inbox в настоящем домашнем каталоге, а без него временный каталог расширения.
  static func inboxDirectory(homeDirectory: URL?, temporaryDirectory: URL) -> URL {
    guard let homeDirectory else {
      return temporaryDirectory.appendingPathComponent(inboxDirectoryName, isDirectory: true)
    }
    return homeDirectory.appendingPathComponent(sharedInboxHomeRelativePath, isDirectory: true)
  }

  /// Домашний каталог пользователя. В песочнице NSHomeDirectory указывает в контейнер, поэтому через getpwuid.
  static func realHomeDirectory() -> URL? {
    guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else { return nil }
    return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
  }

  /// Имя копии: исходное имя без пути и расширения плюс расширение по типу.
  static func stagedFileName(suggestedName: String?, typeIdentifier: String) -> String {
    let fileExtension = UTType(typeIdentifier)?.preferredFilenameExtension ?? "png"
    let rawName = (suggestedName ?? "").replacingOccurrences(of: "/", with: "-")
      .replacingOccurrences(of: ":", with: "-")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    var baseName = (rawName as NSString).deletingPathExtension
    if baseName.isEmpty || baseName.hasPrefix(".") { baseName = fallbackFileName }
    return "\(baseName).\(fileExtension)"
  }

  /// Записи каталога передачи, срок которых истёк.
  static func expiredEntries(_ entries: [(url: URL, modificationDate: Date)], now: Date) -> [URL] {
    entries.filter { now.timeIntervalSince($0.modificationDate) > stagedFileLifetime }.map(\.url)
  }

  /// Копирует файл в отдельный подкаталог inbox: одинаковые имена не перетирают друг друга.
  static func stageFile(
    at sourceURL: URL,
    suggestedName: String?,
    typeIdentifier: String,
    in inboxDirectory: URL,
    now: Date = Date(),
    fileManager: FileManager = .default
  ) throws -> URL {
    try fileManager.createDirectory(at: inboxDirectory, withIntermediateDirectories: true)
    removeExpiredEntries(in: inboxDirectory, now: now, fileManager: fileManager)
    let directory = inboxDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let destination = directory.appendingPathComponent(
      stagedFileName(suggestedName: suggestedName ?? sourceURL.lastPathComponent, typeIdentifier: typeIdentifier)
    )
    try fileManager.copyItem(at: sourceURL, to: destination)
    return destination
  }

  private static func removeExpiredEntries(in directory: URL, now: Date, fileManager: FileManager) {
    let contents = (try? fileManager.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.contentModificationDateKey],
      options: [.skipsHiddenFiles]
    )) ?? []
    let entries = contents.compactMap { url -> (url: URL, modificationDate: Date)? in
      guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else {
        return nil
      }
      return (url, date)
    }
    for url in expiredEntries(entries, now: now) { try? fileManager.removeItem(at: url) }
  }

  // MARK: - Запрос расширения

  /// Копирует картинку вложения в inbox и возвращает путь копии.
  static func stage(_ provider: NSItemProvider, in inboxDirectory: URL) async throws -> URL {
    guard let typeIdentifier = imageTypeIdentifier(in: provider.registeredTypeIdentifiers) else {
      throw HandoffError.noImageAttachment
    }
    let suggestedName = provider.suggestedName
    return try await withCheckedThrowingContinuation { continuation in
      // Временный файл провайдера живёт только внутри обработчика, поэтому копия делается здесь же.
      _ = provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
        guard let url else {
          continuation.resume(throwing: error ?? HandoffError.unreadableAttachment)
          return
        }
        do {
          let staged = try stageFile(
            at: url,
            suggestedName: suggestedName,
            typeIdentifier: typeIdentifier,
            in: inboxDirectory
          )
          continuation.resume(returning: staged)
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  /// Общий inbox, если песочница пускает в него, иначе временный каталог расширения.
  static func resolvedInboxDirectory(fileManager: FileManager = .default) -> URL {
    let temporary = fileManager.temporaryDirectory
    if let home = realHomeDirectory() {
      let inbox = inboxDirectory(homeDirectory: home, temporaryDirectory: temporary)
      if (try? fileManager.createDirectory(at: inbox, withIntermediateDirectories: true)) != nil { return inbox }
    }
    return inboxDirectory(homeDirectory: nil, temporaryDirectory: temporary)
  }

  /// Обрабатывает запрос Share-расширения: каждая картинка уходит в приложение отдельной командой.
  @MainActor
  static func perform(_ command: Command, context: NSExtensionContext?) {
    guard let context else { return }
    let providers = (context.inputItems as? [NSExtensionItem] ?? [])
      .flatMap { $0.attachments ?? [] }
      .filter { imageTypeIdentifier(in: $0.registeredTypeIdentifiers) != nil }
    guard !providers.isEmpty else {
      context.cancelRequest(withError: HandoffError.noImageAttachment)
      return
    }
    let inbox = resolvedInboxDirectory()
    Task { @MainActor in
      do {
        for provider in providers {
          let file = try await stage(provider, in: inbox)
          guard let url = url(for: command, fileURL: file) else { throw HandoffError.invalidFileURL }
          guard NSWorkspace.shared.open(url) else { throw HandoffError.applicationDidNotOpenURL }
        }
        context.completeRequest(returningItems: nil)
      } catch {
        context.cancelRequest(withError: error)
      }
    }
  }
}
