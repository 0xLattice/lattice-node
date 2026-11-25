/// This build's version, as `lattice-node --version` prints it and
/// `GET /status` reports it. Set to the release tag in the commit that is
/// tagged; between releases it names the last release with `+dev`.
public enum LatticeNodeVersion {
    public static let current = "5.2.0"
}
