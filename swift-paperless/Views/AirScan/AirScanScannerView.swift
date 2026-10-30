import AirScan
import SwiftUI

@MainActor
struct AirScanScannerView: View {
  @Environment(\.dismiss) private var dismiss
  @StateObject private var model = AirScanScannerModel()
  @StateObject private var discovery = AirScanDiscoveryModel()
  @StateObject private var selection = AirScanSelectionModel()
  @StateObject private var scan = AirScanRunModel()
  @State private var manualExpanded = false

  @AppStorage("airscan.manualResourceRoot")
  private var address = ""

  @AppStorage("airscan.debugPanelEnabled")
  private var debugEnabled = false
  private var isWorking: Bool {
  model.isBusy || scan.isBusy
  }

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
                .disabled(isWorking)
              }
            }
            .padding(.vertical, 4)
          }

          Button("Erneut suchen") {
            discovery.start()
          }
          .disabled(isWorking)

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
            .disabled(isWorking)
            .accessibilityLabel("Scanner-Adresse")

            Button(model.isConnected ? "Neu verbinden" : "Verbinden") {
              discovery.stop()
              model.connect(address: address)
            }
            .disabled(
              isWorking
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
        if model.capabilities != nil {
          AirScanSettingsSection(
            selection: selection,
            isBusy: isWorking
          )
        }
        if let capabilities = model.capabilities {
  Section {
    if scan.isBusy {
      ProgressView("Scan wird verarbeitet …")

      LabeledContent(
        "Gespeicherte Bildseiten",
        value: String(scan.receivedPages)
      )

      Button("Scan abbrechen", role: .cancel) {
        scan.cancel()
      }
    } else {
      Button {
        guard let option = selection.selectedOption else { return }

        discovery.stop()
        scan.start(
          address: address,
          settings: option.settings,
          capabilities: capabilities,
          expectedPages: selection.expectedPages
        )
      } label: {
        Label("Scan starten", systemImage: "scanner")
      }
      .disabled(
        isWorking
          || !model.isConnected
          || selection.selectedOption == nil
      )
    }

    if let message = scan.message {
      Text(message)
        .foregroundStyle(.secondary)
    }

    if let error = scan.errorMessage {
      Text(error)
        .foregroundStyle(.red)
    }

    if scan.cleanupWarning {
      Text(
        "Die Seiten wurden empfangen, aber das Aufräumen "
          + "des Geräteauftrags konnte nicht bestätigt werden. "
          + "Scannerzustand vor einem erneuten Start prüfen."
      )
      .foregroundStyle(.orange)
    }

    if let directory = scan.directory {
      LabeledContent(
        "Lokaler Scan-Ordner",
        value: directory.lastPathComponent
      )
      .font(.caption)
      .textSelection(.enabled)
    }
  } header: {
    Text("Scan")
  } footer: {
    Text(
      "Die Bildseiten werden lokal aufbewahrt. "
        + "PDF-Erstellung und Dokumentimport sind noch nicht angebunden."
    )
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
            .disabled(isWorking)
          }
        }

        Section {
          Toggle("Debug-Ansicht anzeigen", isOn: $debugEnabled)
        } footer: {
          Text(
            "Entwicklungsstand: Scan-Bedienung und lokale Seitenspeicherung. "
              + "PDF-Erstellung und Dokumentimport folgen separat."
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
          .disabled(isWorking)
        }
      }
    }
    .interactiveDismissDisabled(isWorking)
    .onAppear {
      if !model.isConnected {
        discovery.start()
      }
    }
    .onChange(of: address) { _, _ in
      model.invalidateConnection()
    }
    .onChange(of: model.capabilities) { _, capabilities in
      selection.configure(capabilities)
    }
    .onDisappear {
      discovery.stop()
      model.cancel()
      scan.cancel()
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
