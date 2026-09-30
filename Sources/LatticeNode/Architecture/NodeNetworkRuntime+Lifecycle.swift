import Foundation
import Ivy
import Lattice
import Tally
import UInt256
import VolumeBroker
import cashew

extension NodeNetworkRuntime {
    /// Installs the delegate and the recovered process's local content source
    /// before the listener becomes visible.
    public func start(
        process: ChainProcess,
        chain: any ChainInterface
    ) async throws {
        try await enqueueStart(process: process, chain: chain).value
    }

    func enqueueStart(
        process: ChainProcess,
        chain: any ChainInterface
    ) -> Task<Void, any Error> {
        let previous = lifecycleTail
        let operation = Task { [weak self] in
            await previous?.value
            guard let self else { throw CancellationError() }
            try await self.startNow(process: process, chain: chain)
        }
        lifecycleTail = Task { _ = try? await operation.value }
        return operation
    }

    private func startNow(
        process: ChainProcess,
        chain: any ChainInterface
    ) async throws {
        guard !isRunning else { throw NodeNetworkRuntimeError.alreadyRunning }
        var recoveredDescendants: [String: Set<DurableDescendant>] = [:]
        for requirement in await process.unresolvedSameChainPredecessors() {
            let roots = try await process.recoveredIncomingCarrierRootCIDs(
                for: requirement.descendantCID
            )
            let descendants = roots.isEmpty
                ? [DurableDescendant(
                    blockCID: requirement.descendantCID,
                    rootCID: nil
                )]
                : roots.map {
                    DurableDescendant(
                        blockCID: requirement.descendantCID,
                        rootCID: $0
                    )
                }
            recoveredDescendants[
                requirement.predecessorCID,
                default: []
            ].formUnion(descendants)
        }
        runtimeGeneration = callbackEpoch.advance()
        self.process = process
        self.chain = chain
        blockFetcher.reset(
            retryWindow: planeConfigurations.overlay.requestTimeout
                * Self.maximumCandidateWaitTicks,
            durableDescendants: recoveredDescendants
        )
        await overlay.install(
            delegate: self,
            contentSource: ChainProcessIvyContentSource(process: process)
        )
        do {
            do {
                try await overlay.start()
            } catch {
                await overlay.stop()
                throw error
            }
            isRunning = true
            // Recovered seeds (the missing-predecessor frontier the reset
            // readied) run now: on a quiet network no later enqueue would
            // start the worker for them. The worker is fenced to this
            // generation by `startCandidateWorker`.
            serviceBlockFetcher()
            scheduleGenesisProviderAnnounce(
                generation: runtimeGeneration,
                process: process
            )
            triggerGenesisActivation()
            schedulePeerSearch(
                generation: runtimeGeneration,
                process: process
            )
        } catch {
            isRunning = false
            _ = callbackEpoch.advance()
            runtimeGeneration = 0
            await clearRuntimeState()
            throw error
        }
    }

    public func stop() async {
        let previous = lifecycleTail
        let operation = Task { [weak self] in
            await previous?.value
            await self?.stopNow()
        }
        lifecycleTail = operation
        await operation.value
    }

    private func stopNow() async {
        guard isRunning || process != nil else { return }
        _ = callbackEpoch.advance()
        runtimeGeneration = 0
        isRunning = false
        await overlay.stop()
        await clearRuntimeState()
    }

    private func clearRuntimeState() async {
        process = nil
        let removedOverlayRecords = overlayState.overlayRecords.removeAll()
        sessionLeases.servingReadEndpoints.removeAll()
        overlayState.readURLDiscovery.cache.removeAll()
        for inFlight in overlayState.readURLDiscovery.tasks.values {
            inFlight.task.cancel()
        }
        overlayState.readURLDiscovery.tasks.removeAll()
        let readEndpointWaiters = overlayState.readURLDiscovery.pendingReadEndpoints.values
        overlayState.readURLDiscovery.pendingReadEndpoints.removeAll()
        for pending in readEndpointWaiters {
            pending.timeout.cancel()
            pending.continuation.resume(returning: [])
        }
        for record in removedOverlayRecords { record.helloDeadline?.task.cancel() }
        waitingCandidateRetryTask.cancel()
        for pending in overlayState.pendingTransactionInventories.values {
            pending.timeout.cancel()
        }
        overlayState.pendingTransactionInventories.removeAll()
        sessionLeases.activeTransactionVolumes.removeAll()
        genesisAnnounceTask.cancel()
        genesisActivationRequested = false
        // Joined, not just cancelled: `Task.sleep` unwinds on cancellation but
        // an in-flight dial does not, and the search holds the ChainProcess
        // strongly, so an unjoined task can outlive stop() still holding the
        // storage lock. Actors are reentrant, so awaiting here lets the task's
        // own callbacks into this actor run to completion.
        let peerSearch = overlayState.peerSearchTask.take()
        peerSearch?.cancel()
        await peerSearch?.value
        // Joined for the same reason: a genesis activation attempt holds
        // the ChainProcess and could persist the genesis after stop.
        let genesisActivation = genesisActivationTask.take()
        let genesisRetry = genesisRetryTask.take()
        genesisActivation?.cancel()
        genesisRetry?.cancel()
        await genesisActivation?.value
        await genesisRetry?.value
        sessionLeases.servingAcceptedLeaves.removeAll()
        sessionLeases.servingAncestorRange.removeAll()
        clearRangeSync()
        candidateWorker.cancel()
        blockFetcher.reset(
            retryWindow: planeConfigurations.overlay.requestTimeout
                * Self.maximumCandidateWaitTicks
        )
        parentStateQueryGuard.removeAll()
        overlayState.rangeSync.reentryTask.cancel()
        overlayState.childEvidenceSync.cancel()
        overlayState.childEvidenceAnnounce.cancel()
        overlayState.childProofLookupCursor = nil
        overlayState.lastChildEvidencePeer = nil
        overlayState.childEvidenceAnnounceDirty = false
        overlayState.announcedChildEvidenceRoot = nil
        chain = nil
    }
}

extension Ivy {
    fileprivate func install(
        delegate: IvyDelegate,
        contentSource: (any IvyContentSource)?
    ) {
        self.delegate = delegate
        setContentSource(contentSource)
    }
}
