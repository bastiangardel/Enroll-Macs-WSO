//
//  ConfigManager.swift
//  Enroll Macs WSO
//
//  Created by Bastian Gardel on 17.03.2025.
//

import Foundation

class ConfigManager {
    static let shared = ConfigManager()
    
    private let testKey = "isTestMode"
    
    var isTestMode: Bool {
        get {
            UserDefaults.standard.bool(forKey: testKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: testKey)
        }
    }
    
    private init() {
        // Si la clé n'existe pas, on initialise à `false`
        if UserDefaults.standard.object(forKey: testKey) == nil {
            isTestMode = true
        }
    }
}
