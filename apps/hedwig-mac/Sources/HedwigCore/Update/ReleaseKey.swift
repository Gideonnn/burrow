/// The public half of the Hedwig release key (Ed25519, base64). Builds are only
/// installed when their signature checks out against it; empty turns updates off.
/// Written by scripts/release-key.sh; the private half lives in SOPS.
public enum ReleaseKey {
    public static let publicKey = "O7Btrao2XkgrO5U6QfwJ65+j9doUN9HMlp0zrGo7rv8="
}
