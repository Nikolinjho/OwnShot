//
//  CaptureOutputNaming.swift
//  Snapzy
//
//  Shared output filename generation for screenshots and recordings.
//

import AppKit
import Darwin
import Foundation

/// Contextual metadata about the capture source, used for template token replacement.
nonisolated struct CaptureContext: Equatable {
  let appName: String?
  let windowTitle: String?
  var sourceAppBundleID: String? = nil
  var bypassesDefaultPreset = false
  var asksForName = true
  var pinsToScreen = false
  /// Явный Copy или Ctrl при захвате просит обработчик результата скопировать снимок.
  var copiesToClipboard = false
  var opensInAnnotate = false
  var copiesOnlyToClipboard = false

  func requestingPin(_ pin: Bool) -> CaptureContext {
    var result = self
    result.pinsToScreen = pin
    return result
  }

  func requestingCopy(_ copy: Bool) -> CaptureContext {
    var result = self
    result.copiesToClipboard = copiesToClipboard || copy
    return result
  }

  func requestingAnnotation(_ annotate: Bool) -> CaptureContext {
    var result = self
    result.opensInAnnotate = opensInAnnotate || annotate
    return result
  }

  func requestingCopyOnly(_ copyOnly: Bool) -> CaptureContext {
    var result = self
    result.copiesOnlyToClipboard = copiesOnlyToClipboard || copyOnly
    return result
  }

  @MainActor
  func capturingModifiers(isInteractive: Bool = true) -> CaptureContext {
    var result = self
    result.bypassesDefaultPreset = isInteractive && (bypassesDefaultPreset || NSEvent.modifierFlags.contains(.shift))
    result.copiesToClipboard = isInteractive && (copiesToClipboard || NSEvent.modifierFlags.contains(.control))
    result.asksForName = asksForName && isInteractive
    return result
  }

  func withoutNamePrompt() -> CaptureContext {
    var result = self
    result.asksForName = false
    return result
  }

  static let empty = CaptureContext(appName: nil, windowTitle: nil)

  /// Max characters for windowTitle in filenames to prevent excessively long paths.
  private static let maxTitleLength = 80

  var sanitizedWindowTitle: String? {
    guard let title = windowTitle, !title.isEmpty else { return nil }
    if title.count <= Self.maxTitleLength { return title }
    return String(title.prefix(Self.maxTitleLength))
  }

  /// Creates a CaptureContext from a process ID, resolving app name from NSRunningApplication.
  @MainActor
  static func fromPID(_ pid: Int32?, windowTitle: String? = nil) -> CaptureContext {
    guard let pid else {
      CaptureSourceApplication.reset()
      return CaptureContext(appName: nil, windowTitle: windowTitle)
    }
    let app = NSRunningApplication(processIdentifier: pid)
    let bundleID = app?.bundleIdentifier
    let ownBundleID = Bundle.main.bundleIdentifier
    CaptureSourceApplication.note(bundleID: bundleID, ownBundleID: ownBundleID)
    let name = app?.localizedName
      ?? bundleID.flatMap { $0.split(separator: ".").last.map(String.init) }
    return CaptureContext(
      appName: name,
      windowTitle: windowTitle,
      sourceAppBundleID: CaptureSourceApplication.externalBundleID(bundleID, ownBundleID: ownBundleID)
    )
  }

  /// Creates a CaptureContext from the frontmost application (for fullscreen/area captures).
  @MainActor
  static func fromFrontmostApp() -> CaptureContext {
    guard let app = NSWorkspace.shared.frontmostApplication else {
      CaptureSourceApplication.reset()
      return .empty
    }
    let bundleID = app.bundleIdentifier
    let ownBundleID = Bundle.main.bundleIdentifier
    CaptureSourceApplication.note(bundleID: bundleID, ownBundleID: ownBundleID)
    // Don't resolve Snapzy itself as the app name
    if bundleID == ownBundleID { return .empty }
    return CaptureContext(
      appName: app.localizedName,
      windowTitle: nil,
      sourceAppBundleID: CaptureSourceApplication.externalBundleID(bundleID, ownBundleID: ownBundleID)
    )
  }
}

enum CaptureOutputKind {
  case screenshot
  case recording

  var defaultTemplate: String {
    switch self {
    case .screenshot:
      return "OwnShot_{datetime}_{ms}"
    case .recording:
      return "OwnShot_Recording_{datetime}"
    }
  }

  var typeTokenValue: String {
    switch self {
    case .screenshot:
      return "screenshot"
    case .recording:
      return "recording"
    }
  }

  var templatePreferenceKey: String {
    switch self {
    case .screenshot:
      return PreferencesKeys.screenshotFileNameTemplate
    case .recording:
      return PreferencesKeys.recordingFileNameTemplate
    }
  }
}

/// Элементы формата имени файла из sheet Customize… (как в CleanShot X: `%y`, `%m` и т.д.).
nonisolated enum CaptureFileNameToken: String, CaseIterable, Identifiable {
  case year = "y"
  case monthNumeric = "m"
  case monthName = "n"
  case day = "d"
  case dayOfWeek = "w"
  case hour = "H"
  case minutes = "M"
  case seconds = "S"
  case amPm = "p"
  case windowTitle = "t"
  case appName = "a"
  case randomCharacters = "r"
  case autoIncrement = "i"

  var id: String { rawValue }

  /// Текст токена в шаблоне.
  var code: String { "%" + rawValue }

  /// Подпись в палитре sheet Customize….
  var title: String {
    switch self {
    case .year: return "Year:"
    case .monthNumeric: return "Month (numeric):"
    case .monthName: return "Month (name):"
    case .day: return "Day:"
    case .dayOfWeek: return "Day of week:"
    case .hour: return "Hour:"
    case .minutes: return "Minutes:"
    case .seconds: return "Seconds:"
    case .amPm: return "AM/PM:"
    case .windowTitle: return "Window title:"
    case .appName: return "App name:"
    case .randomCharacters: return "Random characters:"
    case .autoIncrement: return "Auto-increment:"
    }
  }

  /// Колонки палитры в порядке эталона.
  static let paletteLeftColumn: [CaptureFileNameToken] = [.year, .monthNumeric, .monthName, .day, .dayOfWeek, .windowTitle, .appName]
  static let paletteRightColumn: [CaptureFileNameToken] = [.hour, .minutes, .seconds, .amPm, .randomCharacters, .autoIncrement]

  /// Длина значения `%r`.
  static let randomCharactersLength = 6
}

/// Флажки sheet Customize…, общие для превью и настоящего имени файла.
struct CaptureFileNameOptions: Equatable {
  var usesUTC = false
  var removesIllegalCharacters = true

  static let defaults = CaptureFileNameOptions()

  static func current(defaults: UserDefaults = .standard) -> CaptureFileNameOptions {
    CaptureFileNameOptions(
      usesUTC: defaults.object(forKey: OwnShotAdvancedPreferenceKeys.fileNameUsesUTC) as? Bool ?? false,
      removesIllegalCharacters: defaults.object(forKey: OwnShotAdvancedPreferenceKeys.fileNameRemovesIllegalCharacters) as? Bool ?? true
    )
  }

  func save(to defaults: UserDefaults = .standard) {
    defaults.set(usesUTC, forKey: OwnShotAdvancedPreferenceKeys.fileNameUsesUTC)
    defaults.set(removesIllegalCharacters, forKey: OwnShotAdvancedPreferenceKeys.fileNameRemovesIllegalCharacters)
  }

  var timeZone: TimeZone {
    usesUTC ? TimeZone(identifier: "UTC") ?? .current : .current
  }
}

enum CaptureOutputNaming {
  private static let invalidPathComponentCharacters = CharacterSet(charactersIn: "\\:?%*|\"<>\n\r\t")
  /// Двоеточие Finder показывает как «/», управляющие символы ломают имя.
  private static let minimalInvalidPathComponentCharacters = CharacterSet(charactersIn: ":\n\r\t\u{0}")
  private static let knownExtensions: Set<String> = ["png", "jpg", "jpeg", "webp", "mov", "mp4", "gif"]

  static func resolveBaseName(
    customName: String?,
    kind: CaptureOutputKind,
    date: Date = Date(),
    context: CaptureContext = .empty,
    scaleFactor: CGFloat? = nil,
    defaults: UserDefaults = .standard
  ) -> String {
    if let customName {
      let sanitizedCustomName = sanitizeBaseName(customName)
      if !sanitizedCustomName.isEmpty {
        return applyRetinaSuffix(sanitizedCustomName, kind: kind, scaleFactor: scaleFactor, defaults: defaults)
      }
    }

    let template = resolvedTemplate(for: kind, defaults: defaults)
    // %i расходует номер только при настоящем сохранении, превью его не трогает.
    let autoIncrement = usesAutoIncrement(template) ? consumeAutoIncrement(defaults: defaults) : nil
    let baseName = resolveTemplateBaseName(
      template,
      kind: kind,
      date: date,
      context: context,
      options: .current(defaults: defaults),
      autoIncrement: autoIncrement,
      defaults: defaults
    )
    return applyRetinaSuffix(baseName, kind: kind, scaleFactor: scaleFactor, defaults: defaults)
  }

  private static func applyRetinaSuffix(
    _ baseName: String,
    kind: CaptureOutputKind,
    scaleFactor: CGFloat?,
    defaults: UserDefaults
  ) -> String {
    guard kind == .screenshot,
          let scaleFactor, scaleFactor >= 2,
          defaults.object(forKey: OwnShotAdvancedPreferenceKeys.addRetinaSuffix) as? Bool ?? true,
          !baseName.hasSuffix("@2x") else { return baseName }
    return baseName + "@2x"
  }

  static func resolvedTemplate(for kind: CaptureOutputKind, defaults: UserDefaults = .standard) -> String {
    guard let raw = defaults.string(forKey: kind.templatePreferenceKey) else {
      return kind.defaultTemplate
    }

    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? kind.defaultTemplate : trimmed
  }

  static func resolveTemplateBaseName(
    _ template: String,
    kind: CaptureOutputKind,
    date: Date = Date(),
    context: CaptureContext = .empty,
    options: CaptureFileNameOptions? = nil,
    autoIncrement: Int? = nil,
    randomCharacters: (() -> String)? = nil,
    defaults: UserDefaults = .standard
  ) -> String {
    let options = options ?? .current(defaults: defaults)
    let parsed = parseTemplate(
      template,
      kind: kind,
      date: date,
      context: context,
      timeZone: options.timeZone,
      autoIncrement: autoIncrement ?? nextAutoIncrement(defaults: defaults),
      randomCharacters: randomCharacters ?? { randomString(length: CaptureFileNameToken.randomCharactersLength) }
    )
    let sanitizedParsed = sanitizeBaseName(parsed, strict: options.removesIllegalCharacters)
    if !sanitizedParsed.isEmpty {
      return sanitizedParsed
    }

    return fallbackName(for: kind, date: date)
  }

  // MARK: - Auto-increment

  /// Есть ли в шаблоне токен %i.
  static func usesAutoIncrement(_ template: String) -> Bool {
    segments(of: template).contains { $0 == .token(.autoIncrement) }
  }

  /// Номер, который получит следующий файл. Значения меньше 1 считаются 1.
  static func nextAutoIncrement(defaults: UserDefaults = .standard) -> Int {
    max(1, defaults.integer(forKey: OwnShotAdvancedPreferenceKeys.fileNameNextAutoIncrement))
  }

  static func setNextAutoIncrement(_ value: Int, defaults: UserDefaults = .standard) {
    defaults.set(max(1, value), forKey: OwnShotAdvancedPreferenceKeys.fileNameNextAutoIncrement)
  }

  /// Возвращает текущий номер и сдвигает счётчик на следующий.
  static func consumeAutoIncrement(defaults: UserDefaults = .standard) -> Int {
    let value = nextAutoIncrement(defaults: defaults)
    setNextAutoIncrement(value + 1, defaults: defaults)
    return value
  }

  // MARK: - Сегменты шаблона

  /// Часть шаблона: обычный текст или токен вида %y.
  enum TemplateSegment: Equatable {
    case text(String)
    case token(CaptureFileNameToken)
  }

  /// Разбивает шаблон на текст и %-токены. Неизвестные `%x` остаются текстом.
  static func segments(of template: String) -> [TemplateSegment] {
    var result: [TemplateSegment] = []
    var buffer = ""
    var iterator = template.makeIterator()
    var pending: Character?

    func flush() {
      guard !buffer.isEmpty else { return }
      result.append(.text(buffer))
      buffer = ""
    }

    while let character = pending ?? iterator.next() {
      pending = nil
      guard character == "%" else {
        buffer.append(character)
        continue
      }
      guard let next = iterator.next() else {
        buffer.append(character)
        break
      }
      if let token = CaptureFileNameToken(rawValue: String(next)) {
        flush()
        result.append(.token(token))
      } else {
        buffer.append(character)
        pending = next
      }
    }
    flush()
    return result
  }

  static func makeUniqueFileURL(in directory: URL, baseName: String, fileExtension: String) -> URL {
    var candidate = directory.appendingPathComponent("\(baseName).\(fileExtension)")
    var suffix = 2

    while isOutputNameTaken(candidate) {
      candidate = directory.appendingPathComponent("\(baseName)_\(suffix).\(fileExtension)")
      suffix += 1
    }

    return candidate
  }

  static func isOutputNameTaken(_ url: URL) -> Bool {
    url.withUnsafeFileSystemRepresentation { path in
      guard let path else { return false }
      var info = stat()
      return lstat(path, &info) == 0
    }
  }

  private static func parseTemplate(
    _ template: String,
    kind: CaptureOutputKind,
    date: Date,
    context: CaptureContext,
    timeZone: TimeZone,
    autoIncrement: Int,
    randomCharacters: () -> String
  ) -> String {
    let segments = segments(of: template)
    // При %p часы идут в 12-часовом формате, как в превью эталона «1.39.52 PM».
    let usesTwelveHourClock = segments.contains(.token(.amPm))
    return segments.map { segment in
      switch segment {
      case .text(let text):
        return replaceBraceTokens(in: text, kind: kind, date: date, context: context, timeZone: timeZone)
      case .token(let token):
        return value(
          for: token,
          date: date,
          context: context,
          timeZone: timeZone,
          usesTwelveHourClock: usesTwelveHourClock,
          autoIncrement: autoIncrement,
          randomCharacters: randomCharacters
        )
      }
    }.joined()
  }

  private static func value(
    for token: CaptureFileNameToken,
    date: Date,
    context: CaptureContext,
    timeZone: TimeZone,
    usesTwelveHourClock: Bool,
    autoIncrement: Int,
    randomCharacters: () -> String
  ) -> String {
    switch token {
    case .year: return numeric(date, style: "yyyy", timeZone: timeZone)
    case .monthNumeric: return numeric(date, style: "MM", timeZone: timeZone)
    case .monthName: return format(date, style: "MMMM", timeZone: timeZone)
    case .day: return numeric(date, style: "dd", timeZone: timeZone)
    case .dayOfWeek: return format(date, style: "EEEE", timeZone: timeZone)
    case .hour: return numeric(date, style: usesTwelveHourClock ? "h" : "HH", timeZone: timeZone)
    case .minutes: return numeric(date, style: "mm", timeZone: timeZone)
    case .seconds: return numeric(date, style: "ss", timeZone: timeZone)
    case .amPm: return numeric(date, style: "a", timeZone: timeZone)
    // Название окна и приложения не должны создавать подпапки.
    case .windowTitle: return pathSafeValue(context.sanitizedWindowTitle)
    case .appName: return pathSafeValue(context.appName)
    case .randomCharacters: return randomCharacters()
    case .autoIncrement: return String(autoIncrement)
    }
  }

  private static func pathSafeValue(_ value: String?) -> String {
    (value ?? "")
      .replacingOccurrences(of: "/", with: "-")
      .replacingOccurrences(of: ":", with: "-")
  }

  private static func randomString(length: Int) -> String {
    let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
    return String((0..<length).map { _ in alphabet.randomElement() ?? "x" })
  }

  private static func replaceBraceTokens(
    in template: String,
    kind: CaptureOutputKind,
    date: Date,
    context: CaptureContext,
    timeZone: TimeZone
  ) -> String {
    var resolved = template
    let replacements: [String: String] = [
      "{type}": kind.typeTokenValue,
      "{year}": numeric(date, style: "yyyy", timeZone: timeZone),
      "{yearShort}": numeric(date, style: "yy", timeZone: timeZone),
      "{year_short}": numeric(date, style: "yy", timeZone: timeZone),
      "{yy}": numeric(date, style: "yy", timeZone: timeZone),
      "{month}": numeric(date, style: "MM", timeZone: timeZone),
      "{monthName}": format(date, style: "MMMM", timeZone: timeZone),
      "{monthShort}": format(date, style: "MMM", timeZone: timeZone),
      "{month_name}": format(date, style: "MMMM", timeZone: timeZone),
      "{month_short}": format(date, style: "MMM", timeZone: timeZone),
      "{day}": numeric(date, style: "dd", timeZone: timeZone),
      "{date}": numeric(date, style: "yyyy-MM-dd", timeZone: timeZone),
      "{time}": numeric(date, style: "HH-mm-ss", timeZone: timeZone),
      "{datetime}": numeric(date, style: "yyyy-MM-dd_HH-mm-ss", timeZone: timeZone),
      "{ms}": numeric(date, style: "SSS", timeZone: timeZone),
      "{timestamp}": String(Int(date.timeIntervalSince1970)),
      "{appName}": context.appName ?? "",
      "{app_name}": context.appName ?? "",
    ]

    for (token, value) in replacements {
      resolved = resolved.replacingOccurrences(of: token, with: value)
    }

    return resolved
  }

  private static func sanitizeBaseName(_ value: String, strict: Bool = true) -> String {
    let components = value
      .split(separator: "/", omittingEmptySubsequences: true)
      .map { sanitizePathComponent(String($0), strict: strict) }
      .filter { !$0.isEmpty }

    guard !components.isEmpty else { return "" }

    var sanitizedComponents = components
    sanitizedComponents[sanitizedComponents.count - 1] = stripKnownExtension(
      from: sanitizedComponents[sanitizedComponents.count - 1]
    )
    sanitizedComponents = sanitizedComponents.filter { !$0.isEmpty }

    return sanitizedComponents.joined(separator: "/")
  }

  /// strict == false соответствует выключенному Remove illegal characters:
  /// заменяются только символы, без которых файл не сохранить.
  private static func sanitizePathComponent(_ value: String, strict: Bool = true) -> String {
    var sanitized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !sanitized.isEmpty else { return "" }

    let forbidden = strict ? invalidPathComponentCharacters : minimalInvalidPathComponentCharacters
    sanitized = sanitized.components(separatedBy: forbidden).joined(separator: "_")
    sanitized = sanitized.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    sanitized = sanitized.replacingOccurrences(of: "_{2,}", with: "_", options: .regularExpression)
    sanitized = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    return sanitized
  }

  private static func stripKnownExtension(from component: String) -> String {
    var sanitized = component
    let pathExtension = (sanitized as NSString).pathExtension.lowercased()
    if knownExtensions.contains(pathExtension) {
      sanitized = (sanitized as NSString).deletingPathExtension
    }

    sanitized = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    return sanitized
  }

  /// Числовые поля и AM/PM: POSIX-локаль, иначе системный 12-часовой режим
  /// превращает «HH» в «2 PM» и ломает имя файла.
  private static func numeric(_ date: Date, style: String, timeZone: TimeZone) -> String {
    format(date, style: style, timeZone: timeZone, locale: Locale(identifier: "en_US_POSIX"))
  }

  private static func format(
    _ date: Date,
    style: String,
    timeZone: TimeZone = .current,
    locale: Locale? = nil
  ) -> String {
    let formatter = DateFormatter()
    formatter.timeZone = timeZone
    if let locale { formatter.locale = locale }
    // Pin only the calendar so date tokens always resolve to Gregorian values
    // regardless of the user's system calendar. Without this, users on a
    // Buddhist calendar (e.g. Thai `th_TH`) get the Buddhist year (e.g. 2569)
    // instead of the Gregorian year (e.g. 2026) in filenames. The locale is
    // left alone so `{monthName}`/`{monthShort}` stay localized.
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = style
    return formatter.string(from: date)
  }

  private static func fallbackName(for kind: CaptureOutputKind, date: Date) -> String {
    switch kind {
    case .screenshot:
      return "OwnShot_\(numeric(date, style: "yyyy-MM-dd_HH-mm-ss-SSS", timeZone: .current))"
    case .recording:
      return "OwnShot_Recording_\(numeric(date, style: "yyyy-MM-dd_HH-mm-ss", timeZone: .current))"
    }
  }
}
