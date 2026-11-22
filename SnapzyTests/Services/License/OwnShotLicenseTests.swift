import XCTest
@testable import Snapzy

@MainActor
final class OwnShotLicenseTests: XCTestCase {
  func testПриложениеВсегдаЛицензировано() {
    XCTAssertEqual(OwnShotLicense.check(), .licensed)
    XCTAssertTrue(OwnShotLicense.isLicensed)
  }

  func testActivateВМенюТолькоСOption() {
    XCTAssertFalse(OwnShotLicense.showsActivateMenuItem(optionPressed: false))
    XCTAssertTrue(OwnShotLicense.showsActivateMenuItem(optionPressed: true))
  }

  func testФорматКлючаКакУЭталона() {
    XCTAssertTrue(OwnShotLicense.isValidKeyFormat("ABCD1234-efgh5678-IJKL9012-mnop3456"))
    XCTAssertTrue(OwnShotLicense.isValidKeyFormat("  ABCD1234-EFGH5678-IJKL9012-MNOP3456\n"))
    XCTAssertFalse(OwnShotLicense.isValidKeyFormat(""))
    XCTAssertFalse(OwnShotLicense.isValidKeyFormat("ABCD1234-EFGH5678-IJKL9012"))
    XCTAssertFalse(OwnShotLicense.isValidKeyFormat("ABCD1234-EFGH5678-IJKL9012-MNOP345"))
    XCTAssertFalse(OwnShotLicense.isValidKeyFormat("ABCD1234-EFGH5678-IJKL9012-MNOP3456-XXXXXXXX"))
    XCTAssertFalse(OwnShotLicense.isValidKeyFormat("ABCD_234-EFGH5678-IJKL9012-MNOP3456"))
  }

  func testПустойИлиНеверныйКлючДаётОшибкуАктивации() {
    XCTAssertEqual(OwnShotLicense.activationOutcome(for: ""), .invalidKey)
    XCTAssertEqual(OwnShotLicense.activationOutcome(for: "not-a-key"), .invalidKey)
  }

  func testВерныйКлючНеПроверяетсяИЛицензияНеМеняется() {
    XCTAssertEqual(
      OwnShotLicense.activationOutcome(for: "ABCD1234-EFGH5678-IJKL9012-MNOP3456"),
      .notCheckedPersonalBuild
    )
    XCTAssertEqual(OwnShotLicense.check(), .licensed)
  }

  func testВыходПодтверждаетсяТолькоПриОткрытомОкнеАктивации() {
    XCTAssertTrue(OwnShotLicense.shouldConfirmQuit(activationWindowVisible: true))
    XCTAssertFalse(OwnShotLicense.shouldConfirmQuit(activationWindowVisible: false))
  }

  func testОкноАктивацииНеОткрываетсяВТестовомХосте() {
    let presenter = OwnShotLicensePresenter.shared
    presenter.showActivationWindow()
    XCTAssertFalse(presenter.isActivationWindowVisible)
    XCTAssertTrue(presenter.confirmQuitIfNeeded())
  }

  func testСтрокиБерутсяИзL10nСИменемOwnShot() {
    XCTAssertEqual(L10n.License.managerButton, "License Manager…")
    XCTAssertEqual(L10n.License.unlinkButton, "Unlink Device…")
    XCTAssertEqual(L10n.License.invalidKey, "Please enter a valid license key.")
    XCTAssertEqual(L10n.License.thankYou("OwnShot"), "Thank you for choosing OwnShot!")
    XCTAssertTrue(L10n.License.personalBuildTitle.contains("personal build"))
  }
}
