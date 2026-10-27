import Foundation
import XCTest
@testable import AirScan

@MainActor
final class ScanJobClientTests: XCTestCase {
  private func endpoint() throws -> ScannerEndpoint {
    try ScannerEndpoint(
      resourceRoot: XCTUnwrap(URL(string: "http://scanner.local/eSCL/"))
    )
  }

  private func capabilities() throws -> ScannerCapabilities {
    let xml = """
      <s:ScannerCapabilities
        xmlns:s="http://schemas.hp.com/imaging/escl/2011/05/03"
        xmlns:p="http://www.pwg.org/schemas/2010/12/sm">
        <s:Platen>
          <s:PlatenInputCaps>
            <s:MinWidth>32</s:MinWidth>
            <s:MaxWidth>2550</s:MaxWidth>
            <s:MinHeight>32</s:MinHeight>
            <s:MaxHeight>3508</s:MaxHeight>
            <s:SettingProfiles>
              <s:SettingProfile>
                <s:ColorModes>
                  <s:ColorMode>RGB24</s:ColorMode>
                </s:ColorModes>
                <s:DocumentFormats>
                  <p:DocumentFormat>image/jpeg</p:DocumentFormat>
                </s:DocumentFormats>
                <s:SupportedResolutions>
                  <s:DiscreteResolutions>
                    <s:DiscreteResolution>
                      <s:XResolution>150</s:XResolution>
                      <s:YResolution>150</s:YResolution>
                    </s:DiscreteResolution>
                  </s:DiscreteResolutions>
                </s:SupportedResolutions>
              </s:SettingProfile>
            </s:SettingProfiles>
          </s:PlatenInputCaps>
        </s:Platen>
      </s:ScannerCapabilities>
      """
    return try CapabilitiesParser.parse(Data(xml.utf8))
  }

  private func settings() -> ScanSettings {
    ScanSettings(
      source: .platen,
      colorMode: .color,
      documentFormat: .jpeg,
      resolution: 150,
      width: 2480,
      height: 3508
    )
  }

  func testCreatesJobAndSendsXML() async throws {
    let transport = JobStub([
      .init(statusCode: 201, location: "/eSCL/ScanJobs/job-1")
    ])
    let client = ScanJobClient(endpoint: try endpoint(), transport: transport)

    let job = try await client.createJob(
      settings: settings(),
      capabilities: capabilities()
    )

    XCTAssertEqual(job.url.absoluteString, "http://scanner.local/eSCL/ScanJobs/job-1")

    let requests = await transport.requests
    let request = try XCTUnwrap(requests.first)
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.url?.path, "/eSCL/ScanJobs")
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "Content-Type"),
      "text/xml; charset=utf-8"
    )
    XCTAssertFalse(try XCTUnwrap(request.httpBody).isEmpty)
  }

  func testAcceptsRelativeAndSameOriginAbsoluteLocations() async throws {
    for location in [
      "ScanJobs/job-1",
      "/eSCL/ScanJobs/job-1",
      "http://scanner.local/eSCL/ScanJobs/job-1",
      "http://scanner.local:80/eSCL/ScanJobs/job-1",
    ] {
      let transport = JobStub([.init(statusCode: 201, location: location)])
      let client = ScanJobClient(endpoint: try endpoint(), transport: transport)

      let job = try await client.createJob(
        settings: settings(),
        capabilities: capabilities()
      )

      XCTAssertEqual(job.url.path, "/eSCL/ScanJobs/job-1")
    }
  }

  func testRejectsUnsafeLocations() async throws {
    for location in [
      "http://other.local/eSCL/ScanJobs/job-1",
      "https://scanner.local/eSCL/ScanJobs/job-1",
      "http://scanner.local:8080/eSCL/ScanJobs/job-1",
      "http://user@scanner.local/eSCL/ScanJobs/job-1",
      "/admin",
      "/eSCL/ScanJobs/job-1?secret=value",
      "/eSCL/ScanJobs/job-1#fragment",
      "/eSCL/ScanJobs/job-1/NextDocument",
      "/eSCL/ScanJobs/%2E%2E",
    ] {
      let transport = JobStub([.init(statusCode: 201, location: location)])
      let client = ScanJobClient(endpoint: try endpoint(), transport: transport)

      do {
        _ = try await client.createJob(
          settings: settings(),
          capabilities: capabilities()
        )
        XCTFail("Expected unsafe Location rejection: \(location)")
      } catch let error as ScanJobError {
        XCTAssertEqual(error, .unsafeLocation)
      }
    }
  }

  func testRejectsMissingLocation() async throws {
    let transport = JobStub([.init(statusCode: 201)])
    let client = ScanJobClient(endpoint: try endpoint(), transport: transport)

    do {
      _ = try await client.createJob(
        settings: settings(),
        capabilities: capabilities()
      )
      XCTFail("Expected missing Location")
    } catch let error as ScanJobError {
      XCTAssertEqual(error, .missingLocation)
    }
  }

  func testDoesNotRetryRejectedCreation() async throws {
    let transport = JobStub([.init(statusCode: 503)])
    let client = ScanJobClient(endpoint: try endpoint(), transport: transport)

    do {
      _ = try await client.createJob(
        settings: settings(),
        capabilities: capabilities()
      )
      XCTFail("Expected HTTP error")
    } catch let error as ScanJobError {
      XCTAssertEqual(error, .httpStatus(operation: "create", status: 503))
    }

    let requests = await transport.requests
    XCTAssertEqual(requests.count, 1)
  }

  func testRetrievesDocumentThenEndOfDocuments() async throws {
    let image = Data([0xFF, 0xD8, 0xFF, 0xD9])
    let transport = JobStub([
      .init(statusCode: 201, location: "/eSCL/ScanJobs/job-1"),
      .init(statusCode: 200, body: image, contentType: "image/jpeg"),
      .init(statusCode: 404),
    ])
    let client = ScanJobClient(endpoint: try endpoint(), transport: transport)
    let job = try await client.createJob(
      settings: settings(),
      capabilities: capabilities()
    )

    let document = try await client.nextDocument(for: job)
    XCTAssertEqual(document?.data, image)
    XCTAssertEqual(document?.contentType, "image/jpeg")

    let end = try await client.nextDocument(for: job)
    XCTAssertNil(end)

    let requests = await transport.requests
    XCTAssertEqual(requests.count, 3)
    XCTAssertEqual(requests[1].httpMethod, "GET")
    XCTAssertEqual(requests[1].url?.path, "/eSCL/ScanJobs/job-1/NextDocument")
  }

  func testRejectsEmptySuccessfulDocument() async throws {
    let transport = JobStub([
      .init(statusCode: 201, location: "/eSCL/ScanJobs/job-1"),
      .init(statusCode: 200),
    ])
    let client = ScanJobClient(endpoint: try endpoint(), transport: transport)
    let job = try await client.createJob(
      settings: settings(),
      capabilities: capabilities()
    )

    do {
      _ = try await client.nextDocument(for: job)
      XCTFail("Expected empty document error")
    } catch let error as ScanJobError {
      XCTAssertEqual(error, .emptyDocument)
    }
  }

  func testDeletesJobAndAcceptsAlreadyMissingJob() async throws {
    for status in [200, 204, 404, 410] {
      let transport = JobStub([
        .init(statusCode: 201, location: "/eSCL/ScanJobs/job-1"),
        .init(statusCode: status),
      ])
      let client = ScanJobClient(endpoint: try endpoint(), transport: transport)
      let job = try await client.createJob(
        settings: settings(),
        capabilities: capabilities()
      )

      try await client.deleteJob(job)

      let requests = await transport.requests
      XCTAssertEqual(requests.count, 2)
      XCTAssertEqual(requests[1].httpMethod, "DELETE")
      XCTAssertEqual(requests[1].url, job.url)
    }
  }
}

private actor JobStub: ScanJobTransport {
  private var responses: [ScanJobHTTPResponse]
  private(set) var requests: [URLRequest] = []

  init(_ responses: [ScanJobHTTPResponse]) {
    self.responses = responses
  }

  func send(_ request: URLRequest) async throws -> ScanJobHTTPResponse {
    requests.append(request)
    guard !responses.isEmpty else {
      throw URLError(.badServerResponse)
    }
    return responses.removeFirst()
  }
}
