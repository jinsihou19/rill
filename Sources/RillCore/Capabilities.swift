import Foundation

public struct RedisCapability: Identifiable, Equatable, Sendable {
    public enum Status: String, Sendable { case available = "可用", denied = "无权限", unsupported = "不支持", failed = "暂不可用" }
    public let id: String
    public let status: Status
    public let message: String?
}

public actor RedisCapabilities {
    private var values: [String: RedisCapability] = [:]
    public init() {}
    public func observe(_ command: String, reply: RESPValue) {
        let status: RedisCapability.Status
        if let error = reply.serverError {
            switch error.category { case .permission: status = .denied; case .unsupported: status = .unsupported; default: status = .failed }
        } else { status = .available }
        values[command] = RedisCapability(id: command, status: status, message: reply.serverError?.localizedDescription)
    }
    public func snapshot() -> [RedisCapability] { values.values.sorted { $0.id < $1.id } }
    public func supportsScanType() -> Bool { values["SCAN TYPE"]?.status != .unsupported }
    public func markScanTypeUnsupported(_ error: RedisError) {
        values["SCAN TYPE"] = RedisCapability(id: "SCAN TYPE", status: .unsupported, message: error.localizedDescription)
    }
    public static func canRetryScanWithoutType(_ error: Error) -> Bool {
        guard case .server(let text) = error as? RedisError else { return false }
        return text.uppercased().hasPrefix("ERR ") && (text.lowercased().contains("syntax error") || text.lowercased().contains("unknown option"))
    }
}
