// The node's configuration is layered, as systemd drop-ins and sudoers.d
// are: `<root>/lattice.json` first, then each `<root>/config.d/<name>.json`
// in name order (byte order: number them, `10-deploy`, `50-hostmarket`, to
// order them). Each writer owns one file (a deploy script, a hosting seller,
// people and dashboards `operator`); the node merges them and never writes
// lattice.json. Precedence is name order alone: no layer outranks another
// otherwise.
//
// Merge rules, per key:
// - a value (a port, a rate, a mode): the later layer's wins;
// - `hostedChains` (chain paths), each chain's `peers`, `rpcAllowedOrigins`
//   and `operatorAllowedOrigins`: the union of every layer's;
// - `stateWindows` and `finalityWindows`: per chain path, the later layer's.
// A key set to null is as if the layer did not set it: it does not unset
// an earlier layer's value. The listed chains, with their ancestors, make
// the tree the node hosts (`HostedTree`). A setting for a chain not in it
// (its peers, its windows), or a state window while `state` is not
// `recent`, is inert: reported, not applied, not an error. Any other
// problem (a file that is not JSON, an unknown key, a merged result that
// does not check) is the whole configuration's: the node does not start,
// and a change is refused.

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
        files(root: root).filter { isFragment($0) }.map { String($0.dropLast(5)) }.sorted()
    }

    /// The files of config.d that are not read, their names not a
    /// fragment's (hidden files aside).
    public static func ignored(root: URL) -> [String] {
        files(root: root).filter { !$0.hasPrefix(".") && !isFragment($0) }.sorted()
    }

    private static func files(root: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory(root: root).path)) ?? []
    }

    private static func isFragment(_ file: String) -> Bool {
        file.hasSuffix(".json") && isValidName(String(file.dropLast(5)))
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
    /// The merged configuration, checked, as the node's flags take it: its
    /// `hostedChains`, `peers`, `stateWindows` and `finalityWindows` are the
    /// tree's, the inert settings left out.
    public let topology: Topology
    /// The chains hosted: what the layers list, with their ancestors, and
    /// each chain's settings.
    public let tree: HostedTree
    /// What the layers set that does not apply, and why: settings for chains
    /// not in the tree, state windows without `state: recent`, files of
    /// config.d that are not read.
    public let inert: [String]
    /// The layers merged, in order.
    public let layers: [String]

    public static func load(root: URL) throws -> MergedConfig {
        let merged = try merge(ConfigFragments.layers(root: root))
        let ignored = ConfigFragments.ignored(root: root).map {
            "\(ConfigFragments.directoryName)/\($0) is not read: a fragment is <name>.json, the name lowercase letters, digits, ., _ and -"
        }
        guard !ignored.isEmpty else { return merged }
        return MergedConfig(topology: merged.topology, tree: merged.tree, inert: merged.inert + ignored, layers: merged.layers)
    }

    private static let unionLists: Set<String> = ["rpcAllowedOrigins", "operatorAllowedOrigins"]
    private static let chainKeys: Set<String> = ["hostedChains", "peers", "stateWindows", "finalityWindows", Topology.retiredMiningKey]

    public static func merge(_ layers: [ConfigLayer]) throws -> MergedConfig {
        var merged: [String: Any] = [:]
        var listedBy: [String: [String]] = [:]
        var settings: [String: ChainSettings] = [:]
        var lists: [String: [String]] = [:]
        for layer in layers {
            let (paths, parsed) = try check(layer)
            for path in paths where listedBy[path]?.contains(layer.name) != true {
                listedBy[path, default: []].append(layer.name)
            }
            for (chain, list) in parsed.peers?.byChain ?? [:] {
                settings[chain, default: ChainSettings()].peers = union(settings[chain]?.peers ?? [], list)
            }
            for (chain, window) in parsed.stateWindows ?? [:] { settings[chain, default: ChainSettings()].stateWindow = window }
            for (chain, window) in parsed.finalityWindows ?? [:] { settings[chain, default: ChainSettings()].finalityWindow = window }
            for (key, value) in layer.object where !chainKeys.contains(key) && !(value is NSNull) {
                if unionLists.contains(key) {
                    lists[key] = union(lists[key] ?? [], value as? [String] ?? [])
                } else {
                    merged[key] = value
                }
            }
        }
        for (key, list) in lists { merged[key] = list }
        // A zero window is wrong wherever it is, inert or not.
        if merged["stateWindow"] as? Int == 0 || settings.values.contains(where: { $0.stateWindow == 0 }) {
            throw CtlError("a state window is at least 1 block")
        }
        var inert: [String] = []
        let state = merged["state"] as? String ?? "all"
        if state != "recent" {
            if settings.values.contains(where: { $0.stateWindow != nil }) {
                inert.append("stateWindows: state is \(state), not recent")
                for chain in settings.keys { settings[chain]?.stateWindow = nil }
            }
            if merged["stateWindow"] != nil {
                inert.append("stateWindow: state is \(state), not recent")
                merged["stateWindow"] = nil
            }
        }
        let tree = HostedTree(listedBy: listedBy, settings: settings)
        // A setting for a chain not in the tree waits, inert, until it is.
        for (chain, setting) in settings.sorted(by: { $0.key < $1.key }) where tree[chain] == nil {
            if setting.peers != nil { inert.append("peers for \(chain): not hosted") }
            if setting.stateWindow != nil { inert.append("stateWindows for \(chain): not hosted") }
            if setting.finalityWindow != nil { inert.append("finalityWindows for \(chain): not hosted") }
        }
        if !tree.children.isEmpty { merged["hostedChains"] = tree.children }
        let peers = tree.chains.reduce(into: [String: [String]]()) { $0[$1.path] = $1.settings.peers }
        let stateWindows = tree.chains.reduce(into: [String: UInt64]()) { $0[$1.path] = $1.settings.stateWindow }
        let finalityWindows = tree.chains.reduce(into: [String: UInt64]()) { $0[$1.path] = $1.settings.finalityWindow }
        if !peers.isEmpty { merged["peers"] = peers }
        if !stateWindows.isEmpty { merged["stateWindows"] = stateWindows }
        if !finalityWindows.isEmpty { merged["finalityWindows"] = finalityWindows }
        for key in ["listen", "rpc"] where merged[key] == nil {
            throw CtlError("no layer sets \(key) (\(layers.map(\.name).joined(separator: ", ")))")
        }
        let topology: Topology
        do {
            topology = try Topology.load(data: JSONSerialization.data(withJSONObject: merged)).validated()
        } catch {
            throw CtlError("the merged configuration (\(layers.map(\.name).joined(separator: ", "))) does not check: \(error)")
        }
        return MergedConfig(topology: topology, tree: tree, inert: inert, layers: layers.map(\.name))
    }

    /// The layer's hosted chains, and the layer read as lattice.json (its
    /// per-chain settings), after checking every key it sets.
    private static func check(_ layer: ConfigLayer) throws -> ([String], Topology) {
        let name = layer.name == ConfigFragments.baseName ? Topology.fileName : "\(ConfigFragments.directoryName)/\(layer.name).json"
        var paths: [String] = []
        for entry in layer.object["hostedChains"] as? [Any] ?? [] {
            guard let path = entry as? String else {
                throw CtlError("\(name): a hostedChains entry is a chain path; a chain is created with POST /chains (`lattice child create`)")
            }
            guard let address = ChainAddress(string: path), address.key == path, !address.isNexus else {
                throw CtlError("\(name): \(path) is not a child chain's path")
            }
            paths.append(path)
        }
        // Every other key as lattice.json holds it (listen and rpc may be
        // another layer's).
        var probe = layer.object
        probe["hostedChains"] = nil
        probe[Topology.retiredMiningKey] = nil
        for (key, value) in probe where value is NSNull { probe[key] = nil }
        if probe["listen"] == nil { probe["listen"] = 1 }
        if probe["rpc"] == nil { probe["rpc"] = 1 }
        let parsed: Topology
        do {
            parsed = try Topology.load(data: JSONSerialization.data(withJSONObject: probe))
        } catch {
            throw CtlError("\(name): \(error)")
        }
        // A per-chain setting names a chain path (one not hosted is inert).
        for (key, chains) in [
            ("peers", parsed.peers?.byChain.keys.sorted()), ("stateWindows", parsed.stateWindows?.keys.sorted()),
            ("finalityWindows", parsed.finalityWindows?.keys.sorted()),
        ] {
            if let chain = (chains ?? []).first(where: { ChainAddress(string: $0)?.key != $0 }) {
                throw CtlError("\(name): \(key) names \(chain), which is not a chain path")
            }
        }
        return (paths, parsed)
    }

    private static func union(_ first: [String], _ second: [String]) -> [String] {
        var seen = Set(first)
        return first + second.filter { seen.insert($0).inserted }
    }
}
