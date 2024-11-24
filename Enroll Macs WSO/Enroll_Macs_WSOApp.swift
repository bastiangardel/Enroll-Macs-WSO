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


// MARK: - Modèles JSON
struct Machine: Identifiable, Encodable {
    let id = UUID()
    var endUserName: String
    var assetNumber: String
    var locationGroupId: String
    var messageType: Int
    var serialNumber: String
    var platformId: Int
    var friendlyName: String
    var ownership: String
    
    // Définir des clés personnalisées pour l'encodage
    enum CodingKeys: String, CodingKey {
        case endUserName = "EndUserName"
        case assetNumber = "AssetNumber"
        case locationGroupId = "LocationGroupId"
        case messageType = "MessageType"
        case serialNumber = "SerialNumber"
        case platformId = "PlatformId"
        case friendlyName = "FriendlyName"
        case ownership = "Ownership"
    }
    
    func toJSON() -> Data? {
        try? JSONEncoder().encode(self)
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
            
            try await client.connectShare(String(shareName))
            
            let remoteFilePath = url.path.dropFirst(shareName.count + 1) // Chemin relatif
            try await client.upload(content: content, path: remoteFilePath.appending("/\(filename)"))
            try await client.disconnectShare()
            
            completion(true, "Fichier enregistré avec succès sur \(sambaPath)")
            
        } catch {
            completion(false, "Erreur lors de l'envoi du fichier : \(error.localizedDescription)")
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

// MARK: - Vue import csv

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
            
            // Sélection des fichiers
            FilePickerButton(title: "Sélectionner le fichier name.csv") { url in
                nameCSVURL = url
            }
            .padding(.bottom)
            
            FilePickerButton(title: "Sélectionner le fichier ocs.csv") { url in
                ocsCSVURL = url
            }
            .padding(.bottom)
            
            FilePickerButton(title: "Sélectionner le fichier inventory.csv") { url in
                inventoryCSVURL = url
            }
            .padding(.bottom)
            
            FileSavePickerButton(title: "Sélectionner le chemin pour missing.csv", suggestedFileName: "missing.csv") { url in
                missingCSVURL = url
            }
            .padding(.bottom)
            
            FileSavePickerButton(title: "Sélectionner le chemin pour doublons.csv", suggestedFileName: "doublons.csv") { url in
                doublonsCSVURL = url
            }
            .padding(.bottom)
            
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
        let headers = data.first?.keys.joined(separator: ",") ?? ""
        let rows = data.map { $0.values.joined(separator: ",") }
        let csvContent = ([headers] + rows).joined(separator: "\n")
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
        
        for ocsRow in normalizedOcsData {
            guard let computerName = ocsRow["computername"] ,
                  let serialNumber = ocsRow["serialnumber"],
                  let userName = ocsRow["username"] else {
                continue }
            
            for nameRow in normalizedNameData {
                guard let name = nameRow["name"] else {continue }
                
                // Vérifier si computerName contient le nom (insensible à la casse)
                if computerName.range(of: name, options: .caseInsensitive) != nil {
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
        
        for nameRow in nameData {
            guard let name = nameRow["name"] else { continue }
            if nameToComputerMatches[name] == nil {
                missingResults.append(["name": name])
            }
        }
        
        // Exporter missing.csv et doublons.csv
        do {
            try exportCSV(data: missingResults, to: missingURL)
            try exportCSV(data: doublonsResults, to: doublonsURL)
        } catch {
            print("Erreur lors de l'export des fichiers CSV : \(error.localizedDescription)")
        }
        
        // Étape 2 : Générer des fichiers JSON basés sur nextmigrationlist.csv et inventory.csv
        for result in results {
            guard let sourceSerial = result["serialnumber"],
                  let sourceComputerName = result["computername"],
                  let sourceUserName = result["username"] else { continue }
            
            // Récupérer les 6 derniers caractères du numéro de série
            let sourceSerialLast6 = String(sourceSerial.suffix(6))
            
            // Trouver les correspondances dans inventory.csv
            let matchingInventory = inventoryData.filter {
                guard let inventorySerial = $0["serialnumber"] else { return false }
                return inventorySerial.suffix(6) == sourceSerialLast6
            }
            
            // Générer des objets Machine et JSON
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
                    ownership: ownership
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
    @AppStorage("isConfigured") private var isConfigured: Bool = true
    @State private var machines: [Machine] = []
    @State private var statusMessage: String = ""
    @State private var showAddMachineView = false
    @State private var selectedMachines: Set<UUID> = [] // Set to track selected machines for deletion
    @State private var isEditing: Bool = false
    @State private var isAuthenticated = false // Désormais, utilisé uniquement pour l'authentification lors de l'envoi
    @State private var isProcessing: Bool = false // Indicateur d'état de traitement
    @State private var progress: Double = 0.0 // Progression en pourcentage
    @State private var showCSVImportView: Bool = false // Progression en pourcentage
    
    var body: some View {
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
                Text("Friendly Name")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("End User Name")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Asset Number")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Location Group ID")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Serial Number")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                    .onTapGesture {
                        if selectedMachines.contains(machine.id) {
                            selectedMachines.remove(machine.id)
                        } else {
                            selectedMachines.insert(machine.id)
                        }
                    }
                }
                .onDelete(perform: deleteMachines) // Swipe to delete individual machine
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
                    }
                }
                
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
            }
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

// MARK: - Vue pour ajouter une machine
struct AddMachineView: View {
    @Environment(\.dismiss) var dismiss
    var onAdd: (Machine) -> Void
    
    @State private var endUserName = ""
    @State private var assetNumber = ""
    @State private var serialNumber = ""
    @State private var friendlyName = ""
    
    var body: some View {
        Form {
            TextField("Nom d'utilisateur final", text: $endUserName)
            TextField("Numéro d'actif", text: $assetNumber)
            TextField("Numéro de série", text: $serialNumber)
            TextField("Nom convivial", text: $friendlyName)
            
            Button("Ajouter") {
                let config = getAppConfig()
                let newMachine = Machine(
                    endUserName: endUserName,
                    assetNumber: assetNumber,
                    locationGroupId: config?.locationGroupId ?? "",
                    messageType: Int(config?.messageType ?? 0),
                    serialNumber: serialNumber,
                    platformId: Int(config?.platformId ?? 0),
                    friendlyName: friendlyName,
                    ownership: config?.ownership ?? ""
                )
                onAdd(newMachine)
                dismiss()
            }
            
            Button("Annuler") {
                dismiss()
            }
            
        }
        .padding()
    }
}

// MARK: - Configuration Vue
struct ConfigurationView: View {
    @Binding var isConfigured: Bool
    @State private var locID = ""
    @State private var pID = ""
    @State private var OShip = ""
    @State private var MT = ""
    @State private var sPath = ""
    @State private var sUsername = ""
    @State private var sPassword = ""
    
    var body: some View {
        VStack {
            TextField("Location Group ID", text: $locID)
            TextField("Platform ID", text: $pID)
            TextField("Ownership", text: $OShip)
            TextField("Message Type", text: $MT)
            TextField("Chemin Samba", text: $sPath)
            TextField("Nom d'utilisateur Samba", text: $sUsername)
            SecureField("Mot de passe Samba", text: $sPassword)
            
            HStack {
                Button("Enregistrer") {
                    saveConfiguration()
                }
                
                Button("Clear Configuration") {
                    clearConfiguration()
                }
                .foregroundColor(.red)
            }
        }
        .padding()
        .onAppear(perform: loadConfiguration)
    }
    
    /// Charger les valeurs existantes depuis Core Data et Keychain
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
    
    /// Enregistrer les nouvelles valeurs dans Core Data et Keychain
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
        
        clearField()
        
        isConfigured = true
    }
    
    ///  Réinitialiser les champs
    func clearConfiguration() {
        clearField()
    }
    
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
@main
struct Enroll_Macs_WSOApp: App {
    @AppStorage("isConfigured") private var isConfigured: Bool = false
    
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            if isConfigured {
                MachineListView()
            } else {
                ConfigurationView(isConfigured: $isConfigured)
            }
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}


extension View {
    func getHostingWindow() -> NSWindow? {
        guard let window = NSApplication.shared.windows.first(where: { $0.isKeyWindow }) else {
            return nil
        }
        return window
    }
}
