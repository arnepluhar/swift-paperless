import AirScan
import SwiftUI

@MainActor
struct AirScanScannerView: View {
  @Environment(\.dismiss) private var dismiss
  @StateObject private var model = AirScanScannerModel()
  @StateObject private var discovery = AirScanDiscoveryModel()
  @State private var manualExpanded = false

  @AppStorage("airscan.manualResourceRoot")
  private var address = ""

  @AppStorage("airscan.debugPanelEnabled")
  private var debugEnabled = false

  var body: some View {
    NavigationStack {
      Form {
        Section {
          if discovery.isSearching {
            ProgressView("Scanner werden gesucht …")
          }

          if discovery.devices.isEmpty {
            Text("Noch keine Scanner gefunden.")
              .foregroundStyle(.secondary)
          }

          ForEach(discovery.devices) { device in
            VStack(alignment: .leading, spacing: 8) {
              Text(device.name)
                .font(.headline)

              ForEach(device.endpoints) { endpoint in
                Button {
                  select(endpoint)
                } label: {
                  VStack(alignment: .leading, spacing: 3) {
                    Label(
                      endpoint.isEncrypted
                        ? "Verbinden über HTTPS"
                        : "Verbinden über HTTP",
                      systemImage: endpoint.isEncrypted
                        ? "lock"
                        : "lock.open"
                    )

                    Text(endpoint.resourceRoot.absoluteString)
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                }
                .disabled(model.isBusy)
              }
            }
            .padding(.vertical, 4)
          }

          Button("Erneut suchen") {
            discovery.start()
          }
          .disabled(model.isBusy)

          if let message = discovery.errorMessage {
            Text(message)
              .font(.footnote)
              .foregroundStyle(.orange)
          }
        } header: {
          Text("Gefundene Scanner")
        } footer: {
          Text(
            "Die Suche verwendet Bonjour im lokalen Netzwerk. "
              + "Eine Adresse ist nur als Fallback erforderlich."
          )
        }

        Section {
          DisclosureGroup(
            "Adresse manuell eingeben",
            isExpanded: $manualExpanded
          ) {
            TextField(
              "http://scanner.local/eSCL/",
              text: $address
            )
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .disabled(model.isBusy)
            .accessibilityLabel("Scanner-Adresse")

            Button(model.isConnected ? "Neu verbinden" : "Verbinden") {
              discovery.stop()
              model.connect(address: address)
            }
            .disabled(
              model.isBusy
                || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )

            if address.lowercased().hasPrefix("http://") {
              Text("HTTP-Verbindungen sind unverschlüsselt.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
          }
        }

        if model.isBusy {
          Section {
            ProgressView("Verbindung wird verarbeitet …")

            Button("Vorgang abbrechen", role: .cancel) {
              model.cancel()
            }
          }
        }

        if let error = model.errorMessage {
          Section("Hinweis") {
            Text(error)
              .foregroundStyle(.red)
              .textSelection(.enabled)
          }
        }

        if let capabilities = model.capabilities {
          Section("Gerät") {
            LabeledContent(
              "Modell",
              value: capabilities.makeAndModel ?? "Nicht angegeben"
            )
            LabeledContent(
              "Erkannte Quellen",
              value: String(capabilities.inputs.count)
            )
          }

          ForEach(
            Array(capabilities.inputs.enumerated()),
            id: \.offset
          ) { _, input in
            Section(sourceName(input.source)) {
              ForEach(
                Array(input.profiles.enumerated()),
                id: \.offset
              ) { index, profile in
                VStack(alignment: .leading, spacing: 6) {
                  Text("Profil \(index + 1)")
                    .font(.headline)

                  Text(profile.colorModes.joined(separator: ", "))

                  Text(
                    profile.resolutions.map { "\($0.x) × \($0.y) dpi" }
                      .joined(separator: ", ")
                  )

                  Text(profile.documentFormats.joined(separator: ", "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                .textSelection(.enabled)
              }
            }
          }
        }

        if let status = model.status {
          Section("Aktueller Status") {
            LabeledContent(
              "Scanner",
              value: status.state ?? "Nicht angegeben"
            )
            LabeledContent(
              "Einzug",
              value: status.adfState ?? "Nicht angegeben"
            )

            Button("Status aktualisieren") {
              model.refreshStatus()
            }
            .disabled(model.isBusy)
          }
        }

        Section {
          Toggle("Debug-Ansicht anzeigen", isOn: $debugEnabled)
        } footer: {
          Text(
            "Entwicklungsstand: Diese Ansicht liest Fähigkeiten und Status. "
              + "Die Scan-Bedienung wird im nächsten Schritt angebunden."
          )
        }

        if debugEnabled {
          Section("Debug-Bericht") {
            Text(model.debugReport + "\n\n" + discovery.debugReport)
              .font(.system(.caption, design: .monospaced))
              .textSelection(.enabled)

            ShareLink(
              item: model.debugReport + "\n\n" + discovery.debugReport,
              subject: Text("AirScan-Diagnose")
            ) {
              Label("Bericht teilen", systemImage: "square.and.arrow.up")
            }

            Button("Ablaufprotokoll leeren") {
              model.clearEvents()
            }
          }
        }
      }
      .navigationTitle("Netzwerkscanner")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Schließen") {
            dismiss()
          }
          .disabled(model.isBusy)
        }
      }
    }
    .interactiveDismissDisabled(model.isBusy)
    .onAppear {
      if !model.isConnected {
        discovery.start()
      }
    }
    .onChange(of: address) { _, _ in
      model.invalidateConnection()
    }
    .onDisappear {
      discovery.stop()
      model.cancel()
    }
  }

  private func select(_ endpoint: AirScanDiscoveredEndpoint) {
    let selectedAddress = endpoint.resourceRoot.absoluteString
    address = selectedAddress
    discovery.stop()
    model.connect(address: selectedAddress)
  }

  private func sourceName(_ source: ScannerCapabilities.Source) -> String {
    switch source {
    case .platen:
      return "Flachbett"
    case .feederSimplex:
      return "Einzug – einseitig"
    case .feederDuplex:
      return "Einzug – beidseitig"
    }
  }
}
