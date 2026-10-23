// SPDX-License-Identifier: GPL-3.0-only
// Copyright © 2017–2026 JamXi, JSG-LLC.
import AppKit
import CryptoKit
import Darwin

struct PreparedUpdate {
    let directory: URL
    let application: URL
    let version: String
    let target: URL
    var mode: UpdateMode = .normal
}

struct UpdateInstallJob: Codable {
    let parentPID: Int32
    let application: URL
    let target: URL
    let version: String
    var mode: UpdateMode = .normal
}

enum UpdateInstaller {
    static let identifier = "cn.jamsg.editdot"
    @discardableResult static func run(_ executable: String, _ arguments: [String]) throws -> Data {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError.invalidPackage }
        return data
    }
    static func architectures(in data: Data) -> Set<String> {
        let bytes = Array(data.prefix(4096))
        guard bytes.count >= 8 else { return [] }
        func integer(_ offset: Int, littleEndian: Bool) -> UInt32? {
            guard offset >= 0, offset + 4 <= bytes.count else { return nil }
            let chunk = Array(bytes[offset..<offset + 4])
            let ordered = littleEndian ? Array(chunk.reversed()) : chunk
            return ordered.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        func name(_ cpu: UInt32?) -> String? {
            switch cpu { case 0x0100000c: return "arm64"; case 0x01000007: return "x86_64"; default: return nil }
        }
        let magic = Array(bytes.prefix(4))
        if magic == [0xcf, 0xfa, 0xed, 0xfe] || magic == [0xce, 0xfa, 0xed, 0xfe] {
            return Set(name(integer(4, littleEndian: true)).map { [$0] } ?? [])
        }
        if magic == [0xfe, 0xed, 0xfa, 0xcf] || magic == [0xfe, 0xed, 0xfa, 0xce] {
            return Set(name(integer(4, littleEndian: false)).map { [$0] } ?? [])
        }
        let little = magic == [0xbe, 0xba, 0xfe, 0xca] || magic == [0xbf, 0xba, 0xfe, 0xca]
        let fat64 = magic == [0xca, 0xfe, 0xba, 0xbf] || magic == [0xbf, 0xba, 0xfe, 0xca]
        guard little || magic == [0xca, 0xfe, 0xba, 0xbe] || fat64,
              let count = integer(4, littleEndian: little), count > 0, count <= 64,
              8 + Int(count) * (fat64 ? 32 : 20) <= bytes.count else { return [] }
        return Set((0..<Int(count)).compactMap { name(integer(8 + $0 * (fat64 ? 32 : 20), littleEndian: little)) })
    }
    static func info(_ app: URL) throws -> [String: Any] {
        guard let dictionary = try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), options: [], format: nil) as? [String: Any] else { throw UpdateError.invalidPackage }
        return dictionary
    }
    static func validate(_ app: URL, version: String, mode: UpdateMode = .normal) throws {
        let fm = FileManager.default
        let metadata = try info(app)
        let binary = app.appendingPathComponent("Contents/MacOS/EditDot")
        guard app.pathExtension == "app", (try app.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true,
              metadata["CFBundleIdentifier"] as? String == identifier,
              let actual = metadata["CFBundleShortVersionString"] as? String,
              let expectedVersion = ReleaseVersion(version), let actualVersion = ReleaseVersion(actual),
              (mode == .forced || actualVersion == expectedVersion),
              metadata["CFBundleExecutable"] as? String == "EditDot",
              fm.fileExists(atPath: binary.path) else { throw UpdateError.invalidPackage }
        if let minimum = metadata["LSMinimumSystemVersion"] as? String,
           let required = ReleaseVersion(minimum) {
            let os = ProcessInfo.processInfo.operatingSystemVersion
            guard let running = ReleaseVersion("\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"), running >= required else { throw UpdateError.incompatible }
        }
        if mode == .normal { try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) }
        let handle = try FileHandle(forReadingFrom: binary); defer { try? handle.close() }
        let header = try handle.read(upToCount: 4096) ?? Data()
        guard architectures(in: header).contains(ReleaseParser.architecture) else { throw UpdateError.incompatible }
    }
    static func repairSignatureIfNeeded(_ app: URL) throws {
        do { try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) }
        catch { try run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", app.path]) }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
    }
    static func verifyChecksum(_ file: URL, expected: String?, mode: UpdateMode = .normal) throws {
        if mode == .forced { return }
        guard let expected = expected else { return }
        guard ReleaseParser.digest(expected) != nil else { throw UpdateError.checksum }
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
        let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == expected.lowercased() else { throw UpdateError.checksum }
    }
    static func prepare(archive: URL, directory: URL, release: UpdateRelease, target: URL = Bundle.main.bundleURL, mode: UpdateMode = .normal) throws -> PreparedUpdate {
        let fm = FileManager.default
        try verifyChecksum(archive, expected: release.sha256, mode: mode)
        let mount = directory.appendingPathComponent("mount", isDirectory: true)
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, archive.path])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path]) }
        let app = mount.appendingPathComponent("EditDot.app")
        try validate(app, version: release.version, mode: mode)
        let staged = directory.appendingPathComponent("EditDot.app")
        try run("/usr/bin/ditto", [app.path, staged.path])
        try validate(staged, version: release.version, mode: mode)
        if mode == .forced { try repairSignatureIfNeeded(staged) }
        guard let installedVersion = try info(staged)["CFBundleShortVersionString"] as? String else { throw UpdateError.invalidPackage }
        try validate(staged, version: installedVersion)
        return PreparedUpdate(directory: directory, application: staged, version: installedVersion, target: target, mode: mode)
    }
    static func validateTarget(_ target: URL, version: String, mode: UpdateMode = .normal) throws {
        let metadata = try info(target)
        guard target.pathExtension == "app", (try target.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true,
              metadata["CFBundleIdentifier"] as? String == identifier,
              let current = metadata["CFBundleShortVersionString"] as? String,
              let next = ReleaseVersion(version), let previous = ReleaseVersion(current), (mode == .forced || next > previous) else { throw UpdateError.invalidPackage }
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path),
              FileManager.default.isWritableFile(atPath: target.path) else { throw UpdateError.notWritable }
    }
    static func launch(_ prepared: PreparedUpdate) throws {
        try validateTarget(prepared.target, version: prepared.version, mode: prepared.mode)
        if prepared.mode == .forced { try repairSignatureIfNeeded(prepared.application) }
        try validate(prepared.application, version: prepared.version)
        let fm = FileManager.default
        let executable = prepared.directory.appendingPathComponent("EditDotUpdate")
        guard let source = Bundle.main.executableURL else { throw UpdateError.helper }
        if fm.fileExists(atPath: executable.path) { try fm.removeItem(at: executable) }
        try fm.copyItem(at: source, to: executable)
        let resourceTarget = prepared.directory.appendingPathComponent("EditDot_EditDot.bundle")
        if fm.fileExists(atPath: resourceTarget.path) { try fm.removeItem(at: resourceTarget) }
        if let resources = Bundle.main.resourceURL?.appendingPathComponent("EditDot_EditDot.bundle") {
            try fm.copyItem(at: resources, to: resourceTarget)
        }
        let job = UpdateInstallJob(parentPID: getpid(), application: prepared.application, target: prepared.target, version: prepared.version, mode: prepared.mode)
        let manifest = prepared.directory.appendingPathComponent("install.json")
        try JSONEncoder().encode(job).write(to: manifest, options: .atomic)
        let helper = Process(); helper.executableURL = executable; helper.arguments = ["--apply-update", manifest.path]
        helper.currentDirectoryURL = prepared.directory
        helper.standardOutput = FileHandle.nullDevice; helper.standardError = FileHandle.nullDevice
        try helper.run()
    }
    // Both paths are renamed on the same volume; keep the previous app until replacement verifies.
    static func replace(_ job: UpdateInstallJob, beforeCommit: (() throws -> Void)? = nil) throws {
        let fm = FileManager.default, target = job.target
        try validateTarget(target, version: job.version, mode: job.mode)
        try validate(job.application, version: job.version, mode: job.mode)
        let folder = target.deletingLastPathComponent().appendingPathComponent(".EditDot-update-" + UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        var removeFolder = true
        defer { if removeFolder { try? fm.removeItem(at: folder) } }
        let staged = folder.appendingPathComponent("EditDot.app"), backup = folder.appendingPathComponent("Previous.app")
        try run("/usr/bin/ditto", [job.application.path, staged.path])
        if job.mode == .forced { try repairSignatureIfNeeded(staged) }
        try validate(staged, version: job.version)
        try fm.moveItem(at: target, to: backup)
        removeFolder = false
        do {
            try beforeCommit?()
            try fm.moveItem(at: staged, to: target)
            try validate(target, version: job.version)
            removeFolder = true
        } catch {
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.moveItem(at: backup, to: target)
            removeFolder = true
            throw error
        }
    }
    static func runHelper(manifest: URL) -> Int32 {
        var target: URL?
        do {
            let job = try JSONDecoder().decode(UpdateInstallJob.self, from: Data(contentsOf: manifest))
            target = job.target
            guard job.parentPID > 1, job.parentPID != getpid() else { throw UpdateError.helper }
            let deadline = Date().addingTimeInterval(120)
            while kill(job.parentPID, 0) == 0 && Date() < deadline { usleep(100000) }
            guard kill(job.parentPID, 0) != 0 else { throw UpdateError.cancelled }
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            guard !others.contains(where: { $0.bundleURL?.standardizedFileURL == job.target.standardizedFileURL }) else { throw UpdateError.helper }
            try replace(job)
            _ = try? run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", ["-f", job.target.path])
            try run("/usr/bin/open", [job.target.path])
            try? FileManager.default.removeItem(at: manifest.deletingLastPathComponent())
            return 0
        } catch {
            UserDefaults(suiteName: identifier)?.set(true, forKey: "updateInstallFailed")
            _ = UserDefaults(suiteName: identifier)?.synchronize()
            if let target = target { _ = try? run("/usr/bin/open", [target.path]) }
            return 1
        }
    }
}
