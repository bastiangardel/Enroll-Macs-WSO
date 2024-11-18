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

    // Implémentation réelle de la connexion et de l'écriture sur un partage Samba à ajouter ici.
    // Simuler la réussite pour l'instant.
    DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
        completion(true, "Fichier enregistré avec succès sur \(sambaPath)")
    }
}

// MARK: - Vue principale
struct MachineListView: View {
    @State private var machines: [Machine] = []
    @State private var statusMessage: String = ""
    @State private var showAddMachineView = false
    
    var body: some View {
        VStack {
            List(machines) { machine in
                Text(machine.friendlyName)
            }
            Text(statusMessage)
                .foregroundColor(.red)
                .padding()
            
            HStack {
                Button("Ajouter une machine") {
                    showAddMachineView = true
                }
                Button("Envoyer") {
                    sendMachinesToSamba()
                }
                .disabled(machines.isEmpty)
            }
            .padding()
        }
        .sheet(isPresented: $showAddMachineView) {
            AddMachineView { newMachine in
                machines.append(newMachine)
            }
        }
    }
    
    func sendMachinesToSamba() {
        for machine in machines {
            if let jsonData = machine.toJSON() {
                let filename = "\(machine.assetNumber).json"
                saveFileToSamba(filename: filename, content: jsonData) { success, message in
                    DispatchQueue.main.async {
                        statusMessage = message
                    }
                }
            }
        }
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
