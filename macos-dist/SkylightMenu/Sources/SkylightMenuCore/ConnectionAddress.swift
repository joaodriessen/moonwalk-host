import Foundation

public struct ConnectionAddress: Identifiable, Codable, Equatable, Sendable {
    public var id: String { interface + ":" + address }
    public let interface: String
    public let address: String
    public init(interface: String, address: String) { self.interface = interface; self.address = address }
    public func hostValue(port: Int) -> String {
        let host = address.contains(":") ? "[\(address)]" : address
        return port == 47989 ? host : "\(host):\(port)"
    }
}
