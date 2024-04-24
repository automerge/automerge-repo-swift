//
//  Logger+test.swift
//
//
//  Created by Joseph Heck on 4/24/24.
//

import Foundation
import OSLog

extension Logger {
    /// Using your bundle identifier is a great way to ensure a unique identifier.
    private static let subsystem = Bundle.main.bundleIdentifier!

    /// Logs updates and interaction related to watching for external peer systems.
    static let test = Logger(subsystem: subsystem, category: "IntegrationTest")
}

let expectationTimeOut = 10.0 // seconds
