import Foundation
import SwiftUI
import AppKit

@Observable @MainActor
class BackupManager {
    static let shared = BackupManager()
    
    enum BackupMode: String, CaseIterable {
        case smartSync = "Inteligentna Sync. (Szybka - polecane)"
        case fullArchive = "Pełny Archiwalny (Nowy Folder)"
    }
    
    var isExporting = false
    var progressCount = 0
    var progressTotal = 0
    var statusMessage = ""
    var includeThumbnails = true
    var backupMode: BackupMode = .smartSync
    
    // Zwykła, śledzona przez @Observable zmienna
    var lastBackupTimestamp: Double
    
    private var backupTask: Task<Void, Never>?
    
    init() {
        // Ręczne pobranie z UserDefaults przy starcie (zamiast @AppStorage)
        self.lastBackupTimestamp = UserDefaults.standard.double(forKey: "lastBackupTimestamp")
    }
    
    var isBackupRequired: Bool {
        if lastBackupTimestamp == 0 { return true }
        let sevenDays: TimeInterval = 7 * 24 * 60 * 60
        return (Date().timeIntervalSince1970 - lastBackupTimestamp) > sevenDays
    }
    
    func executeBackup(dbUrl: URL, thumbnailDir: URL) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.title = "Wybierz folder docelowy dla kopii zapasowej"
        panel.prompt = "Wybierz"
        
        guard panel.runModal() == .OK, let targetFolder = panel.url else { return }
        
        isExporting = true
        statusMessage = "Inicjalizacja..."
        progressCount = 0
        progressTotal = 0
        let currentModeStr = backupMode.rawValue
        let includeThumbs = includeThumbnails
        
        backupTask = Task { [weak self] in
            guard let self = self else { return }
            defer {
                self.isExporting = false
                self.backupTask = nil
            }
            
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd_HHmmss"
            let dateString = formatter.string(from: Date())
            
            do {
                let processor = BackupProcessor()
                let success = try await processor.runBackup(
                    dbUrl: dbUrl,
                    thumbnailDir: thumbnailDir,
                    targetFolder: targetFolder,
                    modeStr: currentModeStr,
                    includeThumbs: includeThumbs,
                    dateString: dateString
                ) { c, t, msg in
                    await MainActor.run {
                        self.progressCount = c
                        self.progressTotal = t
                        if !msg.isEmpty { self.statusMessage = msg }
                    }
                }
                
                if success {
                    let newTimestamp = Date().timeIntervalSince1970
                    self.lastBackupTimestamp = newTimestamp
                    UserDefaults.standard.set(newTimestamp, forKey: "lastBackupTimestamp")
                    
                    self.statusMessage = "✅ Kopia zapasowa zakończona pomyślnie!"
                    NSSound(named: "Glass")?.play()
                } else {
                    self.statusMessage = "Zatrzymano. Kopia zapasowa jest niekompletna."
                }
            } catch {
                self.statusMessage = "❌ Krytyczny błąd zapisu: \(error.localizedDescription)"
            }
        }
    }
    
    func cancelBackup() {
        backupTask?.cancel()
        statusMessage = "Anulowanie procesu..."
    }
}

actor BackupProcessor {
    func runBackup(
        dbUrl: URL,
        thumbnailDir: URL,
        targetFolder: URL,
        modeStr: String,
        includeThumbs: Bool,
        dateString: String,
        onProgress: @Sendable @escaping (Int, Int, String) async -> Void
    ) async throws -> Bool {
        let isSmartSync = modeStr.contains("Inteligentna Sync")
        
        let backupFolderUrl: URL
        if isSmartSync {
            backupFolderUrl = targetFolder.appendingPathComponent("AIPhotoManager_Backup_Sync")
        } else {
            let folderName = "AIPhotoManager_Backup_\(dateString)"
            backupFolderUrl = targetFolder.appendingPathComponent(folderName)
        }
        
        try FileManager.default.createDirectory(at: backupFolderUrl, withIntermediateDirectories: true)
        
        await onProgress(0, 0, "Zabezpieczanie plików bazy danych...")
        
        let dbDestFolder: URL
        if isSmartSync {
            dbDestFolder = backupFolderUrl.appendingPathComponent("Databases").appendingPathComponent(dateString)
        } else {
            dbDestFolder = backupFolderUrl
        }
        try FileManager.default.createDirectory(at: dbDestFolder, withIntermediateDirectories: true)
        
        let dbFiles = [
            dbUrl,
            dbUrl.deletingPathExtension().appendingPathExtension("store-shm"),
            dbUrl.deletingPathExtension().appendingPathExtension("store-wal")
        ]
        
        for file in dbFiles {
            if Task.isCancelled { return false }
            let dest = dbDestFolder.appendingPathComponent(file.lastPathComponent)
            if FileManager.default.fileExists(atPath: file.path) {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(at: file, to: dest)
            }
        }
        
        if includeThumbs {
            await onProgress(0, 0, "Analizowanie folderu miniaturek...")
            let files = (try? FileManager.default.contentsOfDirectory(at: thumbnailDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
            
            let destThumbsDir = backupFolderUrl.appendingPathComponent("Thumbnails")
            try FileManager.default.createDirectory(at: destThumbsDir, withIntermediateDirectories: true)
            
            var filesToProcess: [URL] = []
            
            if isSmartSync {
                let existingFiles = Set((try? FileManager.default.contentsOfDirectory(atPath: destThumbsDir.path)) ?? [])
                filesToProcess = files.filter { !existingFiles.contains($0.lastPathComponent) }
                await onProgress(0, filesToProcess.count, "Znaleziono \(filesToProcess.count) brakujących z \(files.count) miniatur.")
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            } else {
                filesToProcess = files
                await onProgress(0, files.count, "Gotowy do kopiowania.")
            }
            
            let total = filesToProcess.count
            var copied = 0
            
            for fileUrl in filesToProcess {
                if Task.isCancelled { return false }
                
                let destFile = destThumbsDir.appendingPathComponent(fileUrl.lastPathComponent)
                try? FileManager.default.copyItem(at: fileUrl, to: destFile)
                copied += 1
                
                if copied % 100 == 0 || copied == total {
                    let typeMsg = isSmartSync ? "Kopiowanie nowych:" : "Kopiowanie miniaturek:"
                    await onProgress(copied, total, "\(typeMsg) \(copied) z \(total)")
                }
            }
        }
        
        return true
    }
}
