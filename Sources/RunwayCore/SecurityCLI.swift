import Foundation
import Security

/// Keychain access through Apple's `/usr/bin/security` tool rather than the
/// Security framework from this process.
///
/// Keychain grants ("Always Allow") are tied to the code signature of whoever
/// asks. This app is ad-hoc signed, so every new version has a new signature
/// and macOS would ask for the login password again after each update.
/// `security` is Apple-signed and never changes, so a grant to it lasts. Items
/// *created* by `security` trust it from the start, and never prompt at all.
enum SecurityCLI {
    private static let tool = URL(fileURLWithPath: "/usr/bin/security")

    /// The item's secret, or the failure as an OSStatus.
    static func read(service: String, account: String) -> (Data?, OSStatus) {
        let (status, output) = run(["find-generic-password", "-s", service, "-a", account, "-w"])
        switch status {
        case 0:
            // `-w` appends a newline.
            var data = output
            while data.last == 0x0A { data.removeLast() }
            return data.isEmpty ? (nil, errSecItemNotFound) : (data, errSecSuccess)
        case 44: return (nil, errSecItemNotFound)
        default: return (nil, errSecAuthFailed)  // denied or cancelled at the prompt
        }
    }

    /// Creates or replaces the item.
    ///
    /// The secret goes in on stdin via `security -i`, never as an argument, so it
    /// can't be seen in `ps` by other processes. Values containing quotes or
    /// newlines are rejected rather than escaped.
    @discardableResult
    static func write(service: String, account: String, value: String) -> Bool {
        guard !value.contains(where: { $0 == "\"" || $0 == "\\" || $0.isNewline }) else { return false }
        delete(service: service, account: account)
        let command = "add-generic-password -s \"\(service)\" -a \"\(account)\" -w \"\(value)\"\n"
        return run(["-i"], stdin: Data(command.utf8)).status == 0
    }

    static func delete(service: String, account: String) {
        _ = run(["delete-generic-password", "-s", service, "-a", account])
    }

    private static func run(_ args: [String], stdin: Data? = nil) -> (status: Int32, output: Data) {
        let process = Process()
        process.executableURL = tool
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        let input = Pipe()
        process.standardInput = stdin == nil ? FileHandle.nullDevice : input
        do { try process.run() } catch { return (-1, Data()) }
        if let stdin {
            input.fileHandleForWriting.write(stdin)
            try? input.fileHandleForWriting.close()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }
}
