import Foundation

// Stores a claude.ai session key in the keychain, same slot the app's popover
// writes to. Useful for setup from a terminal, and for verification.
//
// The key is read from stdin, not an argument or environment variable: both of
// those would leave a full-account credential in shell history and expose it to
// any other process of the same user via `ps -E`.
//
//   swiftc Sources/RunwayCore/{SessionKeyStore,UsageParser,UsageModel}.swift \
//          tools/setkey/main.swift -o /tmp/setkey && pbpaste | /tmp/setkey

guard let line = readLine(strippingNewline: true), !line.isEmpty else {
    FileHandle.standardError.write(Data("pipe the session key in on stdin\n".utf8))
    exit(2)
}
let raw = line

guard SessionKeyStore.looksValid(raw) else {
    FileHandle.standardError.write(Data("that doesn't look like a session key (expected sk-ant-sid…)\n".utf8))
    exit(1)
}

if SessionKeyStore.save(raw) {
    SessionKeyStore.organizationID = nil   // re-derive; the key may be a different account
    print("stored (\(SessionKeyStore.normalize(raw).count) chars)")
} else {
    FileHandle.standardError.write(Data("keychain write failed\n".utf8))
    exit(1)
}
