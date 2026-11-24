import Foundation
import Testing
import SeanceCore

@Test(arguments: ["claude", "codex"])
func foregroundTerminalJobReportsItsOwnTab(provider: String) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appendingPathComponent(provider)
    let source = directory.appendingPathComponent("agent.c")
    // Give the child a controlling terminal even on a headless CI runner.
    try """
        #include <util.h>
        #include <unistd.h>
        #include <sys/wait.h>
        int main(void) {
            int terminal;
            pid_t pid = forkpty(&terminal, NULL, NULL, NULL);
            if (pid < 0) return 1;
            if (pid == 0) { pause(); return 0; }
            char byte;
            read(STDIN_FILENO, &byte, 1);
            close(terminal);
            waitpid(pid, NULL, 0);
            return 0;
        }
        """.write(to: source, atomically: true, encoding: .utf8)
    let compiler = Process()
    compiler.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
    compiler.arguments = [source.path, "-o", executable.path]
    try compiler.run()
    compiler.waitUntilExit()
    try #require(compiler.terminationStatus == 0)
    let tab = TabID()
    let process = Process()
    let input = Pipe()
    process.executableURL = executable
    process.environment = ["TAB_ID": tab.rawValue.uuidString, "TERM": "xterm"]
    process.standardInput = input
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    defer {
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
    }
    for _ in 0..<50 {
        if ForegroundAgents.snapshot(parent: process.processIdentifier)[tab] == provider { return }
        try await Task.sleep(for: .milliseconds(30))
    }
    Issue.record("The foreground \(provider) job was not associated with its tab.")
}
