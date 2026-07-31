// lattice-rewards: operator tooling for mining reward payouts.
//
// Rewards are ordinary signed transactions validated by consensus (credit-only,
// fee 0, claimed <= the spec reward, signer nonces strictly sequential), so a
// reward key signs each payout exactly once, in nonce order. This tool keeps
// that signing on the operator's machine: it mints key files and pre-signs
// nonce-sequenced reward batches that a miner host consumes one line per block
// without ever holding the key.

import Foundation
import ArgumentParser
import Lattice
import LatticeNode
import cashew

@main
struct LatticeRewards: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lattice-rewards",
        abstract: "Mint reward keys and pre-signed nonce-sequenced reward batches.",
        subcommands: [GenerateKey.self, EmitBatch.self]
    )
}

private struct KeyFile: Codable {
    let address: String
    let privateKey: String
    let publicKey: String
}

struct GenerateKey: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "generate-key",
        abstract: "Create a reward key file (address, privateKey, publicKey) with mode 0600."
    )

    @Option(name: .long, help: "Destination path; refuses to overwrite.")
    var out: String

    func run() throws {
        let url = URL(fileURLWithPath: out)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw ValidationError("refusing to overwrite existing key file: \(out)")
        }
        let pair = CryptoUtils.generateKeyPair()
        let file = KeyFile(
            address: CryptoUtils.createAddress(from: pair.publicKey),
            privateKey: pair.privateKey,
            publicKey: pair.publicKey
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        // Created with its final mode so the private key is never readable
        // through a permissive umask, even briefly.
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: try encoder.encode(file),
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw ValidationError("could not create key file: \(out)")
        }
        print("address:   \(file.address)")
        print("publicKey: \(file.publicKey)")
    }
}

struct EmitBatch: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "emit-batch",
        abstract: "Pre-sign a nonce-sequenced reward batch (one template request per line)."
    )

    @Option(name: .long, help: "Reward key file from generate-key.")
    var key: String

    @Option(name: .long, help: "Number of reward transactions to sign.")
    var count: UInt64

    @Option(name: .long, help: "First signer nonce. 0 for a key that has never transacted; otherwise the key's next expected nonce.")
    var startNonce: UInt64 = 0

    @Option(name: .long, help: "Amount credited per block. Defaults to the Nexus genesis-spec initial reward; must not exceed the reward at the mined height (halving invalidates a too-large batch).")
    var amount: UInt64?

    @Option(name: .long, help: "Absolute chain path the rewards pay on.")
    var chainPath: String = "Nexus"

    @Option(name: .long, help: "Destination batch file (JSON lines); refuses to overwrite.")
    var out: String

    func run() throws {
        let url = URL(fileURLWithPath: out)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw ValidationError("refusing to overwrite existing batch file: \(out)")
        }
        guard count > 0 else {
            throw ValidationError("--count must be positive")
        }
        guard startNonce <= UInt64.max - count else {
            throw ValidationError("nonce range overflows")
        }
        guard let address = ChainAddress(string: chainPath) else {
            throw ValidationError("--chain-path must be absolute and begin with Nexus")
        }
        let keyFile = try JSONDecoder().decode(
            KeyFile.self,
            from: try Data(contentsOf: URL(fileURLWithPath: key))
        )
        let recipient = CryptoUtils.createAddress(from: keyFile.publicKey)
        let credited = amount ?? NexusGenesis.spec.initialReward
        guard credited > 0, credited <= UInt64(Int64.max) else {
            throw ValidationError("--amount must fit a positive Int64")
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var lines: [String] = []
        lines.reserveCapacity(Int(count))
        for nonce in startNonce..<(startNonce + count) {
            let body = TransactionBody(
                accountActions: [AccountAction(
                    owner: recipient,
                    delta: Int64(credited)
                )],
                actions: [],
                depositActions: [],
                genesisActions: [],
                receiptActions: [],
                withdrawalActions: [],
                signers: [recipient],
                fee: 0,
                nonce: nonce,
                chainPath: address.components
            )
            let header = try HeaderImpl(node: body)
            guard let signature = TransactionSigning.sign(
                bodyHeader: header,
                privateKeyHex: keyFile.privateKey
            ) else {
                throw ValidationError("signing failed; is the key file valid?")
            }
            let request = MiningTemplateRequest(rewards: [MiningReward(
                chainPath: address.components,
                transaction: Transaction(
                    signatures: [keyFile.publicKey: signature],
                    body: header
                )
            )])
            lines.append(String(
                decoding: try encoder.encode(request),
                as: UTF8.self
            ))
        }
        try lines.joined(separator: "\n").appending("\n")
            .data(using: .utf8)!
            .write(to: url)
        print("recipient: \(recipient)")
        print("batch:     \(count) rewards, nonces \(startNonce)..<\(startNonce + count), \(credited) per block -> \(out)")
    }
}
