//
//  QuickAccessCardChrome.swift
//  Snapzy
//
//  Глифы угловых кнопок и инфо-плашка карточки Quick Access
//

import Foundation

enum QuickAccessCardChrome {
  /// SF Symbols угловых кнопок, где у эталона нет ассета (см. cornerAsset): залитые глифы.
  /// Для видео кнопка редактора показывает ножницы (Trim у ScreenRecordingPopup).
  static func cornerSymbol(
    for action: QuickAccessActionKind,
    isVideo: Bool,
    isPinned: Bool,
    uploadedToCloud: Bool
  ) -> String {
    switch action {
    case .copy: return "doc.on.doc.fill"
    case .saveOrOpen: return "square.and.arrow.down.fill"
    case .dismiss: return "xmark"
    case .delete: return "trash.fill"
    case .edit: return isVideo ? "scissors" : "pencil"
    case .uploadToCloud: return uploadedToCloud ? "checkmark.icloud.fill" : "icloud.and.arrow.up.fill"
    case .pinToScreen: return isPinned ? "pin.slash.fill" : "pin.fill"
    }
  }

  /// Символ и размер угловой кнопки.
  struct CornerAsset: Equatable {
    let resourceName: String
    let size: CGSize
  }

  /// Символы для компактных кнопок. Остальные действия используют системные значки стандартного размера.
  static func cornerAsset(
    for action: QuickAccessActionKind,
    isVideo: Bool,
    isPinned: Bool,
    uploadedToCloud: Bool
  ) -> CornerAsset? {
    switch action {
    case .dismiss: return CornerAsset(resourceName: "popupClose", size: CGSize(width: 6, height: 6))
    case .delete: return CornerAsset(resourceName: "popupTrash", size: CGSize(width: 13, height: 14))
    case .edit:
      return isVideo
        ? CornerAsset(resourceName: "popupTrim", size: CGSize(width: 11, height: 10))
        : CornerAsset(resourceName: "popupAnnotate", size: CGSize(width: 16, height: 16))
    case .pinToScreen:
      return isPinned ? nil : CornerAsset(resourceName: "popupPin", size: CGSize(width: 10, height: 10))
    case .uploadToCloud:
      return uploadedToCloud ? nil : CornerAsset(resourceName: "popupUpload", size: CGSize(width: 12, height: 8))
    case .copy, .saveOrOpen: return nil
    }
  }

  /// Значки инфо-плашки записи: тип файла и признак звука.
  enum InfoBadge: Equatable {
    case gif
    case video
    case sound
  }

  static func isGIF(_ url: URL) -> Bool {
    url.pathExtension.lowercased() == "gif"
  }

  static func infoBadges(isVideo: Bool, url: URL, hasSound: Bool) -> [InfoBadge] {
    guard isVideo else { return [] }
    if isGIF(url) { return [.gif] }
    return hasSound ? [.video, .sound] : [.video]
  }

  /// Quick Look у карточки записи (ScreenRecordingPopup.quickLookButton), у GIF его нет.
  static func showsQuickLookButton(isVideo: Bool, url: URL) -> Bool {
    isVideo && !isGIF(url)
  }
}
