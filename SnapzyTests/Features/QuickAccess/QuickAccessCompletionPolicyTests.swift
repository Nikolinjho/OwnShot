import XCTest
@testable import Snapzy

final class QuickAccessCompletionPolicyTests: XCTestCase {
  func testSaveAsMetadataWriteFailureKeepsSourceAssociation() throws {
    try withSaveMetadataFixture { fixture in
      // Preserve a usable index and make only the destination entry unwritable.
      let storeRoot = fixture.store.appendingPathComponent("OwnShot/Captures/RecordingMetadata")
      let entries = storeRoot.appendingPathComponent("Entries")
      let originalEntries = Set(try FileManager.default.contentsOfDirectory(atPath: entries.path))
      try RecordingMetadataStore.save(
        fixture.metadata, for: fixture.target, applicationSupportDirectory: fixture.store
      )
      let allEntries = Set(try FileManager.default.contentsOfDirectory(atPath: entries.path))
      let destinationEntry = try XCTUnwrap(allEntries.subtracting(originalEntries).first)
      let destinationMetadata = entries.appendingPathComponent(destinationEntry)
      try FileManager.default.removeItem(at: destinationMetadata)
      try FileManager.default.createDirectory(at: destinationMetadata, withIntermediateDirectories: false)

      // Use the same new-inode transition as an exclusive cross-volume publication.
      try FileManager.default.removeItem(at: fixture.source)
      XCTAssertThrowsError(try RecordingMetadataStore.save(
        fixture.metadata, for: fixture.target, applicationSupportDirectory: fixture.store
      ))
      QuickAccessSaveDestination.copyRecordingMetadata(
        from: fixture.source, to: fixture.target, removingOriginal: true,
        applicationSupportDirectory: fixture.store
      )
      XCTAssertEqual(RecordingMetadataStore.load(
        for: fixture.source, applicationSupportDirectory: fixture.store
      ), fixture.metadata, "Failed save must retain the recoverable source association")
      XCTAssertEqual(try Data(contentsOf: fixture.target), Data("movie".utf8))
      XCTAssertEqual(try Data(contentsOf: fixture.audio), Data("editor audio".utf8))
    }
  }

  func testSaveAsMetadataBookmarkFailureKeepsSourceAssociationAndAudio() throws {
    try withSaveMetadataFixture { fixture in
      try FileManager.default.removeItem(at: fixture.source)
      let relocated = fixture.target.deletingLastPathComponent().appendingPathComponent("relocated.mov")
      try FileManager.default.moveItem(at: fixture.target, to: relocated)
      XCTAssertThrowsError(try RecordingMetadataStore.save(
        fixture.metadata, for: fixture.target, applicationSupportDirectory: fixture.store
      ))
      QuickAccessSaveDestination.copyRecordingMetadata(
        from: fixture.source, to: fixture.target, removingOriginal: true,
        applicationSupportDirectory: fixture.store
      )
      XCTAssertEqual(RecordingMetadataStore.load(
        for: fixture.source, applicationSupportDirectory: fixture.store
      ), fixture.metadata, "Failed save must retain the recoverable source association")
      XCTAssertEqual(try Data(contentsOf: relocated), Data("movie".utf8))
      XCTAssertEqual(
        try? Data(contentsOf: fixture.audio), Data("editor audio".utf8), "Failed save must retain editor audio"
      )
    }
  }

  func testSuccessfulSaveAsMetadataRetiresSourceAndKeepsAudio() throws {
    try withSaveMetadataFixture { fixture in
      try FileManager.default.removeItem(at: fixture.source)
      QuickAccessSaveDestination.copyRecordingMetadata(
        from: fixture.source, to: fixture.target, removingOriginal: true,
        applicationSupportDirectory: fixture.store
      )
      XCTAssertNil(RecordingMetadataStore.load(for: fixture.source, applicationSupportDirectory: fixture.store))
      XCTAssertEqual(RecordingMetadataStore.load(
        for: fixture.target, applicationSupportDirectory: fixture.store
      ), fixture.metadata)
      XCTAssertEqual(try Data(contentsOf: fixture.audio), Data("editor audio".utf8))
    }
  }

  private func withSaveMetadataFixture(
    _ body: ((store: URL, source: URL, target: URL, metadata: RecordingMetadata, audio: URL)) throws -> Void
  ) throws {
    try withSaveDirectory { temporary in
      let root = temporary.resolvingSymlinksInPath()
      let store = root.appendingPathComponent("ApplicationSupport")
      let source = root.appendingPathComponent("source.mov")
      let target = root.appendingPathComponent("target.mov")
      let master = root.appendingPathComponent("master.mov")
      try Data("movie".utf8).write(to: source)
      try FileManager.default.copyItem(at: source, to: target)
      try Data("editor audio".utf8).write(to: master)
      let audio = try RecordingMetadataStore.storeAudioSource(from: master, applicationSupportDirectory: store)
      let metadata = RecordingMetadata(
        captureSize: CGSize(width: 400, height: 300), samplesPerSecond: 30,
        mouseSamples: [], audioSourceURL: audio
      )
      try RecordingMetadataStore.save(metadata, for: source, applicationSupportDirectory: store)
      try body((store, source, target, metadata, audio))
    }
  }

  func testSaveAsKeepsADirectoryThatReplacedTheSourceCapture() throws {
    for sourceIsTemporary in [true, false] {
      try withSaveDirectory { root in
        let source = root.appendingPathComponent("capture.png", isDirectory: true)
        let target = root.appendingPathComponent("selected.png")
        let contents = source.appendingPathComponent("keep.txt")
        let data = Data("temporary fixture".utf8)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try data.write(to: contents)
        let destination = QuickAccessSaveDestinationSnapshot(
          directory: root, enteredName: "selected.png", extensions: ["png"]
        ).destination(at: target)

        XCTAssertThrowsError(try destination.save(source: source, sourceIsTemporary: sourceIsTemporary))
        XCTAssertEqual(try Data(contentsOf: contents), data)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
      }
    }
  }

  func testSaveAsMovesATemporaryLinkThatKeepsItsTarget() throws {
    try withSaveDirectory { root in
      let original = root.appendingPathComponent("original.png")
      let source = root.appendingPathComponent("capture.png")
      let target = root.appendingPathComponent("selected.png")
      let data = Data("capture".utf8)
      try data.write(to: original)
      try FileManager.default.createSymbolicLink(atPath: source.path, withDestinationPath: original.lastPathComponent)
      let destination = QuickAccessSaveDestinationSnapshot(
        directory: root, enteredName: "selected.png", extensions: ["png"]
      ).destination(at: target)

      XCTAssertEqual(try destination.save(source: source, sourceIsTemporary: true), target)
      XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
      XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: target.path), original.lastPathComponent)
      XCTAssertEqual(try Data(contentsOf: target), data)
    }
  }

  func testSaveAsPreservesATemporaryLinkThatWouldPointToAnotherCapture() throws {
    try withSaveDirectory { root in
      let original = root.appendingPathComponent("original.png")
      let source = root.appendingPathComponent("capture.png")
      let export = root.appendingPathComponent("export", isDirectory: true)
      let target = export.appendingPathComponent("selected.png")
      let other = export.appendingPathComponent(original.lastPathComponent)
      let data = Data("capture".utf8)
      let otherData = Data("other capture".utf8)
      try data.write(to: original)
      try FileManager.default.createSymbolicLink(atPath: source.path, withDestinationPath: original.lastPathComponent)
      try FileManager.default.createDirectory(at: export, withIntermediateDirectories: false)
      try otherData.write(to: other)
      let destination = QuickAccessSaveDestinationSnapshot(
        directory: export, enteredName: "selected.png", extensions: ["png"]
      ).destination(at: target)

      XCTAssertThrowsError(try destination.save(source: source, sourceIsTemporary: true))
      XCTAssertEqual(try Data(contentsOf: source), data)
      XCTAssertEqual(try Data(contentsOf: other), otherData)
      XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }
  }

  func testSaveAsKeepsTheOriginalWhenDestinationIsTheSourceLinkTarget() throws {
    try withSaveDirectory { root in
      let source = root.appendingPathComponent("capture.png")
      let target = root.appendingPathComponent("selected.png")
      let data = Data("capture".utf8)
      try data.write(to: target)
      try FileManager.default.createSymbolicLink(atPath: source.path, withDestinationPath: target.lastPathComponent)
      let destination = QuickAccessSaveDestinationSnapshot(
        directory: root, enteredName: "selected.png", extensions: ["png"]
      ).destination(at: target)

      XCTAssertThrowsError(try destination.save(source: source, sourceIsTemporary: true))
      XCTAssertEqual(try Data(contentsOf: source), data)
      XCTAssertEqual(try Data(contentsOf: target), data)
      XCTAssertThrowsError(try FileManager.default.destinationOfSymbolicLink(atPath: target.path))
    }
  }

  func testSaveAsPreservesFileAppearingAfterDestinationSelection() throws {
    for sourceIsTemporary in [true, false] {
      try withSaveDirectory { root in
        let source = root.appendingPathComponent("capture.png")
        let target = root.appendingPathComponent("selected.png")
        let capture = Data("capture".utf8)
        let other = Data("late arrival".utf8)
        try capture.write(to: source)
        let snapshot = QuickAccessSaveDestinationSnapshot(
          directory: root, enteredName: "selected", extensions: ["png"]
        )
        try other.write(to: target)
        let destination = snapshot.destination(at: target)

        XCTAssertThrowsError(try destination.save(source: source, sourceIsTemporary: sourceIsTemporary))
        XCTAssertEqual(try Data(contentsOf: target), other)
        XCTAssertEqual(try Data(contentsOf: source), capture)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), ["capture.png", "selected.png"])
      }
    }
  }

  func testSaveAsAllowsUnchangedConfirmedDestinationWithAppendedExtension() throws {
    for sourceIsTemporary in [true, false] {
      try withSaveDirectory { root in
        let source = root.appendingPathComponent("capture.png")
        let target = root.appendingPathComponent("selected.png")
        let capture = Data("capture".utf8)
        try capture.write(to: source)
        try Data("old target".utf8).write(to: target)
        let destination = QuickAccessSaveDestinationSnapshot(
          directory: root, enteredName: "selected", extensions: ["png"]
        ).destination(at: target)

        XCTAssertEqual(try destination.save(source: source, sourceIsTemporary: sourceIsTemporary), target)
        XCTAssertEqual(try Data(contentsOf: target), capture)
        XCTAssertEqual(FileManager.default.fileExists(atPath: source.path), !sourceIsTemporary)
      }
    }
  }

  func testSaveAsPreservesReplacementOfOriginallyConfirmedFile() throws {
    try withSaveDirectory { root in
      let source = root.appendingPathComponent("capture.png")
      let target = root.appendingPathComponent("selected.png")
      let previous = root.appendingPathComponent("previous.png")
      let capture = Data("capture".utf8)
      let other = Data("different file".utf8)
      try capture.write(to: source)
      try Data("originally selected".utf8).write(to: target)
      let snapshot = QuickAccessSaveDestinationSnapshot(
        directory: root, enteredName: "selected.png", extensions: ["png"]
      )
      try FileManager.default.moveItem(at: target, to: previous)
      try other.write(to: target)
      let destination = snapshot.destination(at: target)

      XCTAssertThrowsError(try destination.save(source: source, sourceIsTemporary: true))
      XCTAssertEqual(try Data(contentsOf: target), other)
      XCTAssertEqual(try Data(contentsOf: source), capture)
      XCTAssertEqual(try Data(contentsOf: previous), Data("originally selected".utf8))
    }
  }

  func testSaveAsToSameDirectoryEntryThroughLinkedParentIsNoOp() throws {
    try withSaveDirectory { root in
      let real = root.appendingPathComponent("real", isDirectory: true)
      let linked = root.appendingPathComponent("alias", isDirectory: true)
      try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
      try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: real)
      let source = real.appendingPathComponent("capture.png")
      let target = linked.appendingPathComponent("capture.png")
      let capture = Data("capture".utf8)
      try capture.write(to: source)
      let destination = QuickAccessSaveDestinationSnapshot(
        directory: linked, enteredName: "capture", extensions: ["png"]
      ).destination(at: target)

      XCTAssertEqual(try destination.save(source: source, sourceIsTemporary: true), source)
      XCTAssertEqual(try Data(contentsOf: source), capture)
      XCTAssertEqual(try Data(contentsOf: target), capture)
    }
  }

  func testSaveAsDoesNotFollowDestinationLeafSymlink() throws {
    try withSaveDirectory { root in
      let source = root.appendingPathComponent("capture.png")
      let target = root.appendingPathComponent("selected.png")
      let referent = root.appendingPathComponent("referent.png")
      let other = Data("do not replace".utf8)
      try Data("capture".utf8).write(to: source)
      try other.write(to: referent)
      try FileManager.default.createSymbolicLink(at: target, withDestinationURL: referent)
      let destination = QuickAccessSaveDestinationSnapshot(
        directory: root, enteredName: "selected.png", extensions: ["png"]
      ).destination(at: target)

      XCTAssertThrowsError(try destination.save(source: source, sourceIsTemporary: true))
      XCTAssertEqual(try Data(contentsOf: referent), other)
      XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: target.path), referent.path)
      XCTAssertEqual(try Data(contentsOf: source), Data("capture".utf8))
    }
  }

  func testSaveAsUsesActualCaseSensitivityForSourceLeaf() throws {
    try withSaveDirectory { root in
      let source = root.appendingPathComponent("Capture.png")
      let target = root.appendingPathComponent("capture.PNG")
      let capture = Data("capture".utf8)
      try capture.write(to: source)
      let aliasesSource = FileManager.default.fileExists(atPath: target.path)
      let destination = QuickAccessSaveDestinationSnapshot(
        directory: root, enteredName: "capture.PNG", extensions: ["png"]
      ).destination(at: target)

      XCTAssertEqual(try destination.save(source: source, sourceIsTemporary: true), aliasesSource ? source : target)
      XCTAssertEqual(try Data(contentsOf: target), capture)
      if aliasesSource {
        XCTAssertEqual(try Data(contentsOf: source), capture)
      }
      XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [aliasesSource ? "Capture.png" : "capture.PNG"])
    }
  }

  func testSaveAsApprovesConfirmedEntryUnderItsOtherSpelling() throws {
    try withSaveDirectory { root in
      let source = root.appendingPathComponent("Capture.png")
      let destinationEntry = root.appendingPathComponent("Selected.png")
      let destinationAlias = root.appendingPathComponent("selected.PNG")
      let capture = Data("capture".utf8)
      try capture.write(to: source)
      try Data("confirmed contents".utf8).write(to: destinationEntry)
      guard FileManager.default.fileExists(atPath: destinationAlias.path) else {
        throw XCTSkip("This test requires a case-insensitive filesystem")
      }
      let destination = QuickAccessSaveDestinationSnapshot(
        directory: root, enteredName: "Selected", extensions: ["png"]
      ).destination(at: destinationAlias)

      XCTAssertEqual(try destination.save(source: source, sourceIsTemporary: true), destinationAlias)
      XCTAssertEqual(try Data(contentsOf: destinationAlias), capture)
      XCTAssertEqual(FileManager.default.fileExists(atPath: source.path), false)
    }
  }

  func testSaveAsSeparatesHardLinksWithTheSameInode() throws {
    try withSaveDirectory { root in
      let source = root.appendingPathComponent("Capture.png")
      let target = root.appendingPathComponent("Other.png")
      let capture = Data("capture".utf8)
      try capture.write(to: source)
      try FileManager.default.linkItem(at: source, to: target)
      let sourceIdentity = try source.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
      let sourceApproved = QuickAccessSaveDestinationSnapshot(
        directory: root, enteredName: "Capture.png", extensions: ["png"]
      )
      let targetApproved = QuickAccessSaveDestinationSnapshot(
        directory: root, enteredName: "Other.png", extensions: ["png"]
      )

      XCTAssertThrowsError(try sourceApproved.destination(at: target).save(source: source, sourceIsTemporary: false))
      XCTAssertEqual(try targetApproved.destination(at: target).save(source: source, sourceIsTemporary: false), target)
      XCTAssertEqual(try Data(contentsOf: source), capture)
      XCTAssertEqual(try Data(contentsOf: target), capture)
      let publishedIdentity = try target.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
      XCTAssertNotEqual(sourceIdentity as? NSObject, publishedIdentity as? NSObject)
    }
  }

  func testSaveAsReplacesConfirmedFileWhenCaptureIsOnAnotherVolume() throws {
    try withCrossVolumeReplacementFixture { source, target, destination in
      let capture = Data("new capture".utf8)
      XCTAssertEqual(
        try destination.save(source: source, sourceIsTemporary: true, volumesAreEqual: { _, _ in false }),
        target
      )
      XCTAssertEqual(try Data(contentsOf: target), capture)
      XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
      XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path), ["selected.png"])
    }
  }

  func testSaveAsFailedCrossVolumeCopyPreservesConfirmedFileAndSource() throws {
    try withCrossVolumeReplacementFixture { source, target, destination in
      let fileManager = FileManager.default
      try fileManager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: source.path)
      defer { try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path) }

      XCTAssertThrowsError(
        try destination.save(source: source, sourceIsTemporary: true, volumesAreEqual: { _, _ in false })
      ) { error in
        XCTAssertEqual((error as NSError).domain, NSCocoaErrorDomain)
        XCTAssertTrue([NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains((error as NSError).code))
      }
      XCTAssertEqual(try Data(contentsOf: target), Data("approved original".utf8))
      try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path)
      XCTAssertEqual(try Data(contentsOf: source), Data("new capture".utf8))
      XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: target.deletingLastPathComponent().path), ["selected.png"])
    }
  }

  func testSaveAsCrossVolumeRechecksDestinationAfterStaging() throws {
    try withCrossVolumeReplacementFixture { source, target, destination in
      let fileManager = FileManager.default
      let archived = target.deletingLastPathComponent().appendingPathComponent("archived.png")
      let thirdParty = Data("new external file".utf8)
      XCTAssertThrowsError(
        try destination.save(source: source, sourceIsTemporary: true, volumesAreEqual: { _, _ in
          do {
            try fileManager.moveItem(at: target, to: archived)
            try thirdParty.write(to: target)
          } catch {
            XCTFail("Could not change the destination fixture: \(error)")
          }
          return false
        })
      ) { error in
        XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain)
        XCTAssertEqual((error as NSError).code, Int(POSIXErrorCode.EEXIST.rawValue))
      }
      XCTAssertEqual(try Data(contentsOf: target), thirdParty)
      XCTAssertEqual(try Data(contentsOf: archived), Data("approved original".utf8))
      XCTAssertEqual(try Data(contentsOf: source), Data("new capture".utf8))
      XCTAssertEqual(
        Set(try fileManager.contentsOfDirectory(atPath: target.deletingLastPathComponent().path)),
        ["selected.png", "archived.png"]
      )
    }
  }

  func testSaveAsCrossVolumeCleanupFailureKeepsPublishedCopyAndSource() throws {
    try withCrossVolumeReplacementFixture { source, target, destination in
      let fileManager = FileManager.default
      let sourceDirectory = source.deletingLastPathComponent()
      try fileManager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: sourceDirectory.path)
      defer { try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sourceDirectory.path) }

      XCTAssertThrowsError(
        try destination.save(source: source, sourceIsTemporary: true, volumesAreEqual: { _, _ in false })
      ) { error in
        XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain)
        XCTAssertEqual((error as NSError).code, Int(POSIXErrorCode.EACCES.rawValue))
      }
      XCTAssertEqual(try Data(contentsOf: source), Data("new capture".utf8))
      XCTAssertEqual(try Data(contentsOf: target), Data("new capture".utf8))
      XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: target.deletingLastPathComponent().path), ["selected.png"])
    }
  }

  private func withCrossVolumeReplacementFixture(
    _ body: (URL, URL, QuickAccessSaveDestination) throws -> Void
  ) throws {
    try withSaveDirectory { root in
      let source = root.appendingPathComponent("capture.png")
      let destinationDirectory = root.appendingPathComponent("destination", isDirectory: true)
      let target = destinationDirectory.appendingPathComponent("selected.png")
      try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: false)
      try Data("new capture".utf8).write(to: source)
      try Data("approved original".utf8).write(to: target)
      let destination = QuickAccessSaveDestinationSnapshot(
        directory: destinationDirectory, enteredName: "selected", extensions: ["png"]
      ).destination(at: target)
      try body(source, target, destination)
    }
  }

  private func withSaveDirectory(_ body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root)
  }

  func testСохранениеИмпортаКопируетНеПерезаписываяОригиналИЛишнийФайл() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source/capture.png")
    let output = root.appendingPathComponent("export")
    try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data([1, 2, 3]).write(to: source)
    let first = try QuickAccessImportedFileSave.copy(source: source, to: output)
    let second = try QuickAccessImportedFileSave.copy(source: source, to: output)
    XCTAssertNotEqual(first, second)
    XCTAssertEqual(try Data(contentsOf: source), Data([1, 2, 3]))
    XCTAssertEqual(try Data(contentsOf: first), Data([1, 2, 3]))
    XCTAssertEqual(try Data(contentsOf: second), Data([1, 2, 3]))
    XCTAssertEqual(try QuickAccessImportedFileSave.copy(source: first, to: output), first)
    try FileManager.default.removeItem(at: first)
    XCTAssertThrowsError(try QuickAccessImportedFileSave.copy(source: first, to: output))
  }

  @MainActor
  func testНовыеСлотыЗакрываютСлеваИЗакрепляютСправаНеПерезаписываяНастройки() {
    let name = "ownshot.parity032.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let fresh = QuickAccessActionConfigurationStore(defaults: defaults)
    XCTAssertEqual(fresh.action(in: .topLeading), .dismiss)
    XCTAssertEqual(fresh.action(in: .topTrailing), .pinToScreen)
    fresh.assignAction(.delete, to: .topLeading)
    fresh.assignAction(.dismiss, to: .topTrailing)
    let restored = QuickAccessActionConfigurationStore(defaults: defaults)
    XCTAssertEqual(restored.action(in: .topLeading), .delete)
    XCTAssertEqual(restored.action(in: .topTrailing), .dismiss)
  }

  @MainActor
  func testКарточкаВышеОбластиЗахвата() {
    let panel = QuickAccessPanel(contentRect: CGRect(x: 0, y: 0, width: 230, height: 180))
    defer { panel.close() }
    XCTAssertEqual(panel.level.rawValue, 2147483628)
  }

  @MainActor
  func testВоВремяВыделенияОбластиКарточкаНеПерехватываетМышь() {
    let panel = QuickAccessPanel(contentRect: CGRect(x: 0, y: 0, width: 230, height: 180))
    defer { panel.close() }
    panel.setFrameOrigin(CGPoint(x: NSEvent.mouseLocation.x - 10, y: NSEvent.mouseLocation.y - 10))
    panel.updatePassthroughRegion(itemCount: 1, scale: 1)
    XCTAssertFalse(panel.ignoresMouseEvents)
    panel.suspendMouseMonitors()
    XCTAssertTrue(panel.ignoresMouseEvents)
    panel.updatePassthroughRegion(itemCount: 1, scale: 1)
    XCTAssertTrue(panel.ignoresMouseEvents)
    panel.resumeMouseMonitors()
    XCTAssertFalse(panel.ignoresMouseEvents)
  }

  func testПеретаскиваниеЗакрываетТолькоПослеУспехаБезOption() {
    XCTAssertTrue(QuickAccessCompletionPolicy.shouldCloseAfterDrag(success: true, closeAfterDragging: true, optionHeld: false))
    XCTAssertFalse(QuickAccessCompletionPolicy.shouldCloseAfterDrag(success: false, closeAfterDragging: true, optionHeld: false))
    XCTAssertFalse(QuickAccessCompletionPolicy.shouldCloseAfterDrag(success: true, closeAfterDragging: true, optionHeld: true))
    XCTAssertFalse(QuickAccessCompletionPolicy.shouldCloseAfterDrag(success: true, closeAfterDragging: false, optionHeld: false))
    // Option при выключенной настройке закрывает карточку
    XCTAssertTrue(QuickAccessCompletionPolicy.shouldCloseAfterDrag(success: true, closeAfterDragging: false, optionHeld: true))
    XCTAssertFalse(QuickAccessCompletionPolicy.shouldCloseAfterDrag(success: false, closeAfterDragging: false, optionHeld: true))
  }

  func testOptionИнвертируетНазначениеКнопкиСохранить() {
    XCTAssertFalse(QuickAccessCompletionPolicy.chooseDestination(behavior: nil, optionHeld: false))
    XCTAssertTrue(QuickAccessCompletionPolicy.chooseDestination(behavior: "exportLocation", optionHeld: true))
    XCTAssertTrue(QuickAccessCompletionPolicy.chooseDestination(behavior: "chooseDestination", optionHeld: false))
    XCTAssertFalse(QuickAccessCompletionPolicy.chooseDestination(behavior: "chooseDestination", optionHeld: true))
  }

  func testСтрелкиПеремещаютОкноВПунктах() {
    XCTAssertEqual(PinWindowKeyboardMovement.offset(keyCode: 123, shift: false), CGPoint(x: -1, y: 0))
    XCTAssertEqual(PinWindowKeyboardMovement.offset(keyCode: 124, shift: true), CGPoint(x: 10, y: 0))
    XCTAssertEqual(PinWindowKeyboardMovement.offset(keyCode: 125, shift: false), CGPoint(x: 0, y: -1))
    XCTAssertEqual(PinWindowKeyboardMovement.offset(keyCode: 126, shift: true), CGPoint(x: 0, y: 10))
    XCTAssertNil(PinWindowKeyboardMovement.offset(keyCode: 53, shift: false))
  }
}
