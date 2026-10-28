import Foundation
import XCTest
@testable import AirScan

final class ScannerStatusTests: XCTestCase {
  private func document(
    state: String = "Idle",
    adf: String = "ScannerAdfLoaded",
    jobs: String = ""
  ) -> Data {
    Data("""
      <s:ScannerStatus
        xmlns:s="http://schemas.hp.com/imaging/escl/2011/05/03"
        xmlns:p="http://www.pwg.org/schemas/2010/12/sm">
        <p:State>\(state)</p:State>
        <s:AdfState>\(adf)</s:AdfState>
        <s:Jobs>\(jobs)</s:Jobs>
      </s:ScannerStatus>
      """.utf8)
  }

  private var completedJobs: String {
    """
    <s:JobInfo>
      <p:JobUri>/eSCL/ScanJobs/old</p:JobUri>
      <p:ImagesCompleted>0</p:ImagesCompleted>
      <p:JobState>Canceled</p:JobState>
    </s:JobInfo>
    <s:JobInfo>
      <p:JobUri>/eSCL/ScanJobs/current</p:JobUri>
      <p:ImagesCompleted>3</p:ImagesCompleted>
      <p:JobState>Completed</p:JobState>
      <p:JobStateReasons>
        <p:JobStateReason>JobCompletedSuccessfully</p:JobStateReason>
      </p:JobStateReasons>
    </s:JobInfo>
    """
  }

  func testAllowsLoadedIdleFeeder() throws {
    let status = try ScannerStatusParser.parse(document())
    XCTAssertNoThrow(try status.requireFeederReady())

    let unknown = try ScannerStatusParser.parse(document(adf: "UnknownState"))
    XCTAssertThrowsError(try unknown.requireFeederReady())
  }

  func testRejectsPaperJamBeforeGeneralStoppedState() throws {
    let status = try ScannerStatusParser.parse(
      document(state: "Stopped", adf: "ScannerAdfJam")
    )

    XCTAssertThrowsError(try status.requireFeederReady()) { error in
      XCTAssertEqual(error as? ScannerStatusError, .paperJam)
    }
  }

  func testRejectsEmptyFeeder() throws {
    let status = try ScannerStatusParser.parse(
      document(adf: "ScannerAdfEmpty")
    )

    XCTAssertThrowsError(try status.requireFeederReady()) { error in
      XCTAssertEqual(error as? ScannerStatusError, .feederEmpty)
    }
  }

  func testMatchesCompletedJobInsteadOfHistoricalCanceledJob() throws {
    let status = try ScannerStatusParser.parse(document(
      adf: "ScannerAdfEmpty",
      jobs: completedJobs
    ))

    let job = try XCTUnwrap(
      URL(string: "http://scanner.local/eSCL/ScanJobs/current")
    )
    let root = try XCTUnwrap(URL(string: "http://scanner.local/eSCL/"))

    XCTAssertEqual(status.jobs.count, 2)
    XCTAssertNoThrow(try status.requireCompleted(
      jobURL: job,
      resourceRoot: root,
      receivedPages: 3
    ))
  }

  func testRejectsWrongJobOrPageCount() throws {
    let status = try ScannerStatusParser.parse(document(jobs: completedJobs))
    let root = try XCTUnwrap(URL(string: "http://scanner.local/eSCL/"))

    for (name, count) in [("old", 3), ("missing", 3), ("current", 2)] {
      let job = try XCTUnwrap(
        URL(string: "http://scanner.local/eSCL/ScanJobs/\(name)")
      )

      XCTAssertThrowsError(try status.requireCompleted(
        jobURL: job,
        resourceRoot: root,
        receivedPages: count
      ))
    }
  }

  func testRejectsMalformedXMLAndWrongNamespace() {
    XCTAssertThrowsError(
      try ScannerStatusParser.parse(Data("<broken>".utf8))
    )
    XCTAssertThrowsError(
      try ScannerStatusParser.parse(Data("<ScannerStatus/>".utf8))
    )
  }
}
