

<img width="1318" height="828" alt="Screenshot" src="https://github.com/user-attachments/assets/4342f848-fcd6-4e68-8888-19d57c84bc4a" />


# AIPhotoManager

An advanced, AI-powered local photo management application built natively for macOS using **SwiftUI**, **SwiftData**, and **Google Gemini API**, integrated with a local Python-based face recognition engine.

---

## Language / Język
* [English](#english-version)
* [Polski (Wersja polska)](#wersja-polska)

---

# English Version

> ⚠️ **Important Note on Language**: Please note that while this documentation is provided in English, the **application user interface (UI) and all text within the app are exclusively in Polish**.

**AIPhotoManager** is a modern desktop application designed to catalog, tag, rate, and manage massive photo libraries (tested on up to 300k+ assets) locally on your Mac. By combining cloud-based multimodal AI with efficient local compute, it delivers semantic search capabilities, facial recognition, and automated organization without compromising performance.

## 🚀 Key Features

- **Multimodal AI Analysis**: Connects with **Google Gemini (1.5 Flash / 3.1 Flash-Lite)** via a secure API layout to automatically describe images in Polish, extract up to 10 highly relevant keywords, rate photo quality (0-6 scale), and detect documents.
- **Local Facial Recognition**: Features an embedded high-resolution face recognition scanner powered by a local Python server execution layer (`face_server`). It detects faces, extracts high-dimensional embeddings, and clusters them using custom Cosine Distance matching (threshold < 0.65) to group people with zero cloud dependency.
- **Smart Folder & Event Hierarchy**: Implements automated and manual hierarchical clustering. Extracts virtual dates dynamically from file names and path strings (`YYYY-MM-DD` / decades) to build chronological structures.
- **XMP Sidecar Serialization**: Ensures complete portability by writing all AI-generated tags and descriptions back to standardized `.xmp` sidecar files directly on your storage/NAS.
- **Advanced UI/UX Architecture**: Uses a custom-engineered multi-selection drag-and-drop grid overlay with responsive coordinate space mapping, side inspectors for atomic details, and a 200MB/2000-image reactive memory cache (`NSCache`) to ensure buttery-smooth scrolling.
- **Smart Synchronization Backup**: Includes a background backup architecture supporting full archival duplication or rapid smart syncing (copying only new thumbnails and database states).

## 🔒 Safety & Budget Protections (Friction by Design)

- **Database Wipe Safeguard**: To prevent accidental total database destruction and catastrophic cloud API re-scan expenses, the data wipe function implements an intentional barrier (**Friction by Design**). Inspired directly by GitHub's repository deletion confirmation flow (where a user must type the full repo name), this app scales down the verification to a hardcoded developer PIN (`8203`). This forces explicit confirmation from the user before executing destructive tasks.

## ⚙️ Architecture & Technical Stack

- **Frontend**: SwiftUI (macOS 14+ / 15+) using modern architectures like `@Observable`, advanced window layouts (`Settings`, `NavigationSplitView`), and structural layouts (`FlowLayout`).
- **Database**: SwiftData with concurrent worker mapping (`actor ScannerService`), background `ModelContext` batching to prevent RAM memory exhaustion, and cascading lifecycle delete rules.
- **AI Backend Gateway**: Built-in multipart runner connecting to local sub-processes (`Process()`) and isolated URLSession network tasks for external cloud engines.

## 📦 Prerequisites & Local AI Engine Installation

> ⚠️ **Repository Exclusion Notice**: Due to GitHub's file size limits (>25MB for web / >100MB for Git CLI), the pre-compiled Python binary `face_server` (responsible for offline facial recognition and biometric vector embeddings) is **excluded from this repository via `.gitignore`**. You must download it separately from the **Releases** tab.

### Installation Instructions:
1. Navigate to the **Releases** section on the right side of this GitHub repository page.
2. Download the `face_server.zip` asset from the latest release.
3. Extract the ZIP archive to obtain the standalone executable file named `face_server`.
4. Open this project in **Xcode**.
5. Drag and drop the `face_server` binary directly into your Xcode project structure under the `AIPhotoManager` folder.
6. In the Xcode dialog prompt, make sure to check:
   - **"Copy items if needed"**
   - **"Create folder references"** (or Groups)
   - Ensure it is checked under **Targets** -> **AIPhotoManager**.
7. Verify under **Project Settings** -> **Build Phases** -> **Copy Bundle Resources** that `face_server` is correctly listed.

*Note: Because this binary is compiled locally without an Apple Developer certificate, macOS Gatekeeper may block it on the first launch. If this occurs, navigate to macOS System Settings -> Privacy & Security and click "Allow Anyway" for `face_server`.*

## 📄 License & Terms of Use

This project is open-source. You are completely free to modify, alter, share, and redistribute this software **strictly under the condition that you provide prominent attribution to the original author by referencing the original GitHub profile/repository from which it was downloaded.** Commercial distribution or repackaging without author attribution is strictly prohibited.

---

# Wersja Polska

> ⚠️ **Ważna uwaga dotycząca języka**: Interfejs użytkownika (UI) oraz wszystkie teksty wewnątrz aplikacji są dostępne **wyłącznie w języku polskim**.

**AIPhotoManager** to zaawansowana aplikacja natywna dla systemu macOS, stworzona do katalogowania, tagowania, oceniania i zarządzania potężnymi bibliotekami zdjęć (projektowany z myślą o bazach przekraczających 300 000 plików) bezpośrednio na Twoim komputerze. Łączy moc chmurowych modeli multimodalnych z wydajnością lokalnego przetwarzania sieci neuronowych.

## 🚀 Główne Funkcje

- **Multimodalna Analiza AI**: Integracja z modelami **Google Gemini (1.5 Flash / 3.1 Flash-Lite)** za pomocą bezpiecznego klucza API. Automatycznie generuje precyzyjne opisy w języku polskim, wyciąga do 10 powiązanych słów kluczowych, ocenia estetykę/wartość zdjęcia (skala 0-6) oraz inteligentnie segreguje dokumenty tekstowe od fotografii.
- **Lokalne Rozpoznawanie Twarzy**: Wbudowany skaner wysokiej rozdzielczości zintegrowany z lokalnym serwerem Pythona (`face_server`). Wykrywa twarze, wyciąga wektory cech (embeddings) i automatycznie grupuje profile osób za pomocą spersonalizowanego algorytmu odległości cosinusowej (Cosine Distance, próg < 0.65).
- **Struktura Albumów i Wydarzeń**: Dynamiczne parzowanie wirtualnych dat z nazw plików oraz ścieżek katalogów (wzorzec `YYYY-MM-DD` lub dekady typu `199X`), budując chronologiczny porządek w bazie SwiftData.
- **Kompatybilność z Plikami XMP**: Wszystkie metadane, tagi twarzy oraz opisy AI są automatycznie synchronizowane do standardowych plików tekstowych `.xmp` (sidecar files), co gwarantuje pełną przenośność danych bez utraty efektów pracy na dyskach sieciowych NAS.
- **Wyrafinowany Interfejs UX**: Własnoręcznie zaprojektowany system masowego zaznaczania zdjęć za pomocą prostokąta przeciągania myszką w siatce `LazyVGrid`, dynamiczny panel Inspektora oraz reaktywna pamięć podręczna `NSCache` (limit 200MB / 2000 miniatur) dbająca o idealną płynność działania interfejsu.
- **Menedżer Kopii Zapasowych**: Wbudowany system automatycznego monitorowania stanu bazy danych (przypomnienia po 7 dniach) z opcją inteligentnej synchronizacji przyrostowej, oszczędzającej czas i pamięć RAM.

## 🔒 Bezpieczeństwo i Finanse (Friction by Design)

- **Blokada resetu bazy**: Aby całkowicie wykluczyć ryzyko przypadkowego wyczyszczenia bazy danych i wygenerowania ogromnych kosztów ponownego skanowania przez chmurowe API, mechanizm czyszczenia implementuje celowy opór interfejsu użytkownika (**Friction by Design**). Rozwiązanie to jest inspirowane mechanizmem bezpieczeństwa z platformy GitHub (gdzie usuwanie repozytorium wymaga ręcznego przepisania jego pełnej nazwy). Na potrzeby wygody w lokalnej aplikacji desktopowej mechanizm ten został uproszczony do konieczności podania z góry ustalonego kodu PIN (`8203`), chroniąc portfel użytkownika przed odruchowym zatwierdzaniem krytycznych wyskakujących okien.

## ⚙️ Architektura i Stack Technologiczny

- **Frontend**: SwiftUI (macOS 14+ / 15+) oparty o makra `@Observable`, zaawansowane sceny systemowe (`Settings`, `NavigationSplitView`) oraz autorskie kontenery widoków (`FlowLayout`).
- **Baza Danych**: SwiftData z wielowątkowym przetwarzaniem wewnątrz bezpiecznego kontekstu aktora (`actor ScannerService`), wykorzystująca technikę wsadowego zapisu (batching) w celu optymalizacji pamięci RAM przy operacjach masowych.
- **Wsparcie Tła**: Zarządzanie procesami systemowymi za pośrednictwem `Process()` i blokad aktywności tła (`beginActivity`) zapobiegających usypianiu systemu w trakcie ciężkich analiz fotografii.

## 📦 Wymagania i Instalacja Lokalnego Silnika AI

> ⚠️ **Uwaga dotycząca rozmiaru plików**: Ze względu na rygorystyczne limity rozmiaru plików na platformie GitHub (>25MB dla przeglądarki / >100MB dla systemu Git CLI), skompilowany binarnie silnik Pythona `face_server` (odpowiedzialny za bezchmurowe rozpoznawanie twarzy i wektoryzację cech biometrycznych) **został wykluczony z repozytorium kodu za pomocą pliku `.gitignore`**. Należy pobrać go osobno z zakładki **Releases**.

### Instrukcja krok po kroku:
1. Przejdź do sekcji **Releases** po prawej stronie głównej strony tego repozytorium GitHub.
2. Pobierz paczkę `face_server.zip` przypisaną do najnowszego wydania.
3. Rozpakuj pobrane archiwum ZIP na swoim komputerze, aby uzyskać samodzielny plik wykonywalny o nazwie `face_server`.
4. Otwórz projekt aplikacji w środowisku **Xcode**.
5. Przeciągnij rozpakowany plik wykonywalny `face_server` bezpośrednio do struktury plików projektu w Xcode, umieszczając go w folderze `AIPhotoManager`.
6. W oknie dialogowym Xcode upewnij się, że zaznaczyłeś opcje:
   - **"Copy items if needed"**
   - **"Create groups"** (lub Folder references)
   - Twój główny target docelowy: **AIPhotoManager**.
7. Wejdź w ustawienia projektu -> **Build Phases** -> **Copy Bundle Resources** i upewnij się, że plik `face_server` znajduje się na liście zasobów.

*Uwaga: Ponieważ plik binarny nie posiada podpisu cyfrowego zarejestrowanego dewelopera Apple, system macOS Gatekeeper zablokuje jego wykonanie przy pierwszym uruchomieniu. Należy wówczas wejść w Ustawienia systemowe -> Prywatność i bezpieczeństwo i kliknąć przycisk „Pozwól na uruchomienie” (Allow Anyway) dla procesu face_server.*

## 📄 Licencja i Warunki Użycia

Projekt udostępniany jest na zasadach open-source. **Modyfikacja, rozpowszechnianie i używanie kodu jest w pełni dozwolone pod JEDYNYM warunkiem: wyraźnego i widocznego wskazania oryginalnego autora projektu poprzez podanie nazwy profilu GitHub lub bezpośredniego linku do tego repozytorium.** Wykorzystanie komercyjne bez podania źródła jest zabronione.
