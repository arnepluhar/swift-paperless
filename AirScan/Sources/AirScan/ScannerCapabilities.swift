import Foundation

public struct ScannerCapabilities: Sendable, Equatable {
  public enum Source: String, Sendable, CaseIterable {
    case platen, feederSimplex, feederDuplex
  }

  public struct Resolution: Sendable, Equatable {
    public let x: Int
    public let y: Int
  }

  /// Profiles remain separate: their values must not be freely cross-combined.
  public struct Profile: Sendable, Equatable {
    public let colorModes: [String]
    public let contentTypes: [String]
    public let documentFormats: [String]
    public let resolutions: [Resolution]
  }

  public struct Input: Sendable, Equatable {
    public let source: Source
    /// eSCL dimensions in 1/300 inch; nil means not advertised.
    public let minWidth: Int?
    public let maxWidth: Int?
    public let minHeight: Int?
    public let maxHeight: Int?
    public let profiles: [Profile]
    public let supportedIntents: [String]
  }

  public struct AdjustmentRange: Sendable, Equatable {
    public let minimum: Int
    public let maximum: Int
    public let normal: Int?
    public let step: Int?
  }

  public enum Adjustment: String, Sendable, CaseIterable {
    case brightness = "BrightnessSupport"
    case contrast = "ContrastSupport"
    case gamma = "GammaSupport"
    case threshold = "ThresholdSupport"
    case sharpen = "SharpenSupport"
    case noiseRemoval = "NoiseRemovalSupport"
    case shadow = "ShadowSupport"
    case highlight = "HighlightSupport"
    case compression = "CompressionFactorSupport"
  }

  public let makeAndModel: String?
  public let blankPageDetection: Bool?
  public let blankPageDetectionAndRemoval: Bool?
  public let inputs: [Input]
  public let adjustments: [Adjustment: AdjustmentRange]
}
