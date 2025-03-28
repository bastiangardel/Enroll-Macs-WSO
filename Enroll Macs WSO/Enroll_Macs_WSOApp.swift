//
//  Enroll_Macs_WSOApp.swift
//  Enroll Macs WSO
//
//  Created by Bastian Gardel on 18.11.2024.
//

import Foundation
import CoreData
import KeychainAccess
import SwiftUI
import SMBClient
import LocalAuthentication
import UniformTypeIdentifiers
import AppKit
import Cocoa

// MARK: - Outils
func normalizeKeys(_ dictionary: [String: String]) -> [String: String] {
    var normalized = [String: String]()
    for (key, value) in dictionary {
        // Supprime les caractères invisibles et normalise la casse
        let cleanedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .lowercased()
        normalized[cleanedKey] = value
    }
    return normalized
}

prefix func ! (value: Binding<Bool>) -> Binding<Bool> {
    Binding<Bool>(
        get: { !value.wrappedValue },
        set: { value.wrappedValue = !$0 }
    )
}

enum SortOrder {
    case ascending, descending
}

@propertyWrapper
struct BoolAsInt: Codable {
    var wrappedValue: Bool
    
    init(wrappedValue: Bool) {
        self.wrappedValue = wrappedValue
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue ? 1 : 0)
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let intValue = try container.decode(Int.self)
        self.wrappedValue = intValue != 0
    }
}

// MARK: - Modèles JSON
struct Machine: Identifiable, Codable {
    let id = UUID()
    var endUserName: String
    var assetNumber: String
    var locationGroupId: String
    var messageType: Int
    var serialNumber: String
    var platformId: Int
    var friendlyName: String
    var ownership: String
    var employeeType: String
    var vpnSelect: String
    @BoolAsInt var tableauDesktop: Bool
    @BoolAsInt var tableauPrep: Bool
    var filemaker: String
    @BoolAsInt var mindmanager: Bool
    @BoolAsInt var linaException: Bool
    @BoolAsInt var acrobatReaderException: Bool
    var devicetype: String
    var SCIPER: String
    
    enum CodingKeys: String, CodingKey {
        case endUserName = "EndUserName"
        case assetNumber = "AssetNumber"
        case locationGroupId = "LocationGroupId"
        case messageType = "MessageType"
        case serialNumber = "SerialNumber"
        case platformId = "PlatformId"
        case friendlyName = "FriendlyName"
        case ownership = "Ownership"
        case employeeType = "employeetypemacssc"
        case vpnSelect = "vpnguestmacssc"
        case tableauDesktop = "tableauDesktopmacssc"
        case tableauPrep = "tableauPrepmacssc"
        case filemaker = "filemakermacssc"
        case mindmanager = "mindmanagermacssc"
        case linaException = "linaexceptionssc"
        case acrobatReaderException = "acrobatreaderexceptionssc"
        case devicetype = "devicetypemacssc"
        case SCIPER = "SCIPER"
    }
    
    func toJSON() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted // Optionnel pour un JSON lisible
        return try? encoder.encode(self)
    }
}

// MARK: - Keychain Keys
enum KeychainKeys: String {
    case sambaUsername = "SambaUsername"
    case sambaPassword = "SambaPassword"
}

let keychain = Keychain(service: "ch.epfl.machineenroll")

// MARK: - Core Data Helpers
func saveToCoreData(locationGroupId: String, platformId: Int, ownership: String, messageType: Int, sambaPath: String) {
    let context = PersistenceController.shared.container.viewContext
    let config = AppConfig(context: context)
    config.locationGroupId = locationGroupId
    config.platformId = Int32(platformId)
    config.ownership = ownership
    config.messageType = Int32(messageType)
    config.sambaPath = sambaPath
    
    do {
        try context.save()
    } catch {
        print("Erreur lors de la sauvegarde des données dans Core Data: \(error)")
    }
}

func clearStorage() {
    // Effacer Core Data
    let context = PersistenceController.shared.container.viewContext
    let fetchRequest: NSFetchRequest<NSFetchRequestResult> = AppConfig.fetchRequest()
    let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
    
    do {
        try context.execute(deleteRequest)
        try context.save()
    } catch {
        print("Erreur lors de la suppression des données dans Core Data: \(error)")
    }
    
    // Effacer Keychain
    do {
        try keychain.removeAll()
    } catch let error {
        print("Erreur lors de la suppression des informations du Keychain: \(error)")
    }
}

func getAppConfig() -> AppConfig? {
    let context = PersistenceController.shared.container.viewContext
    let request: NSFetchRequest<AppConfig> = AppConfig.fetchRequest()
    return try? context.fetch(request).first
}



// MARK: - Samba Storage Helper
func saveFileToSamba(filename: String, content: Data, completion: @escaping (Bool, String) -> Void) {
    if ConfigManager.shared.isTestMode { // Testmode flag stored in configfile
           // Stockage en local
           let localPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/TestStorage")
           let fileURL = localPath.appendingPathComponent(filename)

           do {
               // Créer le dossier s'il n'existe pas
               try FileManager.default.createDirectory(at: localPath, withIntermediateDirectories: true, attributes: nil)
               
               // Écrire le fichier
               try content.write(to: fileURL)
               completion(true, "Fichier enregistré localement dans \(fileURL.path)")
           } catch {
               completion(false, "Erreur lors de l'enregistrement local : \(error.localizedDescription)")
           }
       } else {
           // Stockage sur le partage Samba
           guard let config = getAppConfig(),
                 let sambaUsername = keychain[KeychainKeys.sambaUsername.rawValue],
                 let sambaPassword = keychain[KeychainKeys.sambaPassword.rawValue],
                 let sambaPath = config.sambaPath else {
               completion(false, "Configuration manquante")
               return
           }
           
           guard let url = URL(string: sambaPath), let host = url.host else {
               completion(false, "Chemin SMB invalide")
               return
           }
           
           let client = SMBClient(host: host)

           Task {
               do {
                   // Se connecter au serveur SMB
                   try await client.login(username: sambaUsername, password: sambaPassword)
                   
                   // Connexion au partage
                   let shareName = url.pathComponents.count > 1 ? url.pathComponents[1] : ""
                   guard !shareName.isEmpty else {
                       completion(false, "Nom de partage manquant dans l'URL SMB")
                       return
                   }
                   
                   try await client.connectShare(shareName)
                   
                   let remoteFilePath = url.path.dropFirst(shareName.count + 1) // Chemin relatif
                   try await client.upload(content: content, path: remoteFilePath.appending("/\(filename)"))
                   try await client.disconnectShare()
                   
                   completion(true, "Fichier enregistré avec succès sur \(sambaPath)")
                   
               } catch {
                   completion(false, "Erreur lors de l'envoi du fichier : \(error.localizedDescription)")
               }
           }
       }
}

// MARK: - Vue selection chemin de sauvegarde
struct FileSavePickerButton: View {
    let title: String
    let suggestedFileName: String
    let onSelect: (URL) -> Void
    
    var body: some View {
        Button(title) {
            showSavePanel()
        }
    }
    
    private func showSavePanel() {
        DispatchQueue.main.async {
            guard let window = NSApplication.shared.windows.first(where: { $0.isKeyWindow }) else {
                print("Impossible de trouver la fenêtre hôte.")
                return
            }
            
            let savePanel = NSSavePanel()
            savePanel.title = title
            savePanel.prompt = "Enregistrer"
            savePanel.nameFieldStringValue = suggestedFileName
            savePanel.allowedContentTypes = [.commaSeparatedText]
            
            savePanel.beginSheetModal(for: window) { response in
                if response == .OK, let url = savePanel.url {
                    onSelect(url)
                }
            }
        }
    }
}

// MARK: - Vue selection fichier
struct FilePickerButton: View {
    let title: String
    let onSelect: (URL) -> Void
    
    var body: some View {
        Button(title) {
            openFilePanel()
        }
    }
    
    private func openFilePanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.commaSeparatedText] // Restriction sur les fichiers CSV
        
        // Afficher le panneau et gérer le résultat
        if panel.runModal() == .OK, let selectedURL = panel.url {
            onSelect(selectedURL)
        }
    }
}

// MARK: - Vue import CSV
struct CSVImportView: View {
    @Environment(\.dismiss) var dismiss
    var onImport: ([Machine]) -> Void
    
    @State private var nameCSVURL: URL?
    @State private var ocsCSVURL: URL?
    @State private var inventoryCSVURL: URL?
    @State private var missingCSVURL: URL?
    @State private var doublonsCSVURL: URL?
    @State private var errorMessage: String = ""
    
    var body: some View {
        VStack {
            Text("Importer via CSV")
                .font(.headline)
                .padding()
            
            // Sélection des fichiers avec indication visuelle
            filePickerWithCheckmark(title: "Sélectionner le fichier name.csv", selectedURL: $nameCSVURL)
            filePickerWithCheckmark(title: "Sélectionner le fichier ocs.csv", selectedURL: $ocsCSVURL)
            filePickerWithCheckmark(title: "Sélectionner le fichier inventory.csv", selectedURL: $inventoryCSVURL)
            
            // Sélection des chemins pour les fichiers à enregistrer
            fileSavePickerWithCheckmark(title: "Sélectionner le chemin pour missing.csv", suggestedFileName: "missing.csv", selectedURL: $missingCSVURL)
            fileSavePickerWithCheckmark(title: "Sélectionner le chemin pour doublons.csv", suggestedFileName: "doublons.csv", selectedURL: $doublonsCSVURL)
            
            Button("Importer") {
                generateAndImportCSVFiles()
            }
            .disabled(nameCSVURL == nil || ocsCSVURL == nil || missingCSVURL == nil || doublonsCSVURL == nil)
            .padding()
            
            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .padding()
            }
            
            Button("Annuler") {
                dismiss()
            }
        }
        .padding()
    }
    
    /// Helper pour les sélecteurs de fichiers avec un checkmark
    func filePickerWithCheckmark(title: String, selectedURL: Binding<URL?>) -> some View {
        HStack {
            VStack(alignment: .leading) {
                // Affiche le bouton de sélection de fichier
                FilePickerButton(title: title) { url in
                    DispatchQueue.main.async {
                        selectedURL.wrappedValue = url
                    }
                }
            }
            
            Spacer()  // Espacement entre les colonnes
            
            VStack {
                // Affiche un cercle ou un checkmark selon si l'URL est sélectionnée
                if selectedURL.wrappedValue != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                } else {
                    Image(systemName: "circle")
                        .foregroundColor(.gray)
                }
            }
        }
        .padding(.bottom)
    }
    
    /// Helper pour les sélecteurs de chemins de fichiers avec un checkmark
    func fileSavePickerWithCheckmark(title: String, suggestedFileName: String, selectedURL: Binding<URL?>) -> some View {
        HStack {
            VStack(alignment: .leading) {
                // Affiche le bouton de sélection de fichier
                FileSavePickerButton(title: title, suggestedFileName: suggestedFileName) { url in
                    DispatchQueue.main.async {
                        selectedURL.wrappedValue = url
                    }
                }
            }
            
            Spacer()  // Permet d'espacer les deux colonnes
            
            VStack {
                // Affiche un cercle ou un checkmark selon si le chemin de fichier est sélectionné
                if selectedURL.wrappedValue != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                } else {
                    Image(systemName: "circle")
                        .foregroundColor(.gray)
                }
            }
        }
        .padding(.bottom)
    }
    
    func generateAndImportCSVFiles() {
        guard let nameURL = nameCSVURL,
              let ocsURL = ocsCSVURL,
              let inventoryURL = inventoryCSVURL,
              let missingURL = missingCSVURL,
              let doublonsURL = doublonsCSVURL else {
            errorMessage = "Veuillez sélectionner tous les fichiers nécessaires."
            return
        }
        
        do {
            let nameData = try parseCSV(url: nameURL)
            let ocsData = try parseCSV(url: ocsURL)
            let inventoryData = try parseCSV(url: inventoryURL)
            
            // Utilise processCSVData pour traiter les données et générer les fichiers nécessaires
            let machines = processCSVData(
                nameData: nameData,
                ocsData: ocsData,
                inventoryData: inventoryData,
                missingURL: missingURL,
                doublonsURL: doublonsURL
            )
            
            // Passe les machines au callback
            onImport(machines)
            dismiss()
        } catch {
            errorMessage = "Erreur lors du traitement : \(error.localizedDescription)"
        }
    }
    
    func exportCSV(data: [[String: String]], to url: URL) throws {
        guard let firstRow = data.first else {
            throw NSError(domain: "CSVExportError", code: 1, userInfo: [NSLocalizedDescriptionKey: "No data to export"])
        }
        
        // Assure l'ordre des colonnes en fonction des clés du premier élément
        let headers = Array(firstRow.keys)
        
        // Crée les lignes du CSV en suivant l'ordre des en-têtes
        let rows = data.map { row in
            headers.map { header in
                row[header] ?? "" // Si une clé est manquante, utiliser une chaîne vide
            }.joined(separator: ",")
        }
        
        // Crée le contenu CSV avec les en-têtes suivis des lignes
        let csvContent = ([headers.joined(separator: ",")] + rows).joined(separator: "\n")
        
        // Écrit le contenu CSV dans le fichier
        try csvContent.write(to: url, atomically: true, encoding: .utf8)
    }
    
    func parseCSV(url: URL) throws -> [[String: String]] {
        let content = try String(contentsOf: url, encoding: .utf8)
        
        // Nettoyer le contenu pour ignorer les caractères invisibles (comme les espaces en début et fin de ligne)
        let cleanedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Séparer le contenu en lignes
        let rows = cleanedContent.components(separatedBy: "\n").filter { !$0.isEmpty }
        
        // Extraire les en-têtes
        let headers = rows[0].components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        
        return rows.dropFirst().compactMap { row in
            let values = row.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            
            // Si le nombre de valeurs ne correspond pas à celui des en-têtes, on ignore cette ligne
            guard values.count == headers.count else { return nil }
            
            // Retourner le dictionnaire des valeurs
            return Dictionary(uniqueKeysWithValues: zip(headers, values))
        }
    }
    
    func processCSVData(
        nameData: [[String: String]],
        ocsData: [[String: String]],
        inventoryData: [[String: String]],
        missingURL: URL,
        doublonsURL: URL
    ) -> [Machine] {
        var machines: [Machine] = []
        var missingResults: [[String: String]] = []
        var doublonsResults: [[String: String]] = []
        
        // Récupération des valeurs constantes de configuration
        let config = getAppConfig() // Méthode pour récupérer la configuration depuis Core Data
        let locationGroupId = config?.locationGroupId ?? "DefaultGroup"
        let platformId = config?.platformId ?? 12
        let messageType = config?.messageType ?? 0
        let ownership = config?.ownership ?? "C"
        
        // Étape 1 : Traiter name.csv et ocs.csv
        var nameToComputerMatches: [String: [String]] = [:]
        var results: [[String: String]] = []
        
        let normalizedOcsData = ocsData.map { normalizeKeys($0) }
        let normalizedNameData = nameData.map { normalizeKeys($0) }
        let normalizedInventoryData = inventoryData.map { normalizeKeys($0) }
        
        for ocsRow in normalizedOcsData {
            guard let computerName = ocsRow["computername"] ,
                  let serialNumber = ocsRow["serialnumber"],
                  let userName = ocsRow["username"] else {
                continue }
            
            for nameRow in normalizedNameData {
                guard let name = nameRow["name"] else { continue }
                
                // Construire une expression régulière qui vérifie si `computerName` contient toutes les lettres de `name` dans l'ordre (insensible à la casse)
                let pattern = name.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: ".*")
                
                if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                    let range = NSRange(location: 0, length: computerName.utf16.count)
                    if regex.firstMatch(in: computerName, options: [], range: range) != nil {
                        // Si le nom est trouvé dans computerName
                        if nameToComputerMatches[name] == nil {
                            nameToComputerMatches[name] = []
                        }
                        nameToComputerMatches[name]?.append(computerName)
                        
                        // Ajouter aux résultats
                        results.append([
                            "computername": computerName,
                            "username": userName,
                            "serialnumber": serialNumber
                        ])
                    }
                }
            }
        }
        
        // Détecter doublons et manquants
        for (name, computerNames) in nameToComputerMatches {
            if computerNames.count > 1 {
                for duplicateComputerName in computerNames {
                    doublonsResults.append(["computername": duplicateComputerName, "name": name])
                }
            }
            if computerNames.isEmpty {
                missingResults.append(["name": name])
            }
        }
        
        for nameRow in normalizedNameData {
            guard let name = nameRow["name"] else { continue }
            if nameToComputerMatches[name] == nil {
                missingResults.append(["name": name])
            }
        }
        
        // Exporter missing.csv
        if(!missingResults.isEmpty){
            do {
                try exportCSV(data: missingResults, to: missingURL)
            } catch {
                print("Erreur lors de l'export des fichiers CSV : \(error.localizedDescription)")
            }
        }
        
        // Exporter doublons.csv
        if(!doublonsResults.isEmpty){
            do {
                try exportCSV(data: doublonsResults, to: doublonsURL)
            } catch {
                print("Erreur lors de l'export des fichiers CSV : \(error.localizedDescription)")
            }
        }
        
        
        // Étape 2 : Générer des fichiers JSON basés sur nextmigrationlist.csv et inventory.csv
        for result in results {
            guard let sourceSerial = result["serialnumber"],
                  let sourceComputerName = result["computername"],
                  let sourceUserName = result["username"] else { continue }
            
            // Récupérer les 6 derniers caractères du numéro de série
            let sourceSerialLast6 = String(sourceSerial.suffix(6))
            
            // Trouver les correspondances dans inventory.csv
            let matchingInventory = normalizedInventoryData.filter {
                guard let inventorySerial = $0["serialnumber"] else { return false }
                return inventorySerial.suffix(6) == sourceSerialLast6
            }
            
            // Générer des objets Machine
            var outputMachines: [Machine] = []
            
            for inventoryRow in matchingInventory {
                guard let inventoryNumber = inventoryRow["inventorynumber"] else { continue }
                let machine = Machine(
                    endUserName: sourceUserName,
                    assetNumber: inventoryNumber,
                    locationGroupId: locationGroupId,
                    messageType: Int(messageType),
                    serialNumber: sourceSerial,
                    platformId: Int(platformId),
                    friendlyName: sourceComputerName,
                    ownership: ownership,
                    employeeType: "",
                    vpnSelect: "",
                    tableauDesktop: false,
                    tableauPrep: false,
                    filemaker: "",
                    mindmanager: false,
                    linaException: false,
                    acrobatReaderException: false,
                    devicetype: "",
                    SCIPER: ""
                )
                outputMachines.append(machine)
            }
            
            machines.append(contentsOf: outputMachines)
        }
        
        return machines
    }
}

// MARK: - Vue principale
struct MachineListView: View {
    @AppStorage("isConfigured") private var isConfigured: Bool = false
    @State private var machines: [Machine] = []
    
    @State private var statusMessage: String = ""
    @State private var showAddMachineView = false
    @State private var showDetailsMachine = false // État pour afficher les détails de la machine selectionnée
    @State private var selectedMachines: Set<UUID> = [] // Set to track selected machines for deletion
    @State private var isEditing: Bool = false
    @State private var isAuthenticated = false // Désormais, utilisé uniquement pour l'authentification lors de l'envoi
    @State private var isProcessing: Bool = false // Indicateur d'état de traitement
    @State private var progress: Double = 0.0 // Progression en pourcentage
    @State private var showCSVImportView: Bool = false // Progression en pourcentage
    
    // Nouveaux états pour gérer le tri
    @State private var sortOrder: SortOrder = .ascending
    @State private var sortKey: String = "friendlyName"
    
    @State private var isTestMode: Bool = ConfigManager.shared.isTestMode
    
    var body: some View {
        Text("")
            .navigationTitle(ConfigManager.shared.isTestMode ? "TEST - Affectation des machines dans WSO" : "Affectation des machines dans WSO")
            .onAppear {
                isTestMode = ConfigManager.shared.isTestMode
                print(isTestMode)
            }
        VStack {
            if isProcessing {
                VStack {
                    ProgressView(value: progress)
                        .progressViewStyle(LinearProgressViewStyle())
                        .controlSize(.large)
                        .padding()
                    Text("Progression : \(Int(progress * 100))%")
                        .font(.subheadline)
                        .fontWeight(.bold)
                }
            }
            
            Spacer()
                .frame(height: 20)
            
            // Titre des colonnes
            HStack {
                Spacer()
                    .frame(width: 20) // Marge avant la première colonne
                HStack(spacing: 4) {
                    Text("Friendly Name")
                        .font(.headline)
                    if sortKey == "friendlyName" {
                        Image(systemName: sortOrder == .ascending ? "arrow.down" : "arrow.up")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onTapGesture {
                    sortMachines(by: "friendlyName")
                }
                
                HStack(spacing: 4) {
                    Text("End User Name")
                        .font(.headline)
                    if sortKey == "endUserName" {
                        Image(systemName: sortOrder == .ascending ? "arrow.down" : "arrow.up")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onTapGesture {
                    sortMachines(by: "endUserName")
                }
                
                HStack(spacing: 4) {
                    Text("Asset Number")
                        .font(.headline)
                    if sortKey == "assetNumber" {
                        Image(systemName: sortOrder == .ascending ? "arrow.down" : "arrow.up")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onTapGesture {
                    sortMachines(by: "assetNumber")
                }
                
                HStack(spacing: 4) {
                    Text("Location Group ID")
                        .font(.headline)
                    if sortKey == "locationGroupId" {
                        Image(systemName: sortOrder == .ascending ? "arrow.down" : "arrow.up")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onTapGesture {
                    sortMachines(by: "locationGroupId")
                }
                
                HStack(spacing: 4) {
                    Text("Serial Number")
                        .font(.headline)
                    if sortKey == "serialNumber" {
                        Image(systemName: sortOrder == .ascending ? "arrow.down" : "arrow.up")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onTapGesture {
                    sortMachines(by: "serialNumber")
                }
            }
            .padding(.bottom, 5)
            
            // Liste des machines
            List {
                ForEach(machines) { machine in
                    HStack {
                        Spacer()
                            .frame(width: 20) // Marge avant la première colonne
                        Text(machine.friendlyName)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(machine.endUserName)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(machine.assetNumber)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(String(machine.locationGroupId))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(machine.serialNumber)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 5)
                    .background(selectedMachines.contains(machine.id) ? Color.blue.opacity(0.2) : Color.clear) // Highlight selected machines
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        TapGesture(count: 2).onEnded {
                            if selectedMachines.isEmpty {
                                selectedMachines.insert(machine.id)
                            }
                            else if selectedMachines.contains(machine.id){
                                selectedMachines.filter { $0 != machine.id }.forEach { selectedMachines.remove($0) }
                            }
                            else
                            {
                                selectedMachines.insert(machine.id)
                                selectedMachines.filter { $0 != machine.id }.forEach { selectedMachines.remove($0) }
                            }
                            
                            showDetailsMachine = true
                        }
                    )
                    .onTapGesture() {
                        if selectedMachines.contains(machine.id) {
                            selectedMachines.remove(machine.id)
                        } else {
                            selectedMachines.insert(machine.id)
                        }
                    }
                }
                .onDelete(perform: deleteMachines) // Swipe to delete individual machine
                .onAppear() {
                    sortMachines(by: sortKey)
                }
            }
            .listStyle(DefaultListStyle()) // Style pour macOS
            
            
            // Messages d'état
            Text(statusMessage)
                .foregroundColor(.red)
                .padding()
            
            // Boutons d'action
            HStack {
                Button("Ajouter une machine") {
                    showAddMachineView = true
                }
                .disabled(isProcessing)
                
                Button("Importer via CSV") {
                    showCSVImportView = true
                }
                .sheet(isPresented: $showCSVImportView) {
                    CSVImportView { importedMachines in
                        machines.append(contentsOf: importedMachines)
                        showStatusMessage("\(importedMachines.count) machine(s) importée(s) avec succès !")
                        sortMachines(by: sortKey)
                    }
                }
                
                Button("Détails Machine") {
                    showDetailsMachine = true
                }
                .disabled(selectedMachines.isEmpty)
                .disabled(selectedMachines.count > 1)
                .disabled(isProcessing)
                
                Button("Supprimer sélectionnées") {
                    deleteSelectedMachines()
                }
                .disabled(selectedMachines.isEmpty)
                .disabled(isProcessing)
                
                Button("Supprimer tout") {
                    deleteAllMachines()
                }
                .foregroundColor(.red)
                .disabled(machines.isEmpty)
                .disabled(isProcessing)
                
                Button("Envoyer") {
                    authenticateUserAndSendMachines()
                }
                .disabled(machines.isEmpty)
                .disabled(isProcessing)
                
                Button("Editer Config") {
                    isConfigured = false // Retourne temporairement à la vue de configuration
                }
                .disabled(isProcessing)
                .sheet(isPresented: !$isConfigured){
                    ConfigurationView(isConfigured: $isConfigured)
                        .frame(minWidth: 900, minHeight: 400)
                }
                
                Button("Close App") {
                    NSApp.terminate(nil)
                }
                .disabled(isProcessing)
            }
            .padding()
        }
        .sheet(isPresented: $showAddMachineView) {
            AddMachineView { newMachine in
                machines.append(newMachine)
                showStatusMessage("Machine ajoutée avec succès !")
                sortMachines(by: sortKey)
            }
        }
        .sheet(isPresented: $showDetailsMachine) {
            DetailsMachineView(
                endUserName: machines.first { $0.id == selectedMachines.first! }?.endUserName ?? "",
                SCIPER: machines.first { $0.id == selectedMachines.first! }?.SCIPER ?? "",
                assetNumber: machines.first { $0.id == selectedMachines.first! }?.assetNumber ?? "",
                serialNumber: machines.first { $0.id == selectedMachines.first! }?.serialNumber ?? "",
                friendlyName: machines.first { $0.id == selectedMachines.first! }?.friendlyName ?? "",
                selectedEmployee: machines.first { $0.id == selectedMachines.first! }?.employeeType ?? "",
                selectedDeviceType: machines.first { $0.id == selectedMachines.first! }?.devicetype ?? "",
                selectedVPN: machines.first { $0.id == selectedMachines.first! }?.vpnSelect ?? "",
                selectedFileMaker: machines.first { $0.id == selectedMachines.first! }?.filemaker ?? "",
                selectedTableauDesktop: machines.first { $0.id == selectedMachines.first! }?.tableauDesktop ?? false,
                selectedTableauPrep: machines.first { $0.id == selectedMachines.first! }?.tableauPrep ?? false,
                mindmanagerSelected: machines.first { $0.id == selectedMachines.first! }?.mindmanager ?? false,
                linaExceptionSelected: machines.first { $0.id == selectedMachines.first! }?.linaException ?? false,
                acrobatreaderExceptionSelected: machines.first { $0.id == selectedMachines.first! }?.acrobatReaderException ?? false
            )
        }
    }
    
    
    // Fonction de tri
    func sortMachines(by key: String) {
        if sortKey == key {
            // Inverser l'ordre de tri si on clique sur la même colonne
            sortOrder = (sortOrder == .ascending) ? .descending : .ascending
        } else {
            sortKey = key
            sortOrder = .ascending
        }
        
        switch sortKey {
        case "friendlyName":
            machines.sort { sortOrder == .ascending ?
                $0.friendlyName.localizedCaseInsensitiveCompare($1.friendlyName) == .orderedAscending :
                $0.friendlyName.localizedCaseInsensitiveCompare($1.friendlyName) == .orderedDescending }
        case "endUserName":
            machines.sort { sortOrder == .ascending ?
                $0.endUserName.localizedCaseInsensitiveCompare($1.endUserName) == .orderedAscending :
                $0.endUserName.localizedCaseInsensitiveCompare($1.endUserName) == .orderedDescending }
        case "assetNumber":
            machines.sort { sortOrder == .ascending ?
                $0.assetNumber.localizedCaseInsensitiveCompare($1.assetNumber) == .orderedAscending :
                $0.assetNumber.localizedCaseInsensitiveCompare($1.assetNumber) == .orderedDescending }
        case "locationGroupId":
            machines.sort { sortOrder == .ascending ?
                $0.locationGroupId < $1.locationGroupId :
                $0.locationGroupId > $1.locationGroupId }
        case "serialNumber":
            machines.sort { sortOrder == .ascending ?
                $0.serialNumber.localizedCaseInsensitiveCompare($1.serialNumber) == .orderedAscending :
                $0.serialNumber.localizedCaseInsensitiveCompare($1.serialNumber) == .orderedDescending }
        default:
            break
        }
    }
    
    // Fonction utilitaire pour afficher un message temporaire
    func showStatusMessage(_ message: String, duration: TimeInterval = 3.0) {
        statusMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            if statusMessage == message { // Évite de supprimer un nouveau message qui pourrait avoir été défini entre-temps
                statusMessage = ""
            }
        }
    }
    
    func authenticateUserAndSendMachines() {
        let context = LAContext()
        var error: NSError?
        
        isProcessing = true
        
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "que vous vous authentifiez pour envoyer les machines") { success, authenticationError in
                DispatchQueue.main.async {
                    if success {
                        isAuthenticated = true
                        sendMachinesToSamba()
                    } else {
                        showStatusMessage(authenticationError?.localizedDescription ?? "Échec de l'authentification.")
                        isProcessing = false
                    }
                }
            }
        } else {
            showStatusMessage("La biométrie n'est pas disponible sur cet appareil.")
        }
    }
    
    func sendMachinesToSamba() {
        guard !machines.isEmpty else {
            showStatusMessage("Aucune machine à envoyer.")
            return
        }
        
        selectedMachines.removeAll()
        
        isProcessing = true
        progress = 0.0
        let totalMachines = machines.count
        var successfullySent = 0
        
        var remainingMachines: [Machine] = []
        
        for (index, machine) in machines.enumerated() {
            if let jsonData = machine.toJSON() {
                let filename = "scx-\(machine.assetNumber).json"
                saveFileToSamba(filename: filename, content: jsonData) { success, message in
                    DispatchQueue.main.async {
                        if success {
                            successfullySent += 1
                        } else {
                            remainingMachines.append(machine)
                        }
                        
                        progress = Double(index + 1) / Double(totalMachines)
                        
                        if index == totalMachines - 1 {
                            isProcessing = false
                            machines = remainingMachines
                            showStatusMessage("\(successfullySent) fichier(s) enregistré(s) sur \(totalMachines).\n \(message)")
                        }
                    }
                }
            } else {
                remainingMachines.append(machine)
            }
        }
    }
    
    func deleteMachines(at offsets: IndexSet) {
        for index in offsets {
            let machine = machines[index]
            if selectedMachines.contains(machine.id) {
                selectedMachines.remove(machine.id)
            }
        }
        machines.remove(atOffsets: offsets)
    }
    
    func deleteSelectedMachines() {
        machines.removeAll { machine in
            selectedMachines.contains(machine.id)
        }
        selectedMachines.removeAll()
        showStatusMessage("Machines sélectionnées supprimées.")
    }
    
    func deleteAllMachines() {
        machines.removeAll()
        selectedMachines.removeAll()
        showStatusMessage("Toutes les machines ont été supprimées.")
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ theApplication: NSApplication) -> Bool {
        return true
    }
    
}

// MARK: - Details machine Sheet

struct DetailsMachineView: View {
    var endUserName: String
    var SCIPER: String
    var assetNumber: String
    var serialNumber: String
    var friendlyName: String
    var selectedEmployee: String = ""
    var selectedDeviceType: String = ""
    var selectedVPN: String = ""
    var selectedFileMaker: String = ""
    var selectedTableauDesktop: Bool
    var selectedTableauPrep: Bool
    var mindmanagerSelected: Bool
    var linaExceptionSelected: Bool
    var acrobatreaderExceptionSelected: Bool
    
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Détails de la machine")
                .font(.title)
                .bold()
                .padding(.top, 10)
                .frame(maxWidth: .infinity, alignment: .center)
            
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    
                    InfoSectionView(title: "Informations Générales", content: [
                        ("Nom d'utilisateur", endUserName),
                        ("SCIPER", SCIPER),
                        ("Numéro d'actif", assetNumber),
                        ("Numéro de série", serialNumber),
                        ("Nom convivial", friendlyName)
                    ])
                    
                    InfoSectionView(title: "Sélections", content: [
                        ("Type d'employé", selectedEmployee),
                        ("Type d'appareil", selectedDeviceType),
                        ("VPN Guest", selectedVPN == "" ? "Aucune sélection" : selectedVPN),
                        ("FileMaker", selectedFileMaker == "" ? "Aucune sélection" : selectedFileMaker),
                        ("TableauDesktop", selectedTableauDesktop ? "Oui" : "Non"),
                        ("TableauPrep", selectedTableauPrep ? "Oui" : "Non"),
                        ("MindManager", mindmanagerSelected ? "Oui" : "Non"),
                        ("Lina", linaExceptionSelected ? "Non" : "Oui"),
                        ("Exception Acrobat Pro", acrobatreaderExceptionSelected ? "Oui" : "Non")
                    ])
                }
                .padding()
            }
            
            // Bouton de fermeture
            HStack {
                Spacer()
                Button("Fermer") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                Spacer()
            }
            .padding(.bottom, 10)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.gray.opacity(0.05)) // Fond gris clair pour plus de lisibilité
    }
}

struct InfoSectionView: View {
    var title: String
    var content: [(String, String)]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundColor(.blue)
                .padding(.bottom, 5)
            
            ForEach(content, id: \.0) { label, value in
                HStack {
                    Text("\(label) :")
                        .bold()
                        .frame(width: 150, alignment: .leading)
                    Text(value)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(8)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(8)
            }
        }
        .padding()
        .background(Color.gray.opacity(0.2)) // Fond de section plus visible
        .cornerRadius(10)
    }
}

// MARK: - Vue pour ajouter une machine
struct AddMachineView: View {
    @Environment(\.dismiss) var dismiss
    var onAdd: (Machine) -> Void
    
    @State private var selectedEmployee: String? = nil
    @State private var selectedDeviceType: String? = nil
    @State private var selectedVPN: String? = nil
    @State private var selectedFileMaker: String? = nil
    @State private var selectedTableau: [String] = []
    @State private var mindmanagerSelected = false
    @State private var linaExceptionSelected = false
    @State private var acrobatReaderExceptionSelected = false
    
    @State private var locationGroupIdDyn = ""
    
    @State private var endUserName = ""
    @State private var SCIPER = ""
    @State private var assetNumber = ""
    @State private var serialNumber = ""
    @State private var friendlyName = ""
    
    
    
    let columns = [
        GridItem(.flexible(minimum: 200, maximum: 300)),
        GridItem(.flexible(minimum: 200, maximum: 300)),
        GridItem(.flexible(minimum: 200, maximum: 300))
    ]
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(spacing: 10) {
                    requiredField(label: "Nom d'utilisateur final", text: $endUserName)
                    requiredField(label: "SCIPER", text: $SCIPER)
                    requiredField(label: "Numéro d'actif", text: $assetNumber)
                    requiredField(label: "Numéro de série", text: $serialNumber)
                    requiredField(label: "Nom convivial", text: $friendlyName)
                }
                .padding(.horizontal)
                
                LazyVGrid(columns: columns, spacing: 20) {
                    SectionView(title: "Employee Type", options: ["Personnel", "Hôte", "Hors-EPFL"], selection: $selectedEmployee, isRequired: true)
                    SectionView(title: "Device Type", options: ["Laptop", "Workstation", "Mobile"], selection: $selectedDeviceType, isRequired: true)
                    SectionView(title: "VPN Guest", options: ["SSC","AGA"], selection: $selectedVPN)
                    SectionView(title: "FileMaker", options: ["TTO-AJ", "OHSPR-DSE", "Autres"], selection: $selectedFileMaker)
                    
                    MultipleSelectionView(title: "Tableau", options: ["Desktop", "Prep"], selections: $selectedTableau)
                    
                    borderedToggle(title: "MindManager", isOn: $mindmanagerSelected)
                    borderedToggle(title: "Pas de Lina", isOn: $linaExceptionSelected)
                    Spacer()
                        .frame(width: 50, height: 50)
                    borderedToggle(title: "Exception Acrobat Pro", isOn: $acrobatReaderExceptionSelected, isDisabled: selectedEmployee == "Personnel")
                }
                .padding(.horizontal)
            }
            .padding()
        }
        
        HStack {
            Button("Ajouter") {
                let config = getAppConfig()
                switch selectedDeviceType {
                    case "Laptop":
                     locationGroupIdDyn = "628"
                    break
                case "Workstation":
                     locationGroupIdDyn = "629"
                    break
                case "Mobile":
                     locationGroupIdDyn = "627"
                    break
                default:
                     locationGroupIdDyn = "628"
                    break
                }
                
                let newMachine = Machine(
                    endUserName: endUserName,
                    assetNumber: assetNumber,
                    locationGroupId: locationGroupIdDyn,
                    messageType: Int(config?.messageType ?? 0),
                    serialNumber: serialNumber,
                    platformId: Int(config?.platformId ?? 0),
                    friendlyName: friendlyName,
                    ownership: config?.ownership ?? "",
                    employeeType: selectedEmployee ?? "",
                    vpnSelect: selectedVPN ?? "",
                    tableauDesktop: selectedTableau.contains("Desktop"),
                    tableauPrep: selectedTableau.contains("Prep"),
                    filemaker: selectedFileMaker ?? "",
                    mindmanager: mindmanagerSelected,
                    linaException: linaExceptionSelected,
                    acrobatReaderException: acrobatReaderExceptionSelected,
                    devicetype: selectedDeviceType ?? "",
                    SCIPER: SCIPER
                )
                onAdd(newMachine)
                dismiss()
            }
            .disabled(endUserName.isEmpty || selectedDeviceType == nil || assetNumber.isEmpty || serialNumber.isEmpty || friendlyName.isEmpty || selectedEmployee == nil)
            .buttonStyle(.borderedProminent)
            
            Button("Annuler") {
                dismiss()
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
    
    /// Fonction pour afficher un champ obligatoire avec une étoile rouge `*`
    @ViewBuilder
    private func requiredField(label: String, text: Binding<String>) -> some View {
        HStack {
            Text("\(label) ")
                .frame(width: 180, alignment: .leading)
                .foregroundColor(.primary)
            Text("*")
                .foregroundColor(.red)
            TextField("Entrez le \(label.lowercased())", text: text)
                .textFieldStyle(RoundedBorderTextFieldStyle())
        }
    }
    
    /// Fonction pour créer un Toggle encadré
    @ViewBuilder
    private func borderedToggle(title: String, isOn: Binding<Bool>, isDisabled: Bool = false) -> some View {
        Toggle(title, isOn: isOn)
            .padding()
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(RoundedRectangle(cornerRadius: 8).stroke(Color.gray, lineWidth: 1))
            .disabled(isDisabled) // Désactive le Toggle si isDisabled est true
            .opacity(isDisabled ? 0.5 : 1.0) // Change l'opacité pour indiquer la désactivation
    }
}

/// Vue pour les sélecteurs avec option obligatoire (affichage d'une étoile `*` si nécessaire)
struct SectionView: View {
    let title: String
    let options: [String]
    @Binding var selection: String?
    var isRequired: Bool = false
    
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text(title)
                    .font(.headline)
                if isRequired {
                    Text("*")
                        .foregroundColor(.red)
                }
            }
            ForEach(options, id: \.self) { option in
                RadioButton(title: option, selection: $selection)
            }
        }
        .padding()
        .border(Color.gray, width: 1)
    }
}

/// Vue pour une sélection multiple
struct MultipleSelectionView: View {
    let title: String
    let options: [String]
    @Binding var selections: [String]
    
    var body: some View {
        VStack(alignment: .leading) {
            Text(title).font(.headline)
            ForEach(options, id: \.self) { option in
                Toggle(option, isOn: Binding(
                    get: { selections.contains(option) },
                    set: { newValue in
                        if newValue {
                            selections.append(option)
                        } else {
                            selections.removeAll { $0 == option }
                        }
                    }
                ))
            }
        }
        .padding()
        .border(Color.gray, width: 1)
    }
}

/// Vue pour les boutons radio
struct RadioButton: View {
    let title: String
    @Binding var selection: String?
    
    var body: some View {
        Button(action: {
            if selection == title {
                selection = nil  // Désélectionner si déjà sélectionné
            } else {
                selection = title
            }
        }) {
            HStack {
                Image(systemName: selection == title ? "largecircle.fill.circle" : "circle")
                Text(title)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Configuration Vue
struct ConfigurationView: View {
    @Environment(\.dismiss) var dismiss
    @Binding var isConfigured: Bool
    @State private var showAlert = false
    @State private var locID = ""
    @State private var pID = ""
    @State private var OShip = ""
    @State private var MT = ""
    @State private var sPath = ""
    @State private var sUsername = ""
    @State private var sPassword = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Location Group ID:")
                    .frame(width: 150, alignment: .leading)
                TextField("Entrez le Location Group ID", text: $locID)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }
            HStack {
                Text("Platform ID:")
                    .frame(width: 150, alignment: .leading)
                TextField("Entrez le Platform ID", text: $pID)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }
            HStack {
                Text("Ownership:")
                    .frame(width: 150, alignment: .leading)
                TextField("Entrez l'Ownership", text: $OShip)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }
            HStack {
                Text("Message Type:")
                    .frame(width: 150, alignment: .leading)
                TextField("Entrez le Message Type", text: $MT)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }
            HStack {
                Text("Chemin Samba:")
                    .frame(width: 150, alignment: .leading)
                TextField("Entrez le chemin Samba", text: $sPath)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }
            HStack {
                Text("Nom d'utilisateur Samba:")
                    .frame(width: 150, alignment: .leading)
                TextField("Entrez le nom d'utilisateur Samba", text: $sUsername)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }
            HStack {
                Text("Mot de passe Samba:")
                    .frame(width: 150, alignment: .leading)
                SecureField("Entrez le mot de passe Samba", text: $sPassword)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }
            HStack {
                Button("Enregistrer") {
                    saveConfiguration()
                }
                .buttonStyle(.borderedProminent)
                .disabled(locID.isEmpty || pID.isEmpty || OShip.isEmpty || MT.isEmpty || sPath.isEmpty)
                
                Button("Clear Configuration") {
                    clearField()
                }
                .foregroundColor(.red)
                .buttonStyle(.bordered)
                
                Button("Close App") {
                    if(!locID.isEmpty && !pID.isEmpty && !OShip.isEmpty && !MT.isEmpty && !sPath.isEmpty){
                        saveConfiguration()
                        exit(0)
                    }else{
                        isConfigured = false
                        showAlert = true
                    }
                }
                .alert(isPresented: $showAlert) {
                    Alert(
                        title: Text("Confirmer la fermeture"),
                        message: Text("La config est vide ou incompléte, elle sera donc pas enregistrée.\nVoulez-vous vraiment quitter l'application ?"),
                        primaryButton: .destructive(Text("Quitter")) {
                            exit(0)
                        },
                        secondaryButton: .cancel()
                    )
                }
            }
        }
        .padding()
        .onAppear(perform: loadConfiguration)
    }
    
    // Charger les valeurs existantes depuis Core Data et Keychain
    func loadConfiguration() {
        if let config = getAppConfig() {
            locID = config.locationGroupId ?? ""
            pID = String(config.platformId)
            OShip = config.ownership ?? ""
            MT = String(config.messageType)
            sPath = config.sambaPath ?? ""
        }
        sUsername = keychain[KeychainKeys.sambaUsername.rawValue] ?? ""
        sPassword = keychain[KeychainKeys.sambaPassword.rawValue] ?? ""
        
        clearStorage()
    }
    
    // Enregistrer les nouvelles valeurs dans Core Data et Keychain
    func saveConfiguration() {
        saveToCoreData(
            locationGroupId: locID,
            platformId: Int(pID) ?? 0,
            ownership: OShip,
            messageType: Int(MT) ?? 0,
            sambaPath: sPath
        )
        keychain[KeychainKeys.sambaUsername.rawValue] = sUsername
        keychain[KeychainKeys.sambaPassword.rawValue] = sPassword
        
        isConfigured = true
    }
    
    // Réinitialiser les champs
    func clearField() {
        locID = ""
        pID = ""
        OShip = ""
        MT = ""
        sPath = ""
        sUsername = ""
        sPassword = ""
    }
}

// MARK: - Main
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        let _ = NSApplication.shared.windows.map { $0.tabbingMode = .disallowed }
        
        guard MTLCreateSystemDefaultDevice() != nil else {
            fatalError("Metal is not supported on this device")
        }
    }
}

@main
struct Enroll_Macs_WSOApp: App {
    @AppStorage("isConfigured") private var isConfigured: Bool = false
    
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            MachineListView()
                .frame(minWidth: 900, minHeight: 400) // Taille minimum du contenu
        }
        .commandsRemoved()
        .commands {
            AppMenu()
            FileMenu()
            EditMenu()
        }
    }
}

// MARK: - Menus
struct AppMenu: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("À propos de l'application") {
                NSApplication.shared.orderFrontStandardAboutPanel(nil)
            }
        }
        
        CommandGroup(replacing: .appTermination) {
            Button("Quitter") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}

struct FileMenu: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            // Supprime le groupe "Nouveau"
        }
        
        CommandGroup(after: .newItem) {
            Button("Fermer la fenêtre") {
                if let keyWindow = NSApplication.shared.keyWindow {
                    keyWindow.performClose(nil)
                }
            }
            .keyboardShortcut("w")
        }
    }
}

struct EditMenu: Commands {
    var body: some Commands {
        CommandGroup(replacing: .pasteboard) {
            Button("Couper") {
                NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("x")
            
            Button("Copier") {
                NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("c")
            
            Button("Coller") {
                NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("v")
        }
    }
}
