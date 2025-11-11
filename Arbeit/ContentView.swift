// MARK: - ContentView.swift
import SwiftUI
import UserNotifications
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

// MARK: - Auftrag Model
struct Auftrag: Identifiable, Codable {
    let id: UUID
    var nummer: String
    var datum: Date = Date()
    var startzeit: Date?
    var endzeit: Date?
    var ruestZeit: TimeInterval = 0
    var pauseZeit: TimeInterval = 0
    var gutStueck: Int = 0
    var schlechtStueck: Int = 0
    var notizen: String = ""
    var isRunning: Bool = false
    var isRuesten: Bool = false
    var isFertig: Bool = false
    var isEditable: Bool = false
    var lastStart: Date?
    var lastPauseStart: Date?
    
    // Optionale Felder für manuelle Zeiten (aktuell nicht genutzt)
    var manuelleArbeitszeit: Double?
    var manuelleRuestzeit: Double?
    
    var gesamtZeit: TimeInterval {
        if let manuell = manuelleArbeitszeit {
            return manuell * 3600
        }
        var zeit = pauseZeit
        if let last = lastStart, isRunning && !isRuesten {
            zeit += Date().timeIntervalSince(last)
        }
        return zeit
    }
    
    func dezimalStunden(_ sekunden: TimeInterval) -> Double {
        let stunden = sekunden / 3600
        return Double(round(100 * stunden) / 100)
    }
    
    var aktuelleRuestZeit: TimeInterval {
        if let manuell = manuelleRuestzeit {
            return manuell * 3600
        }
        var zeit = ruestZeit
        if let last = lastStart, isRunning && isRuesten {
            zeit += Date().timeIntervalSince(last)
        }
        return zeit
    }
    
    var aktuellePauseZeit: TimeInterval {
        var zeit = pauseZeit
        // Wenn aktuell läuft und nicht gerüstet wird, zählt die Zeit NICHT zur Pause
        // Pausenzeit wächst nur, wenn der Auftrag angehalten ist (isRunning == false)
        if let last = lastStart, !isRunning {
            zeit += Date().timeIntervalSince(last)
        }
        return zeit
    }
    
    // Echte Pausenzeit: nur innerhalb der tatsächlichen Laufzeit (Start -> Ende/Jetzt)
    var echtePauseZeit: TimeInterval {
        // Basisgrenzen bestimmen
        guard let start = startzeit else { return 0 }
        let ende = endzeit ?? Date()
        if ende <= start { return 0 }
        
        // Bereits verbuchte Pausenzeit als Ausgangsbasis
        var zeit = pauseZeit
        
        // Laufende Pause berücksichtigen (nur wenn aktuell nicht läuft und es einen Pausenbeginn gibt)
        if !isRunning, let pauseStart = lastPauseStart {
            // Laufende Pause endet spätestens am Ende des Auftragszeitraums
            let pauseEnde = min(Date(), ende)
            if pauseEnde > pauseStart {
                zeit += pauseEnde.timeIntervalSince(pauseStart)
            }
        }
        
        // Pausenzeit darf die Gesamtdauer nicht überschreiten
        let gesamtDauer = ende.timeIntervalSince(start)
        return max(0, min(zeit, gesamtDauer))
    }
    
    // Gesamtdauer von Start bis Ende (oder jetzt)
    var gesamtDauer: TimeInterval {
        guard let start = startzeit else { return 0 }
        let ende = endzeit ?? Date()
        if ende <= start { return 0 }
        return ende.timeIntervalSince(start)
    }
    
    // Reine Arbeitszeit: Gesamtdauer minus Rüstzeit minus echte Pause
    var arbeitsZeit: TimeInterval {
        guard let start = startzeit else { return 0 }
        let ende = endzeit ?? Date()
        if ende <= start { return 0 }
        let dauer = ende.timeIntervalSince(start)
        let arbeit = dauer - aktuelleRuestZeit - echtePauseZeit
        return max(0, arbeit)
    }
}

// MARK: - ViewModel
class AuftragViewModel: ObservableObject {
    @Published var auftraege: [Auftrag] = [] {
        didSet {
            saveData()
            let running = auftraege.filter { !$0.isFertig }
            let snapshot = running.map { a in
                ConnectivityManager.LightweightOrder(id: a.id, nummer: a.nummer, isRunning: a.isRunning, isRuesten: a.isRuesten, isFertig: a.isFertig, datum: a.datum)
            }
            ConnectivityManager.shared.sendRunningOrders(snapshot)
        }
    }
    
    init() { loadData() }
    
    let speicherKey = "auftraege"
    
    func addAuftrag(nummer: String) {
        let neuer = Auftrag(id: UUID(), nummer: nummer, startzeit: Date(), isRunning: true, lastStart: Date())
        auftraege.insert(neuer, at: 0)
    }
    
    func startPause(_ auftrag: Auftrag) {
        guard let index = auftraege.firstIndex(where: { $0.id == auftrag.id }),
              !auftraege[index].isFertig || auftraege[index].isEditable else { return }

        if auftraege[index].isRunning {
            // We are transitioning from running to paused
            if let last = auftraege[index].lastStart {
                if auftraege[index].isRuesten {
                    // Close running ruest phase up to now
                    auftraege[index].ruestZeit += Date().timeIntervalSince(last)
                    auftraege[index].isRuesten = false
                } else {
                    // Do NOT add pause time here; live pause starts now
                }
            }
            // Enter pause
            auftraege[index].isRunning = false
            if !auftraege[index].isRuesten {
                auftraege[index].lastPauseStart = Date()
            }
        } else {
            // We are transitioning from paused to running
            if let pauseStart = auftraege[index].lastPauseStart {
                // Book the live pause duration once, then clear marker
                auftraege[index].pauseZeit += Date().timeIntervalSince(pauseStart)
                auftraege[index].lastPauseStart = nil
            }
            if auftraege[index].startzeit == nil {
                auftraege[index].startzeit = Date()
            }
            auftraege[index].lastStart = Date()
            auftraege[index].isRunning = true
        }
    }
    
    func startRuest(_ auftrag: Auftrag) {
        guard let index = auftraege.firstIndex(where: { $0.id == auftrag.id }),
              !auftraege[index].isFertig || auftraege[index].isEditable else { return }
        
        if auftraege[index].isRunning {
            if auftraege[index].isRuesten {
                if let last = auftraege[index].lastStart {
                    auftraege[index].ruestZeit += Date().timeIntervalSince(last)
                }
                auftraege[index].isRuesten = false
                auftraege[index].lastStart = Date()
            } else {
                auftraege[index].isRuesten = true
                auftraege[index].lastStart = Date()
            }
        }
    }
    
    func beenden(_ auftrag: Auftrag) {
        guard let index = auftraege.firstIndex(where: { $0.id == auftrag.id }) else { return }
        if auftraege[index].isRunning, let last = auftraege[index].lastStart {
            if auftraege[index].isRuesten {
                auftraege[index].ruestZeit += Date().timeIntervalSince(last)
                auftraege[index].isRuesten = false
            } else {
                // Wenn tatsächlich eine aktive Laufphase war, keine Pause addieren
                // Pausen werden separat über lastPauseStart erfasst, wenn isRunning == false
            }
        } else if !auftraege[index].isRunning, let pauseStart = auftraege[index].lastPauseStart {
            // Falls der Auftrag in einer Pause beendet wird, diese Pause bis jetzt verbuchen
            auftraege[index].pauseZeit += Date().timeIntervalSince(pauseStart)
            auftraege[index].lastPauseStart = nil
        }
        auftraege[index].isRunning = false
        auftraege[index].isFertig = true
        auftraege[index].isEditable = false
        auftraege[index].endzeit = Date()
        auftraege[index].lastPauseStart = nil
    }
    
    func toggleBearbeiten(_ auftrag: Auftrag) {
        guard let index = auftraege.firstIndex(where: { $0.id == auftrag.id }) else { return }
        auftraege[index].isEditable.toggle()
    }
    
    func deleteAuftrag(at offsets: IndexSet) {
        auftraege.remove(atOffsets: offsets)
    }
    
    // MARK: - Speicherung
    func saveData() {
        if let encoded = try? JSONEncoder().encode(auftraege) {
            UserDefaults.standard.set(encoded, forKey: speicherKey)
        }
    }
    
    func loadData() {
        if let saved = UserDefaults.standard.data(forKey: speicherKey),
           let decoded = try? JSONDecoder().decode([Auftrag].self, from: saved) {
            auftraege = decoded
        }
    }
    
    var groupedByDay: [String: [Auftrag]] {
        let df = DateFormatter()
        df.dateStyle = .medium
        var dict: [String: [Auftrag]] = [:]
        for auftrag in auftraege {
            let tag = df.string(from: Calendar.current.startOfDay(for: auftrag.datum))
            dict[tag, default: []].append(auftrag)
        }
        return dict
    }
    
    var finishedByYear: [Int: [Auftrag]] {
        let calendar = Calendar.current
        var dict: [Int: [Auftrag]] = [:]
        for a in auftraege where a.isFertig {
            let year = calendar.component(.year, from: a.datum)
            dict[year, default: []].append(a)
        }
        return dict
    }

    func finishedByMonth(in year: Int) -> [Int: [Auftrag]] {
        let calendar = Calendar.current
        var dict: [Int: [Auftrag]] = [:]
        for a in finishedByYear[year] ?? [] {
            let month = calendar.component(.month, from: a.datum)
            dict[month, default: []].append(a)
        }
        return dict
    }

    func finishedByDay(in year: Int, month: Int) -> [Date: [Auftrag]] {
        let calendar = Calendar.current
        var dict: [Date: [Auftrag]] = [:]
        for a in finishedByMonth(in: year)[month] ?? [] {
            let dayStart = calendar.startOfDay(for: a.datum)
            dict[dayStart, default: []].append(a)
        }
        return dict
    }
}


// MARK: - ContentView
struct ContentView: View {
    @StateObject var vm = AuftragViewModel()
    @State private var neueNummer = ""
    @State private var timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var expandedDays: Set<String> = [DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .none)]
    @State private var isRauchenActive: Bool = false
    @State private var rauchPauseIDs: [UUID] = []
    @State private var search: String = ""
    
    @State private var savedNumbers: [String] = []
    @State private var showSavedSheet: Bool = false
    @State private var newSavedNumber: String = ""
    
    private let connectivity = ConnectivityManager.shared
    
    enum SidebarItem: String, CaseIterable, Identifiable {
        case laufend
        case beendet
        
        var id: String { rawValue }
        
        var label: String {
            switch self {
            case .laufend: return "Laufend"
            case .beendet: return "Beendet"
            }
        }
        
        var systemImage: String {
            switch self {
            case .laufend: return "play.circle"
            case .beendet: return "checkmark.circle"
            }
        }
    }
    
    @State private var selection: SidebarItem? = .laufend
    
    @Environment(\.horizontalSizeClass) private var hSizeClass
    
    let datumFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .short
        return df
    }()
    
    let monthFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale.current
        df.dateFormat = "LLLL" // Full month name
        return df
    }()

    let dayOnlyFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .none
        return df
    }()
    
    @State private var ausgabe = ""
    @State private var warnung: String? = nil
    
    var body: some View {
        Group {
            if hSizeClass == .compact {
                // iPhone: Tab bar unten mit drei Tabs
                TabView {
                    NavigationStack { laufendView }
                        .tabItem { Label("Laufend", systemImage: "play.circle") }

                    NavigationStack { beendetView }
                        .tabItem { Label("Beendet", systemImage: "checkmark.circle") }
                }
            } else {
                // iPad/Mac: Behalte die Sidebar-Navigation
                NavigationSplitView {
                    List(selection: $selection) {
                        ForEach(SidebarItem.allCases) { item in
                            Label(item.label, systemImage: item.systemImage)
                                .tag(item as SidebarItem?)
                        }
                    }
                    .navigationTitle("Übersicht")
                    .listStyle(.sidebar)
                } detail: {
                    switch selection {
                    case .laufend:
                        laufendView
                    case .beendet:
                        beendetView
                    case .none:
                        Text("Bitte wählen")
                    }
                }
                .toolbar {
                    ToolbarItemGroup(placement: .topBarLeading) {
                        Button { selection = .laufend } label: { Label("Laufend", systemImage: "play.circle") }
                        Button { selection = .beendet } label: { Label("Beendet", systemImage: "checkmark.circle") }
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {
                            let nummer = neueNummer.isEmpty ? "NEU-\(Int.random(in: 1000...9999))" : neueNummer
                            vm.addAuftrag(nummer: nummer)
                            neueNummer = ""
                        } label: {
                            Label("Neuer Auftrag", systemImage: "plus")
                        }
                    }
                }
                .tint(.blue)
                .background(.ultraThinMaterial)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Color.black.opacity(0.08)).frame(height: 0.5)
                }
                .onChange(of: selection) { oldValue, newValue in
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }
        }
        .onAppear {
            connectivity.addOrder = { nummer in
                vm.addAuftrag(nummer: nummer)
            }
            connectivity.pauseOrResume = { id in
                if let a = vm.auftraege.first(where: { $0.id == id }) {
                    vm.startPause(a)
                }
            }
            connectivity.toggleRuest = { id in
                if let a = vm.auftraege.first(where: { $0.id == id }) {
                    vm.startRuest(a)
                }
            }
            connectivity.endOrder = { id in
                if let a = vm.auftraege.first(where: { $0.id == id }) {
                    vm.beenden(a)
                }
            }
            let running = vm.auftraege.filter { !$0.isFertig }
            let snapshot = running.map { a in
                ConnectivityManager.LightweightOrder(id: a.id, nummer: a.nummer, isRunning: a.isRunning, isRuesten: a.isRuesten, isFertig: a.isFertig, datum: a.datum)
            }
            connectivity.sendRunningOrders(snapshot)
        }
    }
    
    @ViewBuilder
    var laufendView: some View {
        NavigationStack {
            let openItems = vm.auftraege.filter { !$0.isFertig }
                .sorted(by: { $0.datum > $1.datum })
            List {
                ForEach(openItems) { auftrag in
                    AuftragRow(auftrag: auftrag, vm: vm, datumFormatter: datumFormatter)
                }
            }
            .listStyle(.plain)
            .listRowSeparator(.hidden)
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Laufende Aufträge")
            .sheet(isPresented: $showSavedSheet, onDismiss: { hideKeyboard() }) {
                NavigationStack {
                    VStack(spacing: 12) {
                        HStack(spacing: 8) {
                            TextField("Neue Auftragsnummer speichern", text: $newSavedNumber)
                                .textFieldStyle(.roundedBorder)
                                .textInputAutocapitalization(.none)
                                .autocorrectionDisabled()
                                .submitLabel(.done)
                                .onSubmit { addSavedNumber() }
                            Button(action: addSavedNumber) {
                                Label("Hinzufügen", systemImage: "plus.circle.fill")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(.horizontal)

                        if savedNumbers.isEmpty {
                            ContentUnavailableView("Keine gespeicherten Nummern", systemImage: "tray")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            List {
                                ForEach(savedNumbers, id: \.self) { nummer in
                                    Button {
                                        vm.addAuftrag(nummer: nummer)
                                        showSavedSheet = false
                                    } label: {
                                        HStack {
                                            Image(systemName: "play.circle.fill").foregroundStyle(.green)
                                            Text(nummer)
                                            Spacer()
                                        }
                                    }
                                }
                                .onDelete(perform: removeSavedNumber)
                            }
                            .listStyle(.insetGrouped)
                        }
                    }
                    .navigationTitle("Gespeicherte Nummern")
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Fertig") { showSavedSheet = false }
                        }
                    }
                    .onAppear { loadSavedNumbers() }
                }
                .presentationDetents([.medium, .large])
            }
        }
        .safeAreaInset(edge: .top) {
            HStack(spacing: 12) {
                TextField("Auftragsnummer", text: $neueNummer)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.none)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                Button {
                    guard !neueNummer.isEmpty else { return }
                    vm.addAuftrag(nummer: neueNummer)
                    neueNummer = ""
                    hideKeyboard()
                } label: {
                    Label("Start", systemImage: "play.fill")
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)
                Button {
                    showSavedSheet = true
                } label: {
                    Label("Gespeichert", systemImage: "externaldrive")
                        .labelStyle(.iconOnly)
                        .font(.headline)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(.regularMaterial)
            .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 4)
        }
        .onReceive(timer) { _ in
            let hasRunningOrder = vm.auftraege.contains { $0.isRunning }
            let hasActivePause = vm.auftraege.contains { !$0.isRunning && $0.lastPauseStart != nil && !$0.isFertig }
            if hasRunningOrder || hasActivePause {
                vm.objectWillChange.send()
            }
        }
    }
    
    @ViewBuilder
    var beendetView: some View {
        NavigationStack {
            let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
            if !query.isEmpty {
                // Flat list of matching finished orders
                let allFinished = vm.auftraege.filter { $0.isFertig }
                let matches = allFinished
                    .filter { $0.nummer.localizedCaseInsensitiveContains(query) }
                    .sorted { $0.datum > $1.datum }
                List {
                    if matches.isEmpty {
                        ContentUnavailableView("Keine Treffer", systemImage: "magnifyingglass", description: Text("Keine beendeten Aufträge mit dieser Nummer gefunden."))
                    } else {
                        ForEach(matches) { auftrag in
                            AuftragRow(auftrag: auftrag, vm: vm, datumFormatter: datumFormatter)
                        }
                    }
                }
                .listStyle(.plain)
                .listRowSeparator(.hidden)
                .scrollContentBackground(.hidden)
                .background(Color(.systemGroupedBackground))
                .navigationTitle("Beendete Aufträge")
                .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Nach Nummer suchen")
            } else {
                // Hierarchical view: Year > Month > Day
                List {
                    // Beendete Aufträge: Jahr > Monat > Tag > Aufträge
                    let years = vm.finishedByYear.keys.sorted(by: >)
                    ForEach(years, id: \.self) { year in
                        Section(header: Text(String(year)).bold()) {
                            let monthsDict = vm.finishedByMonth(in: year)
                            let months = monthsDict.keys.sorted(by: >)
                            ForEach(months, id: \.self) { month in
                                NavigationLink {
                                    // Day level
                                    let daysDict = vm.finishedByDay(in: year, month: month)
                                    let days = daysDict.keys.sorted(by: >)
                                    List {
                                        ForEach(days, id: \.self) { day in
                                            NavigationLink {
                                                // Orders for the selected day
                                                let orders = (daysDict[day] ?? [])
                                                    .sorted { $0.datum > $1.datum }
                                                List {
                                                    ForEach(orders) { auftrag in
                                                        AuftragRow(auftrag: auftrag, vm: vm, datumFormatter: datumFormatter)
                                                    }
                                                }
                                                .listStyle(.plain)
                                                .listRowSeparator(.hidden)
                                                .scrollContentBackground(.hidden)
                                                .background(Color(.systemGroupedBackground))
                                                .navigationTitle(dayOnlyFormatter.string(from: day))
                                            } label: {
                                                HStack {
                                                    Text(dayOnlyFormatter.string(from: day))
                                                    Spacer()
                                                    Text("\(daysDict[day]?.count ?? 0)")
                                                        .foregroundStyle(.secondary)
                                                }
                                                .contentShape(Rectangle())
                                                .padding(.vertical, 8)
                                            }
                                        }
                                    }
                                    .listStyle(.plain)
                                    .listRowSeparator(.hidden)
                                    .scrollContentBackground(.hidden)
                                    .background(Color(.systemGroupedBackground))
                                    .navigationTitle("\(monthFormatter.monthSymbols[month-1]) \(year)")
                                } label: {
                                    HStack {
                                        Text(monthFormatter.monthSymbols[month-1])
                                        Spacer()
                                        Text("\(monthsDict[month]?.count ?? 0)")
                                            .foregroundStyle(.secondary)
                                    }
                                    .contentShape(Rectangle())
                                    .padding(.vertical, 8)
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .listRowSeparator(.hidden)
                .scrollContentBackground(.hidden)
                .background(Color(.systemGroupedBackground))
                .navigationTitle("Beendete Aufträge")
                .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Nach Nummer suchen")
            }
        }
    }
    
    func pauseAllForRauchen() {
        rauchPauseIDs = []
        for i in vm.auftraege.indices {
            if vm.auftraege[i].isRunning {
                rauchPauseIDs.append(vm.auftraege[i].id)
                if let last = vm.auftraege[i].lastStart {
                    if vm.auftraege[i].isRuesten {
                        vm.auftraege[i].ruestZeit += Date().timeIntervalSince(last)
                        vm.auftraege[i].isRuesten = false
                    } else {
                        vm.auftraege[i].pauseZeit += Date().timeIntervalSince(last)
                    }
                }
                vm.auftraege[i].isRunning = false
                // Sammel-Pause: Zeitpunkt der letzten Pause merken (wie bei Einzel-Pause)
                if !vm.auftraege[i].isRuesten {
                    vm.auftraege[i].lastPauseStart = Date()
                }
            }
        }
    }
    
    func resumeAfterRauchen() {
        for id in rauchPauseIDs {
            if let index = vm.auftraege.firstIndex(where: { $0.id == id }) {
                // If a collective pause was active, book it up to now
                if let pauseStart = vm.auftraege[index].lastPauseStart {
                    vm.auftraege[index].pauseZeit += Date().timeIntervalSince(pauseStart)
                    vm.auftraege[index].lastPauseStart = nil
                }
                vm.auftraege[index].isRunning = true
                vm.auftraege[index].lastStart = Date()
            }
        }
        rauchPauseIDs.removeAll()
    }
    
    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
    
    private let savedNumbersKey = "savedOrderNumbers"
    private func loadSavedNumbers() {
        if let data = UserDefaults.standard.array(forKey: savedNumbersKey) as? [String] {
            savedNumbers = data
        }
    }
    private func saveSavedNumbers() {
        UserDefaults.standard.set(savedNumbers, forKey: savedNumbersKey)
    }
    private func addSavedNumber() {
        let trimmed = newSavedNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !savedNumbers.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            savedNumbers.insert(trimmed, at: 0)
            saveSavedNumbers()
        }
        newSavedNumber = ""
        hideKeyboard()
    }
    private func removeSavedNumber(at offsets: IndexSet) {
        savedNumbers.remove(atOffsets: offsets)
        saveSavedNumbers()
    }
}

extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

// MARK: - AuftragRow
struct AuftragRow: View {
    var auftrag: Auftrag
    @ObservedObject var vm: AuftragViewModel
    var datumFormatter: DateFormatter

    private static let dateOnlyFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .none
        return df
    }()

    private static let timeOnlyFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .none
        df.timeStyle = .short
        return df
    }()
    
    @ViewBuilder
    private func statusChip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2).bold()
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Nr: \(auftrag.nummer)").font(.headline)
                Spacer()
                Text(AuftragRow.dateOnlyFormatter.string(from: auftrag.datum))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Datum \(AuftragRow.dateOnlyFormatter.string(from: auftrag.datum))")
            }
            
            HStack(spacing: 8) {
                if auftrag.isRuesten {
                    statusChip("Rüsten", color: .blue)
                } else if !auftrag.isRunning && !auftrag.isFertig {
                    statusChip("Pause", color: .orange)
                } else if auftrag.isRunning {
                    statusChip("Läuft", color: .green)
                }
                if auftrag.isFertig {
                    statusChip("Beendet", color: .gray)
                }
            }
            
            if let start = auftrag.startzeit {
                Label { Text(AuftragRow.timeOnlyFormatter.string(from: start)).font(.caption) } icon: { Image(systemName: "play.circle").foregroundStyle(.green) }
            }
            if let ende = auftrag.endzeit {
                Label { Text(AuftragRow.timeOnlyFormatter.string(from: ende)).font(.caption) } icon: { Image(systemName: "stop.circle").foregroundStyle(.red) }
            }
            if !auftrag.isRunning, let pauseStart = auftrag.lastPauseStart {
                Label {
                    Text("Pause seit: \(datumFormatter.string(from: pauseStart))").font(.caption)
                } icon: {
                    Image(systemName: "pause.circle").foregroundStyle(.orange)
                }
            }

            HStack(spacing: 12) {
                Label { Text(String(format: "%.2f h", auftrag.dezimalStunden(auftrag.gesamtDauer))) } icon: { Image(systemName: "clock") }
                .labelStyle(.titleAndIcon)
                .font(.subheadline)

                Label { Text(String(format: "%.2f h", auftrag.dezimalStunden(auftrag.aktuelleRuestZeit))) } icon: { Image(systemName: "wrench.and.screwdriver") }
                .labelStyle(.titleAndIcon)
                .font(.subheadline)
                .foregroundStyle(.secondary)

                Label { Text(String(format: "%.2f h", auftrag.dezimalStunden(auftrag.echtePauseZeit))) } icon: { Image(systemName: "pause.circle") }
                .labelStyle(.titleAndIcon)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                
                Label { Text(String(format: "%.2f h", auftrag.dezimalStunden(auftrag.arbeitsZeit))) } icon: { Image(systemName: "hammer") }
                .labelStyle(.titleAndIcon)
                .font(.subheadline)
                .foregroundStyle(.primary)
            }
            
            let total = max(auftrag.gesamtDauer, 1)
            let arbeit = min(auftrag.arbeitsZeit, total)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.2))
                    RoundedRectangle(cornerRadius: 4).fill(.green)
                        .frame(width: geo.size.width * arbeit / total)
                }
            }
            .frame(height: 6)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .padding(.top, 4)

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Gut").font(.caption).foregroundStyle(.secondary)
                    TextField("0", value: Binding(
                        get: { auftrag.gutStueck },
                        set: { neue in
                            if let index = vm.auftraege.firstIndex(where: { $0.id == auftrag.id }) {
                                vm.auftraege[index].gutStueck = max(0, neue)
                            }
                        }
                    ), formatter: NumberFormatter())
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .disabled(auftrag.isFertig && !auftrag.isEditable)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Schlecht").font(.caption).foregroundStyle(.secondary)
                    TextField("0", value: Binding(
                        get: { auftrag.schlechtStueck },
                        set: { neue in
                            if let index = vm.auftraege.firstIndex(where: { $0.id == auftrag.id }) {
                                vm.auftraege[index].schlechtStueck = max(0, neue)
                            }
                        }
                    ), formatter: NumberFormatter())
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .disabled(auftrag.isFertig && !auftrag.isEditable)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Notizen").font(.caption).foregroundStyle(.secondary)
                TextField("", text: Binding(
                    get: { auftrag.notizen },
                    set: { neue in
                        if let index = vm.auftraege.firstIndex(where: { $0.id == auftrag.id }) {
                            vm.auftraege[index].notizen = neue
                        }
                    }
                ))
                .textFieldStyle(.roundedBorder)
                .disabled(auftrag.isFertig && !auftrag.isEditable)
            }
            
            if auftrag.isEditable && auftrag.isFertig {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Rüstzeit").font(.caption).foregroundStyle(.secondary)

                    // Read-only display (always visible)
                    HStack(spacing: 6) {
                        Image(systemName: "wrench.and.screwdriver").foregroundStyle(.secondary)
                        Text("\(Int(round(auftrag.ruestZeit / 60))) min")
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                    }

                    // Editable minutes when in edit mode and not running
                    if !auftrag.isRunning {
                        HStack(spacing: 8) {
                            Image(systemName: "slider.horizontal.3").foregroundStyle(.secondary)
                            TextField(
                                "0",
                                text: Binding(
                                    get: {
                                        let minutes = Int(round(auftrag.ruestZeit / 60))
                                        return String(minutes)
                                    },
                                    set: { value in
                                        let cleaned = value.replacingOccurrences(of: ",", with: ".")
                                        if let minutes = Double(cleaned), let index = vm.auftraege.firstIndex(where: { $0.id == auftrag.id }) {
                                            let seconds = max(0, minutes * 60)
                                            vm.auftraege[index].ruestZeit = seconds
                                        }
                                    }
                                )
                            )
                            .keyboardType(.numberPad)
                            .textFieldStyle(.roundedBorder)
                            Text("min").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            
            VStack(alignment: .leading, spacing: 6) {
                Text("Pausenzeit").font(.caption).foregroundStyle(.secondary)

                // Read-only display (always visible)
                HStack(spacing: 6) {
                    Image(systemName: "pause.circle").foregroundStyle(.secondary)
                    Text({
                        var total = auftrag.pauseZeit
                        if !auftrag.isRunning, let pauseStart = auftrag.lastPauseStart {
                            total += Date().timeIntervalSince(pauseStart)
                        }
                        return "\(Int(round(total / 60))) min"
                    }())
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                }

                // Editable minutes when in edit mode and finished
                if auftrag.isEditable && auftrag.isFertig {
                    HStack(spacing: 8) {
                        Image(systemName: "slider.horizontal.3").foregroundStyle(.secondary)
                        TextField(
                            "0",
                            text: Binding(
                                get: {
                                    let minutes = Int(round(auftrag.pauseZeit / 60))
                                    return String(minutes)
                                },
                                set: { value in
                                    let cleaned = value.replacingOccurrences(of: ",", with: ".")
                                    if let minutes = Double(cleaned), let index = vm.auftraege.firstIndex(where: { $0.id == auftrag.id }) {
                                        let seconds = max(0, minutes * 60)
                                        vm.auftraege[index].pauseZeit = seconds
                                    }
                                }
                            )
                        )
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                        Text("min").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            
            if auftrag.isEditable && auftrag.isFertig {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Zeiten bearbeiten").font(.caption).foregroundStyle(.secondary)

                    // Startzeit (nur Uhrzeit)
                    DatePicker(
                        "Startzeit",
                        selection: Binding(
                            get: {
                                // Compose a date using auftrag.datum's date with startzeit's time (or now)
                                let calendar = Calendar.current
                                let baseDate = auftrag.datum
                                let timeSource = auftrag.startzeit ?? Date()
                                let dateComps = calendar.dateComponents([.year, .month, .day], from: baseDate)
                                let timeComps = calendar.dateComponents([.hour, .minute, .second], from: timeSource)
                                var comps = DateComponents()
                                comps.year = dateComps.year
                                comps.month = dateComps.month
                                comps.day = dateComps.day
                                comps.hour = timeComps.hour
                                comps.minute = timeComps.minute
                                comps.second = timeComps.second
                                return Calendar.current.date(from: comps) ?? (auftrag.startzeit ?? Date())
                            },
                            set: { newTime in
                                if let index = vm.auftraege.firstIndex(where: { $0.id == auftrag.id }) {
                                    let calendar = Calendar.current
                                    let dateComps = calendar.dateComponents([.year, .month, .day], from: vm.auftraege[index].datum)
                                    let timeComps = calendar.dateComponents([.hour, .minute, .second], from: newTime)
                                    var comps = DateComponents()
                                    comps.year = dateComps.year
                                    comps.month = dateComps.month
                                    comps.day = dateComps.day
                                    comps.hour = timeComps.hour
                                    comps.minute = timeComps.minute
                                    comps.second = timeComps.second
                                    vm.auftraege[index].startzeit = calendar.date(from: comps)
                                }
                            }
                        ),
                        displayedComponents: [.hourAndMinute]
                    )
                    
                    if let _ = auftrag.endzeit {
                        DatePicker(
                            "Endzeit",
                            selection: Binding(
                                get: {
                                    let calendar = Calendar.current
                                    let baseDate = auftrag.datum
                                    let timeSource = auftrag.endzeit ?? Date()
                                    let dateComps = calendar.dateComponents([.year, .month, .day], from: baseDate)
                                    let timeComps = calendar.dateComponents([.hour, .minute, .second], from: timeSource)
                                    var comps = DateComponents()
                                    comps.year = dateComps.year
                                    comps.month = dateComps.month
                                    comps.day = dateComps.day
                                    comps.hour = timeComps.hour
                                    comps.minute = timeComps.minute
                                    comps.second = timeComps.second
                                    return Calendar.current.date(from: comps) ?? (auftrag.endzeit ?? Date())
                                },
                                set: { newTime in
                                    if let index = vm.auftraege.firstIndex(where: { $0.id == auftrag.id }) {
                                        let calendar = Calendar.current
                                        let dateComps = calendar.dateComponents([.year, .month, .day], from: vm.auftraege[index].datum)
                                        let timeComps = calendar.dateComponents([.hour, .minute, .second], from: newTime)
                                        var comps = DateComponents()
                                        comps.year = dateComps.year
                                        comps.month = dateComps.month
                                        comps.day = dateComps.day
                                        comps.hour = timeComps.hour
                                        comps.minute = timeComps.minute
                                        comps.second = timeComps.second
                                        vm.auftraege[index].endzeit = calendar.date(from: comps)
                                    }
                                }
                            ),
                            displayedComponents: [.hourAndMinute]
                        )
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Datum").font(.caption).foregroundStyle(.secondary)
                        DatePicker(
                            "",
                            selection: Binding(
                                get: { auftrag.datum },
                                set: { newDate in
                                    if let index = vm.auftraege.firstIndex(where: { $0.id == auftrag.id }) {
                                        let calendar = Calendar.current
                                        // Preserve time components of start/end when shifting the day
                                        let newDay = calendar.startOfDay(for: newDate)

                                        // Update main date
                                        vm.auftraege[index].datum = newDay

                                        // Helper to move a date to the new day preserving time
                                        func moveToNewDay(_ old: Date?) -> Date? {
                                            guard let old = old else { return nil }
                                            let time = calendar.dateComponents([.hour, .minute, .second], from: old)
                                            var comps = calendar.dateComponents([.year, .month, .day], from: newDay)
                                            comps.hour = time.hour
                                            comps.minute = time.minute
                                            comps.second = time.second
                                            return calendar.date(from: comps)
                                        }

                                        vm.auftraege[index].startzeit = moveToNewDay(vm.auftraege[index].startzeit)
                                        vm.auftraege[index].endzeit = moveToNewDay(vm.auftraege[index].endzeit)
                                    }
                                }
                            ),
                            displayedComponents: [.date]
                        )
                        .labelsHidden()
                    }
                }
            }
            
            if !auftrag.isFertig {
                HStack(spacing: 24) {
                    // Rüsten (icon-only; scaled if active)
                    Button {
                        vm.startRuest(auftrag)
                    } label: {
                        Label(auftrag.isRuesten ? "Rüsten Ende" : "Rüsten", systemImage: "wrench.and.screwdriver")
                            .labelStyle(.iconOnly)
                            .symbolVariant(auftrag.isRuesten ? .fill : .none)
                            .foregroundStyle(auftrag.isRuesten ? .blue : .primary)
                            .scaleEffect(auftrag.isRuesten ? 1.15 : 1.0)
                            .animation(.easeInOut(duration: 0.2), value: auftrag.isRuesten)
                    }
                    .buttonStyle(.plain)
                    .controlSize(.small)
                    .disabled((auftrag.isFertig && !auftrag.isEditable) || !auftrag.isRunning)

                    // Pause/Weiter (icon-only; filled)
                    Button {
                        vm.startPause(auftrag)
                    } label: {
                        Label(auftrag.isRunning ? "Pause" : "Weiter", systemImage: auftrag.isRunning ? "pause.circle" : "play.circle")
                            .labelStyle(.iconOnly)
                            .symbolVariant(.fill)
                            .foregroundStyle((!auftrag.isRunning && auftrag.lastPauseStart != nil) ? .orange : .primary)
                            .scaleEffect((!auftrag.isRunning && auftrag.lastPauseStart != nil) ? 1.15 : 1.0)
                            .animation(.easeInOut(duration: 0.2), value: (!auftrag.isRunning && auftrag.lastPauseStart != nil))
                    }
                    .buttonStyle(.plain)
                    .controlSize(.small)
                    .disabled(auftrag.isFertig && !auftrag.isEditable)
                    
                    // Ende (icon-only; filled, red)
                    Button {
                        vm.beenden(auftrag)
                    } label: {
                        Label("Ende", systemImage: "stop.circle")
                            .labelStyle(.iconOnly)
                            .symbolVariant(.fill)
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .controlSize(.small)
                    .disabled(auftrag.isFertig)
                }
                .font(.title3)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.thinMaterial)
        )
        .shadow(color: Color.black.opacity(0.08), radius: 10, x: 0, y: 4)
        .padding(.vertical, 6)
        .opacity(auftrag.isFertig && !auftrag.isEditable ? 0.6 : 1.0)
        .swipeActions(edge: .leading) {
            if auftrag.isFertig {
                Button {
                    vm.toggleBearbeiten(auftrag)
                } label: {
                    Label("Bearbeiten", systemImage: "pencil")
                }
                .tint(.orange)
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                if let index = vm.auftraege.firstIndex(where: { $0.id == auftrag.id }) {
                    vm.auftraege.remove(at: index)
                }
            } label: {
                Label("Löschen", systemImage: "trash")
            }
        }
    }
}


extension View {
    func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

