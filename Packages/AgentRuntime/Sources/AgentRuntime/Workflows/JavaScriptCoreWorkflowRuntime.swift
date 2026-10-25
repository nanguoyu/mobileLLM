// SPDX-License-Identifier: MIT

import AgentContracts
import Foundation
@preconcurrency import JavaScriptCore

/// iOS 17-compatible orchestration realm. This is deliberately advertised as a logical realm,
/// not as a hard OS sandbox; a private isolated provider can replace it through the same protocol.
public struct JavaScriptCoreWorkflowRuntime: WorkflowScriptRuntimeProvider, Sendable {
    public let capabilities = try! WorkflowRuntimeCapabilitiesV1(
        providerID: "mobilellm.javascriptcore",
        abiVersions: [WorkflowScriptABI.v1],
        isolation: .logicalRealm,
        hasHardMemoryLimit: false,
        hasPreemptiveTermination: false
    )

    public init() {}

    public func execute(
        _ script: AnalyzedWorkflowScriptV1,
        args: CanonicalJSON?,
        limits: WorkflowRunLimitsV1,
        requirement: WorkflowRuntimeRequirementV1,
        host: WorkflowScriptHost
    ) async throws -> CanonicalJSON {
        guard capabilities.satisfies(requirement) else {
            throw WorkflowScriptRuntimeError.unsupportedRequirement
        }
        let execution = JSCWorkflowExecution(
            script: script,
            args: args,
            limits: limits,
            host: host
        )
        return try await withTaskCancellationHandler {
            try await execution.run()
        } onCancel: {
            execution.cancel()
        }
    }
}

private final class JSCWorkflowExecution: @unchecked Sendable {
    private enum StopReason { case cancelled, timedOut, stepLimit }

    private let script: AnalyzedWorkflowScriptV1
    private let args: CanonicalJSON?
    private let limits: WorkflowRunLimitsV1
    private let host: WorkflowScriptHost
    private let queue = DispatchQueue(label: "app.mobilellm.dynamic-workflow.javascriptcore")
    private let stateLock = NSLock()
    private let deadline: UInt64
    private var stopReason: StopReason?
    private var continuation: CheckedContinuation<CanonicalJSON, Error>?
    private var completed = false
    private var context: JSContext?
    private var settleFunction: JSValue?
    private var nextRequestID: Int32 = 1
    private var pendingTasks: [Int32: Task<Void, Never>] = [:]
    private var scriptSteps: UInt64 = 0
    private var watchdog: Task<Void, Never>?

    init(
        script: AnalyzedWorkflowScriptV1,
        args: CanonicalJSON?,
        limits: WorkflowRunLimitsV1,
        host: WorkflowScriptHost
    ) {
        self.script = script
        self.args = args
        self.limits = limits
        self.host = host
        let now = DispatchTime.now().uptimeNanoseconds
        let (delta, overflow) = limits.maximumWallClockMilliseconds.multipliedReportingOverflow(by: 1_000_000)
        let (deadline, deadlineOverflow) = now.addingReportingOverflow(delta)
        self.deadline = overflow || deadlineOverflow ? UInt64.max : deadline
    }

    func run() async throws -> CanonicalJSON {
        try await withCheckedThrowingContinuation { continuation in
            stateLock.lock()
            self.continuation = continuation
            stateLock.unlock()
            queue.async { [self] in start() }
            watchdog = Task { [weak self, milliseconds = limits.maximumWallClockMilliseconds] in
                try? await Task.sleep(nanoseconds: milliseconds * 1_000_000)
                guard !Task.isCancelled else { return }
                self?.cancel(reason: .timedOut)
            }
        }
    }

    func cancel() { cancel(reason: .cancelled) }

    private func cancel(reason: StopReason) {
        stateLock.lock()
        if stopReason == nil { stopReason = reason }
        let shouldFinish = !completed
        stateLock.unlock()
        guard shouldFinish else { return }
        queue.async { [self] in
            for task in pendingTasks.values { task.cancel() }
            pendingTasks.removeAll()
            finish(.failure(error(for: reason)))
        }
    }

    private func start() {
        guard !isStopped else { finish(.failure(error(for: currentStopReason ?? .cancelled))); return }
        guard let context = JSContext() else {
            finish(.failure(WorkflowScriptRuntimeError.internalInvariant("JavaScriptCore context unavailable")))
            return
        }
        self.context = context
        context.exceptionHandler = { [weak self] _, value in
            guard let self else { return }
            let message = value?.toString() ?? "unknown JavaScript exception"
            self.finish(.failure(WorkflowScriptRuntimeError.invalidScript(Self.sanitize(message))))
        }
        let userFunction = context.evaluateScript(
            userFunctionSource(),
            withSourceURL: URL(string: "mobilellm-workflow://\(script.script.sourceDigest.rawValue).js")
        )
        guard let userFunction, !isCompleted else {
            if !isCompleted {
                let message = context.exception?.toString() ?? "workflow function compilation failed"
                finish(.failure(WorkflowScriptRuntimeError.invalidScript(Self.sanitize(message))))
            }
            return
        }
        // The user function is compiled as a distinct global lexical unit. It therefore cannot
        // close over any of the driver's native bridge variables. The temporary global is removed
        // before the function is invoked, along with every native callback.
        context.setObject(userFunction, forKeyedSubscript: "__mllmUserFunction" as NSString)
        installNativeBridge(in: context)
        let source = wrapperSource()
        let value = context.evaluateScript(
            source,
            withSourceURL: URL(string: "mobilellm-workflow-runtime://driver.js")
        )
        settleFunction = value?.forProperty("settle")
        if value == nil, !isCompleted {
            let message = context.exception?.toString() ?? "script evaluation returned no value"
            finish(.failure(WorkflowScriptRuntimeError.invalidScript(Self.sanitize(message))))
        }
    }

    private func installNativeBridge(in context: JSContext) {
        let checkpoint: @convention(block) () -> Bool = { [weak self] in
            guard let self else { return false }
            stateLock.lock()
            defer { stateLock.unlock() }
            if stopReason != nil { return false }
            if DispatchTime.now().uptimeNanoseconds >= deadline {
                stopReason = .timedOut
                return false
            }
            scriptSteps &+= 1
            if scriptSteps > limits.maximumScriptSteps {
                stopReason = .stepLimit
                return false
            }
            return true
        }
        let stopCode: @convention(block) () -> String = { [weak self] in
            guard let reason = self?.currentStopReason else { return "cancelled" }
            switch reason {
            case .cancelled: return "cancelled"
            case .timedOut: return "timedOut"
            case .stepLimit: return "stepLimit"
            }
        }
        let phase: @convention(block) (String) -> Void = { [host] value in host.phase(value) }
        let log: @convention(block) (String) -> Void = { [host] value in host.log(value) }
        let collectionAllowed: @convention(block) (Int32) -> Bool = { [limits] count in
            count >= 0 && UInt32(count) <= limits.maximumCollectionItems
        }
        let serializedEstimateAllowed: @convention(block) (Double) -> Bool = { [limits] estimate in
            estimate.isFinite && estimate >= 0
                && estimate <= Double(limits.maximumSerializedValueBytes)
        }
        let budgetTotal: @convention(block) () -> Double = { [host] in
            host.budget().totalOutputTokens.map { Double($0) } ?? -1
        }
        let budgetSpent: @convention(block) () -> Double = { [host] in
            Double(host.budget().spentOutputTokens)
        }
        let startAgent: @convention(block) (Int32, Int32, String, String, Bool) -> Void = {
            [weak self] requestID, sequence, prompt, optionsJSON, detached in
            self?.startAgent(
                requestID: requestID,
                sequence: sequence,
                prompt: prompt,
                optionsJSON: optionsJSON,
                detached: detached
            )
        }
        let startWorkflow: @convention(block) (Int32, String, String) -> Void = {
            [weak self] requestID, name, argsJSON in
            self?.startSavedWorkflow(requestID: requestID, name: name, argsJSON: argsJSON)
        }
        let startEvidence: @convention(block) (Int32, String) -> Void = { [weak self] requestID, query in
            self?.startEvidence(requestID: requestID, query: query)
        }
        let startBudgetSnapshot: @convention(block) (Int32) -> Void = { [weak self] requestID in
            self?.startBudgetSnapshot(requestID: requestID)
        }
        let startWait: @convention(block) (Int32, Int32, String) -> Void = { [weak self] requestID, index, ordinals in
            self?.startWait(requestID: requestID, index: index, ordinals: ordinals)
        }
        let finished: @convention(block) (Bool, String) -> Void = { [weak self] succeeded, payload in
            self?.scriptFinished(succeeded: succeeded, payload: payload)
        }

        context.setObject(checkpoint, forKeyedSubscript: "__mllmCheckpoint" as NSString)
        context.setObject(stopCode, forKeyedSubscript: "__mllmStopCode" as NSString)
        context.setObject(phase, forKeyedSubscript: "__mllmPhase" as NSString)
        context.setObject(log, forKeyedSubscript: "__mllmLog" as NSString)
        context.setObject(collectionAllowed, forKeyedSubscript: "__mllmCollectionAllowed" as NSString)
        context.setObject(
            serializedEstimateAllowed,
            forKeyedSubscript: "__mllmSerializedEstimateAllowed" as NSString
        )
        context.setObject(budgetTotal, forKeyedSubscript: "__mllmBudgetTotal" as NSString)
        context.setObject(budgetSpent, forKeyedSubscript: "__mllmBudgetSpent" as NSString)
        context.setObject(startAgent, forKeyedSubscript: "__mllmStartAgent" as NSString)
        context.setObject(startWorkflow, forKeyedSubscript: "__mllmStartWorkflow" as NSString)
        context.setObject(startEvidence, forKeyedSubscript: "__mllmStartEvidence" as NSString)
        context.setObject(startBudgetSnapshot, forKeyedSubscript: "__mllmStartBudgetSnapshot" as NSString)
        context.setObject(startWait, forKeyedSubscript: "__mllmStartWait" as NSString)
        context.setObject(finished, forKeyedSubscript: "__mllmFinished" as NSString)
    }

    private func userFunctionSource() -> String {
        """
        (async function(agent, parallel, pipeline, workflow, phase, log, serialize, unique, webEvidence, args, budget, console, spawn, waitAny,
                        __workflowCheckpoint) {
        'use strict';
        \(script.instrumentedSource)
        })
        """
    }

    private func wrapperSource() -> String {
        let encodedArgs = args?.string ?? "null"
        let argsLiteral = Self.javaScriptStringLiteral(encodedArgs)
        return """
        (function() {
          'use strict';
          const __checkpointNative = globalThis.__mllmCheckpoint;
          const __stopCodeNative = globalThis.__mllmStopCode;
          const __phaseNative = globalThis.__mllmPhase;
          const __logNative = globalThis.__mllmLog;
          const __collectionAllowedNative = globalThis.__mllmCollectionAllowed;
          const __serializedEstimateAllowedNative = globalThis.__mllmSerializedEstimateAllowed;
          const __budgetTotalNative = globalThis.__mllmBudgetTotal;
          const __budgetSpentNative = globalThis.__mllmBudgetSpent;
          const __startAgentNative = globalThis.__mllmStartAgent;
          const __startWorkflowNative = globalThis.__mllmStartWorkflow;
          const __startEvidenceNative = globalThis.__mllmStartEvidence;
          const __startBudgetSnapshotNative = globalThis.__mllmStartBudgetSnapshot;
          const __startWaitNative = globalThis.__mllmStartWait;
          const __finishedNative = globalThis.__mllmFinished;
          const __userFunction = globalThis.__mllmUserFunction;
          for (const __name of ['__mllmCheckpoint','__mllmStopCode','__mllmPhase','__mllmLog',
            '__mllmCollectionAllowed','__mllmSerializedEstimateAllowed','__mllmBudgetTotal','__mllmStartEvidence',
            '__mllmBudgetSpent','__mllmStartAgent','__mllmStartWorkflow','__mllmFinished',
            '__mllmUserFunction','__mllmStartBudgetSnapshot','__mllmStartWait']) { try { delete globalThis[__name]; } catch (_) {} }

          const __RealJSON = JSON;
          const __RealJSONParse = __RealJSON.parse.bind(__RealJSON);
          const __RealJSONStringify = __RealJSON.stringify.bind(__RealJSON);
          const __RealPromise = Promise;
          const __RealMap = Map;
          const __RealRegExpPrototype = RegExp.prototype;
          const __RealObjectPrototype = Object.prototype;
          const __RealArrayPrototype = Array.prototype;
          const __RealFunctionPrototype = Function.prototype;
          const __pending = new __RealMap();
          let __requestID = 1;
          let __agentSequence = 1;
          let __currentPhase;
          const __checkpoint = () => {
            if (!__checkpointNative()) {
              const __error = new Error('__MOBILELLM_WORKFLOW_STOP__:' + __stopCodeNative());
              __error.__workflowFatal = true;
              throw __error;
            }
          };
          const __settle = (id, ok, payload, fatal) => {
            const waiter = __pending.get(id);
            if (!waiter) return;
            __pending.delete(id);
            if (ok) {
              try { waiter.resolve(__RealJSONParse(payload)); }
              catch (error) { waiter.reject(error); }
            } else {
              const error = new Error(String(payload));
              error.__workflowFatal = Boolean(fatal);
              waiter.reject(error);
            }
          };
          const __request = (nativeStart, values) => new __RealPromise((resolve, reject) => {
            __checkpoint();
            const id = __requestID++;
            __pending.set(id, { resolve, reject });
            try { nativeStart(id, ...values); }
            catch (error) { __pending.delete(id); reject(error); }
          });
          const __validationError = detail => {
            const error = new Error('__MOBILELLM_WORKFLOW_ERROR__|invalidResult|' + detail);
            error.__workflowFatal = true;
            return error;
          };
          const __validateJSONValue = root => {
            const active = new __RealMap();
            const stack = [{ value: root, exiting: false, depth: 0 }];
            let nodes = 0;
            let estimate = 0;
            const addEstimate = amount => {
              estimate += amount;
              if (!__serializedEstimateAllowedNative(estimate)) {
                throw __validationError('serialized value exceeds the configured limit');
              }
            };
            while (stack.length > 0) {
              __checkpoint();
              const entry = stack.pop();
              const value = entry.value;
              if (entry.exiting) { active.delete(value); continue; }
              nodes += 1;
              if (!__collectionAllowedNative(nodes)) {
                throw __validationError('serialized value exceeds the node limit');
              }
              if (value === null) { addEstimate(4); continue; }
              const type = typeof value;
              if (type === 'string') { addEstimate(2 + value.length * 6); continue; }
              if (type === 'boolean') { addEstimate(5); continue; }
              if (type === 'number') {
                if (!Number.isFinite(value)) throw __validationError('non-finite number');
                addEstimate(32);
                continue;
              }
              if (type !== 'object') throw __validationError('value is not JSON serializable');
              if (entry.depth > 64) throw __validationError('value nesting exceeds the limit');
              if (active.has(value)) throw __validationError('cyclic value');
              active.set(value, true);
              stack.push({ value, exiting: true, depth: entry.depth });
              if (Array.isArray(value)) {
                if (!__collectionAllowedNative(value.length)) {
                  throw __validationError('array exceeds the collection limit');
                }
                addEstimate(2 + value.length);
                for (let index = value.length - 1; index >= 0; index -= 1) {
                  stack.push({ value: value[index], exiting: false, depth: entry.depth + 1 });
                }
              } else {
                if (Object.prototype.hasOwnProperty.call(value, 'toJSON')) {
                  throw __validationError('custom JSON serialization is unavailable');
                }
                const keys = Object.keys(value);
                if (!__collectionAllowedNative(keys.length)) {
                  throw __validationError('object exceeds the collection limit');
                }
                addEstimate(2 + keys.length);
                for (let index = keys.length - 1; index >= 0; index -= 1) {
                  const key = keys[index];
                  addEstimate(3 + key.length * 6);
                  stack.push({ value: value[key], exiting: false, depth: entry.depth + 1 });
                }
              }
            }
          };
          const __stringify = value => {
            __validateJSONValue(value);
            const encoded = __RealJSONStringify(value);
            if (encoded === undefined) throw new Error('value is not JSON serializable');
            return encoded;
          };
          const __safeMessage = error => error && error.message ? String(error.message) : String(error);
          const __recoverElement = error => {
            if (error && error.__workflowFatal) throw error;
            __logNative('workflow element failed: ' + __safeMessage(error));
            return null;
          };
          const agent = (prompt, options = {}) => {
            if (typeof prompt !== 'string' || prompt.trim().length === 0) {
              return __RealPromise.reject(new Error('agent prompt must be a non-empty string'));
            }
            const effective = { ...options };
            if (effective.phase === undefined && __currentPhase !== undefined) effective.phase = __currentPhase;
            return __request(__startAgentNative, [__agentSequence++, prompt, __stringify(effective), false]);
          };
          const __spawned = new __RealMap();
          let __waitSequence = 1;
          let __waiting = false;
          const spawn = (prompt, options = {}) => {
            if (typeof prompt !== 'string' || prompt.trim().length === 0) throw new Error('spawn requires a prompt');
            const sequence = __agentSequence++;
            const effective = { ...options };
            if (effective.phase === undefined && __currentPhase !== undefined) effective.phase = __currentPhase;
            __spawned.set(sequence, true);
            __request(__startAgentNative, [sequence, prompt, __stringify(effective), true]).catch(() => null);
            return sequence;
          };
          const waitAny = handles => {
            if (__waiting || !Array.isArray(handles) || handles.length === 0 || !__collectionAllowedNative(handles.length)
                || handles.some(h => !__spawned.has(h))) throw new Error('waitAny requires outstanding handles and one active wait');
            __waiting = true;
            return __request(__startWaitNative, [__waitSequence++, __stringify(handles)]).then(result => {
              __waiting = false;
              __spawned.delete(result.handle);
              return result;
            }, error => { __waiting = false; throw error; });
          };
          const parallel = thunks => {
            if (!Array.isArray(thunks) || !__collectionAllowedNative(thunks.length)) {
              const error = new Error('__MOBILELLM_WORKFLOW_ERROR__|collectionLimitExceeded|parallel input exceeds the collection limit');
              error.__workflowFatal = true;
              throw error;
            }
            for (const thunk of thunks) if (typeof thunk !== 'function') throw new Error('parallel expects thunks');
            return __RealPromise.all(thunks.map(thunk => __RealPromise.resolve().then(thunk).catch(__recoverElement)));
          };
          const pipeline = (items, ...stages) => {
            if (!Array.isArray(items) || !__collectionAllowedNative(items.length)) {
              const error = new Error('__MOBILELLM_WORKFLOW_ERROR__|collectionLimitExceeded|pipeline input exceeds the collection limit');
              error.__workflowFatal = true;
              throw error;
            }
            for (const stage of stages) if (typeof stage !== 'function') throw new Error('pipeline expects functions');
            return __RealPromise.all(items.map((item, index) => (async () => {
              let value = item;
              for (const stage of stages) {
                __checkpoint();
                try { value = await stage(value, item, index); }
                catch (error) { return __recoverElement(error); }
              }
              return value;
            })()));
          };
          const phase = title => {
            if (typeof title !== 'string' || title.trim().length === 0) throw new Error('phase title is required');
            __currentPhase = title;
            __phaseNative(title);
          };
          const log = value => __logNative(typeof value === 'string' ? value : __stringify(value));
          // Public bounded structured handoff. Unlike JSON.stringify/Array.join, this route runs
          // the checkpointed node/depth/collection/size validator before the native serializer.
          const serialize = value => __stringify(value);
          // String sets are bounded and checkpointed. Do not use a user-provided iterator/getter,
          // or a model-written character-by-character comparison of multi-character identifiers.
          const unique = values => {
            __checkpoint();
            if (!Array.isArray(values) || !__collectionAllowedNative(values.length)) {
              throw __validationError('unique requires a bounded array of strings');
            }
            const seen = new __RealMap();
            const result = [];
            let bytes = 2;
            for (let i = 0; i < values.length; i++) {
              __checkpoint();
              const entry = Object.getOwnPropertyDescriptor(values, i);
              if (!entry || typeof entry.value !== 'string') throw __validationError('unique accepts string values only');
              bytes += 3 + entry.value.length * 6;
              if (!__serializedEstimateAllowedNative(bytes)) throw __validationError('unique input exceeds size limit');
              if (!seen.has(entry.value)) { seen.set(entry.value, true); result.push(entry.value); }
            }
            return result;
          };
          const webEvidence = (query = '') => {
            if (typeof query !== 'string' || query.length > 24000) throw new Error('webEvidence query must be bounded text');
            return __request(__startEvidenceNative, [query]);
          };
          const workflow = (name, value) => {
            if (typeof name !== 'string' || name.trim().length === 0) {
              return __RealPromise.reject(new Error('workflow name is required'));
            }
            return __request(__startWorkflowNative, [name, __stringify(value === undefined ? null : value)]);
          };
          const budget = Object.freeze({
            snapshot: () => __request(__startBudgetSnapshotNative, []),
            get total() { const value = __budgetTotalNative(); return value < 0 ? null : value; },
            spent: () => __budgetSpentNative(),
            remaining: () => { const total = __budgetTotalNative(); return total < 0 ? Infinity : Math.max(0, total - __budgetSpentNative()); },
          });
          const args = (() => {
            const parsed = __RealJSONParse(\(argsLiteral));
            __validateJSONValue(parsed);
            const freeze = value => {
              if (value && typeof value === 'object' && !Object.isFrozen(value)) {
                for (const key of Object.keys(value)) freeze(value[key]);
                Object.freeze(value);
              }
              return value;
            };
            return freeze(parsed);
          })();
          const console = Object.freeze({ log, info: log, warn: log, error: log, debug: log });

          // Remove code generation and nondeterministic/host capabilities after capturing the bridge.
          const __poisonConstructor = value => {
            try { Object.defineProperty(value, 'constructor', { value: undefined, writable: false, configurable: false }); } catch (_) {}
          };
          __poisonConstructor(__RealFunctionPrototype);
          __poisonConstructor(__RealObjectPrototype);
          __poisonConstructor(__RealArrayPrototype);
          __poisonConstructor(Object.getPrototypeOf(async function() {}));
          __poisonConstructor(Object.getPrototypeOf(function*() {}));
          __poisonConstructor(Object.getPrototypeOf(async function*() {}));
          for (const __name of ['eval','Function','WebAssembly','RegExp','fetch','XMLHttpRequest','process','Deno','Bun',
            'window','document','navigator','location','Worker','SharedWorker','SharedArrayBuffer','Atomics',
            'setTimeout','setInterval','setImmediate','queueMicrotask','Date','Temporal','performance','crypto',
            'Reflect','Proxy','ArrayBuffer','BigInt','Symbol','WeakRef','FinalizationRegistry']) {
            try { Object.defineProperty(globalThis, __name, { value: undefined, writable: false, configurable: false }); } catch (_) {}
          }
          const __disable = (target, names) => {
            for (const name of names) {
              try { Object.defineProperty(target, name, { value: undefined, writable: false, configurable: false }); } catch (_) {}
            }
          };
          __disable(String.prototype, ['repeat','padStart','padEnd','match','matchAll','search','replace','replaceAll','split']);
          __disable(__RealArrayPrototype, ['fill','join','concat','flat','flatMap','copyWithin']);
          __disable(__RealRegExpPrototype, ['exec','test']);
          __disable(__RealJSON, ['stringify','parse']);
          __disable(Array, ['from']);
          __disable(Object, ['assign','fromEntries']);
          __disable(String, ['raw','fromCharCode','fromCodePoint']);
          try { Math.random = undefined; } catch (_) {}
          // Host bridge behavior must not be replaceable by the workflow between dispatch and
          // asynchronous settlement. Freeze every intrinsic the bridge continues to call.
          try { Object.freeze(__RealJSON); } catch (_) {}
          try { Object.freeze(Object); } catch (_) {}
          try { Object.freeze(Number); } catch (_) {}
          try { Object.freeze(String); } catch (_) {}
          try { Object.freeze(String.prototype); } catch (_) {}
          try { Object.freeze(Math); } catch (_) {}
          try { Object.freeze(__RealPromise); } catch (_) {}
          try { Object.freeze(__RealPromise.prototype); } catch (_) {}
          try { Object.freeze(__RealMap); } catch (_) {}
          try { Object.freeze(__RealMap.prototype); } catch (_) {}
          try { Object.freeze(__RealRegExpPrototype); } catch (_) {}
          try { Object.freeze(Array); } catch (_) {}
          Object.freeze(__RealObjectPrototype);
          Object.freeze(__RealArrayPrototype);
          Object.freeze(__RealFunctionPrototype);

          const __finishSuccess = value => {
            try { __finishedNative(true, __stringify(value === undefined ? null : value)); }
            catch (error) { __finishedNative(false, __safeMessage(error)); }
          };
          __userFunction(agent, parallel, pipeline, workflow, phase, log, serialize, unique, webEvidence, args, budget, console, spawn, waitAny,
                         __checkpoint).then(
            __finishSuccess,
            error => __finishedNative(false, __safeMessage(error))
          );
          return Object.freeze({ settle: __settle });
        }).call(undefined);
        """
    }

    private func startAgent(requestID: Int32, sequence: Int32, prompt: String, optionsJSON: String, detached: Bool) {
        guard pendingTasks[requestID] == nil, !isCompleted else { return }
        let task = Task { [weak self, host] in
            guard let self else { return }
            do {
                let options = try Self.decodeOptions(optionsJSON)
                // Chat instructions are canonical at the contract boundary. A generated prompt
                // often ends with a newline after its data delimiter; normalize before hashing,
                // journaling or building the child, while preserving all interior whitespace.
                let canonicalPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !canonicalPrompt.isEmpty else {
                    throw WorkflowScriptRuntimeError.invalidResult("agent prompt must be non-empty")
                }
                guard sequence > 0 else {
                    throw WorkflowScriptRuntimeError.internalInvariant("invalid agent sequence")
                }
                let result = try await host.agent(WorkflowAgentInvocation(
                    sequence: UInt32(sequence),
                    prompt: canonicalPrompt,
                    options: options,
                    deliversOnWait: detached
                ))
                guard !Task.isCancelled else { throw CancellationError() }
                switch result {
                case .value(let value):
                    try resolve(requestID: requestID, value: value)
                case .unavailable(let reason):
                    host.log("agent unavailable: \(Self.sanitize(reason))")
                    resolveNull(requestID: requestID)
                case .stopped:
                    resolveNull(requestID: requestID)
                }
            } catch is CancellationError {
                reject(requestID: requestID, error: .cancelled, fatal: true)
            } catch let error as WorkflowScriptRuntimeError {
                reject(requestID: requestID, error: error, fatal: true)
            } catch {
                let safeMessage = Self.sanitize(String(describing: error))
                // A script may intentionally catch a failed child. Keep the safe cause observable
                // even if its catch returns a generic message before a child handle was created.
                host.log("agent \(sequence) failed: \(safeMessage)")
                reject(
                    requestID: requestID,
                    error: .hostFailure(safeMessage),
                    fatal: true
                )
            }
        }
        pendingTasks[requestID] = task
    }

    private func startWait(requestID: Int32, index: Int32, ordinals: String) {
        guard pendingTasks[requestID] == nil, !isCompleted else { return }
        pendingTasks[requestID] = Task { [weak self, host] in
            guard let self else { return }
            do {
                guard index > 0 else { throw WorkflowScriptRuntimeError.invalidArguments("wait index") }
                let handles = try JSONDecoder().decode([UInt32].self, from: Data(ordinals.utf8))
                let result = try await host.waitAny(UInt32(index), handles)
                try Task.checkCancellation()
                try resolve(requestID: requestID, value: result)
            } catch is CancellationError {
                reject(requestID: requestID, error: .cancelled, fatal: true)
            } catch {
                reject(requestID: requestID, error: .hostFailure(Self.sanitize(String(describing: error))), fatal: true)
            }
        }
    }

    private func startBudgetSnapshot(requestID: Int32) {
        guard pendingTasks[requestID] == nil, !isCompleted else { return }
        pendingTasks[requestID] = Task { [weak self, host] in
            guard let self else { return }
            do {
                let value = try await host.settledBudget()
                try Task.checkCancellation()
                try resolve(requestID: requestID, value: value)
            } catch is CancellationError {
                reject(requestID: requestID, error: .cancelled, fatal: true)
            } catch {
                reject(requestID: requestID, error: .hostFailure(Self.sanitize(String(describing: error))), fatal: true)
            }
        }
    }

    private func startEvidence(requestID: Int32, query: String) {
        guard pendingTasks[requestID] == nil, !isCompleted else { return }
        pendingTasks[requestID] = Task { [weak self, host] in
            guard let self else { return }
            do {
                guard query.utf8.count <= 64 * 1024 else {
                    throw WorkflowScriptRuntimeError.invalidArguments("web evidence query exceeds 64 KiB")
                }
                let value = query.isEmpty ? try await host.webEvidence() : try await host.queryWebEvidence(query)
                try Task.checkCancellation()
                try resolve(requestID: requestID, value: value)
            } catch is CancellationError {
                reject(requestID: requestID, error: .cancelled, fatal: true)
            } catch {
                reject(requestID: requestID, error: .hostFailure(Self.sanitize(String(describing: error))), fatal: true)
            }
        }
    }

    private func startSavedWorkflow(requestID: Int32, name: String, argsJSON: String) {
        guard pendingTasks[requestID] == nil, !isCompleted else { return }
        guard let callSavedWorkflow = host.callSavedWorkflow else {
            reject(
                requestID: requestID,
                error: .hostFailure("saved workflow calls are unavailable"),
                fatal: true
            )
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let decoded = try CanonicalJSON(JSONDecoder().decode(JSONValue.self, from: Data(argsJSON.utf8)))
                let value = try await callSavedWorkflow(name, decoded)
                guard !Task.isCancelled else { throw CancellationError() }
                try resolve(requestID: requestID, value: value)
            } catch is CancellationError {
                reject(requestID: requestID, error: .cancelled, fatal: true)
            } catch {
                reject(
                    requestID: requestID,
                    error: .hostFailure(Self.sanitize(String(describing: error))),
                    fatal: true
                )
            }
        }
        pendingTasks[requestID] = task
    }

    private func resolve(requestID: Int32, value: JSONValue) throws {
        let canonical = try CanonicalJSON(value)
        guard canonical.data.count <= limits.maximumSerializedValueBytes else {
            throw WorkflowScriptRuntimeError.invalidResult("agent value exceeds the bridge limit")
        }
        settle(requestID: requestID, succeeded: true, payload: canonical.string, fatal: false)
    }

    private func resolveNull(requestID: Int32) {
        settle(requestID: requestID, succeeded: true, payload: "null", fatal: false)
    }

    private func reject(requestID: Int32, error: WorkflowScriptRuntimeError, fatal: Bool) {
        settle(
            requestID: requestID,
            succeeded: false,
            payload: Self.encodedBridgeError(error),
            fatal: fatal
        )
    }

    private func settle(requestID: Int32, succeeded: Bool, payload: String, fatal: Bool) {
        queue.async { [weak self] in
            guard let self, !isCompleted else { return }
            pendingTasks[requestID] = nil
            settleFunction?.call(withArguments: [requestID, succeeded, payload, fatal])
        }
    }

    private func scriptFinished(succeeded: Bool, payload: String) {
        guard !isCompleted else { return }
        if succeeded {
            do {
                let data = Data(payload.utf8)
                guard data.count <= limits.maximumSerializedValueBytes else {
                    throw WorkflowScriptRuntimeError.invalidResult("final value exceeds the bridge limit")
                }
                let value = try JSONDecoder().decode(JSONValue.self, from: data)
                finish(.success(try CanonicalJSON(value)))
            } catch let error as WorkflowScriptRuntimeError {
                finish(.failure(error))
            } catch {
                finish(.failure(.invalidResult(Self.sanitize(String(describing: error)))))
            }
        } else if let reason = currentStopReason {
            finish(.failure(error(for: reason)))
        } else if let error = Self.decodedBridgeError(payload) {
            finish(.failure(error))
        } else {
            finish(.failure(.invalidScript(Self.sanitize(payload))))
        }
    }

    private static let bridgeErrorPrefix = "__MOBILELLM_WORKFLOW_ERROR__|"

    private static func encodedBridgeError(_ error: WorkflowScriptRuntimeError) -> String {
        let code: String
        let detail: String
        switch error {
        case .unsupportedRequirement: (code, detail) = ("unsupportedRequirement", error.description)
        case .invalidScript(let value): (code, detail) = ("invalidScript", value)
        case .invalidArguments(let value): (code, detail) = ("invalidArguments", value)
        case .invalidAgentOptions(let value): (code, detail) = ("invalidAgentOptions", value)
        case .invalidResult(let value): (code, detail) = ("invalidResult", value)
        case .collectionLimitExceeded: (code, detail) = ("collectionLimitExceeded", error.description)
        case .stepLimitExceeded: (code, detail) = ("stepLimitExceeded", error.description)
        case .timedOut: (code, detail) = ("timedOut", error.description)
        case .cancelled: (code, detail) = ("cancelled", error.description)
        case .hostFailure(let value): (code, detail) = ("hostFailure", value)
        case .internalInvariant(let value): (code, detail) = ("internalInvariant", value)
        }
        return bridgeErrorPrefix + code + "|" + sanitize(detail)
    }

    private static func decodedBridgeError(_ payload: String) -> WorkflowScriptRuntimeError? {
        guard payload.hasPrefix(bridgeErrorPrefix) else { return nil }
        let remainder = payload.dropFirst(bridgeErrorPrefix.count)
        let fields = remainder.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard fields.count == 2 else {
            return .internalInvariant("malformed workflow bridge error")
        }
        let detail = sanitize(String(fields[1]))
        switch fields[0] {
        case "unsupportedRequirement": return .unsupportedRequirement
        case "invalidScript": return .invalidScript(detail)
        case "invalidArguments": return .invalidArguments(detail)
        case "invalidAgentOptions": return .invalidAgentOptions(detail)
        case "invalidResult": return .invalidResult(detail)
        case "collectionLimitExceeded": return .collectionLimitExceeded
        case "stepLimitExceeded": return .stepLimitExceeded
        case "timedOut": return .timedOut
        case "cancelled": return .cancelled
        case "hostFailure": return .hostFailure(detail)
        case "internalInvariant": return .internalInvariant(detail)
        default: return .internalInvariant("unknown workflow bridge error")
        }
    }

    private func finish(_ result: Result<CanonicalJSON, WorkflowScriptRuntimeError>) {
        stateLock.lock()
        guard !completed else { stateLock.unlock(); return }
        completed = true
        let continuation = self.continuation
        self.continuation = nil
        stateLock.unlock()

        watchdog?.cancel()
        watchdog = nil
        let outstanding = Array(pendingTasks.values)
        for task in outstanding { task.cancel() }
        pendingTasks.removeAll()
        context?.exceptionHandler = nil
        settleFunction = nil
        context = nil
        Task {
            // A workflow is not settled until every un-awaited bridge call has observed
            // cancellation. This prevents detached durable children from escaping the run.
            for task in outstanding { await task.value }
            switch result {
            case .success(let value): continuation?.resume(returning: value)
            case .failure(let error): continuation?.resume(throwing: error)
            }
        }
    }

    private var isStopped: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return stopReason != nil
    }

    private var isCompleted: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return completed
    }

    private var currentStopReason: StopReason? {
        stateLock.lock(); defer { stateLock.unlock() }
        return stopReason
    }

    private func error(for reason: StopReason) -> WorkflowScriptRuntimeError {
        switch reason {
        case .cancelled: .cancelled
        case .timedOut: .timedOut
        case .stepLimit: .stepLimitExceeded
        }
    }

    private static func decodeOptions(_ source: String) throws -> WorkflowAgentOptionsV1 {
        let value: JSONValue
        do { value = try JSONDecoder().decode(JSONValue.self, from: Data(source.utf8)) }
        catch { throw WorkflowScriptRuntimeError.invalidAgentOptions("options must be JSON") }
        guard case .object(let object) = value else {
            throw WorkflowScriptRuntimeError.invalidAgentOptions("options must be an object")
        }
        let unknown = Set(object.keys).subtracting(WorkflowAgentOptionContract.allowedKeys).sorted()
        guard unknown.isEmpty else {
            throw WorkflowScriptRuntimeError.invalidAgentOptions(
                "unknown option: \(unknown.joined(separator: ", "))"
            )
        }
        let schema: JSONSchemaDocument?
        if let root = object["schema"] {
            do { schema = try JSONSchemaDocument(root: root) }
            catch { throw WorkflowScriptRuntimeError.invalidAgentOptions("schema is not fully supported") }
        } else { schema = nil }
        let isolation = try optionalString(object["isolation"], field: "isolation")
        guard isolation == nil
            || isolation.map(WorkflowAgentOptionContract.supportedIsolationValues.contains) == true
        else {
            throw WorkflowScriptRuntimeError.invalidAgentOptions("unsupported isolation")
        }
        let stall: UInt64?
        switch object["stallMs"] {
        case nil: stall = nil
        case .integer(let value) where value >= 0: stall = UInt64(value)
        case .unsignedInteger(let value): stall = value
        default: throw WorkflowScriptRuntimeError.invalidAgentOptions("stallMs must be a nonnegative integer")
        }
        let maximumToolCalls: UInt64?
        switch object["maxToolCalls"] {
        case nil: maximumToolCalls = nil
        case .integer(let value) where value >= 0: maximumToolCalls = UInt64(value)
        case .unsignedInteger(let value): maximumToolCalls = value
        default: throw WorkflowScriptRuntimeError.invalidAgentOptions("maxToolCalls must be a nonnegative integer")
        }
        do {
            let task = try object["task"].map {
                try JSONDecoder().decode(WorkflowTaskDescriptorV1.self, from: CanonicalJSON($0).data)
            }
            return try WorkflowAgentOptionsV1(
                label: try optionalString(object["label"], field: "label"),
                phase: try optionalString(object["phase"], field: "phase"),
                schema: schema,
                requestedModel: try optionalString(object["model"], field: "model"),
                requestedAgentType: try optionalString(object["agentType"], field: "agentType"),
                requiresIsolatedWorkspace: isolation != nil,
                stallMilliseconds: stall,
                maximumToolCalls: maximumToolCalls,
                task: task,
                sessionKey: try optionalString(object["session"], field: "session")
            )
        } catch {
            throw WorkflowScriptRuntimeError.invalidAgentOptions(Self.sanitize(String(describing: error)))
        }
    }

    private static func optionalString(_ value: JSONValue?, field: String) throws -> String? {
        switch value {
        case nil: nil
        case .string(let value): value
        default: throw WorkflowScriptRuntimeError.invalidAgentOptions("\(field) must be a string")
        }
    }

    private static func javaScriptStringLiteral(_ value: String) -> String {
        let data = try! JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    private static func sanitize(_ value: String) -> String {
        String(value.unicodeScalars.filter { $0.value >= 0x20 || $0 == "\n" || $0 == "\t" }.prefix(2_048))
    }
}
