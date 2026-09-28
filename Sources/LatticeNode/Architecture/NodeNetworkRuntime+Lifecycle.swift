import Foundation
import Ivy
import Lattice
import Tally
import UInt256
import VolumeBroker
import cashew

extension NodeNetworkRuntime {
    /// Installs both delegates and the recovered process's local content source
    /// before either listener becomes visible. The private plane starts first.
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
        await hierarchy.install(
            delegate: self,
            contentSource: ChainProcessIvyContentSource(
                process: process,
                authorizes: { [weak self] peer in
                    await self?.canServeHierarchyContent(to: peer) == true
                }
            )
        )
        do {
            let recoveredParentCandidates =
                try await prepareParentEvidenceInbox(process: process)
            try await Self.startPlanes(
                startHierarchy: { try await self.hierarchy.start() },
                startOverlay: { try await self.overlay.start() },
                stopOverlay: { await self.overlay.stop() },
                stopHierarchy: { await self.hierarchy.stop() }
            )
            isRunning = true
            for candidate in recoveredParentCandidates {
                guard await enqueueInboxParentCandidate(
                    candidate,
                    generation: runtimeGeneration,
                    process: process
                ) else {
                    throw NodeStoreError.corrupt(
                        "durable parent evidence could not be replayed"
                    )
                }
            }
            // A peer may complete its hello while the listeners are starting.
            // Replay the evidence-index pull after ingress becomes runnable so
            // an early response cannot be the only copy we ever request.
            if !configuration.address.isNexus {
                await requestEvidenceIndex(
                    generation: runtimeGeneration,
                    process: process
                )
            }
            scheduleChildProofRecovery(
                generation: runtimeGeneration,
                process: process
            )
            scheduleGenesisProviderAnnounce(
                generation: runtimeGeneration,
                process: process
            )
            scheduleAdoptedGenesisBootstrap(
                generation: runtimeGeneration,
                process: process
            )
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

    private func prepareParentEvidenceInbox(
        process: ChainProcess
    ) async throws -> [CandidateSeed] {
        var candidates: [CandidateSeed] = []
        for item in try await process.store.parentEvidenceInbox() {
            let directHop = await item.package.package.proof.directHop()
            guard let childCID = directHop?.childCID else {
                throw NodeStoreError.corrupt(
                    "durable parent evidence could not be replayed"
                )
            }
            // A parent-carried block is a network block: weighed on its
            // proof, executed when fork choice would step into it.
            candidates.append(CandidateSeed(
                blockCID: childCID,
                package: item.package,
                weighed: true,
                fromParent: true
            ))
        }
        return candidates
    }

    func enqueueInboxParentCandidate(
        _ candidate: CandidateSeed,
        peer: AuthenticatedPeer? = nil,
        generation: UInt64,
        process: ChainProcess
    ) async -> Bool {
        await Timers.poll(every: .milliseconds(10), onCancel: false) {
            guard isCurrentRuntime(generation: generation, process: process),
                  peer.map({
                      hierarchyState.hierarchyRecords[$0.key]?.session?.sessionID == $0.sessionID
                        && hierarchyState.hierarchyRecords[$0.key]?.role == .parent
                  }) ?? true else { return .done(false) }
            return enqueueCandidate(candidate, generation: generation) ? .done(true) : .again
        }
    }

    private func stopNow() async {
        guard isRunning || process != nil else { return }
        _ = callbackEpoch.advance()
        runtimeGeneration = 0
        isRunning = false
        await Self.stopPlanes(
            stopOverlay: { await self.overlay.stop() },
            stopHierarchy: { await self.hierarchy.stop() }
        )
        await clearRuntimeState()
    }

    private func clearRuntimeState() async {
        process = nil
        let removedOverlayRecords = overlayState.overlayRecords.removeAll()
        let removedHierarchyRecords = hierarchyState.hierarchyRecords.removeAll()
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
        for record in removedHierarchyRecords {
            for waiter in record.evidence.waiters {
                waiter.continuation.resume(returning: false)
            }
        }
        for record in removedOverlayRecords { record.helloDeadline?.task.cancel() }
        for record in removedHierarchyRecords { record.helloDeadline?.task.cancel() }
        waitingCandidateRetryTask.cancel()
        for pending in overlayState.pendingTransactionInventories.values {
            pending.timeout.cancel()
        }
        overlayState.pendingTransactionInventories.removeAll()
        sessionLeases.activeTransactionVolumes.removeAll()
        hierarchyState.childProofRecoveryTask.cancel()
        genesisAnnounceTask.cancel()
        hierarchyState.adoptedGenesisTask.cancel()
        // Joined, not just cancelled: `Task.sleep` unwinds on cancellation but
        // an in-flight dial does not, and the search holds the ChainProcess
        // strongly, so an unjoined task can outlive stop() still holding the
        // storage lock. Actors are reentrant, so awaiting here lets the task's
        // own callbacks into this actor run to completion.
        let peerSearch = overlayState.peerSearchTask.take()
        peerSearch?.cancel()
        await peerSearch?.value
        hierarchyState.childProofRecoveryNeedsRefresh = false
        sessionLeases.servingAcceptedLeaves.removeAll()
        sessionLeases.servingAncestorRange.removeAll()
        clearRangeSync()
        candidateWorker.cancel()
        blockFetcher.reset(
            retryWindow: planeConfigurations.overlay.requestTimeout
                * Self.maximumCandidateWaitTicks
        )
        hierarchyState.pendingEvidenceIndexes.removeAll()
        _ = discardPendingParentChainFacts(where: { _ in true })
        for pending in hierarchyState.pendingGenesisVerifications.values {
            pending.continuation.resume(returning: false)
        }
        hierarchyState.pendingGenesisVerifications.removeAll()
        for pending in hierarchyState.pendingGenesisResolves.values {
            pending.continuation.resume(returning: nil)
        }
        hierarchyState.pendingGenesisResolves.removeAll()
        parentStateQueryGuard.removeAll()
        overlayState.rangeSync.reentryTask.cancel()
        sessionLeases.activeEvidenceVolumes.removeAll()
        overlayState.portableEvidenceWorker.cancel()
        sessionLeases.portableEvidenceOrder.removeAll()
        sessionLeases.portableEvidenceWork.removeAll()
        parentEvidence.reset()
        hierarchyState.runReportApplyTail?.cancel()
        hierarchyState.runReportApplyTail = nil
        hierarchyState.parentTipContext = nil
        hierarchyState.parentTipPushTask.cancel()
        hierarchyState.parentTipPushDirty = false
        hierarchyState.carriedEvidenceDirty = false
        hierarchyState.childProofRecoveryIterations = 0
        hierarchyState.childProofRecoveryIterating = false
        hierarchyState.carriedRoutesToRecord = [:]
        hierarchyState.descendantRewards = []
        hierarchyState.descendantMinimumWork = []
        hierarchyState.receivedParentTip = nil
        hierarchyState.releasedCarriedChildCID = nil
        hierarchyState.namedCarriedEvidence = nil
        hierarchyState.namedCarriedEvidenceAppend = nil
        hierarchyState.evidenceRoundStarting = false
        hierarchyState.parentEvidenceInFlight.removeAll()
        hierarchyState.candidateOfferTask.cancel()
        hierarchyState.candidateOfferDirty = false
        hierarchyState.lastOfferedCandidateCID = nil
        // Sequences are per session, and a restart is a new session.
        hierarchyState.nextCandidateOfferSequence = 0
        candidateOfferDeferredByAdmission = false
        hierarchyState.childPeerRotation.removeAll()
        hierarchyState.childPathRotation = 0
        hierarchyState.childProofPathRotation = 0
        hierarchyState.backfilledChildDirectories.removeAll()
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
