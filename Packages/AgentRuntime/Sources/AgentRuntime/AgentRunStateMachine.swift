// SPDX-License-Identifier: MIT

import AgentContracts

/// User-visible mutation families allowed by the state-traits registry.
public enum AgentRunUserCommand: String, CaseIterable, Hashable, Codable, Sendable {
    case pause
    case cancel
    case resume
    case decideApproval
    case respond
    case reconcile
}

/// Compiled traits for one durable run state.
public struct AgentRunStateTraits: Hashable, Codable, Sendable {
    public let isTerminal: Bool
    public let isResumable: Bool
    public let ownsExecutionSlot: Bool
    public let allowedUserCommands: [AgentRunUserCommand]

    init(
        isTerminal: Bool,
        isResumable: Bool,
        ownsExecutionSlot: Bool,
        allowedUserCommands: [AgentRunUserCommand]
    ) {
        self.isTerminal = isTerminal
        self.isResumable = isResumable
        self.ownsExecutionSlot = ownsExecutionSlot
        self.allowedUserCommands = allowedUserCommands
    }
}

/// Minimal immutable state/version projection used when applying pure routing decisions.
public struct AgentRunStateSnapshot: Hashable, Codable, Sendable {
    public let state: AgentRunState
    public let stateVersion: UInt64
    public let terminalReason: AgentTerminalReason?

    /// Creates a snapshot while enforcing terminal-state consistency.
    public init(
        state: AgentRunState,
        stateVersion: UInt64,
        terminalReason: AgentTerminalReason? = nil
    ) throws {
        guard stateVersion > 0 else { throw AgentRunStateMachineError.invalidSnapshot }
        switch state {
        case .completed:
            guard terminalReason == .completed else {
                throw AgentRunStateMachineError.invalidSnapshot
            }
        case .cancelled:
            guard terminalReason == .cancelledByUser else {
                throw AgentRunStateMachineError.invalidSnapshot
            }
        case .failed:
            guard let terminalReason,
                  terminalReason != .completed,
                  terminalReason != .cancelledByUser
            else { throw AgentRunStateMachineError.invalidSnapshot }
        case .created, .preparing, .waitingForModel, .generating, .validatingAction,
             .waitingForApproval, .executingTools, .waitingForUser, .synthesizing,
             .pausing, .paused, .waitingForForeground, .waitingForReconciliation:
            guard terminalReason == nil else { throw AgentRunStateMachineError.invalidSnapshot }
        @unknown default:
            throw AgentRunStateMachineError.invalidSnapshot
        }
        self.state = state
        self.stateVersion = stateVersion
        self.terminalReason = terminalReason
    }

    /// Decodes and revalidates state/version/terminal-reason consistency.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                state: container.decode(AgentRunState.self, forKey: .state),
                stateVersion: container.decode(UInt64.self, forKey: .stateVersion),
                terminalReason: container.decodeIfPresent(
                    AgentTerminalReason.self,
                    forKey: .terminalReason
                )
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey { case state, stateVersion, terminalReason }
}

/// Fail-closed errors produced while applying a decision to a state/version snapshot.
public enum AgentRunStateMachineError: Error, Hashable, Sendable {
    case invalidSnapshot
    case statelessDecisionCannotTransition
    case sourceStateMismatch(expected: AgentRunState, actual: AgentRunState)
    case decisionDidNotAccept(
        disposition: AgentRunDecisionDisposition,
        diagnostic: AgentRunDecisionDiagnostic?
    )
    case versionOverflow
}

/// Public pure state-machine facade over the compiled run reducer.
public enum AgentRunStateMachine {
    /// Returns compiled state traits, failing closed with nil for a future unknown state.
    public static func traits(for state: AgentRunState) -> AgentRunStateTraits? {
        switch state {
        case .created:
            AgentRunStateTraits(
                isTerminal: false,
                isResumable: false,
                ownsExecutionSlot: false,
                allowedUserCommands: [.cancel]
            )
        case .preparing, .waitingForModel, .generating, .validatingAction, .executingTools,
             .synthesizing:
            AgentRunStateTraits(
                isTerminal: false,
                isResumable: false,
                ownsExecutionSlot: true,
                allowedUserCommands: [.pause, .cancel]
            )
        case .waitingForApproval:
            AgentRunStateTraits(
                isTerminal: false,
                isResumable: true,
                ownsExecutionSlot: false,
                allowedUserCommands: [.decideApproval, .cancel]
            )
        case .waitingForUser:
            AgentRunStateTraits(
                isTerminal: false,
                isResumable: true,
                ownsExecutionSlot: false,
                allowedUserCommands: [.respond, .cancel]
            )
        case .pausing:
            AgentRunStateTraits(
                isTerminal: false,
                isResumable: false,
                ownsExecutionSlot: true,
                allowedUserCommands: [.cancel]
            )
        case .paused:
            AgentRunStateTraits(
                isTerminal: false,
                isResumable: true,
                ownsExecutionSlot: false,
                allowedUserCommands: [.resume, .cancel]
            )
        case .waitingForForeground:
            AgentRunStateTraits(
                isTerminal: false,
                isResumable: true,
                ownsExecutionSlot: false,
                allowedUserCommands: [.resume, .cancel]
            )
        case .waitingForReconciliation:
            AgentRunStateTraits(
                isTerminal: false,
                isResumable: true,
                ownsExecutionSlot: false,
                allowedUserCommands: [.reconcile]
            )
        case .completed, .failed, .cancelled:
            AgentRunStateTraits(
                isTerminal: true,
                isResumable: false,
                ownsExecutionSlot: false,
                allowedUserCommands: []
            )
        @unknown default:
            nil
        }
    }

    /// Returns the compiled deterministic decision for one table input.
    public static func decide(_ input: AgentRunDecisionInput) -> AgentRunDecision {
        AgentRunReducer.reduce(input)
    }

    /// Returns whether this exact routed input accepts the requested committed edge.
    ///
    /// This intentionally does not treat every reflexive edge as legal. The only accepted self
    /// transitions are those encoded by the decision tables themselves.
    public static func allows(
        _ input: AgentRunDecisionInput,
        from source: AgentRunState,
        to destination: AgentRunState
    ) -> Bool {
        guard input.sourceState == source else { return false }
        let decision = decide(input)
        return decision.disposition == .accepted && decision.nextState == destination
    }

    /// Applies one accepted routed transition and advances the compare-and-swap version exactly once.
    public static func applying(
        _ input: AgentRunDecisionInput,
        to snapshot: AgentRunStateSnapshot
    ) throws -> AgentRunStateSnapshot {
        guard let sourceState = input.sourceState else {
            throw AgentRunStateMachineError.statelessDecisionCannotTransition
        }
        guard sourceState == snapshot.state else {
            throw AgentRunStateMachineError.sourceStateMismatch(
                expected: sourceState,
                actual: snapshot.state
            )
        }
        let decision = decide(input)
        guard decision.disposition == .accepted, let nextState = decision.nextState else {
            throw AgentRunStateMachineError.decisionDidNotAccept(
                disposition: decision.disposition,
                diagnostic: decision.diagnostic
            )
        }
        let (nextVersion, overflow) = snapshot.stateVersion.addingReportingOverflow(1)
        guard !overflow else { throw AgentRunStateMachineError.versionOverflow }
        return try AgentRunStateSnapshot(
            state: nextState,
            stateVersion: nextVersion,
            terminalReason: decision.terminalReason
        )
    }
}
