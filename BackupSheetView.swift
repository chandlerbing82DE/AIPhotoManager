import SwiftUI
import SwiftData

struct BackupSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    
    @State private var backupManager = BackupManager.shared
    
    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Image(systemName: "archivebox.circle.fill")
                    .font(.largeTitle)
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading) {
                    Text("Kopia Zapasowa Biblioteki")
                        .font(.title2).bold()
                    Text("Zabezpiecz swoje tagi, opisy AI i strukturę albumów.")
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
            }
            
            Divider()
            
            if !backupManager.isExporting && !backupManager.statusMessage.contains("✅") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Tryb", selection: $backupManager.backupMode) {
                        ForEach(BackupManager.BackupMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .padding(.bottom, 8)
                    
                    Toggle(isOn: $backupManager.includeThumbnails) {
                        VStack(alignment: .leading) {
                            Text("Dołącz miniatury zdjęć do kopii")
                            Text(backupManager.backupMode == .smartSync ? "W trybie smart sync system skopiuje tylko nowe i zmienione pliki." : "Zalecane dla dużych baz (jak Twoje 300k zdjęć), aby uniknąć ponownego generowania obrazków z NAS przy odzyskiwaniu.")
                                .font(.caption2).foregroundColor(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                .padding()
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(8)
            } else {
                VStack(spacing: 10) {
                    Text(backupManager.statusMessage)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    
                    if backupManager.progressTotal > 0 {
                        ProgressView(value: Double(backupManager.progressCount), total: Double(backupManager.progressTotal))
                            .progressViewStyle(.linear)
                        Text("\(backupManager.progressCount) / \(backupManager.progressTotal)")
                            .font(.caption2).foregroundColor(.secondary)
                    } else if backupManager.isExporting {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding()
            }
            
            Spacer()
            
            HStack {
                if backupManager.isExporting {
                    Button("Anuluj", role: .destructive) {
                        backupManager.cancelBackup()
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button("Zamknij") { dismiss() }
                    
                    Spacer()
                    
                    if !backupManager.statusMessage.contains("✅") {
                        Button("Rozpocznij Backup") {
                            if let dbUrl = modelContext.container.configurations.first?.url {
                                backupManager.executeBackup(dbUrl: dbUrl, thumbnailDir: LocalStorage.thumbnailsDir)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .padding()
        .frame(width: 500, height: 280)
    }
}
