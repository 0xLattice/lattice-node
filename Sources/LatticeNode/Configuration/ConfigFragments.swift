// The node's configuration is layered, as systemd drop-ins and sudoers.d
// are: `<root>/lattice.json` first, then each `<root>/config.d/<name>.json`
// in name order. Each writer owns one file (a deploy script `deploy`, a
// hosting seller `hostmarket`, people and dashboards `operator`); the node
// merges them and never writes lattice.json.
//
// Merge rules, per key:
// - a value (a port, a rate, a mode): the later layer's wins;
// - `hostedChains`, each chain's `peers`, `rpcAllowedOrigins` and
//   `operatorAllowedOrigins`: the union of every layer's;
// - `stateWindows` and `finalityWindows`: per chain path, the later layer's.
// A `hostedChains` entry is a chain's path, or an object that also carries
// what creates the chain (`{path, spec, premineTo, genesisTransactions,
// policyModules}`); two layers that create one chain differently leave it
// unhosted with an error, as is a chain whose parent no layer hosts. Any
// other problem (a file that is not JSON, an unknown key, a merged result
// that does not check) is the whole configuration's: the node does not start.

import Foundation
import Lattice
import LatticeNodeAPI

/// One layer of the configuration: lattice.json (named `lattice`) or one
/// file of config.d.
public struct ConfigLayer {
    public let name: String
    /// The file's JSON object (immutable).
    public let object: [String: Any]

    public init(name: String, object: [String: Any]) {
        self.name = name
        self.object = object
    }
}

public enum ConfigFragments {
    public static let directoryName = "config.d"
    /// lattice.json's name as a layer; no fragment takes it.
    public static let baseName = "lattice"

    public static func directory(root: URL) -> URL {
        root.appendingPathComponent(directoryName)
    }

    public static func file(root: URL, name: String) -> URL {
        directory(root: root).appendingPathComponent(name + ".json")
    }

    /// A fragment's name: lowercase letters, digits, `.`, `_` and `-`,
    /// starting with a letter or digit (`deploy`, `50-hostmarket`).
    public static func isValidName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, name != baseName, name.count <= 64 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
        return CharacterSet.alphanumerics.contains(first) && first != "." && first != "_" && first != "-"
            && name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// The fragments' names in config.d, in merge order. A file whose name
    /// is not a fragment's (`x.json.bak`, `README`) is not read.
    public static func names(root: URL) -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory(root: root).path)) ?? []
        return files.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }
            .filter(isValidName).sorted()
    }

    /// lattice.json (when there is one), then every fragment, in order;
    /// with `replacing`, the fragment of that name as `object` would make
    /// it instead (nil: without it).
    public static func layers(
        root: URL, replacing name: String? = nil, with replacement: [String: Any]? = nil
    ) throws -> [ConfigLayer] {
        var layers: [ConfigLayer] = []
        let base = root.appendingPathComponent(Topology.fileName)
        if FileManager.default.fileExists(atPath: base.path) {
            layers.append(ConfigLayer(name: baseName, object: try object(at: base)))
        }
        var all = Set(names(root: root))
        if let name { all.remove(name) }
        if let name, replacement != nil { all.insert(name) }
        for fragment in all.sorted() {
            let object = fragment == name ? replacement ?? [:] : try object(at: file(root: root, name: fragment))
            layers.append(ConfigLayer(name: fragment, object: object))
        }
        guard !layers.isEmpty else {
            throw CtlError("no \(Topology.fileName) and no \(directoryName) in \(root.path); run `lattice init` first")
        }
        return layers
    }

    /// A layer's content, checked as a file of it is.
    public static func object(at file: URL) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: file) else { throw CtlError("\(file.path) cannot be read") }
        return try object(data, named: file.path)
    }

    public static func object(_ data: Data, named name: String) throws -> [String: Any] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw CtlError("\(name) must contain one JSON object")
        }
        return object
    }
}

/// The configuration every layer makes together.
public struct MergedConfig: Sendable {
    /// The merged configuration, checked: its `hostedChains` are the chains
    /// that can be hosted (parent first), the ones in `chainErrors` left out.
    public let topology: Topology
    /// What creates each chain a layer creates, by path.
    public let creates: [String: HostedChain]
    /// The layers that list each chain, in merge order.
    public let declaredBy: [String: [String]]
    /// The chains listed but not hosted, and why.
    public let chainErrors: [String: String]
    /// The layers merged, in order.
    public let layers: [String]

    public static func load(root: URL) throws -> MergedConfig {
        try merge(ConfigFragments.layers(root: root))
    }

    private static let unionLists: Set<String> = ["rpcAllowedOrigins", "operatorAllowedOrigins"]
    private static let chainMaps: Set<String> = ["stateWindows", "finalityWindows"]

    public static func merge(_ layers: [ConfigLayer]) throws -> MergedConfig {
        var merged: [String: Any] = [:]
        var chains: [String] = []
        var declaredBy: [String: [String]] = [:]
        var creates: [String: HostedChain] = [:]
        var createdBy: [String: (layer: String, bytes: Data)] = [:]
        var chainErrors: [String: String] = [:]
        var peers: [String: [String]] = [:]
        var lists: [String: [String]] = [:]
        var maps: [String: [String: Any]] = [:]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for layer in layers {
            let entries = try check(layer)
            for (path, entry) in entries {
                if declaredBy[path] == nil { chains.append(path) }
                if declaredBy[path]?.contains(layer.name) != true { declaredBy[path, default: []].append(layer.name) }
                guard let entry, entry.spec != nil else { continue }
                let bytes = try encoder.encode(entry)
                if let earlier = createdBy[path] {
                    if earlier.bytes != bytes {
                        chainErrors[path] = "\(earlier.layer) and \(layer.name) create \(path) differently"
                    }
                } else {
                    createdBy[path] = (layer.name, bytes)
                    creates[path] = entry
                }
            }
            for (key, value) in layer.object where key != "hostedChains" && key != Topology.retiredMiningKey {
                if value is NSNull { continue }
                if key == "peers" {
                    let byChain = (value as? [String]).map { [ChainAddress.nexus: $0] } ?? (value as? [String: [String]] ?? [:])
                    for (chain, list) in byChain { peers[chain] = union(peers[chain] ?? [], list) }
                } else if unionLists.contains(key) {
                    lists[key] = union(lists[key] ?? [], value as? [String] ?? [])
                } else if chainMaps.contains(key) {
                    maps[key, default: [:]].merge(value as? [String: Any] ?? [:]) { _, later in later }
                } else {
                    merged[key] = value
                }
            }
        }
        // Parent first; a chain whose parent is not hosted waits for it.
        var hosted: [String] = []
        var hostable: Set<String> = [ChainAddress.nexus]
        let depth = { (path: String) in path.split(separator: "/").count }
        for path in chains.sorted(by: { (depth($0), $0) < (depth($1), $1) }) where chainErrors[path] == nil {
            guard let parent = ChainAddress(string: path)?.parent?.key, hostable.contains(parent) else {
                let parent = ChainAddress(string: path)?.parent?.key ?? "its parent"
                chainErrors[path] = "waiting for \(parent), which is not hosted"
                continue
            }
            hostable.insert(path)
            hosted.append(path)
        }
        if !chains.isEmpty { merged["hostedChains"] = hosted }
        // A listed chain left unhosted takes its peers with it; peers for a
        // chain no layer lists are an error of the whole.
        let hostedPeers = peers.filter { chainErrors[$0.key] == nil }
        if !hostedPeers.isEmpty { merged["peers"] = hostedPeers }
        for (key, list) in lists { merged[key] = list }
        for (key, map) in maps { merged[key] = map }
        for key in ["listen", "rpc"] where merged[key] == nil {
            throw CtlError("no layer sets \(key) (\(layers.map(\.name).joined(separator: ", ")))")
        }
        let topology: Topology
        do {
            topology = try Topology.load(data: JSONSerialization.data(withJSONObject: merged)).validated()
        } catch {
            throw CtlError("the merged configuration (\(layers.map(\.name).joined(separator: ", "))) does not check: \(error)")
        }
        return MergedConfig(
            topology: topology, creates: creates, declaredBy: declaredBy, chainErrors: chainErrors,
            layers: layers.map(\.name)
        )
    }

    /// The layer's hosted chains (with what creates each, when it does),
    /// after checking every key the layer sets as lattice.json's.
    private static func check(_ layer: ConfigLayer) throws -> [(String, HostedChain?)] {
        let name = layer.name == ConfigFragments.baseName ? Topology.fileName : "\(ConfigFragments.directoryName)/\(layer.name).json"
        var entries: [(String, HostedChain?)] = []
        for entry in layer.object["hostedChains"] as? [Any] ?? [] {
            if let path = entry as? String {
                entries.append((path, nil))
            } else if entry is [String: Any],
                      let chain = try? JSONDecoder().decode(HostedChain.self, from: JSONSerialization.data(withJSONObject: entry)) {
                entries.append((chain.path, chain))
            } else {
                throw CtlError("\(name): a hostedChains entry is a chain path or {path, spec, premineTo, genesisTransactions, policyModules}")
            }
        }
        for (path, chain) in entries {
            guard let address = ChainAddress(string: path), address.key == path, !address.isNexus else {
                throw CtlError("\(name): \(path) is not a child chain's path")
            }
            if let chain, chain.spec == nil,
               chain.premineTo != nil || chain.genesisTransactions != nil || chain.policyModules != nil {
                throw CtlError("\(name): \(path): premineTo, genesisTransactions and policyModules come with a spec")
            }
        }
        // Every other key as lattice.json holds it (listen and rpc may be
        // another layer's).
        var probe = layer.object
        probe["hostedChains"] = nil
        probe[Topology.retiredMiningKey] = nil
        for (key, value) in probe where value is NSNull { probe[key] = nil }
        if probe["listen"] == nil { probe["listen"] = 1 }
        if probe["rpc"] == nil { probe["rpc"] = 1 }
        do {
            _ = try Topology.load(data: JSONSerialization.data(withJSONObject: probe))
        } catch {
            throw CtlError("\(name): \(error)")
        }
        return entries
    }

    private static func union(_ first: [String], _ second: [String]) -> [String] {
        var seen = Set(first)
        return first + second.filter { seen.insert($0).inserted }
    }
}
