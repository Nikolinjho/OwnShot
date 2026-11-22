//
//  QuickAccessCardMenuLayout.swift
//  Snapzy
//
//  Состав и порядок контекстного меню карточки Quick Access, как в CleanShot X.
//

import Foundation

/// Пункт контекстного меню карточки. Порядок case совпадает с эталоном.
enum QuickAccessCardMenuCommand: String, CaseIterable, Hashable {
  case openAnnotation
  case pinToScreen
  case extractText
  case rotateLeft
  case flipHorizontal
  case resize
  /// Scale Retina to 1x: только у Retina-снимков (menuItemScaleRetina эталона)
  case scaleRetina
  /// Send To Raycast AI Chat...: у эталона только при установленном Raycast,
  /// в OwnShot – заглушка без отправки.
  case sendToRaycastAIChat
  case uploadToCloud
  case quickLook
  case print
  case saveAs
  case openWith
  case openInMail
  case moveToTrash
  case showInFinder
  case share
  case temporarilyHide
  case close

  /// Команды, которые работают только с картинкой.
  var requiresImage: Bool {
    switch self {
    case .pinToScreen, .extractText, .rotateLeft, .flipHorizontal, .resize, .scaleRetina, .sendToRaycastAIChat, .print:
      return true
    default:
      return false
    }
  }
}

enum QuickAccessCardMenuLayout {
  /// Группы эталона, между группами стоит разделитель.
  /// Шаг 35pt вместо 24pt в AX-снимке CleanShot отмечает границы групп.
  static let referenceGroups: [[QuickAccessCardMenuCommand]] = [
    [.openAnnotation, .pinToScreen, .extractText],
    [.rotateLeft, .flipHorizontal, .resize],
    [.uploadToCloud, .quickLook, .print, .saveAs],
    [.openWith, .openInMail],
    [.moveToTrash, .showInFinder],
    [.share],
    [.temporarilyHide, .close],
  ]

  /// Группы для конкретной карточки: у видео нет операций над картинкой,
  /// без облака нет Upload to Cloud. Пустые группы выпадают.
  static func groups(
    isVideo: Bool,
    includesCloud: Bool,
    isRetina: Bool = false,
    includesRaycast: Bool = false
  ) -> [[QuickAccessCardMenuCommand]] {
    referenceGroups
      .map { group in
        // Scale Retina to 1x встаёт за Resize... только у Retina-снимка
        guard isRetina, let index = group.firstIndex(of: .resize) else { return group }
        var extended = group
        extended.insert(.scaleRetina, at: index + 1)
        return extended
      }
      .map { group in
        // Send To Raycast AI Chat... в строках эталона идёт за Scale Retina to 1x
        guard includesRaycast, group.contains(.resize) else { return group }
        return group + [.sendToRaycastAIChat]
      }
      .map { group in
        group.filter { command in
          if isVideo && command.requiresImage { return false }
          if !includesCloud && command == .uploadToCloud { return false }
          return true
        }
      }
      .filter { !$0.isEmpty }
  }
}
