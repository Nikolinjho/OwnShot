//
//  SnapzyConfigurationShortcutsExporter.swift
//  Snapzy
//
//  Shortcut TOML export helpers.
//

import Foundation

@MainActor
extension SnapzyConfigurationExporter {
  static func writeShortcuts(_ writer: inout SimpleTOMLWriter) {
    let manager = KeyboardShortcutManager.shared
    writer.section("shortcuts")
    writer.value("enabled", manager.isEnabled)

    for kind in GlobalShortcutKind.allCases {
      writeGlobalShortcut(&writer, kind: kind, manager: manager)
    }

    writeOverlayShortcut(
      &writer,
      section: "shortcuts.overlay.area_application_capture",
      shortcut: CaptureOverlayShortcutSettings.applicationCaptureShortcut
    )
    writeOverlayShortcut(
      &writer,
      section: "shortcuts.overlay.recording_application_capture",
      shortcut: CaptureOverlayShortcutSettings.recordingApplicationCaptureShortcut
    )

    writeQuickAccessShortcut(&writer)
    writeQuickAccessCardActionShortcuts(&writer)
    writeAnnotateToolShortcuts(&writer)
    writeAnnotateActionShortcuts(&writer)
    writeVideoEditorShortcuts(&writer) { VideoEditorShortcutSettings.shared.shortcut(for: $0) }
  }

  static func writeVideoEditorShortcuts(
    _ writer: inout SimpleTOMLWriter,
    shortcut: (VideoEditorShortcutAction) -> ShortcutConfig?
  ) {
    for action in VideoEditorShortcutAction.allCases {
      writer.section("shortcuts.video_editor.\(action.rawValue)")
      guard let binding = shortcut(action) else {
        writer.value("key", "")
        writer.stringArray("modifiers", [])
        continue
      }
      let key = SnapzyConfigurationShortcutCodec.exportKey(binding)
      let modifiers = SnapzyConfigurationShortcutCodec.exportModifiers(binding)
      if SnapzyConfigurationShortcutCodec.shortcut(
        key: key, modifiers: modifiers, requireModifier: false
      ) == binding {
        writer.value("key", key)
      } else {
        writer.value("key_code", Int(binding.keyCode))
      }
      writer.stringArray("modifiers", modifiers)
    }
  }

  private static func writeQuickAccessCardActionShortcuts(_ writer: inout SimpleTOMLWriter) {
    let store = QuickAccessActionShortcutStore.shared
    writer.section("shortcuts.quick_access.card_actions")
    writer.value("enabled", store.isEnabled)

    for action in QuickAccessActionKind.defaultOrder {
      writer.section("shortcuts.quick_access.card_actions.\(action.configKey)")
      writer.value("enabled", store.isEnabled(for: action))
      guard let shortcut = store.shortcut(for: action) else {
        writer.value("key", "")
        writer.stringArray("modifiers", [])
        continue
      }
      writer.value("key", SnapzyConfigurationShortcutCodec.exportKey(shortcut))
      writer.stringArray("modifiers", SnapzyConfigurationShortcutCodec.exportModifiers(shortcut))
    }
  }

  private static func writeQuickAccessShortcut(_ writer: inout SimpleTOMLWriter) {
    let manager = QuickAccessManager.shared
    writer.section("shortcuts.quick_access.edit_latest_capture")
    writer.value("enabled", manager.openEditorShortcutEnabled)
    guard let shortcut = manager.openEditorShortcut else {
      writer.value("key", "")
      writer.stringArray("modifiers", [])
      return
    }
    writer.value("key", SnapzyConfigurationShortcutCodec.exportKey(shortcut))
    writer.stringArray("modifiers", SnapzyConfigurationShortcutCodec.exportModifiers(shortcut))
  }

  private static func writeGlobalShortcut(
    _ writer: inout SimpleTOMLWriter,
    kind: GlobalShortcutKind,
    manager: KeyboardShortcutManager
  ) {
    writer.section("shortcuts.global.\(kind.configKey)")
    writer.value("enabled", manager.isShortcutEnabled(for: kind))

    guard let shortcut = manager.shortcut(for: kind) else {
      writer.value("key", "")
      writer.stringArray("modifiers", [])
      return
    }

    writer.value("key", SnapzyConfigurationShortcutCodec.exportKey(shortcut))
    writer.stringArray("modifiers", SnapzyConfigurationShortcutCodec.exportModifiers(shortcut))
  }

  private static func writeOverlayShortcut(
    _ writer: inout SimpleTOMLWriter,
    section: String,
    shortcut: CaptureOverlayShortcut?
  ) {
    writer.section(section)
    guard let shortcut else {
      writer.value("enabled", false)
      writer.value("key", "")
      writer.stringArray("modifiers", [])
      return
    }

    writer.value("enabled", true)
    let config = ShortcutConfig(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers)
    writer.value("key", SnapzyConfigurationShortcutCodec.exportKey(config))
    writer.stringArray("modifiers", SnapzyConfigurationShortcutCodec.exportModifiers(config))
  }

  private static func writeAnnotateToolShortcuts(_ writer: inout SimpleTOMLWriter) {
    let manager = AnnotateShortcutManager.shared
    writer.section("shortcuts.annotate_tools")
    writer.stringArray(
      "disabled",
      AnnotateShortcutManager.configurableTools
        .filter { !manager.isShortcutEnabled(for: $0) }
        .map(\.rawValue)
        .sorted()
    )
    for tool in AnnotateShortcutManager.configurableTools {
      writer.value(String(tool.rawValue), manager.shortcut(for: tool).map(String.init) ?? "")
    }
  }

  private static func writeAnnotateActionShortcuts(_ writer: inout SimpleTOMLWriter) {
    let manager = AnnotateShortcutManager.shared
    writer.section("shortcuts.annotate_actions")
    writer.stringArray(
      "disabled",
      AnnotateActionShortcutKind.allCases
        .filter { !manager.isActionShortcutEnabled(for: $0) }
        .map(\.rawValue)
        .sorted()
    )

    for kind in AnnotateActionShortcutKind.allCases {
      writer.section("shortcuts.annotate_actions.\(kind.configKey)")
      writer.value("enabled", manager.isActionShortcutEnabled(for: kind))
      guard let shortcut = manager.shortcut(for: kind) else {
        writer.value("key", "")
        writer.stringArray("modifiers", [])
        continue
      }
      writer.value("key", SnapzyConfigurationShortcutCodec.exportKey(shortcut))
      writer.stringArray("modifiers", SnapzyConfigurationShortcutCodec.exportModifiers(shortcut))
    }
  }
}

extension GlobalShortcutKind {
  var configKey: String {
    switch self {
    case .fullscreen: return "fullscreen"
    case .area: return "area"
    case .repeatArea: return "repeat_area"
    case .areaAnnotate: return "area_annotate"
    case .activeWindow: return "active_window"
    case .scrollingCapture: return "scrolling_capture"
    case .recording: return "recording"
    case .pauseResumeRecording: return "pause_resume_recording"
    case .togglePenRecording: return "toggle_pen_recording"
    case .restartRecording: return "restart_recording"
    case .deleteRecording: return "delete_recording"
    case .delayedCapture: return "delayed_capture"
    case .delayedFullscreen: return "delayed_fullscreen"
    case .annotate: return "annotate"
    case .videoEditor: return "video_editor"
    case .cloudUploads: return "cloud_uploads"
    case .shortcutList: return "shortcut_list"
    case .ocr: return "ocr"
    case .smartElement: return "smart_element"
    case .objectCutout: return "object_cutout"
    case .history: return "history"
    case .pickColor: return "pick_color"
    case .toggleDesktopIcons: return "toggle_desktop_icons"
    case .restoreLastCapture: return "restore_last_capture"
    case .areaCopy: return "area_copy"
    case .areaSave: return "area_save"
    case .areaPin: return "area_pin"
    case .measureScreen: return "measure_screen"
    case .ocrWithLineBreaks: return "capture_text_with_line_breaks"
    case .ocrWithoutLineBreaks: return "capture_text_without_line_breaks"
    case .toggleCameraFullscreen: return "toggle_camera_fullscreen"
    case .toggleOverlays: return "toggle_overlays"
    case .saveAllOverlays: return "save_all_overlays"
    case .closeAllOverlays: return "close_all_overlays"
    case .chooseAndPinImage: return "choose_and_pin_image"
    case .togglePinsVisibility: return "toggle_pins_visibility"
    case .closeAllPins: return "close_all_pins"
    case .pinLastScreenshot: return "pin_last_screenshot"
    case .openFile: return "open_file"
    case .openFromClipboard: return "open_from_clipboard"
    case .annotateLastScreenshot: return "annotate_last_screenshot"
    }
  }
}

extension QuickAccessActionKind {
  var configKey: String {
    switch self {
    case .copy: return "copy"
    case .saveOrOpen: return "save_or_open"
    case .dismiss: return "dismiss"
    case .delete: return "delete"
    case .edit: return "edit"
    case .uploadToCloud: return "upload_to_cloud"
    case .pinToScreen: return "pin_to_screen"
    }
  }
}

extension AnnotateActionShortcutKind {
  var configKey: String {
    switch self {
    case .copyAndClose: return "copy_and_close"
    case .toggleSidebar: return "toggle_sidebar"
    case .togglePin: return "toggle_pin"
    case .cloudUpload: return "cloud_upload"
    case .autoRedactSensitiveData: return "auto_redact_sensitive_data"
    case .copyObject: return "copy_object"
    case .duplicateObject: return "duplicate_object"
    case .save: return "save"
    case .saveAs: return "save_as"
    case .print: return "print"
    case .addNewScreenshot: return "add_new_screenshot"
    case .addScreenshotFromFile: return "add_screenshot_from_file"
    case .increaseToolSize: return "increase_tool_size"
    case .decreaseToolSize: return "decrease_tool_size"
    }
  }
}
