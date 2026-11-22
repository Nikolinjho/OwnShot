import XCTest
import CoreGraphics
@testable import Snapzy

final class OwnShotAutomationRequestTests: XCTestCase {
  func testОригинальныйURIПередаетГраницыИДействие() throws {
    let url = try XCTUnwrap(URL(string: "ownshot://capture-area?x=500&y=400&width=100&height=80&action=annotate"))
    guard case .automation(let request) = SnapzyDeepLinkAction(url: url) else { return XCTFail("Ожидался прямой захват области") }
    XCTAssertEqual(request.bounds, CGRect(x: 500, y: 400, width: 100, height: 80))
    XCTAssertEqual(request.action, "annotate")
  }

  func testОригинальныеПоляГраницПроверяютсяВместе() {
    for query in ["x=1&y=2&width=10", "x=nan&y=2&width=10&height=20", "x=1&y=2&width=0&height=20", "x=1&y=2&width=10&height=-20", "x=1&bounds=0,0,10,10"] {
      XCTAssertNil(OwnShotAutomationRequest(command: "capture-area", components: URLComponents(string: "ownshot://capture-area?\(query)")))
    }
  }

  func testОригинальныйПараметрПереносаСтрок() throws {
    let request = try XCTUnwrap(OwnShotAutomationRequest(command: "capture-text", components: URLComponents(string: "ownshot://capture-text?linebreaks=false&breaks=true")))
    XCTAssertEqual(request.preserveBreaks, false)
    let url = try XCTUnwrap(URLComponents(string: "ownshot://capture-text?language=en"))
    XCTAssertNil(OwnShotAutomationRequest(command: "capture-text", components: url)?.preserveBreaks)
  }

  func testПараметрыЗапускаПрокрутки() throws {
    let request = try XCTUnwrap(OwnShotAutomationRequest(command: "scrolling-capture", components: URLComponents(string: "ownshot://scrolling-capture?start=true&autoscroll=1")))
    XCTAssertTrue(request.startImmediately)
    XCTAssertTrue(request.autoScroll)
    XCTAssertNil(OwnShotAutomationRequest(command: "scrolling-capture", components: URLComponents(string: "ownshot://scrolling-capture?start=invalid")))
  }

  func testЯвныеДействияСохраняютсяВЗапросе() throws {
    for action in ["save", "copy", "annotate", "pin", "upload"] {
      let request = try XCTUnwrap(OwnShotAutomationRequest(command: "capture-area", components: URLComponents(string: "ownshot://capture-area?x=500&y=400&width=100&height=80&action=\(action)")))
      XCTAssertEqual(request.action, action)
      XCTAssertNotNil(request.bounds)
    }
  }

  func testPinБезФайлаОткрываетВыборИзображения() throws {
    let url = try XCTUnwrap(URL(string: "ownshot://pin"))
    guard case .automation(let request) = SnapzyDeepLinkAction(url: url) else { return XCTFail("Ожидалось действие Pin") }
    XCTAssertEqual(request.command, "pin")
    XCTAssertNil(request.fileURL)
  }

  func testОтложенныйЗахватБезГраницСохраняетРежимОбласти() throws {
    let url = try XCTUnwrap(URL(string: "ownshot://capture/delayed?mode=area"))
    XCTAssertEqual(SnapzyDeepLinkAction(url: url), .captureDelayed)
    let fullscreen = try XCTUnwrap(URL(string: "ownshot://capture/delayed?mode=fullscreen"))
    XCTAssertEqual(SnapzyDeepLinkAction(url: fullscreen), .captureDelayedFullscreen)
  }

  func testДействиеЗахватаОкнаСохраняется() throws {
    for action in ["save", "copy", "annotate", "pin", "upload"] {
      let url = try XCTUnwrap(URL(string: "ownshot://capture-window?action=\(action)"))
      guard case .automation(let request) = SnapzyDeepLinkAction(url: url) else { return XCTFail("Ожидался запрос захвата окна") }
      XCTAssertEqual(request.command, "capture-window")
      XCTAssertEqual(request.action, action)
    }
  }

  func testПолноэкранныйЗахватНеМеняетПредыдущуюОбласть() throws {
    for (command, remembersArea) in [("capture-fullscreen", false), ("capture-area", true)] {
      let url = try XCTUnwrap(URL(string: "ownshot://\(command)?action=save"))
      guard case .automation(let request) = SnapzyDeepLinkAction(url: url) else { return XCTFail("Ожидался запрос захвата") }
      XCTAssertEqual(request.remembersArea, remembersArea)
    }
    let timer = try XCTUnwrap(OwnShotAutomationRequest(command: "self-timer", components: URLComponents(string: "ownshot://self-timer?mode=fullscreen&action=save")))
    XCTAssertFalse(timer.remembersArea)
  }

  func testОтклоняетНевалидныеГраницы() {
    for bounds in ["0,0,0,10", "nan,0,10,10", "0,0,-1,10", "0,1,2"] {
      XCTAssertNil(OwnShotAutomationRequest(command: "capture-area", components: URLComponents(string: "ownshot://capture-area?bounds=\(bounds)")))
    }
  }
  func testДекодируетПутьОдинРаз() throws {
    let request = try XCTUnwrap(OwnShotAutomationRequest(command: "pin", components: URLComponents(string: "ownshot://pin?filepath=%2Ftmp%2Fhello%20world%2520.png")))
    XCTAssertEqual(request.fileURL?.path, "/tmp/hello world%20.png")
  }
  func testВURLПовтораОбластиСохраняетсяЯвноеДействие() throws {
    let aliases = ["capture-previous-area", "capture/repeat-area", "repeat-area",
      "capture-repeat-area", "screenshot/repeat-area"]
    for alias in aliases {
      for action in ["copy", "save", "annotate", "upload", "pin"] {
        let url = try XCTUnwrap(URL(string: "ownshot://\(alias)?action=\(action.uppercased())"))
        guard case .automation(let request) = SnapzyDeepLinkAction(url: url) else {
          return XCTFail("Повтор области отбросил действие \(action) из \(alias)")
        }
        XCTAssertEqual(request.command, "capture-previous-area")
        XCTAssertEqual(request.action, action)
      }
    }
  }

  func testURLПовтораОбластиИспользуетТолькоПараметрДействия() throws {
    let url = try XCTUnwrap(URL(string: "ownshot://capture-previous-area?action=copy&filepath=/tmp/test.png&x=bad"))
    guard case .automation(let request) = SnapzyDeepLinkAction(url: url) else {
      return XCTFail("Лишние параметры не должны менять действие Copy")
    }
    XCTAssertEqual(request.action, "copy")
    XCTAssertNil(request.fileURL)
    XCTAssertNil(request.bounds)

    let unsupported = try XCTUnwrap(URL(string: "ownshot://capture-previous-area?action=unsupported"))
    XCTAssertEqual(SnapzyDeepLinkAction(url: unsupported), .captureRepeatArea)
  }

  func testURLAllInOneРазрешаетКоординатыНаВыбранномДисплее() throws {
    let url = try XCTUnwrap(URL(string: "ownshot://all-in-one?x=105&y=77&width=280&height=180&display=2"))
    guard case .automation(let request) = SnapzyDeepLinkAction(url: url) else {
      return XCTFail("All-in-One должен получить координаты и дисплей")
    }
    let screens = [CGRect(x: 0, y: 0, width: 1920, height: 1080),
      CGRect(x: -1600, y: 100, width: 1600, height: 900)]
    XCTAssertEqual(request.command, "all-in-one")
    XCTAssertEqual(request.display, 2)
    XCTAssertEqual(request.resolvedRect(screenFrames: screens, mouseLocation: CGPoint(x: 400, y: 200)),
      CGRect(x: -1495, y: 177, width: 280, height: 180))
  }

  func testURLRecordScreenПередаётГраницыЗаписиИДисплей() throws {
    let url = try XCTUnwrap(URL(string: "ownshot://record-screen?x=110&y=90&width=320&height=180&display=2"))
    guard case .automation(let request) = SnapzyDeepLinkAction(url: url) else {
      return XCTFail("Record Screen должен получить координаты и дисплей")
    }
    XCTAssertEqual(request.command, "record-screen")
    XCTAssertEqual(request.bounds, CGRect(x: 110, y: 90, width: 320, height: 180))
    XCTAssertEqual(request.display, 2)
  }

  func testПараметрФайлаНеПодменяетКомандуЗахватаИлиОткрытияИзБуфера() throws {
    let commands = [
      ("capture-area", "action=copy"),
      ("capture-window", "action=pin"),
      ("capture-fullscreen", "action=save"),
      ("self-timer", "action=annotate"),
      ("scrolling-capture", "start=false"),
      ("open-from-clipboard", ""),
      ("restore-recently-closed", ""),
    ]
    for (command, options) in commands {
      for filePath in ["/private/tmp/OwnShot-fixture.png", "fixture.png"] {
        let query = ["filepath=\(filePath)", options].filter { !$0.isEmpty }.joined(separator: "&")
        let url = try XCTUnwrap(URL(string: "ownshot://\(command)?\(query)"))
        guard case .automation(let request) = SnapzyDeepLinkAction(url: url) else {
          XCTFail("Сторонний filepath не должен менять или отменять \(command)")
          continue
        }
        XCTAssertEqual(request.command, command)
        XCTAssertNil(request.fileURL, "\(command) не использует filepath")
        if options.hasPrefix("action=") {
          XCTAssertEqual(request.action, options.split(separator: "=").last.map(String.init))
        }
      }
    }
  }

  func testФайловыеКомандыСохраняютПутьКИзображению() throws {
    for command in ["pin", "capture-text", "open-annotate", "add-quick-access-overlay"] {
      let url = try XCTUnwrap(URL(string: "ownshot://\(command)?filepath=/private/tmp/OwnShot%20fixture.png"))
      guard case .automation(let request) = SnapzyDeepLinkAction(url: url) else {
        XCTFail("Ожидалась файловая команда \(command)")
        continue
      }
      XCTAssertEqual(request.fileURL?.path, "/private/tmp/OwnShot fixture.png")
    }
  }

  func testОригинальныеАлиасы() throws {
    XCTAssertEqual(SnapzyDeepLinkAction(url: try XCTUnwrap(URL(string: "ownshot://capture-previous-area"))), .captureRepeatArea)
    XCTAssertEqual(SnapzyDeepLinkAction(url: try XCTUnwrap(URL(string: "ownshot://capture-window"))), .captureApplication)
    XCTAssertEqual(SnapzyDeepLinkAction(url: try XCTUnwrap(URL(string: "ownshot://self-timer"))), .captureDelayed)
    XCTAssertEqual(SnapzyDeepLinkAction(url: try XCTUnwrap(URL(string: "ownshot://open-settings?tab=recording"))), .openSettings(.recording))
  }
}
