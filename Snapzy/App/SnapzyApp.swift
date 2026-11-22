//
//  SnapzyApp.swift
//  Snapzy
//
//  Main app entry point - Menu Bar App
//

import AppKit
import Carbon
import CoreGraphics
import Darwin
import SwiftUI

// MARK: - Notification Names

extension Notification.Name {
  static let showOnboarding = Notification.Name("showOnboarding")
}

@main
@MainActor
enum OwnShotMain {
  static func main() {
    if CommandLine.arguments.contains("--check-screen-capture-granted") {
      exit(CGPreflightScreenCaptureAccess() ? 0 : 1)
    }
    if Bundle.main.bundleIdentifier != "dev.nikoko.ownshot.test-host" {
      AppLaunchGate.shared.prepareSingleInstanceLaunch()
      if AppLaunchGate.shared.isDuplicateInstance {
        AppLaunchGate.shared.forwardDuplicateLaunchAndExit()
      }
    }
    SnapzyApp.main()
  }
}

struct SnapzyApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
  @ObservedObject private var themeManager = ThemeManager.shared

  init() {
    if !AppLaunchPolicy().isRunningUnderXCTest,
      Bundle.main.bundleIdentifier != "dev.nikoko.ownshot.test-host"
    {
      AppIdentityManager.shared.refresh()
    }
  }

  var body: some Scene {
    // Settings Window
    Settings {
      PreferencesView()
        .preferredColorScheme(themeManager.systemAppearance)
    }
    .commands {
      CommandGroup(replacing: .appSettings) {
        Button("Settings…") { PreferencesWindowController.shared.show() }
          .keyboardShortcut(",", modifiers: .command)
      }
    }
  }
}

// SDK также экспортирует структуру Darwin.flock с таким же именем.
@_silgen_name("flock")
private func ownShotFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

/// Блокировка живёт до выхода процесса. Файл не удаляется, чтобы запуски не разошлись по разным inode.
final class AppInstanceLock {
  let isOwner: Bool
  private let descriptor: Int32

  init(url: URL) throws {
    let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    if ownShotFlock(descriptor, LOCK_EX | LOCK_NB) == 0 {
      self.descriptor = descriptor
      isOwner = true
    } else {
      let code = errno
      Darwin.close(descriptor)
      guard code == EWOULDBLOCK else {
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
      }
      self.descriptor = -1
      isOwner = false
    }
  }

  deinit {
    if descriptor >= 0 { Darwin.close(descriptor) }
  }
}

struct AppLaunchPolicy {
  static func redirectApplicationURL(bundleURL: URL?, installedApplicationURL: URL) -> URL? {
    guard bundleURL?.resolvingSymlinksInPath().standardizedFileURL
      != installedApplicationURL.resolvingSymlinksInPath().standardizedFileURL
    else { return nil }
    return installedApplicationURL
  }

  static func commandLineOpenURLs(arguments: [String], currentDirectoryURL: URL) -> [URL] {
    let supportedExtensions: Set<String> = [
      "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "webp", "bmp", "ownshot",
    ]
    return arguments.dropFirst().compactMap { argument in
      guard !argument.hasPrefix("-") else { return nil }
      if let url = URL(string: argument), let scheme = url.scheme {
        if scheme.lowercased() == "ownshot" { return url }
        guard url.isFileURL, supportedExtensions.contains(url.pathExtension.lowercased()) else { return nil }
        return url
      }
      let fileURL = URL(fileURLWithPath: argument, relativeTo: currentDirectoryURL).standardizedFileURL
      return supportedExtensions.contains(fileURL.pathExtension.lowercased()) ? fileURL : nil
    }
  }

  private let environment: [String: String]
  private let screenCountProvider: () -> Int

  init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    screenCountProvider: @escaping () -> Int = { NSScreen.screens.count }
  ) {
    self.environment = environment
    self.screenCountProvider = screenCountProvider
  }

  var shouldStartInteractiveApplication: Bool {
    if isRunningUnderXCTest && !allowsInteractiveXCTestHost {
      return false
    }

    return !isHeadlessDisplaySession
  }

  var isRunningUnderXCTest: Bool {
    environment["XCTestConfigurationFilePath"] != nil
  }

  var isHeadlessDisplaySession: Bool {
    screenCountProvider() == 0
  }

  private var allowsInteractiveXCTestHost: Bool {
    environment["SNAPZY_ALLOW_INTERACTIVE_XCTEST_HOST"] == "1"
  }
}

/// Создаётся до SwiftUI: прямой запуск Mach-O может не получить событие завершения запуска AppKit.
@MainActor
private final class AppLaunchGate {
  static let shared = AppLaunchGate()
  private var instanceLock: AppInstanceLock?
  private(set) var isDuplicateInstance = false
  private var redirectsToInstalledApplication = false
  private var primaryApplicationURL: URL?

  func prepareSingleInstanceLaunch() {
    if AppLaunchPolicy().isRunningUnderXCTest {
      // Прямой запуск XCTest из Xcode не должен создавать второй OwnShot с рабочей идентичностью.
      fputs("OwnShot: run tests with scripts/run-tests.sh to use the isolated test host.\n", stderr)
      exit(1)
    }
    let installedApplicationURL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Applications/OwnShot.app")
    if let target = AppLaunchPolicy.redirectApplicationURL(
      bundleURL: Bundle.main.bundleURL,
      installedApplicationURL: installedApplicationURL
    ) {
      isDuplicateInstance = true
      redirectsToInstalledApplication = true
      primaryApplicationURL = target
      return
    }
    guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
    let otherApplications = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
      .filter { $0.processIdentifier != getpid() && !$0.isTerminated }
    // Уже открытый старый OwnShot ещё не знает о flock. Его окна и процесс сохраняем.
    let earlierApplication = otherApplications.first { $0.isFinishedLaunching }
    if let earlierApplication {
      isDuplicateInstance = true
      primaryApplicationURL = earlierApplication.bundleURL
      return
    }

    do {
      let lockURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("ownshot-instance-\(getuid()).lock")
      let lock = try AppInstanceLock(url: lockURL)
      instanceLock = lock
      isDuplicateInstance = !lock.isOwner
      if isDuplicateInstance {
        primaryApplicationURL = otherApplications.first?.bundleURL
      }
    } catch {
      // При ошибке блокировки второй редактор и базу данных не открываем.
      fputs("OwnShot: cannot acquire instance lock: \(error.localizedDescription)\n", stderr)
      exit(1)
    }
  }

  func forwardDuplicateLaunchAndExit() -> Never {
    var urls = commandLineOpenURLs()
    var seen = Set<URL>()
    urls = urls.filter { seen.insert($0).inserted }
    guard !urls.isEmpty || redirectsToInstalledApplication else { exit(0) }

    let applicationURL = primaryApplicationURL ?? FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Applications/OwnShot.app")
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    configuration.createsNewApplicationInstance = false
    configuration.promptsUserIfNeeded = false
    let completion: (NSRunningApplication?, Error?) -> Void = { _, error in
      if let error {
        fputs("OwnShot: cannot forward launch request: \(error.localizedDescription)\n", stderr)
      }
      // Завершаем только процесс-дубль, без диалогов выхода основного редактора.
      exit(error == nil ? 0 : 1)
    }
    if urls.isEmpty {
      NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration, completionHandler: completion)
    } else {
      NSWorkspace.shared.open(urls, withApplicationAt: applicationURL, configuration: configuration, completionHandler: completion)
    }
    // До SwiftUI нет NSApplication.run. Таймер удерживает run loop и ограничивает передачу.
    Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { _ in
      fputs("OwnShot: launch forwarding timed out.\n", stderr)
      exit(1)
    }
    RunLoop.main.run()
    exit(1)
  }

  private func commandLineOpenURLs() -> [URL] {
    AppLaunchPolicy.commandLineOpenURLs(
      arguments: CommandLine.arguments,
      currentDirectoryURL: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    )
  }
}

// MARK: - App Delegate

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
  private let launchPolicyProvider: () -> AppLaunchPolicy
  private var coordinator: AppCoordinator?
  private var pendingDeepLinkURLs: [URL] = []
  private var pendingOpenFileURLs: [URL] = []
  private var didFinishLaunching = false

  override init() {
    self.launchPolicyProvider = { AppLaunchPolicy() }
    super.init()
  }

  init(launchPolicyProvider: @escaping () -> AppLaunchPolicy) {
    self.launchPolicyProvider = launchPolicyProvider
    super.init()
  }

  func applicationWillFinishLaunching(_ notification: Notification) {
    guard Bundle.main.bundleIdentifier != "dev.nikoko.ownshot.test-host" else { return }
    NSAppleEventManager.shared().setEventHandler(
      self,
      andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
      forEventClass: AEEventClass(kInternetEventClass),
      andEventID: AEEventID(kAEGetURL)
    )
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    guard Bundle.main.bundleIdentifier != "dev.nikoko.ownshot.test-host",
      launchPolicyProvider().shouldStartInteractiveApplication
    else {
      return
    }

    AppIdentityManager.shared.refresh()

    guard ensureDatabaseReadyForLaunch() else {
      return
    }

    // Cleanup orphaned temp capture files from previous sessions
    TempCaptureManager.shared.cleanupOrphanedFiles()
    // Недописанные записи прошлого запуска (аварийный выход) – как recovery у эталона.
    RecordingCrashRecovery.recoverOnLaunch()

    let coordinator = AppCoordinator(environment: AppEnvironment.live())
    self.coordinator = coordinator
    coordinator.applicationDidFinishLaunching()
    didFinishLaunching = true
    for url in commandLineOpenURLs() {
      if url.isFileURL {
        if !pendingOpenFileURLs.contains(url) { pendingOpenFileURLs.append(url) }
      } else if !pendingDeepLinkURLs.contains(url) {
        pendingDeepLinkURLs.append(url)
      }
    }
    flushPendingDeepLinks()
    flushPendingOpenFileURLs()
  }

  private func commandLineOpenURLs() -> [URL] {
    AppLaunchPolicy.commandLineOpenURLs(
      arguments: CommandLine.arguments,
      currentDirectoryURL: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    )
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    // Выход при открытом окне активации подтверждается, как в эталоне.
    guard OwnShotLicensePresenter.shared.confirmQuitIfNeeded() else { return .terminateCancel }
    // Идущая запись и несохранённые окна подтверждаются отдельно.
    return OwnShotQuitGuard.reply(for: sender)
  }

  func applicationWillTerminate(_ notification: Notification) {
    NSAppleEventManager.shared().removeEventHandler(
      forEventClass: AEEventClass(kInternetEventClass),
      andEventID: AEEventID(kAEGetURL)
    )
    coordinator?.applicationWillTerminate()
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    guard didFinishLaunching else { return true }
    let showsMenuBarIcon = UserDefaults.standard.object(forKey: PreferencesKeys.showMenuBarIcon) as? Bool ?? true
    // An enabled icon can still be hidden behind the notch on a crowded menu bar (issue #587).
    let isIconObscured = showsMenuBarIcon && AppStatusBarController.shared.isMenuBarIconObscured
    guard !showsMenuBarIcon || isIconObscured else {
      // Значок виден: как эталон, показываем под ним пузырь «OwnShot is ready to use!»,
      // Settings не открываем.
      AppStatusBarController.shared.showReadyBubble()
      return true
    }

    if isIconObscured {
      DiagnosticLogger.shared.log(.info, .ui, "Opening Settings on reopen because the menu bar icon is hidden")
    }
    AppStatusBarController.shared.openPreferencesWindow(tab: .general)
    return false
  }

  private enum DatabaseLaunchRecoveryAction {
    case repair
    case reset
    case quit
  }

  private enum SandboxOffMigrationRecoveryAction {
    case retry
    case startFresh
    case quit
  }

  private func ensureSandboxOffDataMigrationReadyForLaunch() -> Bool {
    var note: String?

    while true {
      do {
        let result = try SandboxOffDataMigrationService.shared.runIfNeeded()
        if result.didRun {
          DiagnosticLogger.shared.log(
            .info,
            .lifecycle,
            "Sandbox-off data migration completed",
            context: [
              "appSupportCopied": "\(result.copiedApplicationSupportItems)",
              "appSupportSkipped": "\(result.skippedApplicationSupportItems)",
              "appSupportErrorSkipped": "\(result.errorSkippedApplicationSupportItems)",
              "preferencesImported": "\(result.importedPreferenceKeys)",
              "preferencesSkipped": "\(result.skippedPreferenceKeys)",
              "logsCopied": "\(result.copiedLogItems)",
            ]
          )
        }
        return true
      } catch {
        switch presentSandboxOffMigrationRecoveryAlert(error: error, note: note) {
        case .retry:
          note = "Previous attempt also failed. If this keeps happening, Start Fresh will let you use Snapzy without old data."
          continue

        case .startFresh:
          guard confirmMigrationSkip(error: error) else {
            note = nil
            continue
          }
          do {
            try SandboxOffDataMigrationService.shared.skipMigration()
            DiagnosticLogger.shared.log(
              .warning,
              .lifecycle,
              "Sandbox-off data migration skipped by user (Start Fresh)"
            )
            return true
          } catch {
            note = "Could not mark migration as skipped: \(error.localizedDescription)"
            continue
          }

        case .quit:
          NSApp.terminate(nil)
          return false
        }
      }
    }
  }

  private func presentSandboxOffMigrationRecoveryAlert(
    error: Error,
    note: String? = nil
  ) -> SandboxOffMigrationRecoveryAction {
    NSApp.activate(ignoringOtherApps: true)

    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = "Snapzy could not migrate your existing data."

    var informativeText = """
      Snapzy needs to move data from the old sandboxed storage before opening the unsandboxed version.

      No new database was opened yet, so your existing data has not been replaced.

      Error:
      \(error.localizedDescription)
      """
    if let note {
      informativeText += "\n\n\(note)"
    }
    informativeText += "\n\nTry again if the error is temporary. Start Fresh launches Snapzy with default settings — your old data stays in the sandbox container and is not deleted."
    alert.informativeText = informativeText

    alert.addButton(withTitle: "Try Again")
    alert.addButton(withTitle: "Start Fresh…")
    alert.addButton(withTitle: "Quit Snapzy")

    switch alert.runModal() {
    case .alertFirstButtonReturn:
      return .retry
    case .alertSecondButtonReturn:
      return .startFresh
    default:
      return .quit
    }
  }

  private func confirmMigrationSkip(error: Error) -> Bool {
    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = "Start Fresh Without Old Data?"
    alert.informativeText = """
      Snapzy will launch with default settings and an empty capture history.

      Your old data remains in the sandbox container and is not deleted. You can access it manually at:
      ~/Library/Containers/\(Bundle.main.bundleIdentifier ?? "com.duongductrong.Snapzy")

      Current error:
      \(error.localizedDescription)
      """
    alert.addButton(withTitle: "Start Fresh")
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
  }

  private func ensureDatabaseReadyForLaunch() -> Bool {
    switch DatabaseManager.prepare() {
    case .success:
      return true
    case let .failure(error):
      return presentDatabaseRecoveryFlow(startingWith: error)
    }
  }

  private func presentDatabaseRecoveryFlow(startingWith error: Error) -> Bool {
    var currentError: Error = error
    var note: String?

    while true {
      switch presentDatabaseRecoveryAlert(error: currentError, note: note) {
      case .repair:
        do {
          try DatabaseManager.attemptRepair()
          return true
        } catch {
          currentError = error
          note = "Repair did not succeed. You can reset the database after backing up the current files, or quit Snapzy."
        }

      case .reset:
        guard confirmDatabaseReset(error: currentError) else {
          note = nil
          continue
        }

        do {
          let archive = try DatabaseManager.resetDatabaseFiles()
          switch DatabaseManager.retryInitialization() {
          case .success:
            if let archiveDirectoryURL = archive.archiveDirectoryURL {
              DiagnosticLogger.shared.log(
                .warning,
                .lifecycle,
                "Database reset during launch",
                context: ["archive": archiveDirectoryURL.path]
              )
            }
            return true
          case let .failure(error):
            currentError = error
            note = "Reset moved the old database files aside, but Snapzy still could not create a fresh database."
          }
        } catch {
          currentError = error
          note = "Reset failed before Snapzy could create a fresh database."
        }

      case .quit:
        NSApp.terminate(nil)
        return false
      }
    }
  }

  private func presentDatabaseRecoveryAlert(
    error: Error,
    note: String?
  ) -> DatabaseLaunchRecoveryAction {
    NSApp.activate(ignoringOtherApps: true)

    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = "Snapzy could not open its database."

    var informativeText = """
      Snapzy needs this database for capture history and cloud upload records.

      Database:
      \(DatabaseManager.defaultDatabaseURL.path)

      Error:
      \(error.localizedDescription)
      """
    if let note {
      informativeText += "\n\n\(note)"
    }
    informativeText += "\n\nTry a repair first. Reset starts with an empty database after moving the current database files into a recovery folder."
    alert.informativeText = informativeText

    alert.addButton(withTitle: "Try Repair")
    alert.addButton(withTitle: "Reset Database...")
    alert.addButton(withTitle: "Quit Snapzy")

    switch alert.runModal() {
    case .alertFirstButtonReturn:
      return .repair
    case .alertSecondButtonReturn:
      return .reset
    default:
      return .quit
    }
  }

  private func confirmDatabaseReset(error: Error) -> Bool {
    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = "Reset Snapzy Database?"
    alert.informativeText = """
      Snapzy will move the current database files into a recovery folder, then create a new empty database.

      This resets capture history and cloud upload history inside Snapzy. Capture files on disk and cloud files are not deleted.

      Database:
      \(DatabaseManager.defaultDatabaseURL.path)

      Current error:
      \(error.localizedDescription)
      """
    alert.addButton(withTitle: "Reset Database")
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
  }

  @objc private func handleGetURLEvent(
    _ event: NSAppleEventDescriptor,
    withReplyEvent replyEvent: NSAppleEventDescriptor
  ) {
    guard
      let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
      let url = URL(string: urlString)
    else {
      DiagnosticLogger.shared.log(.warning, .action, "Received invalid URL event")
      return
    }

    guard let coordinator else {
      pendingDeepLinkURLs.append(url)
      return
    }

    coordinator.handleDeepLink(url)
  }

  private func flushPendingDeepLinks() {
    guard let coordinator, !pendingDeepLinkURLs.isEmpty else { return }

    let urls = pendingDeepLinkURLs
    pendingDeepLinkURLs.removeAll()
    urls.forEach { coordinator.handleDeepLink($0) }
  }

  // MARK: - Open With (Finder right-click → Open With → Snapzy)

  /// Called when the user opens files with OwnShot from Finder or drops them
  /// onto the app icon. Videos and GIFs open in the video editor.
  ///
  /// Note: macOS 13+ prefers `application(_:open:)` over the legacy
  /// `application(_:openFiles:)`, and the latter is silently skipped on
  /// recent OS releases. We only act on file URLs here so that the existing
  /// Apple Event handler for `snapzy://` deep links keeps working.
  func application(_ application: NSApplication, open urls: [URL]) {
    let fileURLs = urls.filter { $0.isFileURL }
    guard !fileURLs.isEmpty else { return }

    DiagnosticLogger.shared.log(
      .info,
      .action,
      "Received open-file request",
      context: ["count": "\(fileURLs.count)"]
    )

    if didFinishLaunching {
      openFileURLs(fileURLs)
    } else {
      // Files arriving before launch finishes (e.g. a cold launch via "Open With")
      // are queued and flushed once the coordinator is ready.
      pendingOpenFileURLs.append(contentsOf: fileURLs)
    }
  }

  private func openFileURLs(_ urls: [URL]) {
    for url in urls {
      // Открытый извне файл сразу появляется в History, как в эталоне
      HistoryExternalFileRecorder.record(url)
      if VideoEditorManager.isVideoFile(url) {
        VideoEditorManager.shared.openEditor(for: url)
      } else {
        AnnotateManager.shared.openAnnotation(url: url)
      }
    }
  }

  private func flushPendingOpenFileURLs() {
    guard !pendingOpenFileURLs.isEmpty else { return }

    let urls = pendingOpenFileURLs
    pendingOpenFileURLs.removeAll()
    openFileURLs(urls)
  }

  #if DEBUG
    var hasCoordinatorForTesting: Bool {
      coordinator != nil
    }

    var didFinishLaunchingForTesting: Bool {
      didFinishLaunching
    }

    var pendingOpenFileURLCountForTesting: Int {
      pendingOpenFileURLs.count
    }
  #endif
}
