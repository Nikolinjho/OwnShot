//
//  QuickAccessResizeDialog.swift
//  Snapzy
//
//  Диалог Resize Image из контекстного меню карточки Quick Access:
//  Width/Height, замок пропорций, единицы pixels/percent и предупреждение
//  This operation cannot be undone. Кнопки Cancel и красная Resize.
//

import AppKit

@MainActor
final class QuickAccessResizeDialog: NSObject, NSTextFieldDelegate {
  private var dimensions: QuickAccessResizeDimensions
  private let widthField = NSTextField()
  private let heightField = NSTextField()
  private let linkButton = NSButton()
  private let unitPopup = NSPopUpButton(frame: .zero, pullsDown: false)

  init(originalPixelSize: CGSize) {
    dimensions = QuickAccessResizeDimensions(originalPixelSize: originalPixelSize)
    super.init()
  }

  /// Показывает диалог модально. Возвращает итоговый размер в пикселях или nil при Cancel.
  func runModal() -> CGSize? {
    let alert = NSAlert()
    alert.messageText = L10n.QuickAccessMenu.resizeImageTitle
    alert.alertStyle = .informational
    alert.accessoryView = makeAccessoryView()
    let resizeButton = alert.addButton(withTitle: L10n.QuickAccessMenu.resizeConfirm)
    resizeButton.hasDestructiveAction = true
    alert.addButton(withTitle: L10n.Common.cancel)
    alert.window.initialFirstResponder = widthField

    NSApp.activate(ignoringOtherApps: true)
    let response = alert.runModal()
    guard response == .alertFirstButtonReturn else { return nil }
    commitEditing()
    return dimensions.isUnchanged ? nil : dimensions.targetPixelSize
  }

  // MARK: - Layout

  private func makeAccessoryView() -> NSView {
    let widthLabel = NSTextField(labelWithString: L10n.QuickAccessMenu.resizeWidth)
    let heightLabel = NSTextField(labelWithString: L10n.QuickAccessMenu.resizeHeight)
    [widthLabel, heightLabel].forEach { $0.alignment = .right }

    for field in [widthField, heightField] {
      field.alignment = .center
      field.delegate = self
      field.translatesAutoresizingMaskIntoConstraints = false
      field.widthAnchor.constraint(equalToConstant: 96).isActive = true
    }

    linkButton.bezelStyle = .regularSquare
    linkButton.isBordered = false
    linkButton.setButtonType(.toggle)
    linkButton.target = self
    linkButton.action = #selector(toggleLink)
    linkButton.toolTip = L10n.QuickAccessMenu.resizeKeepProportions
    linkButton.translatesAutoresizingMaskIntoConstraints = false
    // Скобка с замком resizeLock эталона, 23×33 pt (ANResizeControlViewController).
    linkButton.imageScaling = .scaleNone
    linkButton.widthAnchor.constraint(equalToConstant: 23).isActive = true
    linkButton.heightAnchor.constraint(equalToConstant: 33).isActive = true

    unitPopup.addItems(withTitles: [L10n.QuickAccessMenu.resizePixels, L10n.QuickAccessMenu.resizePercent])
    unitPopup.target = self
    unitPopup.action = #selector(unitChanged)

    let grid = NSGridView(views: [
      [widthLabel, widthField],
      [heightLabel, heightField],
    ])
    grid.rowSpacing = 8
    grid.columnSpacing = 8

    let fieldsRow = NSStackView(views: [grid, linkButton, unitPopup])
    fieldsRow.orientation = .horizontal
    fieldsRow.alignment = .centerY
    fieldsRow.spacing = 10

    let note = NSTextField(labelWithString: L10n.QuickAccessMenu.resizeCannotUndo)
    note.textColor = .secondaryLabelColor
    note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

    let stack = NSStackView(views: [fieldsRow, note])
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 14
    stack.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
    stack.frame = NSRect(origin: .zero, size: stack.fittingSize)

    refreshFields()
    return stack
  }

  private func refreshFields() {
    widthField.stringValue = Self.format(dimensions.width)
    heightField.stringValue = Self.format(dimensions.height)
    linkButton.state = dimensions.isLinked ? .on : .off
    linkButton.image = OwnShotSymbols.nsImage(dimensions.isLinked ? "resizeLock" : "resizeLockOpen")
    linkButton.setAccessibilityLabel(L10n.QuickAccessMenu.resizeKeepProportions)
    unitPopup.selectItem(at: dimensions.unit == .pixels ? 0 : 1)
  }

  private static func format(_ value: Double) -> String {
    value.rounded() == value ? String(Int(value)) : String(format: "%.2f", value)
  }

  private static func parse(_ text: String) -> Double? {
    Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
  }

  // MARK: - Actions

  @objc private func toggleLink() {
    dimensions.isLinked.toggle()
    if dimensions.isLinked {
      dimensions.setWidth(dimensions.width)
    }
    refreshFields()
  }

  @objc private func unitChanged() {
    commitEditing()
    dimensions.setUnit(unitPopup.indexOfSelectedItem == 1 ? .percent : .pixels)
    refreshFields()
  }

  private func commitEditing() {
    if let width = Self.parse(widthField.stringValue), Self.format(width) != Self.format(dimensions.width) {
      dimensions.setWidth(width)
    } else if let height = Self.parse(heightField.stringValue), Self.format(height) != Self.format(dimensions.height) {
      dimensions.setHeight(height)
    }
  }

  func controlTextDidEndEditing(_ obj: Notification) {
    guard let field = obj.object as? NSTextField else { return }
    if field === widthField, let value = Self.parse(field.stringValue) {
      dimensions.setWidth(value)
    } else if field === heightField, let value = Self.parse(field.stringValue) {
      dimensions.setHeight(value)
    }
    refreshFields()
  }
}
