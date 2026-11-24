import Darwin
import Foundation

/// Ghostty starts one child per local PTY. Its controlling terminal identifies the
/// foreground job even when the user launches an agent without Seance integration.
public enum ForegroundAgents {
    private static func children(of parent: pid_t) -> [pid_t] {
        let stride = MemoryLayout<pid_t>.stride
        let needed = proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(parent), nil, 0)
        var children = [pid_t](repeating: 0, count: max(0, Int(needed)) / stride + 16)
        let used = proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(parent), &children, Int32(children.count * stride))
        return children.prefix(max(0, Int(used)) / stride).filter { $0 > 0 }
    }

    public static func snapshot(parent: pid_t) -> [TabID: String] {
        var result: [TabID: String] = [:]
        var foregroundJobs = Set<pid_t>()
        for child in children(of: parent) {
            // /usr/bin/login runs as root. The user's shell below it can report the tty.
            for member in [child] + children(of: child) {
                var info = proc_bsdinfo()
                guard proc_pidinfo(member, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) > 0,
                      info.e_tpgid > 0, let foreground = pid_t(exactly: info.e_tpgid) else { continue }
                foregroundJobs.insert(foreground)
                break
            }
        }
        for foreground in foregroundJobs {
            var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
            guard proc_pidpath(foreground, &buffer, UInt32(buffer.count)) > 0 else { continue }
            let executable = URL(fileURLWithPath: String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self))
            // Claude's native installation can use a version number as its executable filename.
            var name = [UInt8](repeating: 0, count: 64)
            _ = proc_name(foreground, &name, UInt32(name.count))
            let command = String(decoding: name.prefix { $0 != 0 }, as: UTF8.self)
            let candidates = [command, executable.lastPathComponent]
            guard candidates.contains("node") || candidates.contains("claude") || candidates.contains("codex")
                    || executable.path.contains("/claude/versions/") else { continue }
            var mib = [CTL_KERN, KERN_PROCARGS2, foreground]
            var length = 0
            guard sysctl(&mib, 3, nil, &length, nil, 0) == 0, length > 4 else { continue }
            var bytes = [UInt8](repeating: 0, count: length)
            guard sysctl(&mib, 3, &bytes, &length, nil, 0) == 0 else { continue }
            let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
            guard argc > 0 else { continue }
            let data = bytes.prefix(length).dropFirst(4)
            guard let end = data.firstIndex(of: 0) else { continue }
            let fields = data[end...].drop(while: { $0 == 0 }).split(separator: 0, omittingEmptySubsequences: false)
            let argv = fields.prefix(Int(argc)).prefix(2).map { String(decoding: $0, as: UTF8.self) }
            let provider: String
            if candidates.contains("claude") || executable.path.contains("/claude/versions/")
                || (candidates.contains("node") && argv.last?.contains("/@anthropic-ai/claude-code/") == true) {
                provider = "claude"
            } else if candidates.contains("codex")
                || (candidates.contains("node") && argv.last?.contains("/@openai/codex/") == true) {
                provider = "codex"
            } else { continue }
            let prefix = "TAB_ID=".utf8
            guard let variable = fields.dropFirst(Int(argc)).first(where: { $0.starts(with: prefix) }),
                  let uuid = UUID(uuidString: String(decoding: variable.dropFirst(prefix.count), as: UTF8.self)) else { continue }
            result[TabID(uuid)] = provider
        }
        return result
    }
}
