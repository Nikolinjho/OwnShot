//
//  SnapzyDeepLinkHandlerTests.swift
//  SnapzyTests
//
//  Unit tests for ownshot:// automation URL parsing.
//

import XCTest
@testable import Snapzy

final class SnapzyDeepLinkHandlerTests: XCTestCase {

  func testCanonicalRoutesParseExpectedActions() throws {
    let cases: [(String, SnapzyDeepLinkAction)] = [
      ("ownshot://capture/fullscreen", .captureFullscreen),
      ("ownshot://capture/area", .captureArea),
      ("ownshot://capture/repeat-area", .captureRepeatArea),
      ("ownshot://capture/delayed", .captureDelayed),
      ("ownshot://capture/delayed-fullscreen", .captureDelayedFullscreen),
      ("ownshot://capture/application", .captureApplication),
      ("ownshot://capture/area-annotate", .captureAreaAnnotate),
      ("ownshot://capture/scrolling", .captureScrolling),
      ("ownshot://capture/ocr", .captureOCR),
      ("ownshot://capture/smart-element", .captureSmartElement),
      ("ownshot://capture/object-cutout", .captureObjectCutout),
      ("ownshot://record/screen", .recordScreen),
      ("ownshot://record/application", .recordApplication),
      ("ownshot://open/annotate", .openAnnotate),
      ("ownshot://open/combine", .openCombine([])),
      ("ownshot://open/video-editor", .openVideoEditor),
      ("ownshot://open/cloud-uploads", .openCloudUploads),
      ("ownshot://open/history", .openHistory),
      ("ownshot://tools/pick-color", .pickColor),
      ("ownshot://pick-color", .pickColor),
      ("ownshot://color-picker", .pickColor),
      ("ownshot://tools/measure", .measureScreen),
      ("ownshot://tools/ruler", .measureScreen),
      ("ownshot://screen-ruler", .measureScreen),
      ("ownshot://show/shortcuts", .showShortcuts),
      ("ownshot://settings", .openSettings(nil)),
    ]

    for (urlString, expectedAction) in cases {
      let url = try XCTUnwrap(URL(string: urlString))
      XCTAssertEqual(SnapzyDeepLinkAction(url: url), expectedAction, urlString)
    }
  }

  func testDelayedFullscreenAliasesParseExpectedAction() throws {
    let aliases = [
      "ownshot://delayed-fullscreen",
      "ownshot://capture-delayed-fullscreen",
      "ownshot://screenshot/delayed-fullscreen",
    ]

    for urlString in aliases {
      let url = try XCTUnwrap(URL(string: urlString))
      XCTAssertEqual(SnapzyDeepLinkAction(url: url), .captureDelayedFullscreen, urlString)
    }
  }

  func testDelayedCaptureModeQuerySelectsFullscreen() throws {
    let fullscreen = try XCTUnwrap(URL(string: "ownshot://capture/delayed?mode=fullscreen"))
    XCTAssertEqual(SnapzyDeepLinkAction(url: fullscreen), .captureDelayedFullscreen)

    let area = try XCTUnwrap(URL(string: "ownshot://capture/delayed?mode=area"))
    XCTAssertEqual(SnapzyDeepLinkAction(url: area), .captureDelayed)

    let uppercase = try XCTUnwrap(URL(string: "ownshot://screenshot/delayed?mode=FULLSCREEN"))
    XCTAssertEqual(SnapzyDeepLinkAction(url: uppercase), .captureDelayedFullscreen)
  }

  func testRepeatAreaAliasesParseExpectedAction() throws {
    let aliases = [
      "ownshot://repeat-area",
      "ownshot://capture-repeat-area",
      "ownshot://screenshot/repeat-area",
    ]

    for urlString in aliases {
      let url = try XCTUnwrap(URL(string: urlString))
      XCTAssertEqual(SnapzyDeepLinkAction(url: url), .captureRepeatArea, urlString)
    }
  }

  func testCombineAliasesParseExpectedAction() throws {
    let aliases = [
      "ownshot://combine",
      "ownshot://combine-images",
      "ownshot://open-combine",
    ]

    for urlString in aliases {
      let url = try XCTUnwrap(URL(string: urlString))
      XCTAssertEqual(SnapzyDeepLinkAction(url: url), .openCombine([]), urlString)
    }
  }

  func testCombineRouteParsesRepeatedFileParameters() throws {
    var components = try XCTUnwrap(URLComponents(string: "ownshot://open/combine"))
    components.queryItems = [
      URLQueryItem(name: "file", value: "/tmp/first image.png"),
      URLQueryItem(name: "file", value: "file:///tmp/second.jpg"),
      URLQueryItem(name: "ignored", value: "/tmp/not-used.png"),
    ]

    let url = try XCTUnwrap(components.url)
    XCTAssertEqual(
      SnapzyDeepLinkAction(url: url),
      .openCombine([
        URL(fileURLWithPath: "/tmp/first image.png"),
        URL(fileURLWithPath: "/tmp/second.jpg"),
      ])
    )
  }

  func testApplicationCaptureAliasesParseExpectedAction() throws {
    let aliases = [
      "ownshot://capture/window",
      "ownshot://application-capture",
      "ownshot://window-capture",
      "ownshot://screenshot/window",
    ]

    for urlString in aliases {
      let url = try XCTUnwrap(URL(string: urlString))
      XCTAssertEqual(SnapzyDeepLinkAction(url: url), .captureApplication, urlString)
    }
  }

  func testApplicationRecordingAliasesParseExpectedAction() throws {
    let aliases = [
      "ownshot://record/window",
      "ownshot://application-recording",
      "ownshot://window-recording",
      "ownshot://recording/window",
    ]

    for urlString in aliases {
      let url = try XCTUnwrap(URL(string: urlString))
      XCTAssertEqual(SnapzyDeepLinkAction(url: url), .recordApplication, urlString)
    }
  }

  func testSettingsTabRoutesParseExpectedTabs() throws {
    let cases: [(String, PreferencesTab)] = [
      ("general", .general),
      ("menubar", .menuBar),
      ("menu-bar", .menuBar),
      ("capture", .capture),
      ("annotate", .annotate),
      ("quick-access", .quickAccess),
      ("history", .history),
      ("shortcuts", .shortcuts),
      ("permissions", .permissions),
      ("cloud", .cloud),
      ("command-line", .commandLine),
      ("cli", .commandLine),
      ("advanced", .advanced),
      ("about", .about),
    ]

    for (tabName, expectedTab) in cases {
      let queryURL = try XCTUnwrap(URL(string: "ownshot://settings?tab=\(tabName)"))
      XCTAssertEqual(SnapzyDeepLinkAction(url: queryURL), .openSettings(expectedTab), tabName)

      let pathURL = try XCTUnwrap(URL(string: "ownshot://settings/\(tabName)"))
      XCTAssertEqual(SnapzyDeepLinkAction(url: pathURL), .openSettings(expectedTab), tabName)
    }
  }

  func testUnsupportedRoutesReturnNil() throws {
    let urls = [
      "https://capture/area",
      "ownshot://",
      "ownshot://capture/unknown",
      "ownshot://record/stop",
      "ownshot://open/unknown",
    ]

    for urlString in urls {
      let url = try XCTUnwrap(URL(string: urlString))
      XCTAssertNil(SnapzyDeepLinkAction(url: url), urlString)
    }
  }

  func testDeepLinkHandlerChecksUrlSchemeEnabled() throws {
    let defaults = UserDefaults.standard
    let originalValue = defaults.object(forKey: PreferencesKeys.urlSchemeEnabled)
    defer {
      if let originalValue {
        defaults.set(originalValue, forKey: PreferencesKeys.urlSchemeEnabled)
      } else {
        defaults.removeObject(forKey: PreferencesKeys.urlSchemeEnabled)
      }
    }

    defaults.set(false, forKey: PreferencesKeys.urlSchemeEnabled)
    let viewModel = ScreenCaptureViewModel()
    let handler = SnapzyDeepLinkHandler(screenCaptureViewModel: viewModel)
    let url = try XCTUnwrap(URL(string: "ownshot://capture/fullscreen"))
    handler.handle(url)
  }
}
