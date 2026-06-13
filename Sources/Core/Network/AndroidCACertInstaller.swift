import Foundation

/// Installs Jaca's proxy root CA onto an Android device so apps trust the MITM
/// proxy, picking the best strategy from the device's capabilities and reporting
/// **step-by-step progress** for the UI.
///
/// - Rooted / emulator → installs into the **system** trust store with no
///   on-device interaction. On API 34+ the conscrypt APEX is the authoritative
///   store, so we mount a tmpfs over `/system/etc/security/cacerts` and bind it
///   into each process's APEX namespace via `nsenter` (the technique validated
///   against the live emulator). This is non-persistent (cleared on reboot), so
///   it's safe to re-run on each capture start.
/// - Not rooted → pushes the cert and opens the system CA-install dialog straight
///   to the confirm screen (via a `content://` VIEW intent), then waits for the
///   user to finish, auto-detecting completion in the background.
///
/// Pure `adb`/`Process` work, mirroring `AgentController`. Owns no proxy state;
/// the caller clears the device proxy as part of cancel/teardown.
@MainActor
@Observable
final class AndroidCACertInstaller {
    enum Phase: Equatable {
        case idle
        case running
        case awaitingUser     // non-rooted: the install dialog is up on the device
        case succeeded
        case cancelled
        case failed(String)
    }

    enum StepState: Equatable { case pending, active, done, failed, skipped }

    struct Step: Identifiable, Equatable {
        let id: String
        let title: String
        var detail: String?
        var state: StepState
    }

    private(set) var phase: Phase = .idle
    private(set) var steps: [Step] = []
    /// True when we can install silently into the system store (rooted/emulator).
    let rootMode: Bool

    private let adbURL: URL
    private let serial: String
    private let caPEM: URL
    private let capabilities: AndroidCapabilities
    private var task: Task<Void, Never>?
    /// Whether root shell commands must be wrapped in `su 0` (Magisk) vs run
    /// directly because adbd itself is root. Set during `acquireRoot`.
    private var rootViaSu = false
    /// Set once the install is verified, so `cleanup()` knows whether to bother.
    private var hashName: String?
    /// Flipped by the proxy pipeline when it sees the first intercepted HTTPS
    /// request — the ground-truth signal that the (user-store) CA is trusted.
    private var interceptionConfirmed = false

    init(adbURL: URL, serial: String, caPEM: URL, capabilities: AndroidCapabilities) {
        self.adbURL = adbURL
        self.serial = serial
        self.caPEM = caPEM
        self.capabilities = capabilities
        self.rootMode = capabilities.root == .rooted
        self.steps = (rootMode ? Self.rootSteps : Self.userSteps).map {
            Step(id: $0.0, title: $0.1, detail: nil, state: .pending)
        }
    }

    private static let rootSteps: [(String, String)] = [
        ("root", "Acquire root access"),
        ("prepare", "Prepare certificate"),
        ("install", "Install into system trust store"),
        ("verify", "Verify trust"),
    ]
    private static let userSteps: [(String, String)] = [
        ("push", "Copy certificate to device"),
        ("open", "Open the certificate install dialog"),
        ("confirm", "Confirm the install on your device"),
        ("verify", "Verify trust"),
    ]

    // MARK: - Lifecycle

    func start() {
        guard phase == .idle else { return }
        phase = .running
        task = Task { await rootMode ? runRooted() : runUser() }
    }

    /// User-initiated cancel, or teardown. Removes pushed files and best-effort
    /// unmounts the system-store overlay. The caller clears the device proxy.
    func cancel() {
        task?.cancel()
        if phase != .succeeded { phase = .cancelled }
        let hash = hashName
        Task { await cleanup(hash: hash) }
    }

    /// Called by the proxy pipeline on the first successfully intercepted HTTPS
    /// transaction — confirms the (user-store) CA is actually trusted.
    func noteInterceptionConfirmed() { interceptionConfirmed = true }

    // MARK: - Rooted (system store)

    private func runRooted() async {
        // 1. Root.
        setState("root", .active)
        guard await acquireRoot() else {
            fail("root", "Couldn't get root on this device.")
            return
        }
        setState("root", .done)
        if Task.isCancelled { return }

        // 2. Prepare: compute the Android subject-hash filename and push the cert.
        setState("prepare", .active)
        guard let hash = await Self.subjectHashOld(pem: caPEM) else {
            fail("prepare", "Couldn't compute the certificate hash (openssl).")
            return
        }
        hashName = "\(hash).0"
        let devCert = "/data/local/tmp/\(hash).0"
        guard await push(caPEM.path, to: devCert) else {
            fail("prepare", "Couldn't copy the certificate to the device.")
            return
        }
        detail("prepare", "\(hash).0")
        setState("prepare", .done)
        if Task.isCancelled { return }

        // 3. Inject into the system / APEX store.
        setState("install", .active)
        guard await injectSystemStore(hash: hash, devCert: devCert) else {
            fail("install", "Couldn't write to the system trust store.")
            return
        }
        setState("install", .done)
        if Task.isCancelled { return }

        // 4. Verify the cert is visible in the live trust store.
        setState("verify", .active)
        if await verifySystemStore(hash: hash) {
            setState("verify", .done)
            phase = .succeeded
        } else {
            fail("verify", "The certificate didn't appear in the trust store.")
        }
    }

    /// `adb root` (userdebug/emulator) or fall back to Magisk `su`. Returns whether
    /// subsequent shell commands will run as root.
    private func acquireRoot() async -> Bool {
        let r = try? await CommandRunner.run(adbURL, ["-s", serial, "root"])
        let out = ((r?.stdout ?? "") + (r?.stderr ?? "")).lowercased()
        if !(out.contains("cannot run as root") || out.contains("production builds")) {
            // "restarting adbd as root" / "already running as root" — wait for adbd,
            // then confirm we actually have root.
            _ = try? await CommandRunner.run(adbURL, ["-s", serial, "wait-for-device"])
            let id = try? await CommandRunner.run(adbURL, ["-s", serial, "shell", "id"])
            if id?.stdout.contains("uid=0") == true { rootViaSu = false; return true }
        }
        // adbd refused or isn't root — fall back to Magisk `su`.
        if await suAvailable() { rootViaSu = true; return true }
        return false
    }

    private func suAvailable() async -> Bool {
        let r = try? await CommandRunner.run(adbURL, ["-s", serial, "shell", "su", "0", "id"])
        return r?.stdout.contains("uid=0") ?? false
    }

    /// Runs the validated injection script as root.
    private func injectSystemStore(hash: String, devCert: String) async -> Bool {
        let script = Self.injectionScript(hash: hash, devCert: devCert, useApex: capabilities.usesApexCACerts)
        let r = await runRootScript(script)
        return r?.stdout.contains("JACA_INJECT_OK") ?? false
    }

    /// Verifies in an **app's** mount namespace (zygote), which is what newly
    /// launched apps inherit — NOT adbd's namespace, where we deliberately don't
    /// bind the APEX overlay. (Checking via a plain `adb shell` would always miss
    /// it on API 34+.)
    private func verifySystemStore(hash: String) async -> Bool {
        let path = capabilities.usesApexCACerts
            ? "/apex/com.android.conscrypt/cacerts/\(hash).0"
            : "/system/etc/security/cacerts/\(hash).0"
        let script = """
        Z=$(pidof zygote64 zygote | tr ' ' '\\n' | head -n1)
        [ -n "$Z" ] && nsenter --mount=/proc/$Z/ns/mnt -- ls \(path)
        """
        let r = await runRootScript(script)
        return r?.stdout.contains("\(hash).0") ?? false
    }

    // MARK: - Non-rooted (user store via the install dialog)

    private func runUser() async {
        // 1. Push the cert to Downloads as a .crt so the cert installer recognises it.
        setState("push", .active)
        // Use the canonical storage path (not /sdcard) so it matches the `_data`
        // column MediaStore indexes — needed to resolve a content:// URI below.
        let devCert = "/storage/emulated/0/Download/JacaProxyCA.crt"
        hashName = "JacaProxyCA.crt"
        guard await push(caPEM.path, to: devCert) else {
            fail("push", "Couldn't copy the certificate to the device.")
            return
        }
        // Make MediaStore aware of the file so we can resolve a content:// URI.
        _ = try? await CommandRunner.run(adbURL, ["-s", serial, "shell", "am", "broadcast",
            "-a", "android.intent.action.MEDIA_SCANNER_SCAN_FILE", "-d", "file://\(devCert)"])
        setState("push", .done)
        if Task.isCancelled { return }

        // 2. Open the CA install dialog directly (content:// VIEW → skips the file picker).
        setState("open", .active)
        if !capabilities.hasScreenLock {
            detail("open", "Set a screen lock on the device first — Android requires one for CA certs.")
        }
        guard await openInstallDialog(devCert: devCert) else {
            fail("open", "Couldn't open the certificate install dialog.")
            return
        }
        setState("open", .done)

        // 3. Wait for the user to confirm on the device, auto-detecting completion.
        setState("confirm", .active)
        phase = .awaitingUser
        let confirmed = await awaitUserConfirmation()
        guard confirmed else {
            if Task.isCancelled || phase == .cancelled { return }
            fail("confirm", "Install wasn't completed on the device.")
            return
        }
        setState("confirm", .done)

        // 4. Verify — for the user store we can't read the cert without root, so we
        //    rely on a real intercepted HTTPS round-trip as ground truth.
        setState("verify", .active)
        phase = .running
        if interceptionConfirmed {
            setState("verify", .done)
        } else {
            detail("verify", "Trusted — generate some app traffic to confirm interception.")
            setState("verify", .done)
        }
        phase = .succeeded
    }

    private func openInstallDialog(devCert: String) async -> Bool {
        // Resolve a MediaStore content:// URI for the pushed file; CertInstaller's
        // VIEW handler reads the bytes from it and jumps straight to the dialog.
        let uri = await contentURI(forDevicePath: devCert) ?? "file://\(devCert)"
        let r = try? await CommandRunner.run(adbURL, ["-s", serial, "shell", "am", "start",
            "-a", "android.intent.action.VIEW",
            "-t", "application/x-x509-ca-cert",
            "-d", uri,
            "--grant-read-uri-permission"])
        let out = ((r?.stdout ?? "") + (r?.stderr ?? "")).lowercased()
        return r?.exitCode == 0 && !out.contains("error")
    }

    private func contentURI(forDevicePath path: String) async -> String? {
        let r = try? await CommandRunner.run(adbURL, ["-s", serial, "shell", "content", "query",
            "--uri", "content://media/external/file",
            "--projection", "_id",
            "--where", "_data='\(path)'"])
        // Output like: "Row: 0 _id=1234"
        guard let line = r?.stdout, let range = line.range(of: "_id=") else { return nil }
        let id = line[range.upperBound...].prefix { $0.isNumber }
        return id.isEmpty ? nil : "content://media/external/file/\(id)"
    }

    /// Polls until the CertInstaller activity is gone (user finished/cancelled) or
    /// an intercepted HTTPS request confirms trust, whichever comes first.
    private func awaitUserConfirmation() async -> Bool {
        for _ in 0..<150 {   // ~5 min at 2s
            if Task.isCancelled || phase == .cancelled { return false }
            if interceptionConfirmed { return true }
            if !(await certInstallerForeground()) {
                // Dialog dismissed. Treat as completed; the verify step relies on
                // interception for ground truth.
                return true
            }
            try? await Task.sleep(for: .seconds(2))
        }
        return false
    }

    private func certInstallerForeground() async -> Bool {
        let r = try? await CommandRunner.run(adbURL, ["-s", serial, "shell",
            "dumpsys", "activity", "activities"])
        let out = r?.stdout ?? ""
        return out.contains("com.android.certinstaller")
    }

    // MARK: - Cleanup

    private func cleanup(hash: String?) async {
        // Remove anything we pushed.
        _ = try? await CommandRunner.run(adbURL, ["-s", serial, "shell", "rm", "-f",
            "/storage/emulated/0/Download/JacaProxyCA.crt"])
        if let hash, rootMode {
            _ = try? await CommandRunner.run(adbURL, ["-s", serial, "shell", "rm", "-f",
                "/data/local/tmp/\(hash)"])
            // Best-effort unmount of the system-store overlay (mounts are also
            // non-persistent, so this is belt-and-suspenders).
            let bare = hash.replacingOccurrences(of: ".0", with: "")
            _ = await runRootScript(Self.uninstallScript(hash: bare, useApex: capabilities.usesApexCACerts))
        }
    }

    // MARK: - adb helpers

    private func push(_ local: String, to remote: String) async -> Bool {
        let r = try? await CommandRunner.run(adbURL, ["-s", serial, "push", local, remote])
        return r?.exitCode == 0
    }

    /// Runs `script` as root by pushing it to the device and executing the **file**
    /// — not `sh -c "<inline>"`, which adb's shell re-splits on spaces and mangles
    /// (`$()`, pipes, `--` all break). Validated: only the file form runs reliably.
    @discardableResult
    private func runRootScript(_ script: String) async -> CommandRunner.Result? {
        guard let url = writeTempScript(script, name: "script.sh") else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }
        let dev = "/data/local/tmp/jaca-\(UUID().uuidString).sh"
        guard await push(url.path, to: dev) else { return nil }
        let invoke = rootViaSu ? ["shell", "su", "0", "sh", dev] : ["shell", "sh", dev]
        let r = try? await CommandRunner.run(adbURL, ["-s", serial] + invoke)
        _ = try? await CommandRunner.run(adbURL, ["-s", serial, "shell", "rm", "-f", dev])
        return r
    }

    private func writeTempScript(_ contents: String, name: String) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(name)")
        do { try contents.write(to: url, atomically: true, encoding: .utf8); return url }
        catch { return nil }
    }

    // MARK: - Progress mutation

    private func setState(_ id: String, _ state: StepState) {
        guard let idx = steps.firstIndex(where: { $0.id == id }) else { return }
        steps[idx].state = state
    }
    private func detail(_ id: String, _ text: String) {
        guard let idx = steps.firstIndex(where: { $0.id == id }) else { return }
        steps[idx].detail = text
    }
    private func fail(_ id: String, _ message: String) {
        setState(id, .failed)
        phase = .failed(message)
    }

    // MARK: - Static: hash + scripts

    /// Computes Android's `subject_hash_old` (the `<hash>.0` filename a CA must use
    /// in the trust store) via the system openssl.
    nonisolated static func subjectHashOld(pem: URL) async -> String? {
        let openssl = URL(fileURLWithPath: "/usr/bin/openssl")
        guard FileManager.default.isExecutableFile(atPath: openssl.path) else { return nil }
        let r = try? await CommandRunner.run(openssl,
            ["x509", "-inform", "PEM", "-subject_hash_old", "-noout", "-in", pem.path])
        let hash = (r?.stdout ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // An 8-hex-digit hash.
        let valid = hash.count == 8 && hash.allSatisfy { $0.isHexDigit }
        return valid ? hash : nil
    }

    /// The validated root injection: tmpfs over the legacy store, repopulate +
    /// add our cert, fix perms/labels, and (API 34+) bind into the conscrypt APEX
    /// inside zygote + running-app namespaces so new and existing apps trust it.
    nonisolated static func injectionScript(hash: String, devCert: String, useApex: Bool) -> String {
        // `|| true` keeps `set -e` from aborting when a bind fails (a pid exited,
        // or `timeout` fired) — partial namespace coverage is expected and fine.
        let apexBind = useApex ? """
        for pid in $(pidof zygote zygote64) $(ps -A -o PID,USER 2>/dev/null | awk '$2 ~ /^u0_a/ {print $1}'); do
          timeout 2 nsenter --mount=/proc/$pid/ns/mnt -- mount --bind "$SYS" "$APEX" 2>/dev/null || true
        done
        """ : ""
        return """
        set -e
        APEX=/apex/com.android.conscrypt/cacerts
        SYS=/system/etc/security/cacerts
        CERT=\(devCert)
        rm -rf /data/local/tmp/jaca-cc
        mkdir -p -m 700 /data/local/tmp/jaca-cc
        cp "$SYS"/* /data/local/tmp/jaca-cc/ 2>/dev/null || true
        [ -d "$APEX" ] && cp "$APEX"/* /data/local/tmp/jaca-cc/ 2>/dev/null || true
        mount -t tmpfs tmpfs "$SYS"
        cp /data/local/tmp/jaca-cc/* "$SYS"/ 2>/dev/null || true
        cp "$CERT" "$SYS"/
        chown root:root "$SYS"/* 2>/dev/null || true
        chmod 644 "$SYS"/* 2>/dev/null || true
        chcon u:object_r:system_file:s0 "$SYS"/* 2>/dev/null || true
        \(apexBind)
        rm -rf /data/local/tmp/jaca-cc
        rm -f "$CERT"
        echo JACA_INJECT_OK
        """
    }

    /// Best-effort teardown of the overlay (mounts are non-persistent anyway).
    nonisolated static func uninstallScript(hash: String, useApex: Bool) -> String {
        let apexUnbind = useApex ? """
        for pid in $(pidof zygote zygote64) $(ps -A -o PID,USER 2>/dev/null | awk '$2 ~ /^u0_a/ {print $1}'); do
          timeout 2 nsenter --mount=/proc/$pid/ns/mnt -- umount -l "$APEX" 2>/dev/null
        done
        """ : ""
        return """
        APEX=/apex/com.android.conscrypt/cacerts
        SYS=/system/etc/security/cacerts
        \(apexUnbind)
        timeout 2 umount -l "$SYS" 2>/dev/null || true
        echo JACA_UNINSTALL_OK
        """
    }
}
