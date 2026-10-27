import Foundation

public struct ScanJobHTTPResponse: Sendable {
  public let statusCode: Int
  public let body: Data
  public let location: String?
  public let contentType: String?

  public init(
    statusCode: Int,
    body: Data = Data(),
    location: String? = nil,
    contentType: String? = nil
  ) {
    self.statusCode = statusCode
    self.body = body
    self.location = location
    self.contentType = contentType
  }
}

public protocol ScanJobTransport: Sendable {
  func send(_ request: URLRequest) async throws -> ScanJobHTTPResponse
}

public enum ScanJobError: Error, Equatable, Sendable {
  case httpStatus(operation: String, status: Int)
  case missingLocation
  case unsafeLocation
  case emptyDocument
}

public struct ScanJob: Sendable, Equatable {
  public let url: URL

  // Only the validated client path creates job handles.
  fileprivate init(url: URL) {
    self.url = url
  }
}

public struct ScannedDocument: Sendable {
  public let data: Data
  public let contentType: String?
}

public struct ScanJobClient: Sendable {
  private let endpoint: ScannerEndpoint
  private let transport: any ScanJobTransport

  public init(
    endpoint: ScannerEndpoint,
    transport: any ScanJobTransport
  ) {
    self.endpoint = endpoint
    self.transport = transport
  }

  /// A failed or interrupted POST must not be retried automatically.
  public func createJob(
    settings: ScanSettings,
    capabilities: ScannerCapabilities
  ) async throws -> ScanJob {
    let body = try settings.xml(validating: capabilities)
    try Task.checkCancellation()

    var request = URLRequest(url: endpoint.jobsURL)
    request.httpMethod = "POST"
    request.httpBody = body
    request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")

    let response = try await transport.send(request)

    guard response.statusCode == 201 else {
      throw ScanJobError.httpStatus(
        operation: "create",
        status: response.statusCode
      )
    }
    guard let location = response.location, !location.isEmpty else {
      throw ScanJobError.missingLocation
    }

    // Resolve the handle before any further cancellation check so that a
    // received, valid Location is not discarded merely due to cancellation.
    return ScanJob(url: try resolveJobLocation(location))
  }

  /// Returns nil when the device reports no further document via HTTP 404.
  /// This alone is not proof that every expected page was received.
  public func nextDocument(for job: ScanJob) async throws -> ScannedDocument? {
    let jobURL = try resolveJobLocation(job.url.absoluteString)
    try Task.checkCancellation()

    var request = URLRequest(
      url: jobURL.appendingPathComponent("NextDocument")
    )
    request.httpMethod = "GET"

    let response = try await transport.send(request)
    try Task.checkCancellation()

    if response.statusCode == 404 {
      return nil
    }

    guard response.statusCode == 200 else {
      throw ScanJobError.httpStatus(
        operation: "nextDocument",
        status: response.statusCode
      )
    }
    guard !response.body.isEmpty else {
      throw ScanJobError.emptyDocument
    }

    return ScannedDocument(
      data: response.body,
      contentType: response.contentType
    )
  }

  /// Explicit cleanup operation. A missing job is treated as already removed.
  /// Cleanup from a cancelled scan will later run in a separate bounded task.
  public func deleteJob(_ job: ScanJob) async throws {
    let jobURL = try resolveJobLocation(job.url.absoluteString)

    var request = URLRequest(url: jobURL)
    request.httpMethod = "DELETE"

    let response = try await transport.send(request)
    guard [200, 204, 404, 410].contains(response.statusCode) else {
      throw ScanJobError.httpStatus(
        operation: "delete",
        status: response.statusCode
      )
    }
  }

  private func resolveJobLocation(_ location: String) throws -> URL {
    guard location == location.trimmingCharacters(in: .whitespacesAndNewlines),
          !location.isEmpty,
          let resolved = URL(
            string: location,
            relativeTo: endpoint.jobsURL
          )?.absoluteURL,
          let candidate = URLComponents(
            url: resolved,
            resolvingAgainstBaseURL: false
          ),
          let origin = URLComponents(
            url: endpoint.resourceRoot,
            resolvingAgainstBaseURL: false
          ),
          candidate.scheme?.lowercased() == origin.scheme?.lowercased(),
          candidate.host?.lowercased() == origin.host?.lowercased(),
          effectivePort(candidate) == effectivePort(origin),
          candidate.user == nil,
          candidate.password == nil,
          candidate.query == nil,
          candidate.fragment == nil else {
      throw ScanJobError.unsafeLocation
    }

    let prefix = endpoint.jobsURL.path + "/"
    let path = candidate.path

    guard path.hasPrefix(prefix) else {
      throw ScanJobError.unsafeLocation
    }

    // The current client accepts a single job-ID path component only.
    let identifier = String(path.dropFirst(prefix.count))
    guard !identifier.isEmpty,
          identifier != ".",
          identifier != "..",
          !identifier.contains("/"),
          !identifier.contains("\\"),
          !identifier.contains("%"),
          !identifier.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
          }) else {
      throw ScanJobError.unsafeLocation
    }

    return resolved
  }

  private func effectivePort(_ components: URLComponents) -> Int? {
    if let port = components.port {
      return port
    }
    switch components.scheme?.lowercased() {
    case "http": return 80
    case "https": return 443
    default: return nil
    }
  }
}
