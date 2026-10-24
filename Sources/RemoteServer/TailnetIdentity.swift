import Foundation

/// Who may use the remote API, decided as Rex decides it: the server listens only on the Mac's
/// Tailscale address, and Tailscale names each caller. Only the Mac's owner, from a device of their
/// own (not one owned by an ACL tag), gets in. No pairing or keys of PrompTTY's own.
public enum TailnetIdentity {
    /// This Mac on the tailnet: its addresses, its name, and the user it belongs to
    /// (`tailscale status --json`).
    public struct Node: Equatable, Sendable {
        public var addresses: [String]
        /// "mikkels-studio.example.ts.net".
        public var dnsName: String
        public var ownerID: Int64

        public init(addresses: [String], dnsName: String, ownerID: Int64) {
            self.addresses = addresses
            self.dnsName = dnsName
            self.ownerID = ownerID
        }

        /// The IPv4 address to listen on.
        public var ipv4: String? { addresses.first { $0.contains(".") } }
    }

    /// A caller as Tailscale names it (`tailscale whois --json`).
    public struct Caller: Equatable, Sendable {
        public var userID: Int64
        /// "someone@github".
        public var login: String
        /// The device's ACL tags; a tagged device belongs to its tags, not to a user.
        public var tags: [String]
        /// The device's name.
        public var device: String

        public init(userID: Int64, login: String, tags: [String] = [], device: String = "") {
            self.userID = userID
            self.login = login
            self.tags = tags
            self.device = device
        }
    }

    public enum Decision: Equatable, Sendable {
        case allowed(login: String)
        case refused(String)
    }

    public static func decide(_ caller: Caller?, owner: Int64) -> Decision {
        guard let caller else { return .refused("Tailscale does not know this caller") }
        guard caller.tags.isEmpty else { return .refused("\(caller.device) is a tagged device, not a person's") }
        guard caller.userID == owner else { return .refused("\(caller.login) is not this Mac's owner") }
        return .allowed(login: caller.login)
    }

    /// Reads `tailscale status --json`; nil when Tailscale is not running or logged in.
    public static func node(fromStatus data: Data) -> Node? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["BackendState"] as? String == "Running",
              let me = object["Self"] as? [String: Any],
              let owner = int64(me["UserID"]) else { return nil }
        let addresses = me["TailscaleIPs"] as? [String] ?? []
        let dnsName = (me["DNSName"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return Node(addresses: addresses, dnsName: dnsName, ownerID: owner)
    }

    /// Reads `tailscale whois --json`.
    public static func caller(fromWhois data: Data) -> Caller? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = object["UserProfile"] as? [String: Any],
              let user = int64(profile["ID"]) else { return nil }
        let node = object["Node"] as? [String: Any] ?? [:]
        let device = (node["ComputedName"] as? String) ?? (node["Name"] as? String ?? "")
        return Caller(userID: user, login: profile["LoginName"] as? String ?? "", tags: node["Tags"] as? [String] ?? [], device: device)
    }

    private static func int64(_ value: Any?) -> Int64? {
        (value as? NSNumber)?.int64Value
    }
}

/// Runs the `tailscale` command line, wherever it is installed.
public enum TailscaleCLI {
    static let candidates = [
        "/usr/local/bin/tailscale",
        "/opt/homebrew/bin/tailscale",
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
    ]

    public static var path: String? { candidates.first { FileManager.default.isExecutableFile(atPath: $0) } }

    /// This Mac on the tailnet, or nil when Tailscale is not installed, running or logged in.
    public static func node() async -> TailnetIdentity.Node? {
        await run(["status", "--json"]).flatMap(TailnetIdentity.node(fromStatus:))
    }

    public static func whois(_ address: String) async -> TailnetIdentity.Caller? {
        await run(["whois", "--json", address]).flatMap(TailnetIdentity.caller(fromWhois:))
    }

    /// The command's standard output, or nil when it fails or takes longer than 5 seconds.
    static func run(_ arguments: [String]) async -> Data? {
        guard let path else { return nil }
        return await withCheckedContinuation { continuation in
            // Read while it runs: a status of a large tailnet is more than a pipe holds, and the
            // command would wait for room to write.
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                let output = Pipe()
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    return continuation.resume(returning: nil)
                }
                let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                timeout.cancel()
                continuation.resume(returning: process.terminationReason == .exit && process.terminationStatus == 0 ? data : nil)
            }
        }
    }
}
