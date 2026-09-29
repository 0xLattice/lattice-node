// Wallet keys: a key file holds an address, its private key, and its public
// key. `tx` and `child add` sign with one; its address is what `mine`
// names as a chain's recipient. Moved here from the retired lattice-rewards.

import Foundation
import ArgumentParser
import Lattice

struct Key: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Wallet key files.",
        subcommands: [Generate.self]
    )

    struct Generate: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Create a key file (address, privateKey, publicKey) with mode 0600."
        )

        @Option(name: .long, help: "Destination path; refuses to overwrite.")
        var out: String

        private struct KeyFile: Encodable {
            let address: String
            let privateKey: String
            let publicKey: String
        }

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
}
