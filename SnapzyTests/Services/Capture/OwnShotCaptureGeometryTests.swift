import XCTest
import CoreGraphics
@testable import Snapzy

final class OwnShotCaptureGeometryTests: XCTestCase {
  func testДисплейВыбираетсяПоБолееКрупнойЧастиВыделения() {
    let displays = [
      CGRect(x: 0, y: 0, width: 800, height: 600),
      CGRect(x: 0, y: 600, width: 800, height: 600),
    ]
    let crossing = CGRect(x: 260, y: 580, width: 140, height: 100)
    XCTAssertEqual(OwnShotCaptureGeometry.screenIndex(for: crossing, in: displays), 1)

    let equalOverlap = CGRect(x: 260, y: 550, width: 140, height: 100)
    XCTAssertEqual(OwnShotCaptureGeometry.screenIndex(for: equalOverlap, in: displays), 0)

    let outside = CGRect(x: 800, y: 50, width: 80, height: 100)
    XCTAssertNil(OwnShotCaptureGeometry.screenIndex(for: outside, in: displays))
  }

  func testПанельСтоитПодВыделениемПоЦентру() {
    let origin = OwnShotCaptureGeometry.toolbarOrigin(
      for: CGRect(x: 500, y: 400, width: 640, height: 360),
      panelSize: CGSize(width: 694, height: 69),
      visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1092)
    )
    XCTAssertEqual(origin, CGPoint(x: 473, y: 301))
  }

  func testПанельПоднимаетсяНадВыделениемУНижнегоКрая() {
    let origin = OwnShotCaptureGeometry.toolbarOrigin(
      for: CGRect(x: 100, y: 20, width: 200, height: 100),
      panelSize: CGSize(width: 694, height: 69),
      visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1092)
    )
    XCTAssertEqual(origin, CGPoint(x: 8, y: 150))
  }

  func testПанельУчитываетСмещениеВторогоЭкрана() {
    let origin = OwnShotCaptureGeometry.toolbarOrigin(
      for: CGRect(x: 1800, y: 800, width: 640, height: 200),
      panelSize: CGSize(width: 694, height: 69),
      visibleFrame: CGRect(x: 1728, y: 0, width: 1920, height: 1080)
    )
    XCTAssertEqual(origin, CGPoint(x: 1773, y: 701))
  }

  func testРазмерСохраняетПропорцииИГраницы() {
    let result = OwnShotCaptureGeometry.resized(CGRect(x: 900, y: 700, width: 200, height: 100), width: 400, height: nil, locked: true, within: CGRect(x: 0, y: 0, width: 1000, height: 800))
    XCTAssertEqual(result, CGRect(x: 600, y: 600, width: 400, height: 200))
  }
  func testФиксацияПропорцийНеОкругляетДругуюСторону() {
    let result = OwnShotCaptureGeometry.resized(CGRect(x: 0, y: 0, width: 300, height: 100), width: 100, height: nil, locked: true, within: CGRect(x: 0, y: 0, width: 1000, height: 800))
    XCTAssertEqual(result.width, 100)
    XCTAssertEqual(result.height, 100.0 / 3.0, accuracy: 0.000001)
  }

  func testНекорректныйРазмерНеМеняетОбласть() {
    let rect = CGRect(x: 10, y: 20, width: 100, height: 50)
    XCTAssertEqual(OwnShotCaptureGeometry.resized(rect, width: .nan, height: nil, locked: false, within: CGRect(x: 0, y: 0, width: 1000, height: 800)), rect)
  }

  func testВыборКвадратаСохраняетВысотуИЦентрОбласти() {
    let result = OwnShotCaptureGeometry.applyingAspectRatio(1, to: CGRect(x: 500, y: 400, width: 640, height: 360), within: CGRect(x: 0, y: 0, width: 1728, height: 1117))
    XCTAssertEqual(result, CGRect(x: 640, y: 400, width: 360, height: 360))
  }

  func testШирокийФорматВосстанавливаетШиринуСохраняяЦентр() {
    let result = OwnShotCaptureGeometry.applyingAspectRatio(16.0 / 9, to: CGRect(x: 640, y: 400, width: 360, height: 360), within: CGRect(x: 0, y: 0, width: 1728, height: 1117))
    XCTAssertEqual(result, CGRect(x: 500, y: 400, width: 640, height: 360))
  }

  func testСлишкомШирокаяПропорцияУменьшаетОбеСтороныДоГраницЭкрана() {
    let result = OwnShotCaptureGeometry.applyingAspectRatio(2, to: CGRect(x: 100, y: 100, width: 400, height: 600), within: CGRect(x: 0, y: 0, width: 1000, height: 800))
    XCTAssertEqual(result, CGRect(x: 0, y: 150, width: 1000, height: 500))
  }

  func testПропорцииУчитываютКоординатыВторогоЭкрана() {
    let result = OwnShotCaptureGeometry.applyingAspectRatio(1, to: CGRect(x: 1800, y: 200, width: 640, height: 360), within: CGRect(x: 1728, y: 0, width: 1920, height: 1080))
    XCTAssertEqual(result, CGRect(x: 1940, y: 200, width: 360, height: 360))
  }

  func testНеверныеПропорцииНеМеняютВыделение() {
    let rect = CGRect(x: 10, y: 20, width: 100, height: 50)
    for ratio: CGFloat in [0, -1, .nan, .infinity] {
      XCTAssertEqual(OwnShotCaptureGeometry.applyingAspectRatio(ratio, to: rect, within: CGRect(x: 0, y: 0, width: 1000, height: 800)), rect)
    }
  }

  func testЧисловаяШиринаМожетСохранятьЦентрВместоЛевогоКрая() {
    let result = OwnShotCaptureGeometry.resized(CGRect(x: 500, y: 400, width: 640, height: 360), width: 360, height: nil, locked: false, within: CGRect(x: 0, y: 0, width: 1728, height: 1117), keepingCenter: true)
    XCTAssertEqual(result, CGRect(x: 640, y: 400, width: 360, height: 360))
  }

  func testЦентрированноеИзменениеНеВыходитЗаЛевуюГраницуЭкрана() {
    let result = OwnShotCaptureGeometry.resized(CGRect(x: 10, y: 400, width: 100, height: 50), width: 400, height: nil, locked: true, within: CGRect(x: 0, y: 0, width: 1000, height: 800), keepingCenter: true)
    XCTAssertEqual(result, CGRect(x: 0, y: 325, width: 400, height: 200))
  }

  func testУгловаяРучкаСохраняетПропорцииИПротивоположныйУгол() {
    let result = OwnShotCaptureGeometry.constrainedResize(CGRect(x: 100, y: 100, width: 600, height: 220), from: CGRect(x: 100, y: 100, width: 400, height: 200), aspectRatio: 2, within: CGRect(x: 0, y: 0, width: 1000, height: 800))
    XCTAssertEqual(result, CGRect(x: 100, y: 100, width: 600, height: 300))
  }

  func testВерхняяРучкаСохраняетГоризонтальныйЦентр() {
    let result = OwnShotCaptureGeometry.constrainedResize(CGRect(x: 100, y: 100, width: 400, height: 300), from: CGRect(x: 100, y: 100, width: 400, height: 200), aspectRatio: 2, within: CGRect(x: 0, y: 0, width: 1000, height: 800))
    XCTAssertEqual(result, CGRect(x: 0, y: 100, width: 600, height: 300))
  }

  func testЛеваяРучкаСохраняетПравуюГраницуИВертикальныйЦентр() {
    let result = OwnShotCaptureGeometry.constrainedResize(CGRect(x: 100, y: 200, width: 600, height: 200), from: CGRect(x: 300, y: 200, width: 400, height: 200), aspectRatio: 2, within: CGRect(x: 0, y: 0, width: 1000, height: 800))
    XCTAssertEqual(result, CGRect(x: 100, y: 150, width: 600, height: 300))
  }

  func testОграничениеЭкранаНеИскажаетПропорцииПриПеретаскивании() {
    let result = OwnShotCaptureGeometry.constrainedResize(CGRect(x: 100, y: 100, width: 1200, height: 220), from: CGRect(x: 100, y: 100, width: 400, height: 200), aspectRatio: 2, within: CGRect(x: 0, y: 0, width: 1000, height: 800))
    XCTAssertEqual(result, CGRect(x: 100, y: 100, width: 900, height: 450))
  }

  func testУгловаяРучкаНеТеряетЯкорьПриСтрогоВертикальномДвижении() {
    let result = OwnShotCaptureGeometry.constrainedResize(CGRect(x: 100, y: 100, width: 400, height: 300), from: CGRect(x: 100, y: 100, width: 400, height: 200), aspectRatio: 2, within: CGRect(x: 0, y: 0, width: 1000, height: 800), fixedAnchor: CGPoint(x: 0, y: 0))
    XCTAssertEqual(result, CGRect(x: 100, y: 100, width: 600, height: 300))
  }

  func testНижнийЛевыйУголСохраняетВерхнийПравыйПриГоризонтальномДвижении() {
    let result = OwnShotCaptureGeometry.constrainedResize(CGRect(x: 0, y: 100, width: 500, height: 200), from: CGRect(x: 100, y: 100, width: 400, height: 200), aspectRatio: 2, within: CGRect(x: 0, y: 0, width: 1000, height: 800), fixedAnchor: CGPoint(x: 1, y: 1))
    XCTAssertEqual(result, CGRect(x: 0, y: 50, width: 500, height: 250))
  }
}
