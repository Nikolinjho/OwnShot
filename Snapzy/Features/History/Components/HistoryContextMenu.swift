//
//  HistoryContextMenu.swift
//  Snapzy
//
//  Context menu for history items
//

import SwiftUI

struct HistoryContextMenu: View {
  let record: CaptureHistoryRecord
  @ObservedObject private var manager = HistoryFloatingManager.shared

  /// Состав и порядок эталона: Open Annotation Tool..., Pin to the Screen, Quick Look,
  /// Copy, Restore, Delete. Upload to Cloud – дополнение OwnShot перед Delete.
  var body: some View {
    Button(record.captureType == .screenshot ? L10n.QuickAccessMenu.openAnnotationTool : L10n.QuickAccess.editVideo) {
      HistoryWindowController.shared.openItem(record)
    }
    .keyboardShortcut("e", modifiers: .command)

    if record.captureType == .screenshot {
      Button(L10n.QuickAccessMenu.pinToTheScreen) {
        HistoryWindowController.shared.pinItem(record)
      }
    }

    Button(L10n.QuickAccessMenu.quickLook) {
      HistoryWindowController.shared.toggleQuickLook(record)
    }
    .keyboardShortcut(.space, modifiers: [])

    Divider()

    Button(L10n.Common.copy) {
      HistoryWindowController.shared.copyToClipboard([record])
    }
    .keyboardShortcut("c", modifiers: .command)

    Button(L10n.Common.restore) {
      HistoryWindowController.shared.restoreItem(record, hidesHistory: false)
    }
    .keyboardShortcut(.return, modifiers: [])

    if !OwnShotFeaturePolicy.isAvailable(.cloud) || CloudManager.shared.isConfigured {
      Button {
        manager.uploadToCloud(record)
      } label: {
        Label(uploadMenuTitle, systemImage: uploadMenuIcon)
      }
      .disabled(manager.cloudUploadState(for: record) != nil)
    }

    Divider()

    Button(L10n.Common.delete) {
      // Меню закрывается раньше модального подтверждения.
      DispatchQueue.main.async {
        HistoryWindowController.shared.deleteRecordsConfirmingIfNeeded([record])
      }
    }
    .keyboardShortcut(.delete, modifiers: [])
  }

  private var uploadMenuTitle: String {
    switch manager.cloudUploadState(for: record) {
    case .uploading:
      return L10n.PreferencesHistory.uploadingToCloud
    case .completed:
      return L10n.PreferencesHistory.uploadedToCloud
    case nil:
      return L10n.PreferencesHistory.uploadToCloud
    }
  }

  private var uploadMenuIcon: String {
    switch manager.cloudUploadState(for: record) {
    case .uploading:
      return "icloud.and.arrow.up"
    case .completed:
      return "checkmark.icloud"
    case nil:
      return "icloud.and.arrow.up"
    }
  }
}

struct HistoryCloudUploadOverlayView: View {
  let state: HistoryCloudUploadState
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ZStack {
      Rectangle()
        .fill(Color.black.opacity(0.52))

      VStack(spacing: 8) {
        icon

        Text(title)
          .font(.system(size: 11, weight: .semibold))
          .foregroundColor(.white)
          .lineLimit(1)
          .minimumScaleFactor(0.85)
      }
      .padding(.horizontal, 10)
    }
    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
  }

  @ViewBuilder
  private var icon: some View {
    switch state {
    case .uploading:
      ProgressView()
        .progressViewStyle(.circular)
        .controlSize(.small)
        .tint(.white)
    case .completed:
      Image(systemName: "checkmark.circle.fill")
        .font(.system(size: 26, weight: .semibold))
        .foregroundStyle(.white, Color.green)
    }
  }

  private var title: String {
    switch state {
    case .uploading:
      return L10n.PreferencesHistory.uploadingToCloud
    case .completed:
      return L10n.PreferencesHistory.uploadedToCloud
    }
  }
}
