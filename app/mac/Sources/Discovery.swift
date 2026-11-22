import Foundation

/// Finds LanKvm receivers on the local network.
///
/// Sweeps the /24 around every local IPv4 address, which covers the ordinary
/// home and office LAN without needing mDNS or manual address entry.
enum Discovery {
    private static let session = URLSession(configuration: .ephemeral)

    struct Found {
        var host: String
        var machine: String?
    }

    /// Local IPv4 addresses of this Mac, excluding loopback.
    static func localAddresses() -> [String] {
        var addresses: [String] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return addresses }
        defer { freeifaddrs(head) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(pointer.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard pointer.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                pointer.pointee.ifa_addr,
                socklen_t(pointer.pointee.ifa_addr.pointee.sa_len),
                &buffer, socklen_t(buffer.count),
                nil, 0, NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            let address = String(cString: buffer)
            if !address.isEmpty, address != "127.0.0.1" { addresses.append(address) }
        }
        return addresses
    }

    /// Candidate hosts: every address in the /24 of each local interface.
    static func candidates() -> [String] {
        var hosts: [String] = []
        var seen = Set<String>()
        for address in localAddresses() {
            let parts = address.split(separator: ".").compactMap { Int($0) }
            guard parts.count == 4 else { continue }
            let prefix = "\(parts[0]).\(parts[1]).\(parts[2])"
            for last in 1...254 {
                let host = "\(prefix).\(last)"
                if seen.insert(host).inserted { hosts.append(host) }
            }
        }
        return hosts
    }

    /// Probe one host. Returns the machine name when a receiver answers.
    static func identify(host: String, port: Int, timeout: TimeInterval = 0.5) async -> Found? {
        guard let url = URL(string: "http://\(host):\(port)/api/hello") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            guard let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  payload["ok"] as? Bool == true,
                  let agent = payload["agent"] as? String, ["lankvm", "dsh-lan-kvm"].contains(agent) else { return nil }
            return Found(host: host, machine: payload["machine"] as? String)
        } catch {
            return nil
        }
    }

    /// Sweep the LAN, reporting the first receiver found.
    static func scan(port: Int, onFound: @escaping (Found) -> Void) async -> [Found] {
        let hosts = candidates()
        var found: [Found] = []
        await withTaskGroup(of: Found?.self) { group in
            var index = 0
            let width = 32
            func addNext() {
                guard index < hosts.count else { return }
                let host = hosts[index]
                index += 1
                group.addTask { await identify(host: host, port: port) }
            }
            for _ in 0..<width { addNext() }
            for await result in group {
                if let result {
                    found.append(result)
                    onFound(result)
                }
                addNext()
            }
        }
        return found
    }
}
