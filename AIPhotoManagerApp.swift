import SwiftUI
import SwiftData

// --- DELEGAT APLIKACJI ---
// Odpowiada za cykl życia procesu serwera AI w tle.
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Uruchomienie serwera AI zaraz po starcie aplikacji
        PythonBackendManager.shared.startServer()
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        // Bezpieczne zamknięcie serwera AI przy wyłączaniu aplikacji
        PythonBackendManager.shared.stopServer()
    }
}

@main
struct AIPhotoManagerApp: App {
    // Podpięcie delegata do aplikacji SwiftUI
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            PhotoAsset.self,
            VirtualFolder.self,
            EventFolder.self,
            Person.self,
            FaceCrop.self
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        print("📍 ŚCIEŻKA DO TWOJEJ BAZY DANYCH: \(modelConfiguration.url.path)")
        
        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            // Zamiast kasować bazę, wyrzucamy błąd w konsoli.
            // Będziesz wiedział dokładnie, co poszło nie tak (np. błąd migracji lub brak dostępu).
            fatalError("Nie można załadować bazy danych SwiftData: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
        .defaultSize(width: 1200, height: 800)
        
        // 🚨 TUTAJ DODALIŚMY OKNO USTAWIEŃ:
        Settings {
            SettingsView()
        }
    }
}
