//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Darwin
import Foundation

/// Runs `zip -e` and `unzip` with the password typed on a pseudo-terminal of
/// their own.
///
/// The only way to give /usr/bin/zip or /usr/bin/unzip a password without
/// their terminal is `-P`, an argument that every process of the machine
/// reads (`ps`). Without it, both read the password from /dev/tty, which
/// needs a controlling terminal; `posix_spawn` cannot give one (it opens the
/// file actions before the new session), so the tool is started by
/// `forkpty`, whose child only changes folder, closes the inherited
/// descriptors and runs the tool.
///
/// Both print their prompt, then turn echo off with `TCSAFLUSH`, which drops
/// whatever was typed before: each answer waits for the prompt and for echo
/// to be off on the terminal. Control characters of the password are sent
/// as literal characters (preceded by VLNEXT) so that the line discipline
/// does not act on them. Both read at most 80 characters from the terminal.
enum ZipPasswordTerminal {

    /// The prompts zip prints: "Enter password: " and "Verify password: ".
    private static let prompt = Array("password:".utf8)

    /// How long an answer waits for echo to go off after its prompt before it
    /// is typed anyway.
    private static let echoWait: Duration = .seconds(2)

    /// Runs `tool` with `arguments`, which ask for encryption (-e), in
    /// `directory`; types `password` at both prompts. zip's exit status, or
    /// 128 + the signal that ended it. A third prompt means zip refused the
    /// answer (too long): it is stopped and the run fails.
    static func run(tool: String, arguments: [String], directory: String?, password: String) throws -> Int32 {
        let terminal = try Terminal(tool: tool, arguments: arguments, directory: directory)
        let answer = typed(password)
        var output: [UInt8] = []
        var answered = 0
        var promptSeen: ContinuousClock.Instant?
        while true {
            output += terminal.read()
            let prompts = occurrences(of: prompt, in: output)
            if prompts > 2 {
                terminal.signal(SIGKILL)
            } else if answered < prompts {
                let now = ContinuousClock.now
                let since = promptSeen ?? now
                promptSeen = since
                if !terminal.echoes || now - since > echoWait {
                    terminal.type(answer)
                    answered += 1
                    promptSeen = nil
                }
            }
            if let status = try terminal.exitStatus() {
                return occurrences(of: prompt, in: output) > 2 ? 1 : status
            }
        }
    }

    // MARK: unzip

    /// unzip's prompts: "[<archive>] <entry> password: " (or "Enter password: ")
    /// for an entry, and "password incorrect--reenter: " when the answer did
    /// not open it. Each is the last thing unzip writes before it reads.
    private static let entryPrompt = Array("password: ".utf8)
    private static let retryPrompt = Array("reenter: ".utf8)
    /// What unzip prints before asking again for an answer over 80 characters.
    private static let tooLong = Array("line too long".utf8)

    /// What unzip ends with when no entry opened with the password, the status
    /// of a run refused here.
    static let badPassword: Int32 = 82

    /// Runs `tool` (unzip) with `arguments`, which carry no -P, in `directory`;
    /// types `password` when an entry asks for one. unzip's exit status, or
    /// 128 + the signal that ended it. `continuing` is called on the calling
    /// thread about every 20 ms while unzip runs; false ends unzip (SIGTERM).
    ///
    /// An answer that does not open its entry is followed by unzip's
    /// "reenter" prompt; an empty line answers it, which tells unzip to ask
    /// nothing more and skip the encrypted entries left, as -P did with a
    /// wrong password: plain entries still come out, with the statuses -P
    /// gave (1 when some entries came out, 82 when none did). In an archive
    /// whose entries have different passwords, the entries after the first
    /// one the password does not open are skipped, also those it would open.
    /// A password unzip refuses as too long, or a third entry prompt, ends
    /// unzip with 82.
    static func extract(tool: String, arguments: [String], directory: String?, password: String,
                        continuing: () -> Bool) throws -> Int32 {
        let terminal = try Terminal(tool: tool, arguments: arguments, directory: directory)
        let answer = typed(password)
        // The output since the last answer: the prompt to answer is its end.
        var pending: [UInt8] = []
        var entryAnswers = 0
        var retryAnswers = 0
        var promptSeen: ContinuousClock.Instant?
        var stopped = false
        var refused = false
        while true {
            pending += terminal.read()
            if pending.count > 4096 { pending.removeFirst(pending.count - 4096) }
            if !stopped && !continuing() {
                terminal.signal(SIGTERM)
                stopped = true
            }
            let retry = pending.ends(with: retryPrompt)
            if !stopped && (retry || pending.ends(with: entryPrompt)) {
                // An entry asks at most twice (the first entry, and a later one
                // the password does not open), and unzip asks again only once,
                // as the empty answer stops it asking.
                if occurrences(of: tooLong, in: pending) > 0 || (retry ? retryAnswers : entryAnswers) >= (retry ? 1 : 2) {
                    terminal.signal(SIGKILL)
                    stopped = true
                    refused = true
                } else {
                    let now = ContinuousClock.now
                    let since = promptSeen ?? now
                    promptSeen = since
                    if !terminal.echoes || now - since > echoWait {
                        terminal.type(retry ? [0x0a] : answer)
                        if retry { retryAnswers += 1 } else { entryAnswers += 1 }
                        pending.removeAll()
                        promptSeen = nil
                    }
                }
            }
            if let status = try terminal.exitStatus() {
                return refused ? badPassword : status
            }
        }
    }

    // MARK: Terminal

    /// The password and a newline, each control character after VLNEXT. The
    /// bytes are those `Process` gave zip for -P, the file-system
    /// representation (decomposed UTF-8): a password with accents keeps
    /// opening the archives it made before.
    static func typed(_ password: String) -> [UInt8] {
        var representation = [CChar](repeating: 0, count: CFStringGetMaximumSizeOfFileSystemRepresentation(password as CFString))
        let source = CFStringGetFileSystemRepresentation(password as CFString, &representation, representation.count)
            ? representation.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) } : Array(password.utf8)
        var bytes: [UInt8] = []
        for byte in source {
            if byte < 0x20 || byte == 0x7f { bytes.append(0x16) }
            bytes.append(byte)
        }
        return bytes + [0x0a]
    }

    /// A tool started by `forkpty` and the master side of its terminal, closed
    /// with this object.
    private final class Terminal {
        private let tool: String
        private let pid: pid_t
        private let master: Int32
        private var buffer = [UInt8](repeating: 0, count: 4096)

        init(tool: String, arguments: [String], directory: String?) throws {
            // Everything the child needs is made before the fork: after it, the
            // child may only make system calls.
            let path = strdup(tool)
            var argv: [UnsafeMutablePointer<CChar>?] = ([tool] + arguments).map { strdup($0) } + [nil]
            let folder: UnsafeMutablePointer<CChar>? = directory.flatMap { strdup($0) }
            defer {
                free(path)
                argv.forEach { free($0) }
                free(folder)
            }
            let descriptorLimit = min(getdtablesize(), 65_536)

            var master: Int32 = -1
            let pid = argv.withUnsafeMutableBufferPointer { argv -> pid_t in
                let pid = forkpty(&master, nil, nil, nil)
                if pid == 0 {
                    // As Process does for its tools: no signal blocked or
                    // ignored because the calling thread had it so, which
                    // would keep SIGTERM from ending the tool.
                    var unblocked: sigset_t = 0
                    sigprocmask(SIG_SETMASK, &unblocked, nil)
                    var number: Int32 = 1
                    while number < NSIG { Darwin.signal(number, SIG_DFL); number += 1 }
                    if let folder, chdir(folder) != 0 { _exit(126) }
                    var descriptor: Int32 = 3
                    while descriptor < descriptorLimit { close(descriptor); descriptor += 1 }
                    execv(path, argv.baseAddress)
                    _exit(127)
                }
                return pid
            }
            guard pid > 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: tool])
            }
            _ = fcntl(master, F_SETFD, FD_CLOEXEC)
            self.tool = tool
            self.pid = pid
            self.master = master
        }

        deinit {
            close(master)
        }

        /// What the tool wrote within the next 20 ms, if anything.
        func read() -> [UInt8] {
            var request = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            guard poll(&request, 1, 20) > 0 else { return [] }
            let count = Darwin.read(master, &buffer, buffer.count)
            return count > 0 ? Array(buffer[0..<count]) : []
        }

        func type(_ bytes: [UInt8]) {
            bytes.withUnsafeBufferPointer { bytes in
                var offset = 0
                while offset < bytes.count {
                    let written = write(master, bytes.baseAddress! + offset, bytes.count - offset)
                    if written <= 0 { break }
                    offset += written
                }
            }
        }

        var echoes: Bool {
            var attributes = termios()
            guard tcgetattr(master, &attributes) == 0 else { return false }
            return attributes.c_lflag & tcflag_t(ECHO) != 0
        }

        func signal(_ signal: Int32) {
            kill(pid, signal)
        }

        /// The exit status once the tool ended, or 128 + the signal that ended
        /// it; nil while it runs.
        func exitStatus() throws -> Int32? {
            var status: Int32 = 0
            let waited = waitpid(pid, &status, WNOHANG)
            if waited < 0 && errno != EINTR {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: tool])
            }
            guard waited == pid else { return nil }
            let terminatingSignal = status & 0x7f
            return terminatingSignal == 0 ? (status >> 8) & 0xff : 128 + terminatingSignal
        }
    }

    private static func occurrences(of needle: [UInt8], in haystack: [UInt8]) -> Int {
        guard haystack.count >= needle.count else { return 0 }
        var count = 0
        var index = 0
        while index <= haystack.count - needle.count {
            if haystack[index..<index + needle.count].elementsEqual(needle) {
                count += 1
                index += needle.count
            } else {
                index += 1
            }
        }
        return count
    }
}

private extension Array where Element == UInt8 {
    func ends(with suffix: [UInt8]) -> Bool {
        count >= suffix.count && self[(count - suffix.count)...].elementsEqual(suffix)
    }
}
