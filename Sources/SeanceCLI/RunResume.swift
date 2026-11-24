import Darwin
import Foundation
import SeanceIPC

/// Entered as a normal foreground shell command, with the user's initialized PATH.
func runResume() throws {
    let env = ProcessInfo.processInfo.environment
    guard let path = env["SEANCE_SOCKET_PATH"], let tab = env["TAB_ID"].flatMap(UUID.init(uuidString:)) else {
        throw IPCError.message("Missing Seance tab environment")
    }
    let fd = try LocalSocket.open(path: path, listening: false)
    defer { Darwin.close(fd) }
    try writeLine(Data(LocalSocket.resumeHeader.utf8), to: fd)
    try writeLine(Data(tab.uuidString.utf8), to: fd)
    var reader = LineReader(fd)
    guard let response = try reader.next(), !response.isEmpty else {
        throw IPCError.message("No pending resume for this tab")
    }
    let arguments = try JSONDecoder().decode([String].self, from: response)
    guard let executable = arguments.first else { throw IPCError.message("Missing agent command") }
    // Still consume the reservation and report the error if the directory disappeared
    // while the shell was starting. Never launch the agent in a substitute directory.
    if let directory = env["SEANCE_RESUME_DIRECTORY"], chdir(directory) != 0 {
        throw IPCError.message("Could not enter " + directory + ": " + String(cString: strerror(errno)))
    }
    var argv = arguments.map { strdup($0) }
    defer { for pointer in argv { free(pointer) } }
    guard !argv.contains(where: { $0 == nil }) else { throw POSIXError(.ENOMEM) }
    argv.append(nil)
    execvp(executable, &argv)
    throw IPCError.message("Could not start " + executable + ": " + String(cString: strerror(errno)))
}
