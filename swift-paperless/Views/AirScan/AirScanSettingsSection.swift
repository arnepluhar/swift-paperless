import AirScan
import SwiftUI

@MainActor
struct AirScanSettingsSection: View {
  @ObservedObject var selection: AirScanSelectionModel
  let isBusy: Bool

  var body: some View {
    Section {
      if selection.options.isEmpty {
        Text(
          "Keine unterstützte JPEG-Scan-Kombination mit "
            + "vollständigen Größenangaben gefunden."
        )
        .foregroundStyle(.secondary)
      } else {
        Picker("Quelle", selection: $selection.source) {
          ForEach(selection.sources, id: \.rawValue) { source in
            Text(AirScanSelectionModel.sourceName(source))
              .tag(source)
          }
        }

        Picker("Farbe", selection: $selection.color) {
          ForEach(selection.colors, id: \.rawValue) { color in
            Text(AirScanSelectionModel.colorName(color))
              .tag(color)
          }
        }

        Picker("Auflösung", selection: $selection.resolution) {
          ForEach(selection.resolutions, id: \.self) { resolution in
            Text("\(resolution) dpi")
              .tag(resolution)
          }
        }

        if selection.source != .platen {
          Stepper(
            "Erwartete Bildseiten: \(selection.expectedPages)",
            value: $selection.expectedPages,
            in: 1...100
          )

          Text(
            "Bei Duplex Vorder- und Rückseiten einzeln zählen. "
              + "Die aktuelle Einzugsroutine verlangt eine genaue Seitenzahl."
          )
          .font(.footnote)
          .foregroundStyle(.secondary)
        }

        if let option = selection.selectedOption {
          LabeledContent(
            "Scanbereich",
            value: "\(option.width) × \(option.height)"
          )

          Text(
            "Maximaler Gerätebereich in Einheiten von 1/300 Zoll. "
              + "Das Seitenformat für die Übertragung ist JPEG."
          )
          .font(.footnote)
          .foregroundStyle(.secondary)
        }
      }
    } header: {
      Text("Scan-Einstellungen")
    } footer: {
      Text(
        "Vorbereitung der Scan-Bedienung. "
          + "In diesem Entwicklungsschritt wird noch kein Scan gestartet."
      )
    }
    .disabled(isBusy)
    .onChange(of: selection.source) { _, _ in
      selection.normalize()
    }
    .onChange(of: selection.color) { _, _ in
      selection.normalize()
    }
  }
}
