//
//  OwnShotPersonalBuildStubsTests.swift
//  SnapzyTests
//
//  UI-заглушки личной сборки: флаг Analytics, ссылки About и Raycast AI Chat
//  выглядят как у эталона и не делают сетевых вызовов.
//

import AppKit
import XCTest
@testable import Snapzy

@MainActor
final class OwnShotPersonalBuildStubsTests: XCTestCase {
  private var defaults: UserDefaults!
  private var suiteName: String!

  override func setUp() {
    super.setUp()
    suiteName = "OwnShotPersonalBuildStubsTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
    NetworkRecorder.reset()
    URLProtocol.registerClass(NetworkRecorder.self)
  }

  override func tearDown() {
    URLProtocol.unregisterClass(NetworkRecorder.self)
    defaults.removePersistentDomain(forName: suiteName)
    defaults = nil
    super.tearDown()
  }

  // MARK: - Analytics

  func testUsageStatistics_поУмолчаниюВыключеноКакУЭталона() {
    XCTAssertEqual(OwnShotUsageStatistics.defaultsKey, "analyticsAllowed")
    XCTAssertFalse(OwnShotUsageStatistics.isAllowed(in: defaults))
  }

  func testUsageStatistics_флагСохраняетсяЛокально() {
    OwnShotUsageStatistics.setAllowed(true, in: defaults)
    XCTAssertTrue(OwnShotUsageStatistics.isAllowed(in: defaults))
    XCTAssertTrue(defaults.bool(forKey: "analyticsAllowed"))

    OwnShotUsageStatistics.setAllowed(false, in: defaults)
    XCTAssertFalse(OwnShotUsageStatistics.isAllowed(in: defaults))
  }

  func testUsageStatistics_строкиAboutСовпадаютСЭталоном() {
    XCTAssertEqual(L10n.PersonalBuildStubs.analyticsTitle, "Analytics")
    XCTAssertEqual(L10n.PersonalBuildStubs.shareUsageStatistics, "Share my usage statistics")
    XCTAssertTrue(L10n.PersonalBuildStubs.analyticsHint.contains("does not collect usage statistics"))
  }

  // MARK: - Ссылки About

  func testAboutLinks_пятьСтрокЭталонаВЕгоПорядке() {
    let root = URL(fileURLWithPath: "/tmp/OwnShot")
    let links = OwnShotAboutLink.makeAll(repositoryRoot: root)
    XCTAssertEqual(links.map(\.title), ["Website", "Changelog", "Contact Us", "Twitter / X", "YouTube"])
  }

  func testAboutLinks_ведутТолькоВРепозиторийИDocsOwnShot() {
    let root = URL(fileURLWithPath: "/tmp/OwnShot")
    let links = OwnShotAboutLink.makeAll(repositoryRoot: root)
    let byID = Dictionary(uniqueKeysWithValues: links.map { ($0.id, $0) })

    XCTAssertEqual(byID["website"]?.url, root)
    XCTAssertEqual(byID["changelog"]?.url?.path, "/tmp/OwnShot/docs/implementation-status.md")
    // Своих адресов нет – строки выключены и никуда не ведут.
    for id in ["contact", "twitter", "youtube"] {
      XCTAssertNil(byID[id]?.url, id)
      XCTAssertEqual(byID[id]?.isEnabled, false, id)
    }
    // Ни одной сетевой ссылки, в том числе на Snapzy и CleanShot.
    for link in links {
      if let url = link.url { XCTAssertTrue(url.isFileURL, link.id) }
    }
  }

  func testAboutLinks_безИсходниковВсеСтрокиВыключены() {
    XCTAssertTrue(OwnShotAboutLink.makeAll(repositoryRoot: nil).allSatisfy { !$0.isEnabled })
  }

  func testRepositoryRoot_вычисляетсяИзПутиФайла() {
    let source = "/Users/me/OwnShot/Snapzy/Features/Preferences/Components/OwnShotAcknowledgments.swift"
    XCTAssertEqual(
      OwnShotAboutLink.repositoryRoot(sourceFile: source, fileExists: { $0 == "/Users/me/OwnShot/Snapzy.xcodeproj" })?.path,
      "/Users/me/OwnShot"
    )
    XCTAssertNil(OwnShotAboutLink.repositoryRoot(sourceFile: source, fileExists: { _ in false }))
  }

  // MARK: - Raycast AI Chat

  func testRaycast_видимостьПоBundleIDЭталона() {
    XCTAssertEqual(OwnShotRaycastStub.bundleIdentifiers, ["com.raycast.macos", "com.raycast-x.macos"])
    XCTAssertFalse(OwnShotRaycastStub.isRaycastInstalled(lookup: { _ in nil }))
    XCTAssertTrue(OwnShotRaycastStub.isRaycastInstalled(lookup: { id in
      id == "com.raycast-x.macos" ? URL(fileURLWithPath: "/Applications/Raycast.app") : nil
    }))
  }

  func testRaycast_сочетаниеCmdR() {
    XCTAssertTrue(OwnShotRaycastStub.isSendShortcut(characters: "r", modifiers: .command))
    XCTAssertFalse(OwnShotRaycastStub.isSendShortcut(characters: "r", modifiers: [.command, .shift]))
    XCTAssertFalse(OwnShotRaycastStub.isSendShortcut(characters: "r", modifiers: []))
    XCTAssertFalse(OwnShotRaycastStub.isSendShortcut(characters: "e", modifiers: .command))
  }

  func testRaycast_пунктКарточкиСтоитЗаScaleRetina() {
    let groups = QuickAccessCardMenuLayout.groups(
      isVideo: false, includesCloud: false, isRetina: true, includesRaycast: true
    )
    XCTAssertEqual(groups[1], [.rotateLeft, .flipHorizontal, .resize, .scaleRetina, .sendToRaycastAIChat])
    // У видео операций над картинкой нет
    let video = QuickAccessCardMenuLayout.groups(isVideo: true, includesCloud: false, includesRaycast: true)
    XCTAssertFalse(video.flatMap { $0 }.contains(.sendToRaycastAIChat))
    // Без Raycast меню как в живом снимке эталона
    XCTAssertFalse(QuickAccessCardMenuLayout.groups(isVideo: false, includesCloud: true).flatMap { $0 }.contains(.sendToRaycastAIChat))
  }

  func testRaycast_пунктPinСтоитЗаSaveAs() {
    let entries = QuickAccessPinMenuLayout.entries(includesCloud: true, includesRaycast: true)
    let saveAs = entries.firstIndex(of: .command(.saveAs))
    XCTAssertNotNil(saveAs)
    XCTAssertEqual(entries[saveAs! + 1], .command(.sendToRaycastAIChat))
    XCTAssertFalse(QuickAccessPinMenuLayout.entries(includesCloud: true).contains(.command(.sendToRaycastAIChat)))
  }

  func testRaycast_строкиЭталона() {
    XCTAssertEqual(L10n.PersonalBuildStubs.sendToRaycastAIChat, "Send to Raycast AI Chat")
    XCTAssertEqual(L10n.PersonalBuildStubs.sendToRaycastAIChatMenuItem, "Send To Raycast AI Chat...")
    XCTAssertEqual(L10n.PersonalBuildStubs.captureAreaAndSendToRaycast, "Capture Area & Send to Raycast AI Chat")
  }

  func testRaycast_действиеСообщаетОНедоступностиБезОкнаВТестовомХосте() {
    let windowsBefore = NSApp.windows.count
    let message = OwnShotRaycastStub.send()
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    XCTAssertEqual(message, L10n.PersonalBuildStubs.raycastUnavailableMessage)
    XCTAssertTrue(message.contains("not available in the personal build"))
    XCTAssertEqual(NSApp.windows.count, windowsBefore)
  }

  // MARK: - Сеть

  func testЗаглушки_неДелаютСетевыхВызовов() {
    OwnShotUsageStatistics.setAllowed(true, in: defaults)
    OwnShotUsageStatistics.setAllowed(false, in: defaults)
    _ = OwnShotAboutLink.makeAll()
    _ = OwnShotRaycastStub.isRaycastInstalled()
    OwnShotRaycastStub.send()
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    XCTAssertEqual(NetworkRecorder.requestCount, 0)
  }

  func testNetworkRecorder_перехватываетЗапросы() {
    // Контроль: регистратор действительно видит запросы URLSession.shared.
    let done = expectation(description: "запрос")
    URLSession.shared.dataTask(with: URL(string: "https://example.invalid/ownshot-stub-probe")!) { _, _, _ in
      done.fulfill()
    }.resume()
    wait(for: [done], timeout: 5)
    XCTAssertEqual(NetworkRecorder.requestCount, 1)
  }
}

/// Считает запросы через URL Loading System и отвечает ошибкой, не выходя в сеть.
private final class NetworkRecorder: URLProtocol {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var count = 0

  static var requestCount: Int {
    lock.lock(); defer { lock.unlock() }
    return count
  }

  static func reset() {
    lock.lock(); count = 0; lock.unlock()
  }

  override class func canInit(with request: URLRequest) -> Bool {
    guard let scheme = request.url?.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
    // Один запрос даёт несколько вызовов canInit – считаем в startLoading.
    return true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.lock.lock(); Self.count += 1; Self.lock.unlock()
    client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
  }

  override func stopLoading() {}
}
