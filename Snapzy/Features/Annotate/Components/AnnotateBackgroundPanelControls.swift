//
//  AnnotateBackgroundPanelControls.swift
//  Snapzy
//
//  Сетки фиксированного размера и меню Presets... панели Background
//

import AppKit
import SwiftUI

/// Колонки сеток панели Background: ячейки фиксированного размера, как у эталона,
/// без растягивания на ширину сайдбара.
enum AnnotateBackgroundTileGrid {
  /// Gradients, Wallpapers, Blurred: 5 колонок по 43 pt.
  static var columns: [GridItem] {
    Array(
      repeating: GridItem(.fixed(AnnotateBackgroundPanelLayout.tileSize), spacing: AnnotateBackgroundPanelLayout.tileSpacing),
      count: AnnotateBackgroundPanelLayout.tileColumns
    )
  }

  /// Plain color: 9 колонок по 24 pt.
  static var colorColumns: [GridItem] {
    Array(
      repeating: GridItem(.fixed(AnnotateBackgroundPanelLayout.colorSwatchSize), spacing: AnnotateBackgroundPanelLayout.colorSpacing),
      count: AnnotateBackgroundPanelLayout.colorColumns
    )
  }
}

/// Меню Presets... эталона: список пресетов, подменю Default Preset, разделитель, Add New Preset...
@MainActor
final class AnnotateBackgroundPresetMenuController: NSObject {
  struct Configuration {
    var presets: [(id: UUID, name: String)] = []
    var selectedId: UUID?
    var defaultId: UUID?
    var canAddPreset = true
    var onSelect: (UUID) -> Void = { _ in }
    var onSetDefault: (UUID?) -> Void = { _ in }
    var onAdd: () -> Void = {}
  }

  var configuration = Configuration()
  var isTracking = false

  func makeMenu() -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false

    let presetEntries = AnnotateBackgroundPresetMenu.presetEntries(
      presets: configuration.presets,
      selectedId: configuration.selectedId
    )
    for entry in presetEntries {
      let item = NSMenuItem(title: entry.title, action: #selector(selectPreset(_:)), keyEquivalent: "")
      item.target = self
      item.state = entry.isChecked ? .on : .off
      item.representedObject = entry.presetId
      menu.addItem(item)
    }

    let defaultItem = NSMenuItem(title: AnnotateBackgroundPanelStrings.defaultPreset, action: nil, keyEquivalent: "")
    defaultItem.submenu = makeDefaultPresetMenu()
    menu.addItem(defaultItem)

    menu.addItem(.separator())

    let addItem = NSMenuItem(
      title: AnnotateBackgroundPanelStrings.addNewPresetMenuItem,
      action: #selector(addPreset(_:)),
      keyEquivalent: ""
    )
    addItem.target = self
    addItem.isEnabled = configuration.canAddPreset
    menu.addItem(addItem)
    return menu
  }

  private func makeDefaultPresetMenu() -> NSMenu {
    let menu = NSMenu(title: AnnotateBackgroundPanelStrings.defaultPreset)
    menu.autoenablesItems = false

    let header = NSMenuItem(title: AnnotateBackgroundPanelStrings.autoApplyPresetHeader, action: nil, keyEquivalent: "")
    header.isEnabled = false
    menu.addItem(header)
    menu.addItem(.separator())

    let entries = AnnotateBackgroundPresetMenu.defaultPresetEntries(
      presets: configuration.presets,
      defaultId: configuration.defaultId,
      noneTitle: L10n.Common.none
    )
    for entry in entries {
      let item = NSMenuItem(title: entry.title, action: #selector(setDefaultPreset(_:)), keyEquivalent: "")
      item.target = self
      item.state = entry.isChecked ? .on : .off
      item.representedObject = entry.presetId
      menu.addItem(item)
    }
    return menu
  }

  @objc private func selectPreset(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? UUID else { return }
    configuration.onSelect(id)
  }

  @objc private func setDefaultPreset(_ sender: NSMenuItem) {
    configuration.onSetDefault(sender.representedObject as? UUID)
  }

  @objc private func addPreset(_ sender: NSMenuItem) {
    configuration.onAdd()
  }
}

/// Невидимый якорь: раскрывает меню Presets... под контролом.
struct AnnotateBackgroundPresetMenuAnchor: NSViewRepresentable {
  @Binding var isPresented: Bool
  let configuration: AnnotateBackgroundPresetMenuController.Configuration

  func makeCoordinator() -> AnnotateBackgroundPresetMenuController {
    AnnotateBackgroundPresetMenuController()
  }

  func makeNSView(context: Context) -> NSView { MenuAnchorView() }

  func updateNSView(_ view: NSView, context: Context) {
    let coordinator = context.coordinator
    coordinator.configuration = configuration
    guard isPresented, !coordinator.isTracking else { return }
    coordinator.isTracking = true
    DispatchQueue.main.async {
      defer {
        coordinator.isTracking = false
        isPresented = false
      }
      guard isPresented, view.window != nil else { return }
      let menu = coordinator.makeMenu()
      let y = view.isFlipped ? view.bounds.maxY + 4 : view.bounds.minY - 4
      menu.popUp(positioning: nil, at: NSPoint(x: 0, y: y), in: view)
    }
  }

  private final class MenuAnchorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  }
}
