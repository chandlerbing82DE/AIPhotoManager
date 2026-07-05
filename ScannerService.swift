import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import SwiftData
import AppKit
import Vision

actor ScannerService {
    
    var cancelRequested = false
    
    func requestCancel() {
        cancelRequested = true
    }
    
    private class Cluster {
        let person: Person
        var centroidVector: [Double]
        var count: Int
        
        init(person: Person, initialVector: [Double]) {
            self.person = person
            self.centroidVector = initialVector
            self.count = 1
        }
        
        func addFaceAndRecalculate(newVector: [Double]) {
            let total = Double(count)
            for i in 0..<centroidVector.count {
                centroidVector[i] = (centroidVector[i] * total + newVector[i]) / (total + 1.0)
            }
            count += 1
        }
    }
    
    private struct FaceResponse: Codable {
        let faces: [FaceData]
    }
    
    private struct FaceData: Codable {
        let bbox: [Float]
        let embedding: [Double]
        let score: Float?
    }
    
    nonisolated private func getPhotoAsset(pid: PersistentIdentifier, context: ModelContext) -> PhotoAsset? {
        let reg: PhotoAsset? = context.registeredModel(for: pid)
        if let model = reg { return model }
        return (try? context.model(for: pid)) as? PhotoAsset
    }
    
    // =====================================================================
    // 1. IMPORT ZDJĘĆ
    // =====================================================================
    func scanFolder(url: URL, container: ModelContainer, onProgress: @escaping @Sendable (Int, Int, String) -> Void) async throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        await MainActor.run { onProgress(0, 0, "🔌 Łączenie z bazą danych...") }
        
        let photoDesc = FetchDescriptor<PhotoAsset>()
        let existingPhotos: [PhotoAsset] = (try? context.fetch(photoDesc)) ?? []
        let existingPaths = Set(existingPhotos.map { $0.originalPath })
        
        var folderCache: [String: VirtualFolder] = [:]
        let folderDesc = FetchDescriptor<VirtualFolder>()
        let existingFolders: [VirtualFolder] = (try? context.fetch(folderDesc)) ?? []
        for f in existingFolders {
            var parts: [String] = []
            var current: VirtualFolder? = f
            while let p = current {
                parts.insert(p.name, at: 0)
                current = p.parentFolder
            }
            folderCache[parts.joined(separator: "/")] = f
        }
        
        var eventCache: [String: EventFolder] = [:]
        let eventDesc = FetchDescriptor<EventFolder>()
        let existingEvents: [EventFolder] = (try? context.fetch(eventDesc)) ?? []
        for event in existingEvents {
            eventCache[event.name] = event
        }
        
        var done = 0
        var batchCount = 0
        
        try await processDirectory(url: url, rootUrl: url, context: context, existingPaths: existingPaths, folderCache: &folderCache, eventCache: &eventCache, done: &done, batchCount: &batchCount, onProgress: onProgress)
        
        if batchCount > 0 { try? context.save() }
        let finalDone = done
        await MainActor.run { onProgress(finalDone, finalDone, "Import zakończony! (\(finalDone) zdjęć)") }
    }
    
    private func processDirectory(url: URL, rootUrl: URL, context: ModelContext, existingPaths: Set<String>, folderCache: inout [String: VirtualFolder], eventCache: inout [String: EventFolder], done: inout Int, batchCount: inout Int, onProgress: @escaping @Sendable (Int, Int, String) -> Void) async throws {
        if cancelRequested { return }
        
        guard let contents = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .contentTypeKey], options: [.skipsHiddenFiles]) else { return }
        
        let sortedContents = contents.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let relativeFolder = url.path.replacingOccurrences(of: rootUrl.deletingLastPathComponent().path + "/", with: "")
        
        for itemURL in sortedContents {
            if cancelRequested { return }
            await Task.yield()
            
            let resourceValues = try? itemURL.resourceValues(forKeys: [.isDirectoryKey, .contentTypeKey])
            if resourceValues?.isDirectory == true {
                try await processDirectory(url: itemURL, rootUrl: rootUrl, context: context, existingPaths: existingPaths, folderCache: &folderCache, eventCache: &eventCache, done: &done, batchCount: &batchCount, onProgress: onProgress)
            } else {
                if existingPaths.contains(itemURL.path) { continue }
                if let type = resourceValues?.contentType, type.conforms(to: .image) {
                    await processImage(fileURL: itemURL, rootScanURL: rootUrl, context: context, folderCache: &folderCache, eventCache: &eventCache)
                    done += 1
                    batchCount += 1
                    if done % 10 == 0 {
                        let currentDone = done
                        await MainActor.run { onProgress(currentDone, 0, "📂 \(relativeFolder)\nZaimportowano: \(currentDone)") }
                    }
                    if batchCount >= 200 {
                        try? context.save()
                        batchCount = 0
                    }
                }
            }
        }
    }
    
    private func processImage(fileURL: URL, rootScanURL: URL, context: ModelContext, folderCache: inout [String: VirtualFolder], eventCache: inout [String: EventFolder]) async {
        let path = fileURL.path
        let fileName = fileURL.lastPathComponent
        
        let deterministicId = UUID.deterministic(from: path)
        let thumbUrl = LocalStorage.thumbnailsDir.appendingPathComponent("\(deterministicId.uuidString).jpg")
        let thumbExists = FileManager.default.fileExists(atPath: thumbUrl.path)
        
        let (metadata, thumbnailData, extractedEventName) = await Task.detached(priority: .background) {
            return autoreleasepool {
                let meta = MetadataReader.readMetadata(from: path)
                let eventDate = ScannerService.extractDateOnly(from: fileURL)
                let thumb: Data?
                if thumbExists {
                    thumb = nil
                } else {
                    thumb = ScannerService.generateThumbnail(for: fileURL, maxPixelSize: 512)
                }
                return (meta, thumb, eventDate)
            }
        }.value
        
        // Z racji że PhotoAsset inicjuje self.id za pomocą UUID.deterministic(from: originalPath), 
        // poniższy obiekt będzie miał dokładnie id = deterministicId
        let photo = PhotoAsset(fileName: fileName, originalPath: path)
        context.insert(photo)
        
        if let validThumbnail = thumbnailData {
            LocalStorage.saveThumbnail(data: validThumbnail, id: photo.id)
        }
        
        photo.keywords = metadata.xmpKeywords
        if let desc = metadata.xmpDescription { photo.imageDescription = desc }
        
        let relativePathDir = fileURL.deletingLastPathComponent().path.replacingOccurrences(of: rootScanURL.path, with: "")
        var components = relativePathDir.split(separator: "/").map { String($0) }
        components.insert(rootScanURL.lastPathComponent, at: 0)
        
        if let folder = getOrCreateFolderHierarchy(components: components, context: context, cache: &folderCache) {
            photo.folder = folder
        }
        
        let eventName = extractedEventName ?? components.last ?? "Sieroty"
        let event = getOrCreateEvent(name: eventName, context: context, cache: &eventCache)
        
        if event.virtualDateString == nil {
            event.virtualDateString = extractVirtualDate(from: eventName, allowShort: true)
        }
        
        if photo.virtualDateString == nil {
            photo.virtualDateString = extractVirtualDate(from: fileName, allowShort: false) ?? event.virtualDateString ?? photo.folder?.virtualDateString
        }
        
        photo.event = event
        photo.isFaceScanned = false
        photo.isReviewScanned = false
        
        if !photo.keywords.isEmpty || !photo.imageDescription.isEmpty {
            photo.isAiScanned = true
        } else {
            photo.isAiScanned = false
        }
    }
    
    // --- BRAMKA BEZPIECZEŃSTWA: Czekanie na Pythona ---
    private func waitForPythonServer(onProgress: @escaping @Sendable (Int, Int, String) -> Void) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:8000/extract") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 2.0
        
        for i in 1...30 {
            if cancelRequested { return false }
            await MainActor.run { onProgress(0, 1, "Rozgrzewanie AI (Ładowanie modelu)... \(i)/30") }
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let _ = response as? HTTPURLResponse {
                    await MainActor.run { onProgress(0, 1, "Serwer AI gotowy! Inicjalizacja...") }
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    return true
                }
            } catch {
                if i == 5 || i == 15 {
                    await MainActor.run { PythonBackendManager.shared.startServer() }
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                } else {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
        }
        return false
    }
    
    // =====================================================================
    // 2. NOWY SILNIK TWARZY Z WYSOKĄ ROZDZIELCZOŚCIĄ 1024PX I ŁAGODNYM FILTREM
    // =====================================================================
    func scanFaces(photoIDs: [PersistentIdentifier], container: ModelContainer, forceOverwrite: Bool = false, onProgress: @escaping @Sendable (Int, Int, String) -> Void) async {
        let isServerUp = await waitForPythonServer(onProgress: onProgress)
        if !isServerUp {
            await MainActor.run { onProgress(0, 0, "❌ Błąd: Silnik AI nie wystartował!") }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            return
        }
        
        let context = ModelContext(container)
        context.autosaveEnabled = false
        var clusters: [Cluster] = []
        
        let peopleList: [Person] = (try? context.fetch(FetchDescriptor<Person>())) ?? []
        for person in peopleList {
            let personFaces = person.faceCrops.compactMap { crop -> [Double]? in
                guard let data = crop.featurePrintData else { return nil }
                return try? JSONDecoder().decode([Double].self, from: data)
            }
            if !personFaces.isEmpty {
                var sumVector = personFaces[0]
                for i in 1..<personFaces.count {
                    let vec = personFaces[i]
                    for j in 0..<sumVector.count { sumVector[j] += vec[j] }
                }
                for j in 0..<sumVector.count { sumVector[j] /= Double(personFaces.count) }
                clusters.append(Cluster(person: person, initialVector: sumVector))
            }
        }
        
        let total = photoIDs.count
        var done = 0
        var personCounter = peopleList.count + 1
        
        for pid in photoIDs {
            if cancelRequested { break }
            await Task.yield()
            var processedThisLoop = false
            
            if let photo = getPhotoAsset(pid: pid, context: context), (!photo.isFaceScanned || forceOverwrite) && !photo.isTrash {
                processedThisLoop = true
                let fName = photo.fileName
                let cDone = done
                await MainActor.run { onProgress(cDone, total, "Twarze: \(fName)") }
                
                if forceOverwrite && photo.isFaceScanned {
                    for crop in photo.faceCrops {
                        if let person = crop.person { person.faceCount -= 1 }
                        context.delete(crop)
                    }
                    photo.faceCrops.removeAll()
                    photo.people.removeAll()
                }
                
                // 🚨 Generujemy obraz 1024px specjalnie pod kątem wykrywania małych twarzy
                let fileURL = URL(fileURLWithPath: photo.originalPath)
                if let highResData = ScannerService.generateThumbnail(for: fileURL, maxPixelSize: 1024) {
                    
                    if let facesData = await extractFacesFromPythonAPI(imageData: highResData) {
                        for face in facesData {
                            let width = face.bbox[2] - face.bbox[0]
                            let height = face.bbox[3] - face.bbox[1]
                            
                            // 🚨 ZŁAGODZONY FILTR: Przepuszczamy małe twarze (od 10px) i profile twarzy (score od 0.40)
                            if width < 10 || height < 10 { continue }
                            if let score = face.score, score < 0.40 { continue }
                            
                            let cropData = ScannerService.cropImage(from: highResData, bbox: face.bbox)
                            let dnaData = try? JSONEncoder().encode(face.embedding)
                            
                            let faceCrop = FaceCrop(cropData: cropData ?? highResData, featurePrintData: dnaData)
                            faceCrop.photo = photo
                            context.insert(faceCrop)
                            photo.faceCrops.append(faceCrop)
                            
                            var bestMatch: Cluster? = nil
                            var minDistance: Double = .greatestFiniteMagnitude
                            let currentVector = face.embedding
                            
                            for cluster in clusters {
                                let distance = ScannerService.cosineDistance(currentVector, cluster.centroidVector)
                                if distance < 0.65 && distance < minDistance {
                                    minDistance = distance
                                    bestMatch = cluster
                                }
                            }
                            
                            if let match = bestMatch {
                                faceCrop.person = match.person
                                match.person.faceCrops.append(faceCrop)
                                match.person.faceCount += 1
                                if !match.person.photos.contains(photo) { match.person.photos.append(photo) }
                                if !photo.people.contains(match.person) { photo.people.append(match.person) }
                                match.addFaceAndRecalculate(newVector: currentVector)
                            } else {
                                let newPerson = Person(name: "Osoba \(personCounter)")
                                newPerson.faceCount = 1
                                context.insert(newPerson)
                                faceCrop.person = newPerson
                                newPerson.faceCrops.append(faceCrop)
                                newPerson.photos.append(photo)
                                photo.people.append(newPerson)
                                clusters.append(Cluster(person: newPerson, initialVector: currentVector))
                                personCounter += 1
                            }
                        }
                        photo.isFaceScanned = true
                    } else {
                        await MainActor.run { onProgress(cDone, total, "⚠️ Serwer zawieszony. Reanimacja...") }
                        await MainActor.run { PythonBackendManager.shared.startServer() }
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                    }
                } else {
                    photo.isFaceScanned = true
                }
                
                // 🚨 SZYBKIE ODŚWIEŻANIE INTERFEJSU
                if forceOverwrite { try? context.save() }
                let photoId = photo.id
                await MainActor.run {
                    let mainCtx = container.mainContext
                    if let mainPhoto = self.getPhotoAsset(pid: pid, context: mainCtx) {
                        mainPhoto.isFaceScanned = true
                    }
                    NotificationCenter.default.post(name: NSNotification.Name("AIPhotoUpdated"), object: photoId)
                }
            }
            
            done += 1
            if done % 250 == 0 || done == total {
                try? context.save()
                if !processedThisLoop {
                    let cDone = done
                    await MainActor.run { onProgress(cDone, total, "Szybkie sprawdzanie: \(cDone)/\(total)") }
                }
            }
        }
        try? context.save()
    }
    
    // =====================================================================
    // 3. SKANOWANIE PORZĄDKOWE
    // =====================================================================
    func scanForCleanup(photoIDs: [PersistentIdentifier], container: ModelContainer, onProgress: @escaping @Sendable (Int, Int, String) -> Void) async {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        var sizeHashes: [Int: PersistentIdentifier] = [:]
        
        let allPhotos: [PhotoAsset] = (try? context.fetch(FetchDescriptor<PhotoAsset>())) ?? []
        for photo in allPhotos {
            if !photoIDs.contains(photo.persistentModelID) && !photo.isTrash {
                let attrs = try? FileManager.default.attributesOfItem(atPath: photo.originalPath)
                if let sizeNum = attrs?[FileAttributeKey.size] as? NSNumber {
                    sizeHashes[sizeNum.intValue] = photo.persistentModelID
                }
            }
        }
        
        let total = photoIDs.count
        var done = 0
        
        for pid in photoIDs {
            if cancelRequested { break }
            await Task.yield()
            
            if let photo = getPhotoAsset(pid: pid, context: context), !photo.isTrash {
                let fName = photo.fileName
                let cDone = done
                if done % 10 == 0 {
                    await MainActor.run { onProgress(cDone, total, "Analiza: \(fName)") }
                }
                
                photo.reviewCategory = nil
                let path = photo.originalPath
                let attrs = try? FileManager.default.attributesOfItem(atPath: path)
                
                if let sizeNum = attrs?[FileAttributeKey.size] as? NSNumber {
                    let sizeInt = sizeNum.intValue
                    if sizeHashes[sizeInt] != nil {
                        photo.reviewCategory = "Duplikaty"
                    } else {
                        sizeHashes[sizeInt] = pid
                    }
                }
                
                if photo.reviewCategory == nil {
                    let isDocument: Bool = await Task.detached(priority: .background) { () -> Bool in
                        let request = VNRecognizeTextRequest()
                        request.recognitionLevel = .fast
                        if let handler = try? VNImageRequestHandler(url: URL(fileURLWithPath: path), options: [:]) {
                            try? handler.perform([request])
                            return (request.results?.count ?? 0) > 5
                        }
                        return false
                    }.value
                    
                    if isDocument { photo.reviewCategory = "Dokumenty" }
                }
                photo.isReviewScanned = true
            }
            done += 1
            if done % 250 == 0 || done == total {
                try? context.save()
            }
        }
        try? context.save()
    }
    
    // =====================================================================
    // 4. ANALIZA AI
    // =====================================================================
    func scanWithAI(photoIDs: [PersistentIdentifier], container: ModelContainer, forceOverwrite: Bool = false, onProgress: @escaping @Sendable (Int, Int, String) -> Void) async {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let total = photoIDs.count
        var done = 0
        
        let apiKey = UserDefaults.standard.string(forKey: "geminiAPIKey") ?? ""
        if apiKey.isEmpty {
            await MainActor.run { onProgress(0, total, "❌ BRAK KLUCZA API!") }
            return
        }
        
        for pid in photoIDs {
            if cancelRequested { break }
            await Task.yield()
            var processedThisLoop = false
            
            if let photo = getPhotoAsset(pid: pid, context: context), (!photo.isAiScanned || forceOverwrite) && !photo.isTrash {
                processedThisLoop = true
                let fName = photo.fileName
                let cDone = done
                await MainActor.run { onProgress(cDone, total, "Opisywanie AI: \(fName)") }
                
                if let highResData = ScannerService.generateThumbnail(for: URL(fileURLWithPath: photo.originalPath), maxPixelSize: 1200) {
                    do {
                        let hasVIP = photo.people.contains(where: { $0.isTop100 })
                        let response = try await fetchGeminiDescription(imageData: highResData, apiKey: apiKey, hasVIP: hasVIP)
                        
                        photo.imageDescription = response.description
                        photo.keywords = response.tags
                        photo.rating = response.rating
                        
                        if response.isDocument {
                            photo.reviewCategory = "Dokumenty"
                            photo.isReviewScanned = true
                        }
                        
                        photo.isAiScanned = true
                        try? context.save()
                        writeXMP(to: photo.originalPath, description: response.description, tags: response.tags)
                        
                        let photoId = photo.id
                        await MainActor.run {
                            let mainContext = container.mainContext
                            if let mainPhoto = self.getPhotoAsset(pid: pid, context: mainContext) {
                                mainPhoto.imageDescription = response.description
                                mainPhoto.keywords = response.tags
                                mainPhoto.rating = response.rating
                                if response.isDocument {
                                    mainPhoto.reviewCategory = "Dokumenty"
                                    mainPhoto.isReviewScanned = true
                                }
                                mainPhoto.isAiScanned = true
                            }
                            NotificationCenter.default.post(name: NSNotification.Name("AIPhotoUpdated"), object: photoId)
                        }
                    } catch {
                        print("❌ Błąd Gemini dla \(photo.fileName): \(error)")
                    }
                }
            }
            done += 1
            if done % 250 == 0 || done == total {
                try? context.save()
                if !processedThisLoop {
                    let cDone = done
                    await MainActor.run { onProgress(cDone, total, "Szybkie sprawdzanie: \(cDone)/\(total)") }
                }
            }
        }
        try? context.save()
    }
    
    private struct AIResponse: Codable {
        let description: String
        let tags: [String]
        let rating: Int
        let isDocument: Bool
    }
    
    nonisolated private func fetchGeminiDescription(imageData: Data, apiKey: String, hasVIP: Bool) async throws -> AIResponse {
        let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-lite:generateContent?key=\(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))"
        
        let prompt = hasVIP ? "Opisz to zdjęcie ciepło i empatycznie (PL). Wygeneruj tagi. Na zdjęciu znajdują się osoby z mojego bliskiego otoczenia. Oceń zdjęcie w skali 0-6 pod kątem sentymentalnego albumu rodzinnego (możesz ignorować wady techniczne, jeśli chwila wydaje się wyjątkowa). Rozpoznaj czy to dokument.\nJSON format: {\"description\": \"string\", \"tags\": [\"string\"], \"rating\": int, \"isDocument\": bool}" : "Opisz to zdjęcie szczegółowo i obiektywnie (PL). Wygeneruj tagi. Oceń technicznie w skali 0-6. Nie dodawaj interpretacji emocjonalnych, relacji między ludźmi ani sugestii przeznaczenia zdjęcia. Skup się wyłącznie na fizycznym obrazie. Rozpoznaj czy to dokument.\nJSON format: {\"description\": \"string\", \"tags\": [\"string\"], \"rating\": int, \"isDocument\": bool}"
        
        let requestBody: [String: Any] = [
            "contents": [["parts": [["text": prompt], ["inline_data": ["mime_type": "image/jpeg", "data": imageData.base64EncodedString()]]]]],
            "generationConfig": ["responseMimeType": "application/json", "temperature": 0.2]
        ]
        
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        var text = ""
        
        if let candidates = json?["candidates"] as? [[String: Any]],
           let firstCandidate = candidates.first,
           let content = firstCandidate["content"] as? [String: Any],
           let parts = content["parts"] as? [[String: Any]],
           let firstPart = parts.first,
           let parsedText = firstPart["text"] as? String {
            text = parsedText
        }
        
        var cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanText.hasPrefix("```json") { cleanText.removeFirst(7) }
        if cleanText.hasSuffix("```") { cleanText.removeLast(3) }
        
        let responseData = cleanText.data(using: .utf8) ?? Data()
        return try JSONDecoder().decode(AIResponse.self, from: responseData)
    }
    
    nonisolated private func writeXMP(to path: String, description: String, tags: [String]) {
        let xmpURL = URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("xmp")
        let tagsLI = tags.map { "<rdf:li>\($0)</rdf:li>" }.joined(separator: "\n")
        
        let content = """
        <?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:description><rdf:Alt><rdf:li xml:lang="x-default">\(description)</rdf:li></rdf:Alt></dc:description>
        <dc:subject><rdf:Bag>
        \(tagsLI)
        </rdf:Bag></dc:subject>
        </rdf:Description></rdf:RDF></x:xmpmeta><?xpacket end="w"?>
        """
        try? content.write(to: xmpURL, atomically: true, encoding: .utf8)
    }
    
    // --- FUNKCJE STATYCZNE ---
    nonisolated private func extractFacesFromPythonAPI(imageData: Data) async -> [FaceData]? {
        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = "127.0.0.1"
        comps.port = 8000
        comps.path = "/extract"
        guard let url = comps.url else { return nil }
        
        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"image.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        
        let session = URLSession(configuration: .ephemeral)
        do {
            let (data, response) = try await session.data(for: request)
            guard let res = response as? HTTPURLResponse, res.statusCode == 200 else { return nil }
            let decoded = try JSONDecoder().decode(FaceResponse.self, from: data)
            return decoded.faces
        } catch {
            return nil
        }
    }
    
    nonisolated static func cropImage(from imageData: Data, bbox: [Float]) -> Data? {
        guard let image = NSImage(data: imageData), let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let x1 = CGFloat(bbox[0]); let y1 = CGFloat(bbox[1]); let x2 = CGFloat(bbox[2]); let y2 = CGFloat(bbox[3])
        let width = max(x2 - x1, 10); let height = max(y2 - y1, 10)
        
        var rect = CGRect(x: x1, y: y1, width: width, height: height)
        rect = rect.insetBy(dx: -rect.width * 0.3, dy: -rect.height * 0.3)
        rect.origin.x = max(rect.origin.x, 0)
        rect.origin.y = max(rect.origin.y, 0)
        rect.size.width = min(rect.size.width, CGFloat(cgImage.width) - rect.origin.x)
        rect.size.height = min(rect.size.height, CGFloat(cgImage.height) - rect.origin.y)
        
        guard let cropped = cgImage.cropping(to: rect) else { return nil }
        let finalNSImage = NSImage(cgImage: cropped, size: .zero)
        
        if let tiff = finalNSImage.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
            return jpeg
        }
        return nil
    }
    
    nonisolated static func cosineDistance(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, a.count > 0 else { return 1.0 }
        var dotProduct: Double = 0; var magA: Double = 0; var magB: Double = 0
        for i in 0..<a.count {
            dotProduct += a[i] * b[i]
            magA += a[i] * a[i]
            magB += b[i] * b[i]
        }
        magA = sqrt(magA); magB = sqrt(magB)
        if magA == 0 || magB == 0 { return 1.0 }
        return 1.0 - (dotProduct / (magA * magB))
    }
    
    private func getOrCreateFolderHierarchy(components: [String], context: ModelContext, cache: inout [String: VirtualFolder]) -> VirtualFolder? {
        if components.isEmpty { return nil }
        let pathKey = components.joined(separator: "/")
        if let cached = cache[pathKey] { return cached }
        
        let folderName = components.last!
        let folder = VirtualFolder(name: folderName)
        context.insert(folder)
        
        if let vDate = extractVirtualDate(from: folderName, allowShort: true) {
            folder.virtualDateString = vDate
        }
        if !Array(components.dropLast()).isEmpty {
            folder.parentFolder = getOrCreateFolderHierarchy(components: Array(components.dropLast()), context: context, cache: &cache)
        }
        cache[pathKey] = folder
        return folder
    }
    
    private func getOrCreateEvent(name: String, context: ModelContext, cache: inout [String: EventFolder]) -> EventFolder {
        if let cached = cache[name] { return cached }
        let event = EventFolder(name: name, generatedAutomatically: true)
        if name == "Sieroty" { event.eventDescription = "Zdjęcia bez daty utworzenia." }
        context.insert(event)
        cache[name] = event
        return event
    }
    
    private func extractVirtualDate(from string: String, allowShort: Bool) -> String? {
        let longPattern = "[0-9xX]{4}[-/.\\_][0-9xX]{2}[-/.\\_][0-9xX]{2}|[0-9xX]{4}[-/.\\_][0-9xX]{2}"
        let shortPattern = "[0-9xX]{4}"
        let pattern = allowShort ? "\(longPattern)|\(shortPattern)" : longPattern
        
        if let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) {
            if let range = Range(match.range, in: string) {
                return String(string[range]).uppercased().replacingOccurrences(of: "_", with: "-").replacingOccurrences(of: ".", with: "-")
            }
        }
        return nil
    }
    
    nonisolated static func extractDateOnly(from url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any], let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any], let dateStr = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String else { return nil }
        return String(dateStr.split(separator: " ").first ?? "").replacingOccurrences(of: ":", with: "-")
    }
    
    nonisolated static func generateThumbnail(for url: URL, maxPixelSize: Int) -> Data? {
        return autoreleasepool {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
            ]
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            let mutableData = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(mutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, cgImage, nil)
            CGImageDestinationFinalize(destination)
            return mutableData as Data
        }
    }
}
