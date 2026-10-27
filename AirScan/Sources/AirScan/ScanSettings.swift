import Foundation

public enum ScanSettingsError: Error, Equatable, Sendable {
  case unsupportedSource
  case invalidDimensions
  case unknownDimensionLimits
  case unsupportedProfileCombination
}

public struct ScanSettings: Sendable {
  public enum ColorMode: String, Sendable {
    case grayscale = "Grayscale8"
    case color = "RGB24"
  }

  public enum DocumentFormat: String, Sendable {
    case jpeg = "image/jpeg"
    case pdf = "application/pdf"
  }

  public let source: ScannerCapabilities.Source
  public let colorMode: ColorMode
  public let documentFormat: DocumentFormat
  public let resolution: Int

  /// Region dimensions in 1/300 inch, not pixels at the selected resolution.
  public let width: Int
  public let height: Int

  public init(
    source: ScannerCapabilities.Source,
    colorMode: ColorMode,
    documentFormat: DocumentFormat,
    resolution: Int,
    width: Int,
    height: Int
  ) {
    self.source = source
    self.colorMode = colorMode
    self.documentFormat = documentFormat
    self.resolution = resolution
    self.width = width
    self.height = height
  }

  public func xml(validating capabilities: ScannerCapabilities) throws -> Data {
    guard let input = capabilities.inputs.first(where: { $0.source == source }) else {
      throw ScanSettingsError.unsupportedSource
    }

    guard width > 0, height > 0, resolution > 0 else {
      throw ScanSettingsError.invalidDimensions
    }

    guard let minWidth = input.minWidth,
          let maxWidth = input.maxWidth,
          let minHeight = input.minHeight,
          let maxHeight = input.maxHeight else {
      throw ScanSettingsError.unknownDimensionLimits
    }

    guard minWidth <= maxWidth, minHeight <= maxHeight,
          width >= minWidth, width <= maxWidth,
          height >= minHeight, height <= maxHeight else {
      throw ScanSettingsError.invalidDimensions
    }

    // All selected values must occur together in ONE advertised profile.
    let matchingProfile = input.profiles.contains { profile in
      profile.colorModes.contains(colorMode.rawValue)
        && profile.documentFormats.contains(documentFormat.rawValue)
        && profile.resolutions.contains {
          $0.x == resolution && $0.y == resolution
        }
    }

    guard matchingProfile else {
      throw ScanSettingsError.unsupportedProfileCombination
    }

    let inputSource = source == .platen ? "Platen" : "Feeder"
    let duplexElement: String

    switch source {
    case .platen:
      duplexElement = ""
    case .feederSimplex:
      duplexElement = "<scan:Duplex>false</scan:Duplex>"
    case .feederDuplex:
      duplexElement = "<scan:Duplex>true</scan:Duplex>"
    }

    // All interpolated text values are fixed enum tokens or validated integers.
    return Data("""
      <?xml version="1.0" encoding="UTF-8"?>
      <scan:ScanSettings
        xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm"
        xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03">
        <pwg:Version>2.0</pwg:Version>
        <pwg:ScanRegions>
          <pwg:ScanRegion>
            <pwg:ContentRegionUnits>escl:ThreeHundredthsOfInches</pwg:ContentRegionUnits>
            <pwg:XOffset>0</pwg:XOffset>
            <pwg:YOffset>0</pwg:YOffset>
            <pwg:Width>\(width)</pwg:Width>
            <pwg:Height>\(height)</pwg:Height>
          </pwg:ScanRegion>
        </pwg:ScanRegions>
        <pwg:InputSource>\(inputSource)</pwg:InputSource>
        <pwg:DocumentFormat>\(documentFormat.rawValue)</pwg:DocumentFormat>
        <scan:ColorMode>\(colorMode.rawValue)</scan:ColorMode>
        <scan:XResolution>\(resolution)</scan:XResolution>
        <scan:YResolution>\(resolution)</scan:YResolution>
        \(duplexElement)
      </scan:ScanSettings>
      """.utf8)
  }
}
