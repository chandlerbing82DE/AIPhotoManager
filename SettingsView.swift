import SwiftUI

struct SettingsView: View {
    // Te zmienne automatycznie połączą się z tymi samymi w ScannerService!
    @AppStorage("geminiAPIKey") private var geminiKey = ""
    @AppStorage("selectedAIProvider") private var selectedProvider = "Gemini"
    
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
            } header: {
                Text("Konfiguracja Sztucznej Inteligencji")
                    .font(.headline)
            } footer: {
                Text("Klucz jest bezpiecznie przechowywany na Twoim dysku (macOS UserDefaults) i nigdy nie jest wysyłany poza serwery wybranego dostawcy.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 8)
            }
        }
        .padding(20)
        .frame(width: 450, height: 250)
    }
}
