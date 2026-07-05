import Foundation
import SwiftData
import SwiftUI
import AppKit

@Observable
@MainActor
class AIService {
    var isProcessing = false
    var currentStatus = "Gotowy"
    var processedCount = 0
    var totalToProcess = 0
    
    func processPhotos(_ photos: [PhotoAsset], container: ModelContainer, forceOverwrite: Bool = false) {
        guard !isProcessing else { return }
        
        // POPRAWKA: Prawidłowe pobieranie klucza z AppStorage z ustawień
        let apiKey = UserDefaults.standard.string(forKey: "geminiAPIKey") ?? ""
        guard !apiKey.isEmpty else {
            self.currentStatus = "⚠️ Brak klucza API! Skonfiguruj AI."
            self.isProcessing = true
            Task { try? await Task.sleep(nanoseconds: 4_000_000_000); self.isProcessing = false }
            return
        }
        
        let toProcess = forceOverwrite ? photos : photos.filter { $0.keywords.isEmpty && $0.imageDescription.isEmpty }
        
        guard !toProcess.isEmpty else {
            self.currentStatus = "Wszystkie wybrane mają już tagi!"
            self.isProcessing = true
            Task { try? await Task.sleep(nanoseconds: 3_000_000_000); self.isProcessing = false }
            return
        }
        
        self.totalToProcess = toProcess.count
        self.processedCount = 0
        self.isProcessing = true
        self.currentStatus = "Przygotowywanie..."
        
        let photoIDs = toProcess.map { $0.id }
        
        Task.detached {
            let semaphore = DispatchSemaphore(value: 5)
            
            await withTaskGroup(of: Void.self) { group in
                for photoId in photoIDs {
                    semaphore.wait()
                    group.addTask {
                        defer { semaphore.signal() }
                        
                        let context = ModelContext(container)
                        let fetchDescriptor = FetchDescriptor<PhotoAsset>(predicate: #Predicate { $0.id == photoId })
                        guard let photo = try? context.fetch(fetchDescriptor).first else { return }
                        
                        let path = photo.originalPath
                        let fileName = photo.fileName
                        
                        await MainActor.run { self.currentStatus = "Analiza: \(fileName)" }
                        print("🟢 Rozpoczynam analizę: \(fileName)")
                        
                        if let compressedData = self.compressImage(path: path) {
                            if let result = await self.fetchGeminiData(imageData: compressedData, apiKey: apiKey) {
                                print("🟢 Sukces API! Tagi: \(result.tags)")
                                self.writeXMP(to: path, description: result.description, tags: result.tags)
                                
                                await MainActor.run {
                                    let mainContext = container.mainContext
                                    if let mainPhoto = try? mainContext.fetch(FetchDescriptor<PhotoAsset>(predicate: #Predicate { $0.id == photoId })).first {
                                        mainPhoto.imageDescription = result.description
                                        mainPhoto.keywords = result.tags
                                        try? mainContext.save()
                                        NotificationCenter.default.post(name: NSNotification.Name("AIPhotoUpdated"), object: photoId)
                                    }
                                    self.processedCount += 1
                                }
                            } else {
                                await MainActor.run { self.processedCount += 1 }
                            }
                        } else {
                            await MainActor.run { self.processedCount += 1 }
                        }
                    }
                }
            }
            await MainActor.run {
                self.currentStatus = "Zakończono tagowanie AI!"
                Task { try? await Task.sleep(nanoseconds: 3_000_000_000); self.isProcessing = false }
            }
        }
    }
    
    nonisolated private func compressImage(path: String) -> Data? {
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        let newSize = NSSize(width: 1024, height: 1024 * (image.size.height / image.size.width))
        let resizedImage = NSImage(size: newSize)
        resizedImage.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: newSize))
        resizedImage.unlockFocus()
        guard let tiff = resizedImage.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
    }
    
    nonisolated private struct GeminiResponse: Codable { let description: String; let tags: [String] }
    
    nonisolated private func fetchGeminiData(imageData: Data, apiKey: String) async -> GeminiResponse? {
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else { return nil }
        let base64Image = imageData.base64EncodedString()
        let prompt = """
        Describe this image precisely in Polish (1-2 sentences). 
        Then provide a list of up to 10 relevant keywords in Polish.
        You MUST return ONLY a valid JSON object. No markdown, no HTML, no backticks.
        Example:
        {
          "description": "Opis zdjęcia.",
          "tags": ["tag1", "tag2"]
        }
        """
        let requestBody: [String: Any] = [ "contents": [[ "parts": [ ["text": prompt], ["inline_data": ["mime_type": "image/jpeg", "data": base64Image]] ] ]], "generationConfig": ["response_mime_type": "application/json"] ]
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: requestBody)
        
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let candidates = json["candidates"] as? [[String: Any]],
               let content = candidates.first?["content"] as? [String: Any],
               let parts = content["parts"] as? [[String: Any]],
               let text = parts.first?["text"] as? String {
                
                var cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if cleanText.hasPrefix("```json") { cleanText = String(cleanText.dropFirst(7)) }
                else if cleanText.hasPrefix("```") { cleanText = String(cleanText.dropFirst(3)) }
                if cleanText.hasSuffix("```") { cleanText = String(cleanText.dropLast(3)) }
                cleanText = cleanText.trimmingCharacters(in: .whitespacesAndNewlines)
                
                if let jsonData = cleanText.data(using: .utf8) {
                    return try? JSONDecoder().decode(GeminiResponse.self, from: jsonData)
                }
            }
        } catch { print("❌ Błąd sieci API Gemini: \(error)") }
        return nil
    }
    
    nonisolated private func writeXMP(to imagePath: String, description: String, tags: [String]) {
        // Zostawiam Twoją dotychczasową funkcję zapisu
        let imageURL = URL(fileURLWithPath: imagePath)
        let xmpURL = imageURL.deletingPathExtension().appendingPathExtension("xmp")
        let tagsString = tags.map { "<rdf:li>\($0)</rdf:li>" }.joined(separator: "\n                     ")
        let xmpContent = """
        <?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="XMP Core 6.0.0">
           <rdf:RDF xmlns:rdf="[http://www.w3.org/1999/02/22-rdf-syntax-ns#](http://www.w3.org/1999/02/22-rdf-syntax-ns#)">
              <rdf:Description rdf:about="" xmlns:dc="[http://purl.org/dc/elements/1.1/](http://purl.org/dc/elements/1.1/)">
                 <dc:description><rdf:Alt><rdf:li xml:lang="x-default">\(description)</rdf:li></rdf:Alt></dc:description>
                 <dc:subject><rdf:Bag>\n                     \(tagsString)\n                  </rdf:Bag></dc:subject>
              </rdf:Description>
           </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
        try? xmpContent.write(to: xmpURL, atomically: true, encoding: .utf8)
    }
}
