//
//  ShareViewController.swift
//  AnnotateShareExtension
//
//  Share-расширение «Annotate»: передаёт картинку в OwnShot командой ownshot://open-annotate.
//  Своего интерфейса нет, запрос завершается сразу после передачи.
//

import AppKit

final class ShareViewController: NSViewController {
  override var nibName: NSNib.Name? { nil }

  override func loadView() {
    view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    OwnShotShareHandoff.perform(.annotate, context: extensionContext)
  }
}
