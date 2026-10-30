import AirScan
import SwiftUI

@MainActor
final class AirScanSelectionModel: ObservableObject {
  struct Option: Identifiable {
    let source: ScannerCapabilities.Source
    let color: ScanSettings.ColorMode
    let resolution: Int
    let width: Int
    let height: Int

    var id: String {
      "\(source.rawValue)-\(color.rawValue)-\(resolution)-\(width)-\(height)"
    }

    var settings: ScanSettings {
      ScanSettings(
        source: source,
        colorMode: color,
        documentFormat: .jpeg,
        resolution: resolution,
        width: width,
        height: height
      )
    }
  }

  @Published private(set) var options: [Option] = []
  @Published var source: ScannerCapabilities.Source = .platen
  @Published var color: ScanSettings.ColorMode = .color
  @Published var resolution = 300
  @Published var expectedPages = 1

  var sources: [ScannerCapabilities.Source] {
    ScannerCapabilities.Source.allCases.filter { candidate in
      options.contains { $0.source == candidate }
    }
  }

  var colors: [ScanSettings.ColorMode] {
    [ScanSettings.ColorMode.color, .grayscale].filter { candidate in
      options.contains {
        $0.source == source && $0.color == candidate
      }
    }
  }

  var resolutions: [Int] {
    Array(Set(options.filter {
      $0.source == source && $0.color == color
    }.map(\.resolution))).sorted()
  }

  var selectedOption: Option? {
    options.first {
      $0.source == source
        && $0.color == color
        && $0.resolution == resolution
    }
  }

  func configure(_ capabilities: ScannerCapabilities?) {
    options = []
    expectedPages = 1
    guard let capabilities else { return }

    var seen = Set<String>()

    for input in capabilities.inputs {
      guard let minWidth = input.minWidth,
            let maxWidth = input.maxWidth,
            let minHeight = input.minHeight,
            let maxHeight = input.maxHeight,
            minWidth > 0, minHeight > 0,
            minWidth <= maxWidth,
            minHeight <= maxHeight else {
        continue
      }

      for profile in input.profiles
      where profile.documentFormats.contains("image/jpeg") {
        for rawColor in profile.colorModes {
          guard let color = ScanSettings.ColorMode(rawValue: rawColor) else {
            continue
          }

          for dpi in profile.resolutions
          where dpi.x == dpi.y && dpi.x > 0 {
            let option = Option(
              source: input.source,
              color: color,
              resolution: dpi.x,
              width: maxWidth,
              height: maxHeight
            )

            guard (try? option.settings.xml(validating: capabilities)) != nil,
                  seen.insert(option.id).inserted else {
              continue
            }

            options.append(option)
          }
        }
      }
    }

    normalize()
  }

  func normalize() {
    guard let firstSource = sources.first else { return }

    if !sources.contains(source) {
      source = firstSource
    }

    if !colors.contains(color), let firstColor = colors.first {
      color = firstColor
    }

    if !resolutions.contains(resolution) {
      resolution = resolutions.contains(300)
        ? 300
        : (resolutions.first ?? 300)
    }
  }

  static func sourceName(_ source: ScannerCapabilities.Source) -> String {
    switch source {
    case .platen: "Flachbett"
    case .feederSimplex: "Einzug – einseitig"
    case .feederDuplex: "Einzug – beidseitig"
    }
  }

  static func colorName(_ color: ScanSettings.ColorMode) -> String {
    switch color {
    case .color: "Farbe"
    case .grayscale: "Graustufen"
    }
  }
}
