// One app, two editions. The EMISSARY edition (default) is Matthew's private node app.
// The Worker Bee edition (built with the WORKERBEE flag) is the public version: no preset address.
enum Brand {
    #if WORKERBEE
    static let title = "Worker Bee"
    static let defaultSupervisor = ""
    static let defaultNodeName = "my-iphone"
    static let connectHeader = "2 · Connect to your Supervisor (Tailscale must be on)"
    static let approveHint = "Then approve this iPhone on your Supervisor's dashboard."
    #else
    static let title = "EMISSARY Node"
    static let defaultSupervisor = "https://msi.tail21a0f7.ts.net"
    static let defaultNodeName = "iphone13-node"
    static let connectHeader = "2 · Connect to EMISSARY (Tailscale must be on)"
    static let approveHint = "Then on the MSI approve it for research, the same way as the other Workers."
    #endif
}
