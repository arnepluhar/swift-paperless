# AirScan

Work-in-progress AirScan/eSCL support for Swift Paperless.

This package is not yet integrated into the app. It can retrieve and parse
scanner capabilities, but it cannot create scan jobs or import scanned pages.

## Implemented

- Validated HTTP and HTTPS scanner resource-root URLs.
- Namespace-aware ScannerCapabilities XML parsing.
- Separate flatbed, ADF simplex, and ADF duplex capabilities.
- Separate setting profiles with color modes, content types, document formats,
  and discrete X/Y resolutions.
- Supported intents per input source.
- Advertised scan dimensions in units of 1/300 inch.
- Global adjustment ranges, where advertised.
- Separate optional values for blank-page detection and detection with removal.
- Asynchronous read-only HTTP transport.
- Capability-response size limit of 2,000,000 bytes.
- No automatic HTTP redirects or TLS certificate-validation bypass.
- Command-line diagnostic tool that saves the successful raw response before
  parsing it.

Missing capability values remain unknown or absent. They must not be treated
as unsupported in every case, nor replaced with invented device defaults.

## Build and tests

Run from the AirScan directory:

```bash
swift test \
  --scratch-path "$HOME/Library/Caches/swift-paperless-AirScan-build"
```

A build outside the synchronized source directory avoided a codesigning failure
observed during development:

    resource fork, Finder information, or similar detritus not allowed

The exact origin of those file attributes has not been established.

## Capability diagnostic tool

Run from the AirScan directory, replacing the example address with the scanner's
actual advertised eSCL resource root:

```bash
swift run \
  --scratch-path "$HOME/Library/Caches/swift-paperless-AirScan-build" \
  airscan-diagnose \
  'http://SCANNER-IP/eSCL/' \
  /tmp/scanner-capabilities.xml
```

The tool only retrieves capabilities; it does not create a scan job.

The resource path is device-dependent. Do not assume that every scanner uses
/eSCL/. HTTP is unencrypted. HTTPS support depends on the device and its
certificate configuration.

The diagnostic output does not yet display every field parsed by the library,
including the recently added content types, supported intents, and blank-page
capabilities.

Raw capability XML may contain serial numbers, UUIDs, and local hostnames.
Review and redact it before sharing or committing it.

## Observed device: Canon MF750C II Series

A real capability retrieval over HTTP and parsing of its response succeeded
during development on 2026-10-27.

The supplied response advertises:

- Flatbed, ADF simplex, and ADF duplex.
- Grayscale8 and RGB24.
- 150x150 and 300x300 dpi.
- JPEG and PDF, plus application/octet-stream.
- Content types: Photo, Text, TextAndPhoto.
- Intents: Document, Photo, TextAndGraphic, Preview.
- Sharpening: minimum 1, maximum 7, normal 4, step 1.
- BlankPageDetection: false.
- BlankPageDetectionAndRemoval: true.
- Feeder capacity: 100.
- ADF options: DetectPaperLoaded and Duplex.
- ADF justification: Center horizontally and Top vertically.

Brightness, contrast, and gamma adjustment ranges are not advertised in this
response.

Feeder capacity, ADF options, and justification are not yet represented in the
capability model. Blank-page removal is represented as a capability but cannot
yet be requested in a scan job.

HTTP availability is confirmed. HTTPS availability has not been tested.
No actual flatbed, simplex, or duplex scan has been tested yet.

## Verification status

On 2026-10-27:

- Package and diagnostic executable built successfully on the developer's Mac.
- 21 XCTest tests passed with zero failures.
- Real HTTP capability retrieval succeeded.
- Client unit tests used a simulated transport.
- Real transport redirects, timeouts, size-limit handling, and in-flight
  cancellation have not been independently integration-tested.

## Current limitations and next steps

- Resolve setting-profile references.
- Support resolution ranges in addition to discrete resolutions.
- Extend device-response validation and add sanitized real-device fixtures.
- Model ADF justification, capacity, and options.
- Add scanner status, scan settings, job creation, page retrieval, and cleanup.
- Verify flatbed, ADF simplex, duplex page order, and cancellation on hardware.
- Add Bonjour discovery and saved scanner configuration.
- Add app UI, PDF assembly, and integration with existing document import.
- Add optional application-side image adjustments where appropriate.
- Configure and test local-network access in the iOS app.
- Perform device and TestFlight testing.

Advertised capabilities are not proof that a scan operation works.

## Scan-settings serialization

`ScanSettings` validates a requested source, region, color mode, output format,
and symmetric resolution against parsed capabilities before generating XML.

All selected profile-dependent values must coexist in a single setting profile.
Values from different profiles are not freely combined.

The initial serializer supports:

- Flatbed, ADF simplex, and ADF duplex source selection.
- Grayscale8 and RGB24.
- JPEG and PDF.
- Discrete symmetric resolutions.
- A single region with zero X/Y offsets.
- Explicit region dimensions in units of 1/300 inch.

Unknown region limits cause validation to fail rather than using guessed limits.

This serializer does not send scan jobs. Generated settings have not yet been
accepted by real hardware. ADF centering, custom offsets, content types, intents,
sharpening, and blank-page removal are not yet serialized.

Six additional unit tests cover settings generation and validation. Their
execution result must be checked locally.
