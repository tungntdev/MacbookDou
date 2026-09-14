import os

enum Log {
    static let app = Logger(subsystem: "com.local.MacbookDuo", category: "app")
    static let effect = Logger(subsystem: "com.local.MacbookDuo", category: "effect")
    static let capture = Logger(subsystem: "com.local.MacbookDuo", category: "capture")
}
