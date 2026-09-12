import os

enum Log {
    static let app = Logger(subsystem: "com.local.MacbookDou", category: "app")
    static let effect = Logger(subsystem: "com.local.MacbookDou", category: "effect")
    static let capture = Logger(subsystem: "com.local.MacbookDou", category: "capture")
}
