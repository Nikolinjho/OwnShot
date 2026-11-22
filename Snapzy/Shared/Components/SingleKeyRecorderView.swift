//
//  SingleKeyRecorderView.swift
//  Snapzy
//
//  SwiftUI view for recording single-key shortcuts (no modifiers)
//

import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A single context badge for annotation tool availability
struct AnnotationToolBadge: Hashable {
  let label: String
  let color: Color

  func hash(into hasher: inout Hasher) { hasher.combine(label) }
  static func == (lhs: Self, rhs: Self) -> Bool { lhs.label == rhs.label }
}

/// Context where an annotation tool is available
enum AnnotationToolContext {
  case screenshotOnly
  case recordingOnly
  case both

  var badges: [AnnotationToolBadge] {
    switch self {
    case .screenshotOnly:
      return [AnnotationToolBadge(label: L10n.CaptureKind.screenshot, color: .blue)]
    case .recordingOnly:
      return [AnnotationToolBadge(label: L10n.CaptureKind.recording, color: .orange)]
    case .both:
      return [
        AnnotationToolBadge(label: L10n.CaptureKind.screenshot, color: .blue),
        AnnotationToolBadge(label: L10n.CaptureKind.recording, color: .orange),
      ]
    }
  }
}

/// View for recording single-key shortcuts
struct SingleKeyRecorderView: View {
  let tool: AnnotationToolType
  @Binding var shortcut: Character?
  @Binding var isEnabled: Bool
  let validationIssue: ShortcutValidationIssue?
  let onChanged: (Character?) -> Bool
  let conflictingTool: AnnotationToolType?
  var context: AnnotationToolContext = .both
  var defaultShortcut: Character? = nil
  /// Swaps keys with the tool that owns the rejected key (see `ShortcutSwapProposal`).
  var onSwap: (() -> Void)? = nil
  /// Название строки; по умолчанию имя инструмента.
  var title: String? = nil

  @Environment(\.ownShotWideShortcutRecorder) private var wideRecorder
  @StateObject private var recorder = ShortcutRecordingController()

  var body: some View {
    HStack(spacing: 12) {
      // Title and availability badges share one line so the row matches `SettingRow` height.
      HStack(spacing: 6) {
        Text(title ?? tool.displayName)
        HStack(spacing: 4) {
          ForEach(context.badges, id: \.label) { badge in
            Text(badge.label)
              .font(.system(size: 9, weight: .medium))
              .foregroundColor(badge.color)
              .padding(.horizontal, 5)
              .padding(.vertical, 1)
              .background(
                Capsule().fill(badge.color.opacity(0.15))
              )
          }
        }
      }

      Spacer()

      // Conflict warning
      if isEnabled, validationIssue == nil, let conflict = conflictingTool {
        Label(L10n.ShortcutRecorder.usedBy(conflict.displayName), systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundColor(.orange)
      }

      HStack(spacing: 6) {
      Button {
        startRecording()
      } label: {
        Group {
          if recorder.isRecording {
            KeyCapRecordingView(minWidth: 72)
          } else if wideRecorder {
            // Поле эталона, как у остальных строк Settings › Shortcuts.
            ShortcutFieldView(shortcut: shortcut.map { String($0).uppercased() })
          } else if let key = shortcut {
            KeyCapView(symbol: String(key).uppercased())
          } else {
            KeyCapPlaceholderView(title: L10n.PreferencesShortcuts.setKey, minWidth: 72)
          }
        }
        .frame(
          width: wideRecorder ? ShortcutFieldView.size.width : nil,
          height: wideRecorder ? ShortcutFieldView.size.height : nil
        )
      }
      .buttonStyle(ShortcutButtonStyle(isRecording: recorder.isRecording))
      .shortcutValidationHighlight(issue: validationIssue, onSwap: onSwap)
      .disabled(!isEnabled)
      .help(isEnabled ? L10n.ShortcutRecorder.clickToRecord : L10n.ShortcutRecorder.turnOnToEdit)

        if recorder.isRecording {
          ShortcutRecordingAuxButtons(
            canUseOld: true,
            canReset: defaultShortcut != nil && shortcut != defaultShortcut,
            onUseOld: { recorder.stop() },
            onReset: {
              recorder.stop()
              resetToDefault()
            }
          )
        }
      }
      .background(ShortcutRecorderAnchor(controller: recorder))
      .settingsRowHeight(wideRecorder ? SettingsRowMetrics.shortcutRecorderHeight : .infinity)

      // В Settings эталона шестерёнки нет: её действия – в контекстном меню строки.
      if !wideRecorder {
        ShortcutOptionsMenuButton(
          isEnabled: $isEnabled,
          isDefault: shortcut == defaultShortcut,
          isBusy: recorder.isRecording,
          onReset: resetToDefault
        )
      }
    }
    .contentShape(Rectangle())
    .contextMenu {
      if wideRecorder {
        ShortcutOptionsMenuItems(
          isEnabled: $isEnabled,
          isDefault: shortcut == defaultShortcut,
          onReset: resetToDefault
        )
        .disabled(recorder.isRecording)
      }
    }
    .opacity(isEnabled ? 1 : 0.62)
    .onChange(of: isEnabled) { newValue in
      if !newValue {
        recorder.stop()
      }
    }
    .onDisappear { recorder.stop() }
  }

  private func resetToDefault() {
    if onChanged(defaultShortcut) {
      shortcut = defaultShortcut
    }
  }

  private func startRecording() {
    guard isEnabled else { return }
    recorder.start { [recorder] event in
      // Escape и Delete — по общим правилам рекордера.
      switch ShortcutRecordingRules.decision(keyCode: event.keyCode, modifiers: event.modifierFlags, allowsSingleKey: false) {
      case .cancel:
        recorder.stop()
        return
      case .clear:
        _ = onChanged(nil)
        recorder.stop()
        return
      case .record, .ignore:
        break
      }

      // Get character (lowercase for consistency)
      if let char = event.charactersIgnoringModifiers?.lowercased().first,
         char.isLetter || char.isNumber || char.isPunctuation || char.isSymbol {
        _ = onChanged(char)
        recorder.stop()
      }
    }
  }
}
