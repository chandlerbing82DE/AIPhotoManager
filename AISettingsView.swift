import SwiftUI
import Network

struct AISettingsView: View {
    @Environment(\.dismiss) private var dismiss
    
    // --- Pobieranie zapisanych danych (AI) ---
    @AppStorage("geminiAPIKey") private var geminiKey = ""
    @AppStorage("selectedAIProvider") private var selectedProvider = "Gemini"
    
    // --- Pobieranie zapisanych danych (NAS Watchdog) ---
    @AppStorage("nasWatchdogEnabled") private var nasWatchdogEnabled = false
    @AppStorage("nasVolumePath") private var nasVolumePath = "/Volumes/MEDIA"
    @AppStorage("nasSmbAddress") private var nasSmbAddress = "smb://192.168.1.100/MEDIA" // <-- Pamiętaj, aby potem zmienić IP w aplikacji!
    
    @State private var apiTestStatus = ""
    @State private var nasTestStatus = ""
    @State private var isTestingAPI = false
    @State private var isTestingNAS = false
    
    let providers = ["Gemini", "OpenAI (Wkrótce)", "Claude (Wkrótce)"]
    
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "gearshape.fill")
                    .font(.title)
                    .foregroundColor(.accentColor)
                Text("Ustawienia Główne")
                    .font(.title)
                    .fontWeight(.bold)
            }
            .padding(.bottom, 5)
            
            // ==========================================
            // SEKCJA 1: KONFIGURACJA AI
            // ==========================================
            VStack(alignment: .leading, spacing: 10) {
                Text("Sztuczna Inteligencja (AI)")
                    .font(.headline)
                
                Picker("Dostawca AI:", selection: $selectedProvider) {
                    ForEach(providers, id: \.self) { provider in
                        Text(provider).tag(provider)
                    }
                }
                .pickerStyle(.segmented)
                
                if selectedProvider == "Gemini" {
                    SecureField("Wprowadź swój klucz API Gemini...", text: $geminiKey)
                        .textFieldStyle(.roundedBorder)
                } else {
                    Text("Ten dostawca będzie dostępny w przyszłych aktualizacjach.")
                        .foregroundColor(.secondary)
                        .font(.caption)
                        .padding(.top, 4)
                }
                
                if !apiTestStatus.isEmpty {
                    HStack {
                        Image(systemName: apiTestStatus.contains("✅") ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        Text(apiTestStatus)
                    }
                    .font(.callout)
                    .foregroundColor(apiTestStatus.contains("✅") ? .green : .red)
                }
            }
            .padding()
            .background(Color.secondary.opacity(0.05))
            .cornerRadius(8)
            
            // ==========================================
            // SEKCJA 2: KONFIGURACJA DYSKU NAS
            // ==========================================
            VStack(alignment: .leading, spacing: 12) {
                Text("Dysk Sieciowy (NAS Watchdog)")
                    .font(.headline)
                
                Toggle("Włącz auto-montowanie w tle", isOn: $nasWatchdogEnabled)
                
                HStack {
                    Text("Lokalna ścieżka:")
                        .font(.callout)
                        .frame(width: 110, alignment: .trailing)
                    TextField("/Volumes/MEDIA", text: $nasVolumePath)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!nasWatchdogEnabled)
                }
                
                HStack {
                    Text("Adres SMB:")
                        .font(.callout)
                        .frame(width: 110, alignment: .trailing)
                    TextField("smb://192.168.1.100/MEDIA", text: $nasSmbAddress)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!nasWatchdogEnabled)
                }
                
                if !nasTestStatus.isEmpty {
                    HStack {
                        Image(systemName: nasTestStatus.contains("✅") ? "checkmark.circle.fill" : (nasTestStatus.contains("⚠️") ? "exclamationmark.triangle.fill" : "xmark.octagon.fill"))
                        Text(nasTestStatus)
                    }
                    .font(.callout)
                    .foregroundColor(nasTestStatus.contains("✅") ? .green : (nasTestStatus.contains("⚠️") ? .orange : .red))
                    .padding(.top, 4)
                }
            }
            .padding()
            .background(Color.secondary.opacity(0.05))
            .cornerRadius(8)
            
            Spacer()
            
            // ==========================================
            // DOLNY PASEK Z PRZYCISKAMI
            // ==========================================
            HStack(spacing: 10) {
                // Grupa przycisków testujących po lewej stronie
                Button(action: testAPIKey) {
                    if isTestingAPI {
                        ProgressView().controlSize(.small)
                        Text("Testowanie API...")
                    } else {
                        Text("Testuj klucz AI")
                    }
                }
                .disabled(isTestingAPI || geminiKey.isEmpty || selectedProvider != "Gemini")
                
                Button(action: testNASConnection) {
                    if isTestingNAS {
                        ProgressView().controlSize(.small)
                        Text("Testowanie NAS...")
                    } else {
                        Text("Testuj połączenie NAS")
                    }
                }
                .disabled(isTestingNAS)
                
                Spacer()
                
                Button("Anuluj", role: .cancel) { dismiss() }
                
                Button("Zapisz i Zamknij") { dismiss() }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        // Zwiększono rozmiar okna, żeby pomieścić obie sekcje oraz statusy testów
        .frame(width: 550, height: 500) 
    }
    
    private func testAPIKey() {
        isTestingAPI = true
        apiTestStatus = ""
        
        Task {
            guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?key=\(geminiKey)") else {
                apiTestStatus = "❌ Nieprawidłowy adres API."
                isTestingAPI = false
                return
            }
            
            do {
                let (_, response) = try await URLSession.shared.data(from: url)
                if let httpResponse = response as? HTTPURLResponse {
                    if httpResponse.statusCode == 200 {
                        apiTestStatus = "✅ Połączenie udane! API działa."
                    } else {
                        apiTestStatus = "❌ Odmowa dostępu. Błędny klucz API."
                    }
                }
            } catch {
                apiTestStatus = "❌ Błąd sieci: \(error.localizedDescription)"
            }
            
            isTestingAPI = false
        }
    }
    
    private func testNASConnection() {
        isTestingNAS = true
        nasTestStatus = ""
        
        Task {
            let fileManager = FileManager.default
            let pathExists = fileManager.fileExists(atPath: nasVolumePath)
            
            guard let url = URL(string: nasSmbAddress), let host = url.host else {
                if pathExists {
                    nasTestStatus = "✅ Dysk lokalny podłączony, ale format adresu SMB jest niepoprawny."
                } else {
                    nasTestStatus = "❌ Błędny adres SMB oraz brak lokalnego wolumenu."
                }
                isTestingNAS = false
                return
            }
            
            // Skanuj port 445 (standardowy port SMB sieci Microsoft/Samba)
            let ipReachable = await testPort445(host: host)
            
            if pathExists {
                if ipReachable {
                    nasTestStatus = "✅ Dysk jest podłączony lokalnie, a serwer NAS odpowiada sieciowo!"
                } else {
                    nasTestStatus = "⚠️ Dysk zamontowany lokalnie, ale host NAS (port 445) nie odpowiada sieciowo."
                }
            } else {
                if ipReachable {
                    nasTestStatus = "⚠️ Serwer NAS (\(host)) jest dostępny w sieci, ale dysk NIE jest zamontowany."
                } else {
                    nasTestStatus = "❌ Brak kontaktu z serwerem NAS (\(host)) oraz brak zamontowanego dysku."
                }
            }
            
            isTestingNAS = false
        }
    }
    
    private func testPort445(host: String) async -> Bool {
        let hostEndpoint = NWEndpoint.Host(host)
        let portEndpoint = NWEndpoint.Port(integerLiteral: 445)
        let connection = NWConnection(to: .hostPort(host: hostEndpoint, port: portEndpoint), using: .tcp)
        
        return await withCheckedContinuation { continuation in
            var resumed = false
            let lock = NSLock()
            
            connection.stateUpdateHandler = { state in
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                
                switch state {
                case .ready:
                    resumed = true
                    connection.cancel()
                    continuation.resume(returning: true)
                case .failed:
                    resumed = true
                    connection.cancel()
                    continuation.resume(returning: false)
                default:
                    break
                }
            }
            
            // Timeout ustawiony na 2 sekundy, żeby użytkownik nie czekał bez końca
            DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                connection.cancel()
                continuation.resume(returning: false)
            }
            
            connection.start(queue: .global())
        }
    }
}
