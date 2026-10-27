import Foundation

/// Read-only transport for small capability documents, not scanned page data.
public struct URLSessionScannerTransport: ScannerHTTPTransport {
  public init() {}

  public func get(_ url: URL) async throws -> ScannerHTTPResponse {
    try Task.checkCancellation()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 15
    configuration.timeoutIntervalForResource = 30
    configuration.urlCache = nil
    configuration.urlCredentialStorage = nil
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.waitsForConnectivity = false
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }

    var request = URLRequest(
      url: url,
      cachePolicy: .reloadIgnoringLocalCacheData,
      timeoutInterval: 15
    )
    request.httpMethod = "GET"
    request.setValue("application/xml, text/xml", forHTTPHeaderField: "Accept")

    let (bytes, response) = try await session.bytes(
      for: request,
      delegate: NoRedirectDelegate()
    )
    guard let http = response as? HTTPURLResponse else {
      throw CapabilitiesClientError.nonHTTPResponse
    }
    // Do not download error pages or redirect targets.
    guard http.statusCode == 200 else {
      return ScannerHTTPResponse(statusCode: http.statusCode, body: Data())
    }

    let limit = CapabilitiesClient.maximumResponseBytes
    if response.expectedContentLength > Int64(limit) {
      throw CapabilitiesClientError.responseTooLarge
    }
    var body = Data()
    for try await byte in bytes {
      try Task.checkCancellation()
      guard body.count < limit else {
        throw CapabilitiesClientError.responseTooLarge
      }
      body.append(byte)
    }
    try Task.checkCancellation()
    return ScannerHTTPResponse(statusCode: http.statusCode, body: body)
  }
}

/// Redirects are surfaced as HTTP errors; they are never followed implicitly.
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}
