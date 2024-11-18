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

    // Décomposer l'URL SMB pour extraire l'hôte et le partage
    guard let url = URL(string: sambaPath), let host = url.host else {
        completion(false, "Chemin SMB invalide")
        return
    }

    // Initialiser le client SMB avec l'hôte
    let client = SMBClient(host: host)
    
    Task {
        do {
            // Se connecter au serveur SMB avec les identifiants
            try await client.login(username: sambaUsername, password: sambaPassword)

            // Connexion au partage SMB
            // Extraire le nom du partage à partir du chemin
            let shareName = url.pathComponents.count > 1 ? url.pathComponents[1] : ""

            // Si le partage est manquant dans le chemin, on retourne une erreur
            guard !shareName.isEmpty else {
                completion(false, "Nom de partage manquant dans l'URL SMB")
                return
            }
            
            try await client.connectShare(String(shareName))

            // Télécharger le fichier sur le serveur SMB
            let remoteFilePath = url.path.dropFirst(shareName.count + 1) // Le reste du chemin après le nom du partage
            try await client.upload(content: content, path: remoteFilePath.appending("/\(filename)"))

            // Déconnexion après l'upload
            try await client.disconnectShare()

            // Terminer avec succès
            completion(true, "Fichier enregistré avec succès sur \(sambaPath)")
        } catch {
            // Gérer les erreurs
            completion(false, "Erreur : \(error.localizedDescription)")
        }
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

    var body: some View {
        VStack {
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
                
                Button("Supprimer sélectionnées") {
                    deleteSelectedMachines()
                }
                .disabled(selectedMachines.isEmpty)
                
                Button("Supprimer tout") {
                    deleteAllMachines()
                }
                .foregroundColor(.red)
                .disabled(machines.isEmpty)
                
                Button("Envoyer") {
                    authenticateUserAndSendMachines()
                }
                .disabled(machines.isEmpty) // Désactiver tant que l'utilisateur n'est pas authentifié
                
                Button("Clear Configuration") {
                    clearStorage()
                    isConfigured = false // Retour à l'écran de configuration
                }
                
                Button("Close App") {
                    NSApp.terminate(nil)
                }
            }
            .padding()
        }
        .sheet(isPresented: $showAddMachineView) {
            AddMachineView { newMachine in
                machines.append(newMachine)
            }
        }
    }
    
    // Fonction de demande d'authentification et envoi des machines
    func authenticateUserAndSendMachines() {
        let context = LAContext()
        var error: NSError?
        
        // Vérifier si l'authentification biométrique est disponible
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
            // Demander l'authentification biométrique
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "que vous vous authentifiez pour envoyer les machines") { success, authenticationError in
                DispatchQueue.main.async {
                    if success {
                        isAuthenticated = true
                        sendMachinesToSamba() // Envoyer les machines après authentification réussie
                    } else {
                        statusMessage = authenticationError?.localizedDescription ?? "Échec de l'authentification."
                    }
                }
            }
        } else {
            // Biométrie non disponible, afficher une erreur
            statusMessage = "La biométrie n'est pas disponible sur cet appareil."
        }
    }
    
    func sendMachinesToSamba() {
        for machine in machines {
            if let jsonData = machine.toJSON() {
                let filename = "scx-\(machine.assetNumber).json"
                saveFileToSamba(filename: filename, content: jsonData) { success, message in
                    DispatchQueue.main.async {
                        if success {
                            statusMessage = message
                            machines.removeAll()
                            selectedMachines.removeAll()
                        } else {
                            statusMessage = message
                        }
                    }
                }
            }
        }
    }

    // Supprimer des machines spécifiques
    func deleteMachines(at offsets: IndexSet) {
        for index in offsets {
            let machine = machines[index]
            if selectedMachines.contains(machine.id) {
                selectedMachines.remove(machine.id)
            }
        }
        machines.remove(atOffsets: offsets)
    }

    // Supprimer les machines sélectionnées
    func deleteSelectedMachines() {
        machines.removeAll { machine in
            selectedMachines.contains(machine.id)
        }
        selectedMachines.removeAll()
    }

    // Supprimer toutes les machines
    func deleteAllMachines() {
        machines.removeAll()
        selectedMachines.removeAll()
    }
    
    func applicationShouldTerminateAfterLastWindowClosed (_ theApplication: NSApplication) -> Bool {
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
    @State private var locationGroupId = ""
    @State private var platformId = ""
    @State private var ownership = ""
    @State private var messageType = ""
    @State private var sambaPath = ""
    @State private var sambaUsername = ""
    @State private var sambaPassword = ""
    
    var body: some View {
        VStack {
            TextField("Location Group ID", text: $locationGroupId)
            TextField("Platform ID", text: $platformId)
            TextField("Ownership", text: $ownership)
            TextField("Message Type", text: $messageType)
            TextField("Chemin Samba", text: $sambaPath)
            TextField("Nom d'utilisateur Samba", text: $sambaUsername)
            SecureField("Mot de passe Samba", text: $sambaPassword)
            
            Button("Enregistrer") {
                saveConfiguration()
            }
        }
        .padding()
    }
    
    func saveConfiguration() {
        saveToCoreData(
            locationGroupId: locationGroupId,
            platformId: Int(platformId) ?? 0,
            ownership: ownership,
            messageType: Int(messageType) ?? 0,
            sambaPath: sambaPath
        )
        keychain[KeychainKeys.sambaUsername.rawValue] = sambaUsername
        keychain[KeychainKeys.sambaPassword.rawValue] = sambaPassword
        isConfigured = true
    }
}

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
