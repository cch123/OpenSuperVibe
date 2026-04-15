import Foundation

/// Write directly to stderr – always visible in terminal, never buffered.
func log(_ message: String) {
    let line = message + "\n"
    FileHandle.standardError.write(Data(line.utf8))
}
