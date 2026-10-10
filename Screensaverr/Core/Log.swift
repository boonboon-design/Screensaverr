import os

/// Logs show up in Console.app — search for "Screensaverr".
enum Log {
    static let general = Logger(subsystem: "com.boonboondesign.Screensaverr", category: "Screensaverr")
    static let network = Logger(subsystem: "com.boonboondesign.Screensaverr", category: "Network")
}
