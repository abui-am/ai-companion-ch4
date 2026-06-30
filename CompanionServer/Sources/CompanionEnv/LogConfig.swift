import Foundation
import Logging

public enum LogConfig {
    public static func level() -> Logger.Level {
        switch ProcessInfo.processInfo.environment["LOG_LEVEL"]?.lowercased() {
        case "trace": .trace
        case "debug": .debug
        case "info": .info
        case "warning", "warn": .warning
        case "error": .error
        case "critical": .critical
        default: .debug
        }
    }

    public static func apply(to logger: inout Logger) {
        logger.logLevel = level()
    }
}
