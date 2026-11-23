/// Record of the Bitcoin anchor for the Nexus genesis.
///
/// The genesis CID (`NexusGenesis.expectedBlockHash`) is the `OP_RETURN` payload of
/// the Bitcoin transaction below, so the pinned genesis can be checked against
/// Bitcoin proof-of-work instead of being taken as a bare trusted constant.
///
/// This type only RECORDS the anchor so it is discoverable from code. It is not a
/// security control: whoever ships a competing genesis also controls this file. The
/// real check is made outside the repository, against the live Bitcoin chain. See
/// `docs/design/bitcoin-anchored-genesis.md`.
public enum BitcoinGenesisAnchor {
    /// Bitcoin block height the committing transaction was mined in.
    public static let blockHeight: UInt32 = 970_053
    /// Bitcoin block hash (big-endian display).
    public static let blockHash =
        "000000000000000000005260ddc48a2e8421fff7cb681ca999db1b65d119fdfc"
    /// Committing transaction id (big-endian display).
    public static let txid =
        "7501f77602b581f605e6bc61c310b540e17324d3cc292c18985d8a3464d23236"
    /// The transaction's `OP_RETURN` payload: the raw bytes of
    /// `NexusGenesis.expectedBlockHash`.
    public static let opReturnHex =
        "01711220c699b84ca0a17608a09786bca7a4c76c7a602bc82c73f1fb78afe78dc699e6b8"
}
