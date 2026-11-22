import AppKit
import Carbon.HIToolbox
import Combine

enum VideoEditorShortcutAction: String, CaseIterable, Identifiable {
  case selectionTool = "selection_tool"
  case cutTool = "cut_tool"
  case splitClip = "split_clip"
  case splitZoom = "split_zoom"
  case deselectAll = "deselect_all"
  case zoomIn = "zoom_in"
  case zoomOut = "zoom_out"
  case fitTimeline = "fit_timeline"
  case toggleFullScreen = "toggle_full_screen"
  case exportVideo = "export_video"
  case exportVideoToCloud = "export_video_to_cloud"
  case exportFrame = "export_frame"
  case previousFrame = "previous_frame"
  case nextFrame = "next_frame"
  case backTenFrames = "back_ten_frames"
  case forwardTenFrames = "forward_ten_frames"
  case previousClipEdge = "previous_clip_edge"
  case nextClipEdge = "next_clip_edge"
  case playheadStart = "playhead_start"
  case playheadEnd = "playhead_end"

  var id: String { rawValue }

  var isAvailable: Bool {
    self != .exportVideoToCloud || OwnShotFeaturePolicy.isAvailable(.cloud)
  }

  var settingsTitle: String {
    let title: String
    switch self {
    case .selectionTool: title = "Selection Tool"
    case .cutTool: title = "Cut Tool"
    case .splitClip: title = "Split Clip at Playhead"
    case .splitZoom: title = "Split Zoom at Playhead"
    case .deselectAll: title = "Deselect All"
    case .zoomIn: title = "Zoom Timeline In"
    case .zoomOut: title = "Zoom Timeline Out"
    case .fitTimeline: title = "Fit Timeline to View"
    case .toggleFullScreen: title = "Toggle Full Screen"
    case .exportVideo: title = "Export Video"
    case .exportVideoToCloud: title = "Export Video & Upload to Cloud"
    case .exportFrame: title = "Export Current Frame as Image"
    case .previousFrame: title = "Move Playhead to Previous Frame"
    case .nextFrame: title = "Move Playhead to Next Frame"
    case .backTenFrames: title = "Move Playhead Back 10 Frames"
    case .forwardTenFrames: title = "Move Playhead Forward 10 Frames"
    case .previousClipEdge: title = "Move Playhead to Previous Clip Edge"
    case .nextClipEdge: title = "Move Playhead to Next Clip Edge"
    case .playheadStart: title = "Move Playhead to Start"
    case .playheadEnd: title = "Move Playhead to End"
    }
    return L10n.string(
      "preferences-shortcuts.video-editor.\(rawValue)",
      defaultValue: title,
      comment: "Command name in the Video Editor shortcut settings"
    )
  }

  var defaultShortcut: ShortcutConfig {
    switch self {
    case .selectionTool: return Self.config(kVK_ANSI_V)
    case .cutTool: return Self.config(kVK_ANSI_B)
    case .splitClip: return Self.config(kVK_ANSI_B, cmdKey)
    case .splitZoom: return Self.config(kVK_ANSI_B, cmdKey | shiftKey)
    case .deselectAll: return Self.config(kVK_ANSI_A, cmdKey | shiftKey)
    case .zoomIn: return Self.config(kVK_ANSI_Equal, cmdKey)
    case .zoomOut: return Self.config(kVK_ANSI_Minus, cmdKey)
    case .fitTimeline: return Self.config(kVK_ANSI_Z, shiftKey)
    case .toggleFullScreen: return Self.config(kVK_ANSI_F, cmdKey)
    case .exportVideo: return Self.config(kVK_ANSI_E, cmdKey)
    case .exportVideoToCloud: return Self.config(kVK_ANSI_U, cmdKey)
    case .exportFrame: return Self.config(kVK_ANSI_E, cmdKey | shiftKey)
    case .previousFrame: return Self.config(kVK_LeftArrow)
    case .nextFrame: return Self.config(kVK_RightArrow)
    case .backTenFrames: return Self.config(kVK_LeftArrow, shiftKey)
    case .forwardTenFrames: return Self.config(kVK_RightArrow, shiftKey)
    case .previousClipEdge: return Self.config(kVK_LeftArrow, optionKey)
    case .nextClipEdge: return Self.config(kVK_RightArrow, optionKey)
    case .playheadStart: return Self.config(kVK_LeftArrow, cmdKey)
    case .playheadEnd: return Self.config(kVK_RightArrow, cmdKey)
    }
  }

  private static func config(_ keyCode: Int, _ modifiers: Int = 0) -> ShortcutConfig {
    ShortcutConfig(keyCode: UInt32(keyCode), modifiers: UInt32(modifiers))
  }
}

@MainActor
final class VideoEditorShortcutSettings: ObservableObject {
  static let shared = VideoEditorShortcutSettings()

  @Published private(set) var shortcuts: [VideoEditorShortcutAction: ShortcutConfig]
  private let defaults: UserDefaults
  private static let defaultsKey = "videoEditor.shortcuts.overrides"
  private static let defaultShortcuts = Dictionary(
    uniqueKeysWithValues: VideoEditorShortcutAction.allCases.map { ($0, $0.defaultShortcut) }
  )

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    var saved = Self.defaultShortcuts
    if let data = defaults.data(forKey: Self.defaultsKey),
       let overrides = try? JSONDecoder().decode([String: ShortcutConfig?].self, from: data) {
      for (key, config) in overrides {
        guard let action = VideoEditorShortcutAction(rawValue: key) else { continue }
        saved[action] = config
      }
    }
    shortcuts = saved
  }

  func shortcut(for action: VideoEditorShortcutAction) -> ShortcutConfig? {
    shortcuts[action]
  }

  var activeShortcuts: [ShortcutConfig] {
    VideoEditorShortcutAction.allCases.compactMap { action in
      action.isAvailable ? shortcuts[action] : nil
    }
  }

  func action(for event: NSEvent) -> VideoEditorShortcutAction? {
    guard event.type == .keyDown else { return nil }
    // AppKit supplies the Fn flag on arrows and function keys even without the
    // modifier being held. The settings recorder drops that flag for single keys.
    let config = ShortcutConfig(
      keyCode: UInt32(event.keyCode),
      modifiers: ShortcutRecordingRules.carbonModifiers(from: event.modifierFlags.subtracting(.function))
    )
    return VideoEditorShortcutAction.allCases.first { $0.isAvailable && shortcuts[$0] == config }
  }

  @discardableResult
  func setShortcut(_ config: ShortcutConfig?, for action: VideoEditorShortcutAction) -> Bool {
    if let config, Self.conflictingActionName(for: config, excluding: action, in: shortcuts) != nil {
      return false
    }

    var updated = shortcuts
    updated[action] = config
    replaceShortcuts(with: updated)
    return true
  }

  func resetToDefaults() {
    replaceShortcuts(with: Self.defaultShortcuts)
  }

  func replaceShortcuts(with replacements: [VideoEditorShortcutAction: ShortcutConfig]) {
    guard shortcuts != replacements else { return }
    var overrides: [String: ShortcutConfig?] = [:]
    for action in VideoEditorShortcutAction.allCases where replacements[action] != action.defaultShortcut {
      overrides.updateValue(replacements[action], forKey: action.rawValue)
    }

    if overrides.isEmpty {
      defaults.removeObject(forKey: Self.defaultsKey)
    } else if let data = try? JSONEncoder().encode(overrides) {
      defaults.set(data, forKey: Self.defaultsKey)
    }
    shortcuts = replacements
  }

  static func conflictingActionName(
    for config: ShortcutConfig,
    excluding action: VideoEditorShortcutAction,
    in assignments: [VideoEditorShortcutAction: ShortcutConfig]
  ) -> String? {
    if let reason = fixedActionName(for: config) { return reason }
    return VideoEditorShortcutAction.allCases.first {
      $0 != action && assignments[$0] == config
    }?.settingsTitle
  }

  private static func fixedTitle(_ key: String, fallback: String) -> String {
    L10n.string(
      "preferences-shortcuts.video-editor.fixed-\(key)",
      defaultValue: fallback,
      comment: "Name of an existing Video Editor shortcut that cannot be reassigned"
    )
  }

  private static func fixedActionName(for config: ShortcutConfig) -> String? {
    let key = Int(config.keyCode)
    let modifiers = Int(config.modifiers)
    switch (key, modifiers) {
    case (kVK_Space, 0): return fixedTitle("play-pause", fallback: "Play/Pause")
    case (kVK_ANSI_Z, 0): return fixedTitle("add-zoom", fallback: "Add Zoom")
    case (kVK_ANSI_I, 0): return fixedTitle("trim-start", fallback: "Set Trim Start")
    case (kVK_ANSI_O, 0): return fixedTitle("trim-end", fallback: "Set Trim End")
    case (kVK_Delete, 0): return fixedTitle("delete-selection", fallback: "Delete Selection")
    case (kVK_ANSI_Z, cmdKey): return L10n.ShortcutOverlay.undo
    case (kVK_ANSI_Z, cmdKey | shiftKey): return L10n.ShortcutOverlay.redo
    case (kVK_Tab, 0), (kVK_Tab, shiftKey): return fixedTitle("move-focus", fallback: "Move Focus")
    default: return nil
    }
  }
}
