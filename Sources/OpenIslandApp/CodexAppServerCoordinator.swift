import AppKit
import Foundation
import OpenIslandCore

/// Manages the lifecycle of the Codex app-server connection.
///
/// Automatically starts the app-server subprocess when Codex.app is
/// detected, and tears it down when the app quits.  Converts incoming
/// app-server notifications into `AgentEvent`s that flow through the
/// standard `SessionState` reducer.
@Observable
@MainActor
final class CodexAppServerCoordinator {
    private static let loadedThreadRefreshInterval: Duration = .seconds(2)

    @ObservationIgnored
    private var client: CodexAppServerClient?

    @ObservationIgnored
    private var connectTask: Task<Void, Never>?

    @ObservationIgnored
    private var loadedThreadRefreshTask: Task<Void, Never>?

    /// Callback to emit AgentEvents into AppModel.
    @ObservationIgnored
    var onEvent: ((AgentEvent) -> Void)?

    /// Callback to log status messages.
    @ObservationIgnored
    var onStatusMessage: ((String) -> Void)?

    /// Returns `true` if a session with the given id is already tracked.
    /// Used to avoid re-emitting `sessionStarted` (which rebuilds the
    /// session and wipes richer state from hooks/rediscovery).
    @ObservationIgnored
    var isSessionTracked: ((String) -> Bool)?

    /// Returns the current tracked session snapshot, when available.
    /// Used to refresh stale Codex.app thread status without re-emitting
    /// unchanged events on every polling tick.
    @ObservationIgnored
    var trackedSession: ((String) -> AgentSession?)?

    private(set) var isConnected = false

    // MARK: - Public API

    /// Ensure a connection exists.  Called from the monitoring loop when
    /// Codex.app is detected as running.  Idempotent — does nothing if
    /// already connected or a connection attempt is in progress.
    func ensureConnected() {
        guard !isConnected, connectTask == nil else { return }

        // Resolve the Codex.app bundle location dynamically — users may
        // have installed Codex outside `/Applications` (e.g. ~/Applications).
        guard let bundleURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.openai.codex"
        ) else {
            return
        }
        let codexPath = bundleURL
            .appendingPathComponent("Contents/Resources/codex")
            .path
        guard FileManager.default.isExecutableFile(atPath: codexPath) else {
            return
        }

        connectTask = Task { [weak self] in
            guard let self else { return }
            do {
                let newClient = CodexAppServerClient(codexPath: codexPath)
                newClient.onNotification = { [weak self] notification in
                    Task { @MainActor [weak self] in
                        self?.handleNotification(notification)
                    }
                }
                try await newClient.start()

                self.client = newClient
                self.isConnected = true
                self.connectTask = nil

                self.onStatusMessage?("Connected to Codex app-server.")

                // Fetch currently loaded threads and create sessions.
                await self.syncLoadedThreads()
                self.startLoadedThreadRefreshLoop()
            } catch {
                self.connectTask = nil
                self.onStatusMessage?("Failed to connect to Codex app-server: \(error.localizedDescription)")
            }
        }
    }

    /// Disconnect and clean up.  Called when Codex.app is no longer running.
    func disconnect() {
        connectTask?.cancel()
        connectTask = nil
        loadedThreadRefreshTask?.cancel()
        loadedThreadRefreshTask = nil
        client?.stop()
        client = nil
        isConnected = false
    }

    // MARK: - Thread sync

    private func syncLoadedThreads() async {
        guard let client else { return }
        do {
            let threads = try await client.listLoadedThreads()
            var created = 0
            for thread in threads where !thread.ephemeral {
                if let existing = trackedSession?(thread.id) {
                    refreshTrackedThreadStatus(thread, existing: existing)
                    continue
                }

                // Skip unknown idle threads so manually removed/completed rows
                // do not immediately reappear from periodic app-server polling.
                guard thread.status.type == .active else { continue }

                guard isSessionTracked?(thread.id) != true else { continue }
                emitSessionStarted(from: thread)
                refreshNewThreadStatusIfNeeded(thread)
                created += 1
            }
            if created > 0 {
                onStatusMessage?("Synced \(created) new Codex thread(s) from app-server.")
            }
        } catch {
            onStatusMessage?("Failed to list loaded Codex threads: \(error.localizedDescription)")
        }
    }

    private func startLoadedThreadRefreshLoop() {
        guard loadedThreadRefreshTask == nil else { return }
        loadedThreadRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.loadedThreadRefreshInterval)
                guard !Task.isCancelled else { return }
                await self?.syncLoadedThreads()
            }
        }
    }

    // MARK: - Notification handling

    private func handleNotification(_ notification: CodexAppServerNotification) {
        switch notification {
        case .threadStarted(let thread):
            guard !thread.ephemeral else { return }
            guard isSessionTracked?(thread.id) != true else { return }
            emitSessionStarted(from: thread)

        case .threadStatusChanged(let threadId, let status):
            emitStatusEvent(
                threadId: threadId,
                status: status,
                existing: trackedSession?(threadId),
                force: true
            )

        case .threadClosed(let threadId):
            onEvent?(.sessionCompleted(
                SessionCompleted(
                    sessionID: threadId,
                    summary: "Codex thread closed.",
                    timestamp: .now,
                    isSessionEnd: true
                )
            ))

        case .threadNameUpdated:
            // Title updates don't have a dedicated AgentEvent and we can't
            // safely overwrite phase/summary here (would clobber running or
            // waiting-for-approval state).  Skip for now — the title is
            // populated at sessionStarted time which is usually enough.
            break

        case .turnStarted(let threadId, _):
            onEvent?(.activityUpdated(
                SessionActivityUpdated(
                    sessionID: threadId,
                    summary: "Codex is working…",
                    phase: .running,
                    timestamp: .now
                )
            ))

        case .turnCompleted(let threadId, let turn):
            // A turn completing doesn't end the thread — the user can send
            // another message.  Use activityUpdated(phase: .completed) so the
            // session stays visible as "Completed" rather than being torn
            // down.  `thread/closed` is the authoritative end signal.
            let summary: String
            let phase: SessionPhase
            switch turn.status {
            case .completed:
                summary = "Turn completed."
                phase = .completed
            case .interrupted:
                summary = "Turn interrupted."
                phase = .completed
            case .failed:
                summary = "Turn failed."
                phase = .completed
            case .inProgress:
                summary = "Turn in progress."
                phase = .running
            }
            onEvent?(.activityUpdated(
                SessionActivityUpdated(
                    sessionID: threadId,
                    summary: summary,
                    phase: phase,
                    timestamp: .now
                )
            ))

        case .unknown:
            break
        }
    }

    // MARK: - Helpers

    private func refreshTrackedThreadStatus(_ thread: CodexThread, existing: AgentSession) {
        emitStatusEvent(
            threadId: thread.id,
            status: thread.status,
            existing: existing,
            force: false
        )
    }

    private func refreshNewThreadStatusIfNeeded(_ thread: CodexThread) {
        guard thread.status.isWaitingOnApproval || thread.status.isWaitingOnUserInput else {
            return
        }

        emitStatusEvent(
            threadId: thread.id,
            status: thread.status,
            existing: nil,
            force: true
        )
    }

    @discardableResult
    private func emitStatusEvent(
        threadId: String,
        status: CodexThreadStatus,
        existing: AgentSession?,
        force: Bool
    ) -> Bool {
        switch status.type {
        case .active:
            if status.isWaitingOnApproval {
                guard force || existing?.phase != .waitingForApproval || existing?.permissionRequest == nil else {
                    return false
                }
                onEvent?(.permissionRequested(
                    PermissionRequested(
                        sessionID: threadId,
                        request: PermissionRequest(
                            title: "Approval Required",
                            summary: "Codex is waiting for approval.",
                            affectedPath: ""
                        ),
                        timestamp: .now
                    )
                ))
                return true
            }

            if status.isWaitingOnUserInput {
                guard force || existing?.phase != .waitingForAnswer || existing?.questionPrompt == nil else {
                    return false
                }
                onEvent?(.questionAsked(
                    QuestionAsked(
                        sessionID: threadId,
                        prompt: QuestionPrompt(
                            title: "Codex is waiting for input.",
                            options: []
                        ),
                        timestamp: .now
                    )
                ))
                return true
            }

            return emitActivityUpdateIfNeeded(
                threadId: threadId,
                summary: "Codex is working…",
                phase: .running,
                existing: existing,
                force: force
            )

        case .idle:
            return emitActivityUpdateIfNeeded(
                threadId: threadId,
                summary: "Idle.",
                phase: .completed,
                existing: existing,
                force: force
            )

        case .notLoaded:
            return emitActivityUpdateIfNeeded(
                threadId: threadId,
                summary: "Codex thread not loaded.",
                phase: .completed,
                existing: existing,
                force: force
            )

        case .systemError:
            return emitActivityUpdateIfNeeded(
                threadId: threadId,
                summary: "Codex thread unavailable.",
                phase: .completed,
                existing: existing,
                force: force
            )
        }
    }

    @discardableResult
    private func emitActivityUpdateIfNeeded(
        threadId: String,
        summary: String,
        phase: SessionPhase,
        existing: AgentSession?,
        force: Bool
    ) -> Bool {
        guard force || existing?.phase != phase else {
            return false
        }

        onEvent?(.activityUpdated(
            SessionActivityUpdated(
                sessionID: threadId,
                summary: summary,
                phase: phase,
                timestamp: .now
            )
        ))
        return true
    }

    private func emitSessionStarted(from thread: CodexThread) {
        let workspaceName = URL(fileURLWithPath: thread.cwd).lastPathComponent
        let title = thread.name ?? workspaceName
        let summary = thread.preview.isEmpty ? "Codex session." : String(thread.preview.prefix(120))

        let phase: SessionPhase
        switch thread.status.type {
        case .active: phase = .running
        case .idle: phase = .completed
        case .notLoaded, .systemError: phase = .completed
        }

        onEvent?(.sessionStarted(
            SessionStarted(
                sessionID: thread.id,
                title: title,
                tool: .codex,
                origin: .live,
                initialPhase: phase,
                summary: summary,
                timestamp: .now,
                jumpTarget: JumpTarget(
                    terminalApp: "Codex.app",
                    workspaceName: workspaceName,
                    paneTitle: title,
                    workingDirectory: thread.cwd,
                    codexThreadID: thread.id
                ),
                codexMetadata: CodexSessionMetadata(
                    transcriptPath: thread.path,
                    initialUserPrompt: thread.preview.isEmpty ? nil : thread.preview
                )
            )
        ))
    }
}
