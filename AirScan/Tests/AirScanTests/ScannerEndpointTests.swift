import Foundation
import XCTest
@testable import AirScan

final class ScannerEndpointTests: XCTestCase {
  func testPreservesHTTPPortAndResourcePath() throws {
    let endpoint = try ScannerEndpoint(resourceRoot: XCTUnwrap(URL(string: "http://scanner.local:8080/vendor/eSCL")))
    XCTAssertEqual(endpoint.resourceRoot.absoluteString, "http://scanner.local:8080/vendor/eSCL/")
    XCTAssertEqual(endpoint.capabilitiesURL.absoluteString, "http://scanner.local:8080/vendor/eSCL/ScannerCapabilities")
    XCTAssertEqual(endpoint.statusURL.lastPathComponent, "ScannerStatus")
    XCTAssertEqual(endpoint.jobsURL.lastPathComponent, "ScanJobs")
    XCTAssertFalse(endpoint.isEncrypted)
  }

  func testPreservesHTTPS() throws {
    let endpoint = try ScannerEndpoint(resourceRoot: XCTUnwrap(URL(string: "https://scanner.local/eSCL/")))
    XCTAssertTrue(endpoint.isEncrypted)
    XCTAssertEqual(endpoint.jobsURL.scheme, "https")
  }

  func testPreservesEscapedResourcePath() throws {
    let endpoint = try ScannerEndpoint(resourceRoot: XCTUnwrap(URL(string: "http://scanner.local/scan%20service/")))
    XCTAssertEqual(endpoint.capabilitiesURL.absoluteString, "http://scanner.local/scan%20service/ScannerCapabilities")
  }

  func testRejectsInvalidEndpointComponents() throws {
    for address in [
      "ftp://scanner.local/eSCL/",
      "http://user:password@scanner.local/eSCL/",
      "http://scanner.local/eSCL/?token=secret",
      "http://scanner.local/eSCL/#fragment",
      "/eSCL/",
    ] {
      let url = try XCTUnwrap(URL(string: address))
      XCTAssertThrowsError(try ScannerEndpoint(resourceRoot: url), address)
    }
  }
}
