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
            let container = try ModelContainer(for: schema, configurations: [modelConfiguration])
            // 🚨 NAPRAWA BAZY: Stary błąd w kolejności context.insert() powodował że crop.photo = NIL.
            // Przy starcie naprawiamy tę sytuację: resetujemy isFaceScanned dla zdjęć z uszkodzonymi
            // cropkami, żeby przy kolejnym skanie twarze zostały poprawnie zapisane.
            Task.detached(priority: .background) {
                let ctx = ModelContext(container)
                ctx.autosaveEnabled = false
                if let allCrops = try? ctx.fetch(FetchDescriptor<FaceCrop>()) {
                    let brokenCrops = allCrops.filter { $0.photo == nil }
                    if !brokenCrops.isEmpty {
                        print("🔧 Znaleziono \(brokenCrops.count) cropów z photo=NIL. Resetowanie isFaceScanned...")
                        // Znajdź wszystkie zdjęcia, które mają przynajmniej jeden crop (przez photo.faceCrops)
                        // ale wszystkie te cropy mają photo=NIL. Zresetuj isFaceScanned aby wymusić ponowny skan.
                        // Ponieważ crop.photo=NIL nie możemy dotrzeć do zdjęcia przez crop, więc resetujemy
                        // wszystkie zdjęcia oznaczone jako przeskanowane, które NIE mają żadnych poprawnych cropów.
                        if let allPhotos = try? ctx.fetch(FetchDescriptor<PhotoAsset>()) {
                            var resetCount = 0
                            for photo in allPhotos where photo.isFaceScanned {
                                let validCrops = photo.faceCrops.filter { $0.photo != nil }
                                if photo.faceCrops.isEmpty || validCrops.isEmpty {
                                    // To zdjęcie ma wszystkie cropi z photo=NIL lub brak cropów
                                    // Resetujemy flagę żeby wymusić ponowny skan
                                    photo.isFaceScanned = false
                                    resetCount += 1
                                }
                            }
                            if resetCount > 0 {
                                try? ctx.save()
                                print("✅ Zresetowano isFaceScanned dla \(resetCount) zdjęć. Wymagany ponowny skan twarzy.")
                            }
                        }
                    }
                }
            }
            return container
        } catch {
            fatalError("Nie można załadować bazy danych SwiftData: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
        .defaultSize(width: 1200, height: 800)
        
        Settings {
            SettingsView()
        }
    }
}
