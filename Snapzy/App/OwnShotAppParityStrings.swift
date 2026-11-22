//
//  OwnShotAppParityStrings.swift
//  Snapzy
//
//  Строки паритета Settings, меню, захвата и приложения. Английские значения эталона,
//  ключи лежат в существующих таблицах по префиксу.
//

import Foundation

extension L10n {
  nonisolated enum AllInOne {
    static let captureAreaHelp = string("screen-capture.all-in-one.capture-area-help", defaultValue: "Capture Area (A)", comment: "All-In-One area mode tooltip with its key")
    static let captureFullscreenHelp = string("screen-capture.all-in-one.capture-fullscreen-help", defaultValue: "Capture Fullscreen (F)", comment: "All-In-One fullscreen mode tooltip with its key")
    static let captureWindowHelp = string("screen-capture.all-in-one.capture-window-help", defaultValue: "Capture Window (Space/W)", comment: "All-In-One window mode tooltip with its keys")
    static let scrollingCaptureHelp = string("screen-capture.all-in-one.scrolling-capture-help", defaultValue: "Scrolling Capture (S)", comment: "All-In-One scrolling mode tooltip with its key")
    static let selfTimerHelp = string("screen-capture.all-in-one.self-timer-help", defaultValue: "Self-Timer", comment: "All-In-One self-timer mode tooltip")
    static let captureTextHelp = string("screen-capture.all-in-one.capture-text-help", defaultValue: "Capture Text (O)", comment: "All-In-One OCR mode tooltip with its key")
    static let recordScreenHelp = string("screen-capture.all-in-one.record-screen-help", defaultValue: "Record Screen (R)", comment: "All-In-One recording mode tooltip with its key")
    static let expandToScreen = string("screen-capture.all-in-one.expand-to-screen", defaultValue: "Expand selection to screen", comment: "All-In-One button that expands the selection to the current screen")
  }

  nonisolated enum ScreenRecordingPermissionAlert {
    static let title = string("screen-capture.permission-alert.title", defaultValue: "OwnShot requires Screen Recording permission", comment: "Alert title when Screen Recording permission is denied")
    static let message = string("screen-capture.permission-alert.message", defaultValue: "In order to continue working properly, OwnShot needs Screen Recording permission.\n\nPlease open the Privacy & Security panel in System Settings and enable OwnShot in the Screen Recording section.", comment: "Alert message when Screen Recording permission is denied")
  }

  nonisolated enum CaptureNamePrompt {
    static let title = string("screen-capture.name-prompt.title", defaultValue: "Name Screenshot", comment: "Title of the dialog asking for a screenshot name")
    static let save = string("screen-capture.name-prompt.save", defaultValue: "Save", comment: "Save button in the screenshot name dialog")
    static let discard = string("screen-capture.name-prompt.discard", defaultValue: "Discard", comment: "Discard button in the screenshot name dialog")
  }

  nonisolated enum QRLinkPrompt {
    static let title = string("ocr.qr-link-prompt.title", defaultValue: "Do you want to open this link?", comment: "Alert title when a QR code contains a link")
    static let openInBrowser = string("ocr.qr-link-prompt.open-in-browser", defaultValue: "Open Link in Browser", comment: "Button that opens the QR code link")
    static let neverOpen = string("ocr.qr-link-prompt.never-open", defaultValue: "Never open links", comment: "Button that turns off link prompts")
  }

  nonisolated enum ScrollingCaptureHelp {
    static let helpButton = string("scrolling-capture.help.button", defaultValue: "How to use Scrolling Capture", comment: "Help button next to Start Capture")
    static let areaTitle = string("scrolling-capture.help.area-title", defaultValue: "How to select an area?", comment: "Scrolling capture help page title")
    static let areaBody = string("scrolling-capture.help.area-body", defaultValue: "Only scrollable content should be selected. Any non-moving parts or scroll bar should not be present in your selection.", comment: "Scrolling capture help page text")
    static let scrollTitle = string("scrolling-capture.help.scroll-title", defaultValue: "Slowly scroll down the content", comment: "Scrolling capture help page title")
    static let scrollBody = string("scrolling-capture.help.scroll-body", defaultValue: "You'll see a preview of your screenshot updated in real time. Scrolling too fast might result in breaking the capture process.", comment: "Scrolling capture help page text")
    static let orientationTitle = string("scrolling-capture.help.orientation-title", defaultValue: "Scroll Vertically or Horizontally", comment: "Scrolling capture help page title")
    static let orientationBody = string("scrolling-capture.help.orientation-body", defaultValue: "You can capture content in both vertical and horizontal orientations, but you can't switch directions during capture.", comment: "Scrolling capture help page text")
    static let limitationsIntro = string("scrolling-capture.help.limitations-intro", defaultValue: "Currently, the following conditions may break the scrolling capture:", comment: "Intro of the scrolling capture limitations list")
    static let limitations = string("scrolling-capture.help.limitations", defaultValue: "•  When selected area contains animations or videos.\n•  When you are not scrolling entirely vertically or horizontally.\n•  When you are scrolling too fast.\n•  When you start scrolling up.", comment: "Scrolling capture limitations list")
    static let next = string("scrolling-capture.help.next", defaultValue: "Next", comment: "Next page button in scrolling capture help")
    static let selectDrag = string("scrolling-capture-status.drag-to-capture", defaultValue: "Drag to capture the scrolling part of the screen.", comment: "Hint shown while selecting the scrolling capture area")
  }

  nonisolated enum QuitGuard {
    static let recordingTitle = string("menu.quit-guard.recording-title", defaultValue: "A screen recording is in progress", comment: "Alert title when quitting during a recording")
    static let recordingMessage = string("menu.quit-guard.recording-message", defaultValue: "OwnShot will stop the recording and save it before quitting.", comment: "Alert message when quitting during a recording")
    static let stopAndQuit = string("menu.quit-guard.stop-and-quit", defaultValue: "Stop Recording and Quit", comment: "Button that stops the recording and quits")
    static let unsavedTitle = string("menu.quit-guard.unsaved-title", defaultValue: "Do you want to quit OwnShot?", comment: "Alert title when quitting with unsaved editor changes")
    static let unsavedMessage = string("menu.quit-guard.unsaved-message", defaultValue: "Your media will be lost if you didn't save it.", comment: "Alert message when quitting with unsaved editor changes")
    static let quit = string("menu.quit-guard.quit", defaultValue: "Quit", comment: "Button that quits despite unsaved changes")
  }

  nonisolated enum SettingsParity {
    static let urlSchemeDescription = string("preferences-advanced.url-scheme-api-description", defaultValue: "Disable this option to prevent external apps from controlling OwnShot via [URL scheme API](https://github.com/duongductrong/Snapzy/blob/main/docs/SHORTCUTS.md).", comment: "Description under Allow URL scheme API with a link to the API docs")
    static let pixelSnapTitle = string("preferences-capture.pixelsnap-title", defaultValue: "Need more precision?", comment: "PixelSnap promo title in Screenshots settings")
    static let pixelSnapBody = string("preferences-capture.pixelsnap-body", defaultValue: "Automagically select objects to capture with PixelSnap.", comment: "PixelSnap promo text in Screenshots settings")
    static let learnMore = string("preferences-capture.pixelsnap-learn-more", defaultValue: "Learn more", comment: "Link to the PixelSnap website")
  }
}
