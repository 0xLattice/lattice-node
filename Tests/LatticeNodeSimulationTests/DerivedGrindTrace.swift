import Foundation
import Lattice
@testable import LatticeNodeCore

/// The blocks of one hosted child level Y and of its parent level X that a
/// trace names, by the labels of lattice-formal's `DerivedChildGrinds`:
/// children (Y blocks), carriers (X blocks committing them) and grinds
/// (root blocks, by CID: a grind's id at every level is its root's CID).
struct GrindTraceFixture {
    var children: [(cid: String, label: String, parent: String)] = []
    var carriers: [(cid: String, label: String, commits: String)] = []
    var grinds: [(root: String, label: String, carrier: String, meets: Bool)] = []

    /// `parent` is a child's label, or "genesis": a parent this trace does
    /// not follow, always weighed (or none: a child genesis).
    mutating func child(_ cid: String, _ label: String, parent: String = "genesis") {
        children.append((cid, label, parent))
    }

    mutating func carrier(_ cid: String, _ label: String, commits child: String) {
        carriers.append((cid, label, child))
    }

    /// A root block's grind credited at `carrier`; `meets` when its proof of
    /// the committed child verifies with work.
    mutating func grind(_ root: String, _ label: String, of carrier: String, meets: Bool) {
        grinds.append((root, label, carrier, meets))
    }

    /// A root block carrying a child of a level hosted under the root: its
    /// one grind is its own hash.
    mutating func rootCarrier(_ cid: String, _ label: String, commits child: String, meets: Bool = true) {
        carrier(cid, label, commits: child)
        grind(cid, label.lowercased(), of: label, meets: meets)
    }
}

/// Records one level's steps, one event per `DerivedChildGrinds` action,
/// and after each step that level's state as the model names it. Written as
/// `trace-<name>.json` under `DERIVED_TRACE_DIR` (none written without it).
///
/// One host step is atomic in the code and may be several model actions
/// (a peer proof's check, then a purge as its peer is disconnected; a
/// pending eviction beside a promotion): it becomes those events in an
/// order the model can take, and only the last carries the state after.
final class GrindTracer: @unchecked Sendable {
    nonisolated(unsafe) static var open: [GrindTracer] = []

    let name: String
    let path: ChainPath
    let parentPath: ChainPath
    let fixture: GrindTraceFixture
    let cap: Int
    private let childLabel: [String: String]
    private let carrierLabel: [String: String]
    private let grindLabel: [String: String]
    private var proofLabel: [String: String] = [:]
    private var jobs: [JobKey: Int] = [:]
    private var initial: [String: Any] = [:]
    private(set) var events: [[String: Any]] = []
    /// Code events with no model action that changed what the model names.
    private(set) var anomalies: [String] = []
    /// Set by a restart: the next step is the boot (the model's `Restart`).
    var booting = false

    struct JobKey: Hashable {
        let carrier: String
        let child: String
        let grinds: [String]
    }

    struct Snap: Equatable {
        var hosted: Bool
        var status: [String: String] = [:]
        var credited: [String: [String]] = [:]
        var deriving: [String: Int] = [:]
        var peerQ: [String: [String]] = [:]
        var peerKeys: Set<ChildProofKey> = []
        var peerLabels: [ChildProofKey: String] = [:]
        var weighed: Set<String> = []
        var cgr: [String: [String]] = [:]
        var peers: Set<PeerID> = []

        /// What the model names, without the bookkeeping.
        var model: [String: AnyHashable] {
            ["hosted": hosted, "status": status, "credited": credited, "deriving": deriving, "peerQ": peerQ,
             "weighed": weighed, "cgr": cgr]
        }
    }

    init(name: String, path: ChainPath, fixture: GrindTraceFixture, cap: Int, core: NodeCore) {
        self.name = name
        self.path = path
        parentPath = Array(path.dropLast())
        self.fixture = fixture
        self.cap = cap
        childLabel = Dictionary(uniqueKeysWithValues: fixture.children.map { ($0.cid, $0.label) })
        carrierLabel = Dictionary(uniqueKeysWithValues: fixture.carriers.map { ($0.cid, $0.label) })
        grindLabel = Dictionary(uniqueKeysWithValues: fixture.grinds.map { ($0.root, $0.label) })
        let start = snapshot(core)
        initial = [
            "hosted": start.hosted, "weighed": start.weighed.sorted(), "cgr": start.cgr,
            "status": start.status, "credited": start.credited,
        ]
        if start.status.values.contains(where: { $0 == "awaiting" || $0 == "pending" }) || !start.peerKeys.isEmpty
            || start.deriving.values.contains(where: { $0 > 0 }) {
            anomalies.append("trace started with work in flight")
        }
        Self.open.append(self)
    }

    var grow: Bool { parentPath.count > 1 }

    func label(_ proof: ChildBlockProof, as label: String) {
        if let id = ChildProofJob.id(of: proof) { proofLabel[id] = label }
    }

    private func label(of proof: ChildBlockProof) -> String {
        if let id = ChildProofJob.id(of: proof), let label = proofLabel[id] { return label }
        return grindLabel[proof.rootCID] ?? "bogus"
    }

    private func grinds(_ ids: some Sequence<String>) -> [String] {
        ids.map { grindLabel[$0] ?? "?" + String($0.suffix(8)) }.sorted()
    }

    // MARK: - State

    func snapshot(_ core: NodeCore) -> Snap {
        var snap = Snap(hosted: core.levels[path] != nil, peers: core.peers)
        if let parent = core.levels[parentPath]?.tree {
            for carrier in fixture.carriers where parent.contains(blockHash: carrier.cid) {
                snap.weighed.insert(carrier.label)
                let meta = parent.getConsensusBlock(hash: carrier.cid)
                let own = (meta?.workContributions.keys).map { Set($0) } ?? []
                snap.cgr[carrier.label] = grinds(own.subtracting(meta?.attributedRuns ?? []))
            }
        }
        for carrier in fixture.carriers where snap.cgr[carrier.label] == nil { snap.cgr[carrier.label] = [] }
        guard let level = core.levels[path] else { return snap }
        let proofs = level.sync.proofs
        let held = proofs.queued.map { ($0.key, $0.proof) } + proofs.verifying.map { ($0.key, $0.value.proof) }
        for child in fixture.children {
            let cid = child.cid
            var credited: [String] = []
            if level.tree.contains(blockHash: cid) {
                snap.status[child.label] = "tree"
                let meta = level.tree.getConsensusBlock(hash: cid)
                let all = (meta?.workContributions.keys).map { Set($0) } ?? []
                credited = grinds(all.subtracting(meta?.attributedRuns ?? []))
            } else if let pending = level.sync.pending.entries[cid] {
                snap.status[child.label] = "pending"
                credited = grinds(pending.evidence.keys)
            } else if proofs.awaiting[cid] != nil {
                snap.status[child.label] = "awaiting"
            } else {
                snap.status[child.label] = "unknown"
            }
            snap.credited[child.label] = credited
            snap.deriving[child.label] = proofs.deriving[cid] ?? 0
            let mine = held.filter { $0.0.childCID == cid }
            snap.peerQ[child.label] = Set(mine.map { label(of: $0.1) }).sorted()
            snap.peerKeys.formUnion(mine.map(\.0))
            for (key, proof) in mine { snap.peerLabels[key] = label(of: proof) }
        }
        return snap
    }

    // MARK: - Steps

    /// One host step: `event` took the host from `before` to `core`,
    /// emitting `effects`.
    func record(_ event: NodeEvent, before s0: Snap, after core: NodeCore, effects: [NodeEffect]) {
        let s1 = snapshot(core)
        var sub: [[String: Any]] = []
        var issued: [JobKey] = []
        for effect in effects {
            guard case .level(let at, .deriveProof(let job)) = effect, at == path else { continue }
            guard let child = childLabel[job.childCID], let carrier = carrierLabel[job.carrier] else {
                anomalies.append("\(name): derivation of an unmodelled pair \(job.carrier.suffix(8)) -> \(job.childCID.suffix(8))")
                continue
            }
            issued.append(JobKey(carrier: carrier, child: child, grinds: grinds(job.grinds)))
        }

        var main: [String: Any]?
        var checkedKey: ChildProofKey?
        var clears = false
        var gossiped: String?
        if booting {
            // The restore and the boot pass of the step after it.
            booting = false
            sub.append(["kind": "restart"])
            clears = true
            jobs = [:]
        }
        switch event {
        case .level(let at, .derived(let derivation)) where at == path:
            let job = derivation.job
            if let child = childLabel[job.childCID], let carrier = carrierLabel[job.carrier] {
                let key = JobKey(carrier: carrier, child: child, grinds: grinds(job.grinds))
                main = ["kind": "answer", "carrier": carrier, "child": child, "grinds": key.grinds]
                if let count = jobs[key] { jobs[key] = count == 1 ? nil : count - 1 } else {
                    anomalies.append("\(name): answer of a job not in flight")
                }
            }
        case .level(let at, .proofVerified(let job, _)) where at == path && !job.derived:
            if s0.peerKeys.contains(job.key), let child = childLabel[job.childCID] {
                main = ["kind": "check", "child": child, "proof": label(of: job.proof)]
                checkedKey = job.key
            }
        case .level(let at, .submitted(let entry)) where at == path:
            if let cid = try? BlockHeader(node: entry.block).rawCID, let child = childLabel[cid] {
                main = ["kind": "gossip", "child": child, "proof": "none", "from": "self"]
                gossiped = child
            }
        case .received(let peer, let at, .headers(let response)) where at == path && s0.peers.contains(peer) && s0.hosted:
            // One entry per relay: the asked header, with at most one proof.
            for entry in response.entries {
                guard let cid = try? BlockHeader(node: entry.block).rawCID, let child = childLabel[cid] else { continue }
                if entry.proofs.count > 1 { anomalies.append("\(name): a gossip with several proofs") }
                main = ["kind": "gossip", "child": child, "proof": entry.proofs.first.map(label(of:)) ?? "none",
                        "from": peer.key]
                gossiped = child
            }
        case .unhost(let at) where at == path || at == parentPath:
            main = ["kind": "unhost", "x": at == parentPath]
            clears = true
        case .host(let at, _, _, _) where at == path:
            main = ["kind": "rehost"]
        case .host(let at, _, _, _) where at == parentPath:
            main = ["kind": "rehostX"]
        default:
            break
        }
        if var gossip = main, let child = gossiped {
            let changed = s0.status != s1.status || s0.peerQ[child] != s1.peerQ[child] || !issued.isEmpty
            gossip["accepted"] = changed
            let victims = fixture.children.map(\.label).filter {
                $0 != child && s0.status[$0] == "awaiting" && s1.status[$0] == "unknown"
            }
            gossip["victim"] = victims.first ?? "none"
            main = gossip
        }

        // Pending blocks gone (not weighed) were evicted: before the step's
        // action when they were pending before it.
        if !clears {
            for child in fixture.children.map(\.label)
            where s0.status[child] == "pending" && s1.status[child] == "unknown" {
                sub.append(["kind": "evictPending", "child": child])
            }
        }
        // The parent level weighed a carrier, or credited one more grind.
        for carrier in fixture.carriers.map(\.label) {
            let now = Set(s1.cgr[carrier] ?? [])
            if s1.weighed.contains(carrier), !s0.weighed.contains(carrier) {
                sub.append(["kind": "weigh", "carrier": carrier, "grinds": now.sorted()])
            } else if s1.weighed.contains(carrier) {
                for grind in now.subtracting(s0.cgr[carrier] ?? []).sorted() {
                    sub.append(["kind": "grow", "carrier": carrier, "grind": grind])
                }
            }
        }
        if let main { sub.append(main) }
        if !clears {
            // Peer proofs gone without their check answering: a purge when a
            // peer left this step, else each dropped unchecked (block gone or
            // already credited), which the model checks to no effect.
            let gone = s0.peerKeys.subtracting(s1.peerKeys).subtracting(checkedKey.map { [$0] } ?? [])
            let left = effects.contains { if case .disconnect = $0 { return true }; return false }
                || { if case .peerGone = event { return true }; return false }()
            if !gone.isEmpty, left {
                sub.append(["kind": "purge"])
            } else {
                for key in gone.sorted() {
                    guard let child = childLabel[key.childCID] else { continue }
                    sub.append(["kind": "check", "child": child, "proof": s0.peerLabels[key] ?? "bogus"])
                }
            }
            // A block promoted and evicted in one step.
            if gossiped == nil {
                for child in fixture.children.map(\.label)
                where s0.status[child] == "awaiting" && s1.status[child] == "unknown" {
                    sub.append(["kind": "evictPending", "child": child])
                }
            }
        }
        for key in issued { jobs[key, default: 0] += 1 }
        if sub.isEmpty {
            guard s0.model != s1.model || !issued.isEmpty else { return }
            sub.append(["kind": "internal"])
        }
        if !issued.isEmpty {
            let index = sub.lastIndex { ["weigh", "grow", "gossip", "restart", "rehost"].contains($0["kind"] as? String) }
                ?? sub.count - 1
            sub[index]["issued"] = issued.map { ["carrier": $0.carrier, "child": $0.child, "grinds": $0.grinds] }
        }
        sub[sub.count - 1]["after"] = after(s1)
        events += sub
    }

    /// A change made to the code's state from outside any step (a test
    /// reaching into the core): the model takes its state as found.
    func tamper(_ core: NodeCore, _ what: String) {
        events.append(["kind": "tamper", "what": what, "after": after(snapshot(core))])
    }

    private func after(_ snap: Snap) -> [String: Any] {
        [
            "hosted": snap.hosted,
            "status": snap.status,
            "credited": snap.credited,
            "deriving": snap.deriving,
            "peerQ": snap.peerQ,
            "jobs": jobs.sorted { "\($0.key)" < "\($1.key)" }.map {
                ["carrier": $0.key.carrier, "child": $0.key.child, "grinds": $0.key.grinds, "count": $0.value]
            },
        ]
    }

    // MARK: - Output

    func json() throws -> Data {
        let meets = fixture.grinds.filter(\.meets).map(\.label)
        var real: [String: String] = [:]
        for child in fixture.children {
            let committing = Set(fixture.carriers.filter { $0.commits == child.label }.map(\.label))
            let grinds = fixture.grinds.filter { committing.contains($0.carrier) }
            real[child.label] = (grinds.first(where: \.meets) ?? grinds.first)?.label ?? "bogus"
        }
        let object: [String: Any] = [
            "name": name,
            "grow": grow,
            "cap": cap,
            "children": Dictionary(uniqueKeysWithValues: fixture.children.map { ($0.label, $0.parent) }),
            "carriers": Dictionary(uniqueKeysWithValues: fixture.carriers.map { ($0.label, $0.commits) }),
            "grinds": Dictionary(uniqueKeysWithValues: fixture.grinds.map { ($0.label, $0.carrier) }),
            "meets": meets,
            "real": real,
            "init": initial,
            "anomalies": anomalies,
            "events": events,
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
    }

    /// Write every trace opened since the last flush, when `DERIVED_TRACE_DIR`
    /// is set; return them either way.
    @discardableResult
    static func flush() throws -> [GrindTracer] {
        let traces = open
        open = []
        guard let directory = ProcessInfo.processInfo.environment["DERIVED_TRACE_DIR"] else { return traces }
        let url = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for trace in traces {
            try trace.json().write(to: url.appendingPathComponent("trace-\(trace.name).json"))
        }
        return traces
    }
}
