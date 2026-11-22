//
//  PreferencesAnnotateSettingsView.swift
//  Snapzy
//
//  Annotate preferences tab for editor behavior settings.
//

import SwiftUI

struct AnnotateSettingsView: View {
  @AppStorage(PreferencesKeys.annotateClipboardImageOpenBehavior)
  private var annotateClipboardImageOpenBehavior = AnnotateClipboardImageBehavior.ask.rawValue
  @AppStorage(PreferencesKeys.annotateDefaultTool)
  private var annotateDefaultTool = AnnotationToolType.selection.rawValue
  @AppStorage(PreferencesKeys.annotateRememberLastTool)
  private var annotateRememberLastTool = false
  @AppStorage(PreferencesKeys.annotateCloseAfterDrag) private var annotateCloseAfterDrag = true
  @AppStorage(PreferencesKeys.annotateBringForwardAfterDrag)
  private var annotateBringForwardAfterDrag = false
  @AppStorage(PreferencesKeys.annotateQuickPropertiesSyncEnabled)
  private var annotateQuickPropertiesSyncEnabled = true
  @AppStorage(PreferencesKeys.annotateCombineSaveAsEdit)
  private var annotateCombineSaveAsEdit = true
  @AppStorage(PreferencesKeys.annotateCropSnapToEdgesEnabled)
  private var annotateCropSnapToEdgesEnabled = true
  @AppStorage(PreferencesKeys.annotateHighlighterTextSnappingEnabled)
  private var annotateHighlighterTextSnappingEnabled = true

  var body: some View {
    Form {
      Section(L10n.PreferencesAnnotate.toolsSection) {
        SettingRow(
          title: L10n.PreferencesAnnotate.defaultToolTitle,
          description: L10n.PreferencesAnnotate.defaultToolDescription
        ) {
          Picker("", selection: $annotateDefaultTool) {
            ForEach(AnnotationToolType.inlineAnnotateTools) { tool in
              Label(tool.displayName, systemImage: tool.icon).tag(tool.rawValue)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .fixedSize()
          .frame(width: 180, alignment: .trailing)
        }
        .disabled(annotateRememberLastTool)
        .opacity(annotateRememberLastTool ? 0.5 : 1)

        SettingRow(
          title: L10n.PreferencesAnnotate.rememberLastToolTitle,
          description: L10n.PreferencesAnnotate.rememberLastToolDescription
        ) {
          PreferencesToggle(L10n.PreferencesAnnotate.rememberLastToolTitle, isOn: $annotateRememberLastTool)
        }

        SettingRow(
          title: L10n.PreferencesAnnotate.quickPropertiesSyncTitle,
          description: L10n.PreferencesAnnotate.quickPropertiesSyncDescription
        ) {
          PreferencesToggle(L10n.PreferencesAnnotate.quickPropertiesSyncTitle, isOn: $annotateQuickPropertiesSyncEnabled)
        }
      }

      Section(L10n.PreferencesAnnotate.drawingSection) {
        SettingRow(
          title: L10n.AnnotateUI.cropSnapToEdges,
          description: L10n.AnnotateUI.cropSnapToEdgesDescription
        ) {
          PreferencesToggle(L10n.AnnotateUI.cropSnapToEdges, isOn: $annotateCropSnapToEdgesEnabled)
        }

        SettingRow(
          title: L10n.AnnotateUI.highlighterTextSnapping,
          description: L10n.AnnotateUI.highlighterTextSnappingDescription
        ) {
          PreferencesToggle(L10n.AnnotateUI.highlighterTextSnapping, isOn: $annotateHighlighterTextSnappingEnabled)
        }
      }

      Section(L10n.PreferencesAnnotate.openSaveSection) {
        SettingRow(
          title: L10n.PreferencesAnnotate.clipboardTitle,
          description: L10n.PreferencesAnnotate.clipboardDescription
        ) {
          Picker("", selection: $annotateClipboardImageOpenBehavior) {
            ForEach(AnnotateClipboardImageBehavior.allCases) { behavior in
              Text(behavior.displayName).tag(behavior.rawValue)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .fixedSize()
          .frame(width: 180, alignment: .trailing)
        }

        SettingRow(
          title: L10n.PreferencesAnnotate.combineSaveAsEditTitle,
          description: L10n.PreferencesAnnotate.combineSaveAsEditDescription
        ) {
          PreferencesToggle(L10n.PreferencesAnnotate.combineSaveAsEditTitle, isOn: $annotateCombineSaveAsEdit)
        }
      }

      Section(L10n.PreferencesAnnotate.dragSection) {
        SettingRow(
          title: L10n.PreferencesAnnotate.closeAfterDragTitle,
          description: L10n.PreferencesAnnotate.closeAfterDragDescription
        ) {
          PreferencesToggle(L10n.PreferencesAnnotate.closeAfterDragTitle, isOn: $annotateCloseAfterDrag)
        }

        SettingRow(
          title: L10n.PreferencesAnnotate.bringForwardAfterDragTitle,
          description: L10n.PreferencesAnnotate.bringForwardAfterDragDescription
        ) {
          PreferencesToggle(L10n.PreferencesAnnotate.bringForwardAfterDragTitle, isOn: $annotateBringForwardAfterDrag)
        }
        .disabled(annotateCloseAfterDrag)
      }
    }
    .formStyle(.grouped)
  }
}

#Preview {
  AnnotateSettingsView()
    .frame(width: 600, height: 550)
}
