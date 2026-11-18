import AppKit
import Darwin
import SwiftUI
import SkylightMenuCore

enum LocalConnectionAddresses {
    static func current() -> [ConnectionAddress] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return [] }
        defer { freeifaddrs(first) }
        var result: [ConnectionAddress] = []
        var cursor = first
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            let interface = item.pointee
            guard interface.ifa_flags & UInt32(IFF_UP) != 0, interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let address = interface.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) || address.pointee.sa_family == UInt8(AF_INET6) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let value = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard !value.hasPrefix("fe80:"), !value.hasPrefix("169.254.") else { continue }
            result.append(ConnectionAddress(interface: String(cString: interface.ifa_name), address: value))
        }
        return result.sorted { ($0.address.contains(":") ? 1 : 0, $0.interface, $0.address) < ($1.address.contains(":") ? 1 : 0, $1.interface, $1.address) }
    }
}

struct ConnectionHandoffView: View {
    var host: HostConnection
    @State private var addresses: [ConnectionAddress] = []
    @State private var checking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let info = host.connectionInfo {
                Label(info.ready ? "Streaming listeners are ready on this Mac" : "Some streaming listeners are unavailable",
                      lucide: info.ready ? .circleCheck : .triangleAlert)
                if !info.ready { Text(info.unavailableListeners.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }
                Text("Running base port: \(String(info.basePort))").font(.caption)
                if let saved = Int(host.configValues["port"] ?? "47989"), saved != info.basePort {
                    Text("Saved port \(String(saved)) takes effect after a host restart.").font(.caption).foregroundStyle(.orange)
                }
            } else {
                Text("Streaming listener readiness is unknown until the host connects.").foregroundStyle(.secondary)
                Text("The running port is also unknown. Wait for the host before using Add Host.").font(.caption).foregroundStyle(.secondary)
            }
            if addresses.isEmpty {
                Text("No usable local network address was found. Connect this Mac to your network, then refresh.").font(.callout)
            } else {
                Text("If discovery does not find this Mac, use Add Host on your client:").font(.callout)
                ForEach(addresses) { item in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(host.connectionInfo.map { item.hostValue(port: $0.basePort) } ?? item.address).textSelection(.enabled)
                            Text(item.interface).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(item.hostValue(port: host.connectionInfo?.basePort ?? 47989), forType: .string)
                        }
                        .disabled(host.connectionInfo == nil)
                        .accessibilityLabel("Copy connection address for \(item.interface)")
                    }
                }
            }
            Text("These are this Mac’s addresses and local listener checks. The client must be able to reach the selected network; this does not test a router or Internet ports.")
                .font(.caption).foregroundStyle(.secondary)
            Button(checking ? "Checking…" : "Refresh Connection Details") { Task { await refresh() } }.disabled(checking)
        }
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in Task { await refresh() } }
    }

    private func refresh() async {
        guard !checking else { return }
        checking = true
        addresses = LocalConnectionAddresses.current()
        await host.refreshConnectionInfo()
        checking = false
    }
}
