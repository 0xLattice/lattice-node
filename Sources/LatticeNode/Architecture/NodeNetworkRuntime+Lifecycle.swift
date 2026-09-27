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
                guard await enqueueRetainedParentCandidate(
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
                weighed: true
            ))
        }
        return candidates
    }

    func enqueueRetainedParentCandidate(
        _ candidate: CandidateSeed,
        peer: AuthenticatedPeer? = nil,
        generation: UInt64,
        process: ChainProcess
    ) async -> Bool {
        await Timers.poll(every: .milliseconds(10), onCancel: false) {
            guard isCurrentRuntime(generation: generation, process: process),
                  peer.map({
                      hierarchyRecords[$0.key]?.session?.sessionID == $0.sessionID
                        && hierarchyRecords[$0.key]?.role == .parent
                  }) ?? true else { return .done(false) }
            return enqueueCandidate(candidate) ? .done(true) : .again
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
        let removedOverlayRecords = overlayRecords.removeAll()
        let removedHierarchyRecords = hierarchyRecords.removeAll()
        sessionLeases.servingReadEndpoints.removeAll()
        readURLDiscovery.cache.removeAll()
        for inFlight in readURLDiscovery.tasks.values {
            inFlight.task.cancel()
        }
        readURLDiscovery.tasks.removeAll()
        let readEndpointWaiters = readURLDiscovery.pendingReadEndpoints.values
        readURLDiscovery.pendingReadEndpoints.removeAll()
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
        waitingCandidateRetryTask?.cancel()
        waitingCandidateRetryTask = nil
        waitingCandidateRetryGeneration = nil
        for pending in pendingTransactionInventories.values {
            pending.timeout.cancel()
        }
        pendingTransactionInventories.removeAll()
        sessionLeases.activeTransactionVolumes.removeAll()
        childProofRecoveryTask?.cancel()
        childProofRecoveryTask = nil
        genesisAnnounceTask?.cancel()
        genesisAnnounceTask = nil
        adoptedGenesisTask?.cancel()
        adoptedGenesisTask = nil
        // Joined, not just cancelled: `Task.sleep` unwinds on cancellation but
        // an in-flight dial does not, and the search holds the ChainProcess
        // strongly, so an unjoined task can outlive stop() still holding the
        // storage lock. Actors are reentrant, so awaiting here lets the task's
        // own callbacks into this actor run to completion.
        let peerSearch = peerSearchTask
        peerSearchTask = nil
        peerSearch?.cancel()
        await peerSearch?.value
        childProofRecoveryGeneration = nil
        childProofRecoveryNeedsRefresh = false
        sessionLeases.servingAcceptedLeaves.removeAll()
        sessionLeases.servingAncestorRange.removeAll()
        clearRangeSync()
        candidateWorker?.cancel()
        candidateWorker = nil
        candidateWorkerGeneration = nil
        blockFetcher.reset(
            retryWindow: planeConfigurations.overlay.requestTimeout
                * Self.maximumCandidateWaitTicks
        )
        pendingEvidenceIndexes.removeAll()
        discardPendingParentChainFacts(where: { _ in true }, requeue: false)
        for pending in pendingGenesisVerifications.values {
            pending.continuation.resume(returning: false)
        }
        pendingGenesisVerifications.removeAll()
        for pending in pendingGenesisResolves.values {
            pending.continuation.resume(returning: nil)
        }
        pendingGenesisResolves.removeAll()
        parentStateQueryGuard.removeAll()
        rangeSync.reentryTask?.cancel()
        rangeSync.reentryTask = nil
        sessionLeases.activeEvidenceVolumes.removeAll()
        portableEvidenceWorker?.cancel()
        portableEvidenceWorker = nil
        sessionLeases.portableEvidenceOrder.removeAll()
        sessionLeases.portableEvidenceWork.removeAll()
        parentEvidence.reset()
        // After the peer-search join, as before: a pushed sequence (recorded
        // after its send, without a session check) or anything else these
        // fields took while the join was awaited is dropped too.
        for key in Array(hierarchyRecords.keys) {
            hierarchyRecords.update(key) {
                $0.offer = nil
                $0.pushedSequence = nil
                $0.refusedHint = nil
            }
        }
        runReportApplyTail?.cancel()
        runReportApplyTail = nil
        parentTipContext = nil
        parentTipPushTask?.cancel()
        parentTipPushTask = nil
        parentTipPushDirty = false
        descendantRewards = []
        descendantMinimumWork = []
        receivedParentTip = nil
        releasedCarriedChildCID = nil
        requestedCarriedChildCID = nil
        candidateOfferTask?.cancel()
        candidateOfferTask = nil
        candidateOfferDirty = false
        lastOfferedCandidateCID = nil
        // Sequences are per session, and a restart is a new session.
        nextCandidateOfferSequence = 0
        candidateOfferDeferredByAdmission = false
        childPeerRotation.removeAll()
        childPathRotation = 0
        childProofPathRotation = 0
        backfilledChildDirectories.removeAll()
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
