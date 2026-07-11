import SwiftUI
import Network

struct SettingsView: View {
    // Te zmienne automatycznie połączą się z tymi samymi w ScannerService!
    @AppStorage("geminiAPIKey") private var geminiKey = ""
    @AppStorage("selectedAIProvider") private var selectedProvider = "Gemini"
    
    // Zmienne dla konfiguracji dysku NAS
    @AppStorage("nasWatchdogEnabled") private var nasWatchdogEnabled = false
    @AppStorage("nasVolumePath") private var nasVolumePath = "/Volumes/MEDIA"
    @AppStorage("nasSmbAddress") private var nasSmbAddress = "smb://192.168.1.100/MEDIA" // <-- Wpisz tu prawidłowe IP!
    
    // Diagnostyka połączeń
    @State private var apiTestStatus = ""
    @State private var nasTestStatus = ""
    @State private var isTestingAPI = false
    @State private var isTestingNAS = false
    
    var body: some View {
        Form {
            Section {
                Picker("Dostawca AI", selection: $selectedProvider) {
                    Text("Google Gemini").tag("Gemini")
                    Text("OpenAI (ChatGPT)").tag("OpenAI") // Na przyszłość!
                }
                .pickerStyle(.radioGroup)
                .padding(.bottom, 10)
                
                if selectedProvider == "Gemini" {
                    SecureField("Klucz API Gemini:", text: $geminiKey)
                        .textFieldStyle(.roundedBorder)
                        .help("Wklej tutaj klucz wygenerowany w Google AI Studio")
                } else {
                    // Miejsce na klucz OpenAI, gdybyś kiedyś chciał dodać
                    SecureField("Klucz API OpenAI:", text: .constant(""))
                        .textFieldStyle(.roundedBorder)
                        .disabled(true)
                }
                
                if !apiTestStatus.isEmpty {
                    HStack {
                        Image(systemName: apiTestStatus.contains("✅") ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        Text(apiTestStatus)
                    }
                    .font(.callout)
                    .foregroundColor(apiTestStatus.contains("✅") ? .green : .red)
                    .padding(.top, 4)
                }
            } header: {
                Text("Konfiguracja Sztucznej Inteligencji")
                    .font(.headline)
            } footer: {
                Text("Klucz jest bezpiecznie przechowywany na Twoim dysku (macOS UserDefaults) i nigdy nie jest wysyłany poza serwery wybranego dostawcy.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 8)
            }
            
            Section {
                Toggle("Włącz auto-montowanie (NAS Watchdog)", isOn: $nasWatchdogEnabled)
                
                TextField("Ścieżka na Macu (np. /Volumes/MEDIA):", text: $nasVolumePath)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!nasWatchdogEnabled)
                
                TextField("Adres sieciowy (np. smb://IP/MEDIA):", text: $nasSmbAddress)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!nasWatchdogEnabled)
                
                if !nasTestStatus.isEmpty {
                    HStack {
                        Image(systemName: nasTestStatus.contains("✅") ? "checkmark.circle.fill" : (nasTestStatus.contains("⚠️") ? "exclamationmark.triangle.fill" : "xmark.octagon.fill"))
                        Text(nasTestStatus)
                    }
                    .font(.callout)
                    .foregroundColor(nasTestStatus.contains("✅") ? .green : (nasTestStatus.contains("⚠️") ? .orange : .red))
                    .padding(.top, 4)
                }
            } header: {
                Text("Pilnowanie dysku sieciowego (NAS)")
                    .font(.headline)
            } footer: {
                Text("Jeśli ta opcja jest aktywna, aplikacja będzie sprawdzać dostęp do dysku co 30 sekund. Jeśli dysk zniknie, program sam wyśle komendę do systemu macOS, by podłączyć go ponownie. Szczegóły akcji znajdziesz w pliku logu na Pulpicie.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 8)
            }
            
            // Sekcja z przyciskami diagnostyki
            Section {
                HStack(spacing: 12) {
                    Button(action: testAPIKey) {
                        if isTestingAPI {
                            ProgressView().controlSize(.small)
                            Text("Testowanie API...")
                        } else {
                            Text("Testuj klucz API")
                        }
                    }
                    .disabled(isTestingAPI || geminiKey.isEmpty || selectedProvider != "Gemini")
                    
                    Spacer()
                    
                    Button(action: testNASConnection) {
                        if isTestingNAS {
                            ProgressView().controlSize(.small)
                            Text("Testowanie NAS...")
                        } else {
                            Text("Testuj połączenie NAS")
                        }
                    }
                    .disabled(isTestingNAS)
                }
                .padding(.vertical, 4)
            }
        }
        .padding(20)
        .frame(width: 550, height: 520) // Lekko powiększono okno, żeby idealnie pomieścić dodatkowe statusy oraz przyciski testowe
    }
    
    private func testAPIKey() {
        isTestingAPI = true
        apiTestStatus = ""
        
        Task {
            guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?key=\(geminiKey)") else {
                apiTestStatus = "❌ Nieprawidłowy klucz."
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
            
            let ipReachable = await testPort445(host: host)
            
            if pathExists {
                if ipReachable {
                    nasTestStatus = "✅ Dysk jest podłączony, a serwer NAS odpowiada sieciowo!"
                } else {
                    nasTestStatus = "⚠️ Dysk jest podłączony lokalnie, ale serwer NAS (port 445) nie odpowiada sieciowo."
                }
            } else {
                if ipReachable {
                    nasTestStatus = "⚠️ Serwer NAS (\(host)) odpowiada, ale dysk NIE jest zamontowany lokalnie."
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
