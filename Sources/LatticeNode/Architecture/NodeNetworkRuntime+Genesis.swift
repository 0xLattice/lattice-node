import Foundation
import Lattice

extension NodeNetworkRuntime {
    /// Verify-not-trust gate for a self-contained child genesis: whether the
    /// co-hosted parent level still anchors exactly this genesis CID for
    /// this chain's directory (a parent reorg during the fetch may have
    /// moved it) and recorded it bound to the empty parent state. Local
    /// reads.
    nonisolated func parentRecordedChildGenesis(
        _ childGenesisCID: String
    ) async -> Bool {
        let directory = configuration.address.directory
        guard let parentLevel,
              await parentLevel.anchoredGenesisCID(directory: directory)
                == childGenesisCID
        else { return false }
        return await parentLevel.recordedGenesisLink(
            directory: directory,
            childGenesisCID: childGenesisCID
        ) != nil
    }

    /// One trigger of `activateGenesisIfRecorded`: this level's start, a
    /// parent tip change, a child overlay hello, or the slow
    /// retry after a failed fetch or confirm. One
    /// attempt runs at a time; a trigger that lands during an attempt runs
    /// one more after it, so no trigger is lost.
    func triggerGenesisActivation() {
        guard isRunning, parentLevel != nil, let process else { return }
        let generation = runtimeGeneration
        genesisActivationRequested = true
        genesisActivationTask.start { token in
            Task { [weak self] in
                await self?.runGenesisActivation(
                    token: token, generation: generation, process: process
                )
            }
        }
    }

    private func runGenesisActivation(
        token: LifetimeToken,
        generation: UInt64,
        process: ChainProcess
    ) async {
        defer { genesisActivationTask.clear(token) }
        while genesisActivationRequested, !Task.isCancelled,
              isCurrentRuntime(generation: generation, process: process) {
            genesisActivationRequested = false
            await activateGenesisIfRecorded(
                generation: generation, process: process
            )
        }
    }

    /// A same-chain overlay peer completed its hello. A child still
    /// awaiting its genesis may fetch it from this peer, seeded or not (a
    /// seed that is not the anchored genesis falls back to the fetch). On an
    /// active chain the attempt returns at once.
    func overlayPeerMayProvideGenesis() {
        triggerGenesisActivation()
    }

    /// Where a deployer seeds this node with its child genesis. A seeded
    /// node rebuilds its genesis; an adopting node fetches it.
    private nonisolated var genesisSeedURL: URL {
        configuration.storagePath.appendingPathComponent("child-genesis.json")
    }

    /// A hosted child with no genesis activates the one its parent anchored:
    /// read the CID the parent committed for this directory, rebuild the
    /// genesis from the deployer's seed when this node holds one, and fetch
    /// it through the child overlay when it holds none or the seed is
    /// unreadable or rebuilds to another CID (the fetch is bound to the
    /// anchored CID). Admit it once the parent confirms it. Nothing here
    /// waits: no anchor yet leaves the chain awaiting the next trigger, and
    /// an anchored genesis that could not be fetched or confirmed also arms
    /// the one slow retry, for a parent too quiet to trigger again.
    private func activateGenesisIfRecorded(
        generation: UInt64,
        process: ChainProcess
    ) async {
        let directory = configuration.address.directory
        guard let parentLevel, await process.awaitsGenesis,
              let genesisCID = await parentLevel.anchoredGenesisCID(
                  directory: directory
              ),
              !Task.isCancelled,
              isCurrentRuntime(generation: generation, process: process)
        else { return }
        let confirm: @Sendable (String) async -> Bool = { [weak self] cid in
            await self?.parentRecordedChildGenesis(cid) ?? false
        }
        var outcome = ChildGenesisActivation.notAnchoredGenesis
        if FileManager.default.fileExists(atPath: genesisSeedURL.path) {
            if let seed = try? JSONDecoder().decode(
                ChildGenesisSeed.self, from: Data(contentsOf: genesisSeedURL)
            ) {
                outcome = (try? await process.activateChildGenesis(
                    anchoredCID: genesisCID,
                    from: .seed(seed),
                    confirmParentRecordedGenesis: confirm
                )) ?? .unconfirmed
            } else {
                syncTrace(
                    "child-genesis seed unreadable directory=\(directory);"
                        + " fetching the anchored genesis"
                )
            }
        }
        if outcome == .notAnchoredGenesis, !Task.isCancelled {
            outcome = (try? await remoteContentSource.withRoot(
                genesisCID
            ) { session in
                try await process.activateChildGenesis(
                    anchoredCID: genesisCID,
                    from: .fetch(session),
                    confirmParentRecordedGenesis: confirm
                )
            }) ?? .notAnchoredGenesis
        }
        syncTrace(
            "child-genesis \(outcome) directory=\(directory) cid=\(genesisCID)"
        )
        guard isCurrentRuntime(generation: generation, process: process)
        else { return }
        switch outcome {
        case .activated:
            genesisRetryTask.cancel()
        case .notAnchoredGenesis, .unconfirmed:
            armGenesisRetry(generation: generation)
            return
        case .notAwaiting:
            return
        }
        // The genesis bootstrapped to active OUT OF BAND (not via candidate
        // admission), so it never fired its one-shot connect signal. Wake the
        // successors that parked behind it while awaitingGenesis, or the chain
        // above the genesis stays orphaned at height 0.
        await predecessorConnectedOutOfBand(genesisCID)
        await chain?.genesisActivatedOutOfBand()
    }

    /// The one slow retry of a genesis that was anchored but could not be
    /// fetched or confirmed (say an adopting node asked before any provider
    /// held it): a quiet parent may not move its tip again. At most one
    /// timer is armed; stop cancels and joins it.
    private func armGenesisRetry(generation: UInt64) {
        let delay = Self.genesisRetryNanoseconds
        genesisRetryTask.start { token in
            Task { [weak self] in
                guard await Timers.sleep(nanoseconds: delay) else { return }
                await self?.genesisRetryFired(token: token, generation: generation)
            }
        }
    }

    private func genesisRetryFired(token: LifetimeToken, generation: UInt64) {
        guard genesisRetryTask.clear(token),
              isCurrentGeneration(generation)
        else { return }
        triggerGenesisActivation()
    }
}
