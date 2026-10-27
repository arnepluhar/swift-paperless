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

## Scan-job protocol client

`ScanJobClient` provides explicit operations for:

- Creating a job with validated settings.
- Resolving its Location header.
- Retrieving the next document.
- Deleting a job.

The client requires an injected `ScanJobTransport`. A production transport for
these operations is not implemented yet.

Location validation currently requires the same scheme, host, and effective port
as the scanner endpoint, and one job-ID component beneath its ScanJobs path.
A hostname alias returned for an IP-based endpoint is deliberately rejected
until explicit device-identity handling is implemented.

Creation is never automatically retried. If creation may have succeeded but no
usable Location was received, the job state is uncertain.

HTTP 404 from NextDocument returns nil. This alone does not establish that all
expected pages were received. Scanner-status interpretation and handling of
early, transient, or erroneous end responses remain to be implemented.

Deletion is explicit. The full scan coordinator must still implement bounded
cleanup after success, errors, and cancellation, without hiding cleanup failures.

Document responses currently use Data in the transport contract. File-backed
transfer and resource limits for production scanning remain pending.

Eight additional unit tests use simulated responses. No real scan job has yet
been submitted or deleted by this implementation.

## Experimental single-page flatbed scan

The package now includes:

- A URLSession transport for POST, GET, and DELETE job operations.
- A single-page flatbed JPEG coordinator.
- Explicit cleanup attempts after successful reads, errors, and task cancellation.
- A separate `airscan-scan-flatbed` executable requiring `--scan`.

The diagnostic executable remains read-only.

Example, from the AirScan directory:

```bash
swift run \
  --scratch-path "$HOME/Library/Caches/swift-paperless-AirScan-build" \
  airscan-scan-flatbed \
  --scan \
  'http://SCANNER-IP/eSCL/' \
  /tmp/flatbed-001.jpg

WARNING: This command creates a real scan job.
Initial settings are fixed: flatbed, RGB24, 150 dpi, JPEG, region 2480 x 3508
in units of 1/300 inch, with zero offsets.
The tool decodes the returned JPEG before saving and refuses to overwrite an
existing output file. It does not yet preserve undecodable response data.
Production document responses currently buffer one page in memory, limited to
64 MiB. Other response bodies are limited to 64 KiB. File-backed transfer remains
pending.
The transport does not follow redirects or disable TLS validation. Resource
timeouts are 120 seconds for GET and 30 seconds for POST/DELETE.
Cleanup runs in a separate task so scan-task cancellation does not immediately
cancel cleanup. The production DELETE transfer has a bounded resource timeout.
Forced process termination, including terminal interruption, does not guarantee
cleanup.
If document retrieval succeeds but cleanup fails, the result retains the
document and exposes a warning. If both fail, both errors are reported.
An accepted POST without a usable returned job handle remains an uncertain
state. Creation is not automatically retried.
Four additional coordinator tests use a simulated transport. Real flatbed
acceptance, image quality, cancellation, and cleanup behavior require device
testing. ADF and duplex are not yet supported by this executable.

### First successful real-device flatbed scan

On 2026-10-27, the Canon MF750C II Series successfully completed the
experimental flatbed workflow over HTTP:

- Capabilities retrieved.
- Job created with RGB24, 150 dpi, JPEG, and region 2480 x 3508.
- One document retrieved and decoded as JPEG.
- Output size: 328,987 bytes.
- Decoded image dimensions: 1232 x 1744 pixels.
- Cleanup returned an accepted deletion status or an already-removed status.

This confirms the basic single-page workflow. Visual image quality, requested
region fidelity, repeatability, cancellation, ADF, and duplex remain separate
verification tasks.

### Direct PDF output and repeatability testing

The flatbed executable now selects the scanner-requested format from the output
extension: .jpg/.jpeg requests image/jpeg; .pdf requests application/pdf.
This is direct scanner output, not JPEG-to-PDF conversion.

The coordinator now accepts flatbed JPEG and PDF settings. Earlier descriptions
restricting it to JPEG are superseded by this section.

For PDF output, the tool requires a readable, unlocked, single-page PDF and
reports page dimensions and the number of characters extractable through PDFKit.
The original response bytes are saved unchanged.

Extractable text is an observation about the received PDF, not a general claim
that AirScan exposes a selectable scanner-OCR function. The supplied Canon
capabilities do not advertise an explicit OCR setting.

Repeatability must be checked with consecutive real-device scans. A cleanup
warning causes the tool to exit nonzero after saving the valid document, stopping
the example scan loop.

One additional unit test verifies PDF format selection and cleanup sequencing.
PDF decoding, text extraction, and repeated device operation require hardware
verification.

### Successful consecutive PDF scans

On 2026-10-27, two consecutive real-device flatbed scans on the Canon
MF750C II Series succeeded using RGB24, 150 dpi, direct application/pdf output,
and a region of 2480 x 3508.

Both responses:
- Decoded as readable single-page PDFs.
- Reported a page size of 595.2 x 841.44 PDF points.
- Contained zero characters extractable through PDFKit.
- Completed cleanup with an accepted deletion or already-removed status.

Response sizes were 335,151 and 335,058 bytes.

This verifies repeatability for this particular flatbed workflow. It does not
establish visual image quality, all settings combinations, ADF operation, duplex,
or cancellation behavior.

No extractable text layer was found in these two scanner-generated PDFs.
This does not establish that the device lacks OCR through other workflows.
