import SwiftUI

struct AISettingsView: View {
    @Environment(\.dismiss) private var dismiss
    
    // Pobieranie zapisanych danych
    @AppStorage("geminiAPIKey") private var geminiKey = ""
    @AppStorage("selectedAIProvider") private var selectedProvider = "Gemini"
    
    @State private var testStatus = ""
    @State private var isTesting = false
    
    let providers = ["Gemini", "OpenAI (Wkrótce)", "Claude (Wkrótce)"]
    
    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Image(systemName: "gearshape.fill")
                    .font(.title)
                    .foregroundColor(.accentColor)
                Text("Konfiguracja AI")
                    .font(.title)
                    .fontWeight(.bold)
            }
            .padding(.bottom, 10)
            
            Picker("Dostawca AI:", selection: $selectedProvider) {
                ForEach(providers, id: \.self) { provider in
                    Text(provider).tag(provider)
                }
            }
            .pickerStyle(.segmented)
            
            if selectedProvider == "Gemini" {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Klucz API Google Gemini:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    SecureField("Wprowadź swój klucz API...", text: $geminiKey)
                        .textFieldStyle(.roundedBorder)
                    
                    Text("Klucz jest bezpiecznie przechowywany lokalnie na Twoim komputerze.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 10)
            } else {
                Text("Ten dostawca będzie dostępny w przyszłych aktualizacjach.")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 20)
            }
            
            if !testStatus.isEmpty {
                HStack {
                    Image(systemName: testStatus.contains("✅") ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    Text(testStatus)
                }
                .font(.callout)
                .foregroundColor(testStatus.contains("✅") ? .green : .red)
                .padding(.top, 5)
            }
            
            Spacer()
            
            HStack {
                Button(action: testConnection) {
                    if isTesting {
                        ProgressView().controlSize(.small)
                        Text("Testowanie...")
                    } else {
                        Text("Testuj połączenie")
                    }
                }
                .disabled(isTesting || geminiKey.isEmpty || selectedProvider != "Gemini")
                
                Spacer()
                
                Button("Anuluj", role: .cancel) { dismiss() }
                
                Button("Zapisz i Zamknij") { dismiss() }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 450, height: 320)
    }
    
    private func testConnection() {
        isTesting = true
        testStatus = ""
        
        Task {
            // Bezpieczne zapytanie diagnostyczne do listy modeli Google
            guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?key=\(geminiKey)") else { return }
            
            do {
                let (_, response) = try await URLSession.shared.data(from: url)
                if let httpResponse = response as? HTTPURLResponse {
                    if httpResponse.statusCode == 200 {
                        testStatus = "✅ Połączenie udane! API działa."
                    } else {
                        testStatus = "❌ Odmowa dostępu. Błędny klucz API."
                    }
                }
            } catch {
                testStatus = "❌ Błąd sieci: \(error.localizedDescription)"
            }
            
            isTesting = false
        }
    }
}
