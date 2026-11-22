//
//  AnnotateSaveFormat.swift
//  Snapzy
//
//  Форматы Save As редактора и панель сохранения с выбором формата.
//

import AppKit
import UniformTypeIdentifiers

/// Форматы, которые предлагает Save As. Порядок совпадает с меню формата в панели
/// эталона: Project, разделитель, JPEG, PNG, HEIC, WebP.
enum AnnotateSaveFormat: String, CaseIterable {
  case project
  case jpeg
  case png
  case heic
  case webp

  var contentType: UTType {
    switch self {
    case .png: return .png
    case .jpeg: return .jpeg
    case .heic: return .heic
    case .webp: return .webP
    case .project: return OwnShotProjectFormat.contentType
    }
  }

  var fileExtension: String {
    switch self {
    case .png: return "png"
    case .jpeg: return "jpg"
    case .heic: return "heic"
    case .webp: return "webp"
    case .project: return OwnShotProjectFormat.fileExtension
    }
  }

  var title: String {
    switch self {
    case .png:
      return L10n.string("annotate.save-format.png", defaultValue: "PNG Image", comment: "Save As format menu item")
    case .jpeg:
      return L10n.string("annotate.save-format.jpeg", defaultValue: "JPEG Image", comment: "Save As format menu item")
    case .heic:
      return L10n.string("annotate.save-format.heic", defaultValue: "HEIC Image", comment: "Save As format menu item")
    case .webp:
      return L10n.string("annotate.save-format.webp", defaultValue: "WebP Image", comment: "Save As format menu item")
    case .project:
      return L10n.string(
        "annotate.save-format.project",
        defaultValue: "OwnShot Project",
        comment: "Save As format menu item for the editable OwnShot project"
      )
    }
  }

  /// Формат по расширению файла; nil — расширение не из списка Save As.
  init?(fileExtension: String) {
    switch fileExtension.lowercased() {
    case "png": self = .png
    case "jpg", "jpeg": self = .jpeg
    case "heic", "heif": self = .heic
    case "webp": self = .webp
    case OwnShotProjectFormat.fileExtension: self = .project
    default: return nil
    }
  }

  init?(url: URL) {
    self.init(fileExtension: url.pathExtension)
  }
}

/// NSSavePanel как в эталоне: Save As (имя исходника без расширения), Tags,
/// Where (папка исходника) и accessory с меню Format (по умолчанию PNG) и подсказкой
/// про Project. Выбор формата меняет allowedContentTypes, и панель сама подставляет
/// нужное расширение в имя файла.
@MainActor
final class AnnotateSavePanelController: NSObject {
  let panel: NSSavePanel
  let popUpButton: NSPopUpButton
  let hintLabel: NSTextField
  private let formats: [AnnotateSaveFormat]

  private(set) var selectedFormat: AnnotateSaveFormat

  init(
    baseFileName: String,
    directoryURL: URL? = nil,
    initialFormat: AnnotateSaveFormat = .png,
    formats: [AnnotateSaveFormat] = AnnotateSaveFormat.allCases
  ) {
    self.panel = NSSavePanel()
    self.formats = formats
    self.selectedFormat = formats.contains(initialFormat) ? initialFormat : (formats.first ?? .png)
    self.popUpButton = NSPopUpButton(frame: .zero, pullsDown: false)
    self.hintLabel = NSTextField(wrappingLabelWithString: Self.projectHint)
    super.init()

    panel.canCreateDirectories = true
    panel.showsTagField = true
    panel.allowedContentTypes = [selectedFormat.contentType]
    panel.nameFieldStringValue = "\(baseFileName).\(selectedFormat.fileExtension)"
    // Как у эталона, в поле Save As имя без расширения; расширение формата
    // панель добавляет к url сама, а destinationURL его гарантирует.
    panel.isExtensionHidden = true
    if let directoryURL {
      panel.directoryURL = directoryURL
    }

    let menu = NSMenu()
    for format in formats {
      let item = NSMenuItem(title: format.title, action: nil, keyEquivalent: "")
      item.representedObject = format.rawValue
      menu.addItem(item)
      // Project отделён от растровых форматов разделителем, как в эталоне.
      if format == .project, format != formats.last {
        menu.addItem(.separator())
      }
    }
    popUpButton.menu = menu
    selectFormatItem(selectedFormat)
    popUpButton.target = self
    popUpButton.action = #selector(formatChanged(_:))
    panel.accessoryView = makeAccessoryView()
  }

  /// Итоговый путь: расширение всегда соответствует выбранному формату,
  /// даже если пользователь стёр или поменял его в скрытом поле имени.
  var destinationURL: URL? {
    panel.url.map { Self.url($0, withExtensionOf: selectedFormat) }
  }

  static func url(_ url: URL, withExtensionOf format: AnnotateSaveFormat) -> URL {
    if AnnotateSaveFormat(url: url) == format { return url }
    return url.appendingPathExtension(format.fileExtension)
  }

  /// Выбирает формат так же, как пункт меню Format (используется и в тестах).
  func select(_ format: AnnotateSaveFormat) {
    guard formats.contains(format) else { return }
    selectFormatItem(format)
    formatChanged(popUpButton)
  }

  private func selectFormatItem(_ format: AnnotateSaveFormat) {
    if let item = popUpButton.itemArray.first(where: { $0.representedObject as? String == format.rawValue }) {
      popUpButton.select(item)
    }
  }

  @objc private func formatChanged(_ sender: NSPopUpButton) {
    guard let rawValue = sender.selectedItem?.representedObject as? String,
          let format = AnnotateSaveFormat(rawValue: rawValue) else { return }
    selectedFormat = format
    panel.allowedContentTypes = [format.contentType]
  }

  private static var projectHint: String {
    L10n.string(
      "annotate.save-format.project-hint",
      defaultValue: "Select \"OwnShot Project\" if you want to edit the screenshot later, otherwise select other format.",
      comment: "Hint under the Save As format menu"
    )
  }

  /// Раскладка accessory по живому AX эталона (spec-055-live/editor-saveas.txt, лист 370 pt):
  /// подпись Format 57×18 в 49 pt от левого края листа, попап 207×26 в 114 pt, подсказка 272 pt.
  /// AX панели сохранения раздувает каждый контрол на 1 pt с каждой стороны: наш живой замер
  /// (spec-062-live/own-saveas2.txt) показал подпись 59 и подсказку 274 при ширинах 57 и 272.
  /// Поэтому кадры здесь на 1 pt меньше с каждой стороны, чем числа AX эталона.
  enum AccessoryLayout {
    /// Ширина листа эталона. Панель ставит accessory к левому краю листа и не центрирует его
    /// (в прошлой правке контейнер 304 pt дал подпись в 15 pt от края вместо 49), поэтому
    /// контейнер шириной во весь лист, а блок внутри центрирован гибкими полями.
    static let width: CGFloat = 370
    static let leadingInset: CGFloat = 50
    static let labelWidth: CGFloat = 55
    static let popUpLeading: CGFloat = 115
    static let popUpWidth: CGFloat = 205
    static let hintWidth: CGFloat = 270
    static let topInset: CGFloat = 26
    static let hintSpacing: CGFloat = 15
    static let bottomInset: CGFloat = 27
  }

  /// Кадры заданы явно, без NSStackView: в стеке с распределением gravityAreas попап
  /// не тянулся до ширины строки и оставался по содержимому (151 pt в живом AX вместо 207).
  private func makeAccessoryView() -> NSView {
    let label = NSTextField(labelWithString: L10n.string(
      "annotate.save-format.label",
      defaultValue: "Format:",
      comment: "Label before the Save As format menu"
    ))

    hintLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    hintLabel.textColor = .secondaryLabelColor
    hintLabel.preferredMaxLayoutWidth = AccessoryLayout.hintWidth

    let popUpHeight = ceil(popUpButton.intrinsicContentSize.height)
    let labelHeight = ceil(label.intrinsicContentSize.height)
    let hintBounds = NSRect(x: 0, y: 0, width: AccessoryLayout.hintWidth, height: .greatestFiniteMagnitude)
    let hintHeight = ceil(hintLabel.cell?.cellSize(forBounds: hintBounds).height ?? hintLabel.fittingSize.height)
    let height = AccessoryLayout.topInset + popUpHeight + AccessoryLayout.hintSpacing
      + hintHeight + AccessoryLayout.bottomInset

    // Координаты AppKit снизу вверх: подсказка внизу, строка формата над ней.
    let popUpY = AccessoryLayout.bottomInset + hintHeight + AccessoryLayout.hintSpacing
    hintLabel.frame = NSRect(
      x: AccessoryLayout.leadingInset,
      y: AccessoryLayout.bottomInset,
      width: AccessoryLayout.hintWidth,
      height: hintHeight
    )
    popUpButton.frame = NSRect(
      x: AccessoryLayout.popUpLeading,
      y: popUpY,
      width: AccessoryLayout.popUpWidth,
      height: popUpHeight
    )
    label.frame = NSRect(
      x: AccessoryLayout.leadingInset,
      y: popUpY + ((popUpHeight - labelHeight) / 2).rounded(),
      width: AccessoryLayout.labelWidth,
      height: labelHeight
    )

    let container = NSView(frame: NSRect(x: 0, y: 0, width: AccessoryLayout.width, height: height))
    for view in [label, popUpButton, hintLabel] as [NSView] {
      view.translatesAutoresizingMaskIntoConstraints = true
      // Если панель растянет accessory шире листа эталона, блок останется по центру.
      view.autoresizingMask = [.minXMargin, .maxXMargin]
      container.addSubview(view)
    }
    return container
  }

  // MARK: - Дефолты эталона

  /// Имя для Save As: имя исходника без расширения.
  static func baseFileName(for sourceURL: URL?, isCombine: Bool = false, now: Date = Date()) -> String {
    if isCombine {
      let formatter = DateFormatter()
      formatter.dateFormat = "yyyyMMdd-HHmmss"
      return "combined-\(formatter.string(from: now))"
    }
    guard let sourceURL else { return L10n.AnnotateUI.defaultAnnotatedFileName }
    return sourceURL.deletingPathExtension().lastPathComponent
  }

  /// Папка для Save As: папка исходника, если он лежит в файле.
  static func directoryURL(for sourceURL: URL?) -> URL? {
    guard let sourceURL, sourceURL.isFileURL else { return nil }
    return sourceURL.deletingLastPathComponent()
  }
}
