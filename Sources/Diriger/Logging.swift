import Foundation
import os

enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "tech.inkhorn.diriger"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let chrome = Logger(subsystem: subsystem, category: "chrome")
    static let rules = Logger(subsystem: subsystem, category: "rules")
    static let picker = Logger(subsystem: subsystem, category: "picker")
    static let browser = Logger(subsystem: subsystem, category: "browser")
}
