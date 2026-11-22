//
//  AnnotatePrintAccessory.swift
//  Snapzy
//
//  Печать Annotate: длинное изображение идёт на несколько страниц, флажок
//  в панели печати вписывает его в одну (CSPrintAccessoryViewController эталона).
//

import AppKit

/// Разбиение на страницы для печати изображения.
nonisolated enum AnnotatePrintPagination {
  /// По ширине изображение всегда вписывается в страницу. По высоте без флажка
  /// продолжается на следующих страницах, с флажком – сжимается до одной.
  static func apply(scalesToFitOnePage: Bool, to printInfo: NSPrintInfo) {
    printInfo.horizontalPagination = .fit
    printInfo.verticalPagination = scalesToFitOnePage ? .fit : .automatic
    printInfo.isHorizontallyCentered = true
    printInfo.isVerticallyCentered = scalesToFitOnePage
  }
}

/// Флажок «Scale image to fit on one page» в системной панели печати.
final class AnnotatePrintAccessoryController: NSViewController, NSPrintPanelAccessorizing {
  /// Выбор держится до конца запуска, как lastPrintInfoSnapshot эталона.
  static var lastScalesToFitOnePage = false

  @objc dynamic var scalesToFitOnePage: Bool {
    didSet {
      Self.lastScalesToFitOnePage = scalesToFitOnePage
      applyPagination()
    }
  }

  private let printInfo: NSPrintInfo
  private var checkbox: NSButton?

  init(printInfo: NSPrintInfo, scalesToFitOnePage: Bool = AnnotatePrintAccessoryController.lastScalesToFitOnePage) {
    self.printInfo = printInfo
    self.scalesToFitOnePage = scalesToFitOnePage
    super.init(nibName: nil, bundle: nil)
    applyPagination()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  static var checkboxTitle: String {
    L10n.string(
      "annotate.print.scale-to-fit-one-page",
      defaultValue: "Scale image to fit on one page",
      comment: "Checkbox in the print panel accessory of the annotate editor"
    )
  }

  static var summaryTitle: String {
    L10n.string(
      "annotate.print.scale-to-fit-summary",
      defaultValue: "Scale to fit on one page",
      comment: "Summary item name for the print panel accessory of the annotate editor"
    )
  }

  override func loadView() {
    let checkbox = NSButton(checkboxWithTitle: Self.checkboxTitle, target: self, action: #selector(toggle(_:)))
    checkbox.state = scalesToFitOnePage ? .on : .off
    checkbox.translatesAutoresizingMaskIntoConstraints = false
    self.checkbox = checkbox

    let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 36))
    container.addSubview(checkbox)
    NSLayoutConstraint.activate([
      checkbox.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
      checkbox.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),
      checkbox.centerYAnchor.constraint(equalTo: container.centerYAnchor),
    ])
    view = container
  }

  @objc private func toggle(_ sender: NSButton) {
    scalesToFitOnePage = sender.state == .on
  }

  /// Панель печати передаёт свой NSPrintInfo в representedObject; до показа – исходный.
  private func applyPagination() {
    AnnotatePrintPagination.apply(scalesToFitOnePage: scalesToFitOnePage,
      to: (representedObject as? NSPrintInfo) ?? printInfo)
  }

  override var representedObject: Any? {
    didSet { applyPagination() }
  }

  // MARK: - NSPrintPanelAccessorizing

  func localizedSummaryItems() -> [[NSPrintPanel.AccessorySummaryKey: String]] {
    [[
      .itemName: Self.summaryTitle,
      .itemDescription: scalesToFitOnePage ? L10n.Common.on : L10n.Common.off,
    ]]
  }

  func keyPathsForValuesAffectingPreview() -> Set<String> {
    [#keyPath(scalesToFitOnePage)]
  }
}
