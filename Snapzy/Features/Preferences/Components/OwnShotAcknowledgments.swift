import AppKit
import SwiftUI

/// Строка в разделе Links на вкладке About.
struct OwnShotAboutLink: Identifiable, Equatable {
  let id: String
  let title: String
  let systemImage: String
  /// nil – строка видна как у эталона, но выключена: своего адреса у OwnShot нет.
  let url: URL?

  var isEnabled: Bool { url != nil }

  /// Корень репозитория OwnShot, вычисленный из пути этого файла при сборке.
  /// Если исходников на этом Mac нет, ссылки выключаются.
  static func repositoryRoot(
    sourceFile: String = #filePath,
    fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
  ) -> URL? {
    // Snapzy/Features/Preferences/Components/<файл> – пять уровней до корня.
    var root = URL(fileURLWithPath: sourceFile)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    guard fileExists(root.appendingPathComponent("Snapzy.xcodeproj").path) else { return nil }
    return root
  }

  /// Пять ссылок эталона в его порядке. Website ведёт в репозиторий OwnShot,
  /// Changelog – в состояние реализации в docs/. Своей почты, Twitter / X
  /// и YouTube у личной сборки нет, эти строки выключены.
  static func makeAll(repositoryRoot root: URL? = repositoryRoot()) -> [OwnShotAboutLink] {
    [
      OwnShotAboutLink(
        id: "website",
        title: L10n.PersonalBuildStubs.websiteLink,
        systemImage: "globe",
        url: root
      ),
      OwnShotAboutLink(
        id: "changelog",
        title: L10n.PersonalBuildStubs.changelogLink,
        systemImage: "sparkles",
        url: root?.appendingPathComponent("docs/implementation-status.md")
      ),
      OwnShotAboutLink(id: "contact", title: L10n.PersonalBuildStubs.contactLink, systemImage: "envelope", url: nil),
      OwnShotAboutLink(id: "twitter", title: L10n.PersonalBuildStubs.twitterLink, systemImage: "bird", url: nil),
      OwnShotAboutLink(id: "youtube", title: L10n.PersonalBuildStubs.youtubeLink, systemImage: "play.rectangle", url: nil),
    ]
  }

  static let all: [OwnShotAboutLink] = makeAll()
}

/// Текст окна Acknowledgments: лицензия Snapzy и сторонние пакеты OwnShot.
enum OwnShotAcknowledgments {
  struct Package: Equatable {
    let name: String
    let copyright: String
    let license: String
    let url: String
  }

  /// Копирайт одной строкой в шапке About, как у эталона. Уведомление Snapzy
  /// (BSD 3-Clause) живёт в тексте этого окна, см. `snapzyLicense`.
  static let aboutCopyrightLine = "© 2026 Nikita Pyanov."

  /// Пакеты из Package.resolved приложения.
  static let packages: [Package] = [
    Package(name: "GRDB.swift", copyright: "Copyright (c) Gwendal Roué", license: "MIT License", url: "https://github.com/groue/GRDB.swift"),
    Package(name: "libwebp", copyright: "Copyright (c) Google Inc.", license: "BSD 3-Clause License", url: "https://chromium.googlesource.com/webm/libwebp"),
    Package(name: "Sparkle", copyright: "Copyright (c) Sparkle Project contributors", license: "MIT License", url: "https://github.com/sparkle-project/Sparkle"),
    Package(name: "Swift Argument Parser", copyright: "Copyright (c) Apple Inc. and the Swift project authors", license: "Apache License 2.0", url: "https://github.com/apple/swift-argument-parser"),
    Package(name: "Swift-WebP", copyright: "Copyright (c) Satoshi Namai", license: "MIT License", url: "https://github.com/ainame/Swift-WebP"),
  ]

  static let snapzyLicense = """
  Snapzy
  Copyright (c) 2026, Trong Duong Duc

  Redistribution and use in source and binary forms, with or without
  modification, are permitted provided that the following conditions are met:

  1. Redistributions of source code must retain the above copyright notice, this
     list of conditions and the following disclaimer.

  2. Redistributions in binary form must reproduce the above copyright notice,
     this list of conditions and the following disclaimer in the documentation
     and/or other materials provided with the distribution.

  3. Neither the name of the copyright holder nor the names of its
     contributors may be used to endorse or promote products derived from
     this software without specific prior written permission.

  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
  AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
  IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
  DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
  FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
  DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
  SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
  CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
  OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
  OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
  """

  /// Полный текст окна. Первая фраза повторяет вступление эталона.
  static var text: String {
    let packagesText = packages.map { package in
      "\(package.name)\n\(package.copyright)\n\(package.license) – \(package.url)"
    }.joined(separator: "\n\n")
    return """
    Portions of this software utilize the following copyrighted material, the use of which is hereby acknowledged:

    \(snapzyLicense)


    \(packagesText)
    """
  }
}

extension OwnShotAcknowledgments {
  /// Текст со ссылками: адреса пакетов кликабельны.
  static func attributedText() -> NSAttributedString {
    let result = NSMutableAttributedString(
      string: text,
      attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.textColor]
    )
    let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    let range = NSRange(location: 0, length: result.length)
    detector?.enumerateMatches(in: text, range: range) { match, _, _ in
      guard let match, let url = match.url else { return }
      result.addAttribute(.link, value: url, range: match.range)
    }
    return result
  }
}

/// Отдельное окно Acknowledgments с прокручиваемым выделяемым текстом.
@MainActor
final class OwnShotAcknowledgmentsWindowController {
  static let shared = OwnShotAcknowledgmentsWindowController()

  private var window: NSWindow?

  /// Окно эталона: без изменения размера, рамка 750×420, контент из NIB 750×388.
  static let frameSize = NSSize(width: 750, height: 420)
  static let contentSize = NSSize(width: 750, height: 388)

  private init() {}

  func show() {
    let window = self.window ?? makeWindow()
    self.window = window
    if !window.isVisible { window.center() }
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
  }

  private func makeWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: Self.contentSize),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: true
    )
    window.title = "Acknowledgments"
    window.isReleasedWhenClosed = false
    // Полная рамка эталона 750×420 pt: контент 750×388 под заголовком.
    window.setFrame(NSRect(origin: window.frame.origin, size: Self.frameSize), display: false)

    let scrollView = NSTextView.scrollableTextView()
    scrollView.hasVerticalScroller = true
    if let textView = scrollView.documentView as? NSTextView {
      textView.isEditable = false
      textView.isSelectable = true
      textView.textContainerInset = NSSize(width: 12, height: 12)
      textView.textStorage?.setAttributedString(OwnShotAcknowledgments.attributedText())
    }
    window.contentView = scrollView
    return window
  }
}
