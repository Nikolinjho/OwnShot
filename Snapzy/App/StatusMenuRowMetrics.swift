//
//  StatusMenuRowMetrics.swift
//  Snapzy
//
//  Высота строк меню в строке меню. У эталона строки с иконкой 30 pt (шаг 60 px на снимке 2×,
//  spec-051 status-menu.png), строки без иконки (About, Check for Updates) обычные.
//  Своя view у NSMenuItem отключила бы системную подсветку, а высокая картинка
//  в приложении на SDK 27 строку не растягивает. Растёт строка от высоты строки текста:
//  NSMenu делает пункт на 6 pt выше строки заголовка (замер на macOS 27).
//

import AppKit

enum StatusMenuRowMetrics {
  static let iconRowHeight: CGFloat = 30
  /// Высота строки заголовка, при которой системный пункт выходит 30 pt.
  static let titleLineHeight: CGFloat = 24

  /// Заголовок с фиксированной высотой строки. Цвет не задаётся: подсветку
  /// и серый цвет выключенного пункта рисует NSMenu, как у обычного пункта.
  static func tallTitle(_ title: String, font: NSFont = .menuFont(ofSize: 0)) -> NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.minimumLineHeight = titleLineHeight
    paragraph.maximumLineHeight = titleLineHeight
    // Лишняя высота строки уходит над текстом, сдвиг возвращает его в центр пункта.
    let natural = NSLayoutManager().defaultLineHeight(for: font)
    return NSAttributedString(string: title, attributes: [
      .font: font,
      .paragraphStyle: paragraph,
      .baselineOffset: max(0, (titleLineHeight - natural) / 2),
    ])
  }

  /// Растягивает строки с иконкой во всём меню, включая подменю.
  static func applyIconRowHeight(to menu: NSMenu) {
    for item in menu.items {
      if item.image != nil, !item.isSeparatorItem, item.view == nil {
        item.attributedTitle = tallTitle(item.title)
      }
      if let submenu = item.submenu {
        applyIconRowHeight(to: submenu)
      }
    }
  }
}
