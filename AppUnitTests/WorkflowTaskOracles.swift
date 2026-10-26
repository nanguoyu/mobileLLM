// SPDX-License-Identifier: MIT

import Foundation
import SQLite3

/// Task outputs are checked by executable invariants, independently of the model's self-assessment.
/// SQL runs only in an in-memory database with file attachment, extensions and unsafe pragmas denied.
enum WorkflowLiveCase: String {
    case migration, rollout, incident, research, correction, longContext, formatting, reservation, website

    var goal: String {
        switch self {
        case .website:
            return "开发一个中餐馆网站，支持在线订台。"
        case .reservation:
            return """
            为一家中餐馆制定今晚的订台安排并核对订金。营业时间 18:00–22:00，T1 为 2 人桌，T2 为 4 人桌，T3 为 6 人桌，不能拼桌。
            按以下请求顺序处理，每次选择全时段可用且足够大的最小桌型，相同桌型按桌号排序。预约时段左闭右开。
            A：2 人，18:00–19:30；B：4 人，18:00–19:30；C：6 人，18:00–19:30；D：3 人，19:00–20:00；
            E：6 人，19:30–21:00；F：6 人，21:00–22:30。营业时间内无合适空桌则 waitlist，超出营业时间则 rejected，其余 confirmed。
            已分配的桌位不能被后来请求挤占。仅 confirmed 按每人 5 欧元收订金，用计算器核对总额。
            只返回 JSON，字段为 allocations（按请求顺序，每项 id、status、tableID，未确认的 tableID 为 null）、depositEUR 和 explanation。
            """
        case .migration:
            return """
            Deliver a production SQLite 3.45+ migration script for this legacy help-desk database.
            Existing schema, with foreign_keys=ON:
            CREATE TABLE contacts(id INTEGER PRIMARY KEY, tenant_id INTEGER NOT NULL,
              email TEXT, display_name TEXT NOT NULL, updated_at INTEGER NOT NULL);
            CREATE TABLE tickets(id INTEGER PRIMARY KEY, contact_id INTEGER NOT NULL
              REFERENCES contacts(id), subject TEXT NOT NULL);
            Legacy contacts may duplicate an email within one tenant. Identity is tenant_id plus
            lower(trim(email)), where trim removes ordinary ASCII spaces. Missing means email IS NULL or
            trim(email)='': this includes empty strings and all-space strings. Preserve each missing
            contact separately and normalize its email to NULL.
            For each nonmissing duplicate identity, keep the row with greatest updated_at, breaking
            ties by greatest id. Preserve that winner's id, display_name, tenant_id and updated_at.
            Repoint every ticket to the winning contact before deleting losers. Preserve all ticket
            IDs and subjects. Normalize retained nonmissing emails. Enforce this same normalized
            uniqueness rule for FUTURE INSERTs and UPDATEs, without merging across tenants or making
            missing emails unique. Add a unique index, without triggers or rebuilding the tables.
            Never disable foreign-key enforcement.
            The script must be atomic, including creation of the uniqueness constraint. If a statement
            fails before COMMIT the transaction must still be rollbackable. Running the script twice
            must produce the same data and constraints. Do not assume a particular row count or IDs.
            Organize the work in dependent stages: have independent agents analyze data/FK invariants
            and transaction/retry hazards; use their findings for an implementation agent; then have
            a separate agent inspect that candidate for concrete counterexamples before delivery.
            Correct any issue they identify within this run. You do not have a SQL execution tool,
            so do not claim execution; deliver the script for an external SQLite evaluator.
            Return ONLY JSON: {"marker":"EVAL_MIGRATION","sql":"complete script", "rationale":"..."}.
            """
        case .rollout:
            return """
            Create an executable maintenance staffing plan and then adapt it to a resource outage.
            Time is integer hours from zero. Tasks cannot be split. Each task occupies its stated
            resource for its entire duration. One DB engineer, one App engineer and one QA engineer
            are available, each doing at most one task at a time. All dependencies must finish first.
            Tasks (ID, duration, resource, dependencies):
            A,3,DB,none (snapshot); B,2,App,none (warm pool); C,2,DB,A (schema change);
            D,2,App,B+C (API rollout); E,4,DB,C (backfill); F,2,DB,E (index build);
            G,3,QA,D+E (end-to-end verification); H,1,App,F+G (cutover).
            Labor rates are DB=100, App=80, QA=60 EUR/hour. Only active task time is billed, not idle
            or outage time. Total labor must stay within EUR1800. Use the Calculator tool for the cost.
            First minimize baseline makespan. Then the App engineer becomes unavailable in [5,8);
            adapt the ACTUAL baseline schedule, first minimizing revised makespan, then minimizing
            the number of tasks whose start time changes. Half-open intervals sharing an endpoint
            do not overlap. Give a valid lower bound proving each makespan optimal.
            Use independent scheduling and resource/cost agents first. Once their results exist,
            delegate the outage adaptation using that baseline to another agent. Have a later agent
            verify the proposed schedules, changes and constraints, and repair errors before delivery.
            Return ONLY JSON with marker="EVAL_ROLLOUT", baseline and revised objects containing
            makespan and tasks (array of {id,start,end,resource}), changedStartIDs, laborCostEUR,
            lowerBounds={baseline:...,outage:...}, and explanation.
            """
        case .research: return researchGoal(heldOut: false)
        case .correction: return correctionGoal(heldOut: false)
        case .longContext: return longContextGoal
        case .formatting:
            return "Design an offline museum collection catalogue. Use separate storage and export agents, then an integration agent using both results, then an independent reviewer. Preserve stable object IDs, provenance notes and photos. Export JSON and CSV. No web research or code execution. Keep each worker under 120 words and the final plan under 160 words."
        case .incident:
            return """
            Analyze this distributed-job recovery incident and deliver an implementable decision table.
            Contract: the provider deduplicates requests with the same idempotency key ONLY for 24 hours.
            It supports lookup by that key during that period. Different keys may create different effects.
            Without a durable provider key/result, local state cannot reveal whether a sent request took effect.
            Events: E1 local outbox durably records logical job J, stable key K and payload hash H.
            E2 worker W1 records dispatch intent and sends the request. E3 the connection times out;
            no acknowledgement/result is committed locally. E4 W1's local lease expires. E5 worker W2
            sends the same logical job using NEW key K2. E6 the trace ends. No provider execution logs,
            accepted-write records or lookup results are available. Both sends are observed; effects are not.
            Assess these claims with supported/refuted/unknown, using only the supplied evidence:
            C1: two send attempts happened; C2: two external writes definitely happened;
            C3: expiry of a local lease proves W1's remote operation did not happen;
            C4: changing K to K2 can bypass the provider's same-key deduplication;
            C5: a local fencing token alone guarantees exactly-once external effects under this contract.
            Design recovery actions for these cases. Return exactly one action per case from
            dispatch_new, retry_same_key, reconcile, reuse_result, reject_conflict:
            R1: durable evidence proves no dispatch occurred yet, with no competing owner.
            R2: a request was sent and timed out; original key and identical payload are durable;
                provider deduplication/lookup window is still valid.
            R3: request sent with unknown result, but provider supports neither deduplication nor lookup.
            R4: same logical job already has a durable successful result matching the payload.
            R5: a duplicate logical job arrives with a different payload hash.
            R6: sent request has unknown result; its old provider deduplication window has expired.
            The retry_same_key action means an idempotent resubmission with the ORIGINAL key and payload,
            optionally preceded by lookup. reconcile means stop automatic resubmission and establish the
            external outcome or seek an explicit resolution; it never means assume failure and repeat.
            Use separate event-evidence and protocol-safety agents, then a designer consuming those
            findings, followed by an independent counterexample check of the actual candidate.
            This is diagnosis/design, not authorization to send any request or modify a real service.
            Return ONLY JSON with marker="EVAL_RECOVERY", claims (array {id,verdict,evidence}),
            recovery (array {id,action,reason}), and safeguards (array of concrete implementation steps).
            """
        }
    }

    var usesCalculator: Bool { self == .rollout || self == .reservation }
    var requiresStages: Bool { self != .reservation && self != .website }

    func verify(_ value: [String: Any], heldOut: Bool = false) throws -> [String] {
        switch self {
        case .reservation: return ReservationOracle.verify(value)
        case .website: return ["Website delivery is checked against the unavailable execution capability"]
        case .migration:
            guard value["marker"] as? String == "EVAL_MIGRATION", let sql = value["sql"] as? String, !sql.isEmpty else {
                return ["Missing migration JSON/script"]
            }
            return try MigrationOracle.verify(sql, newest: !heldOut)
        case .rollout: return rolloutFailures(value, heldOut: heldOut)
        case .incident: return incidentFailures(value, heldOut: heldOut)
        case .research: return researchFailures(value, heldOut: heldOut)
        case .correction: return correctionFailures(value, heldOut: heldOut)
        case .longContext: return longContextFailures(value, heldOut: heldOut)
        case .formatting: return ["This case requires plain-text output checking"]
        }
    }

    private func rolloutFailures(_ value: [String: Any], heldOut: Bool) -> [String] {
        let duration = ["A":3,"B":2,"C":2,"D":2,"E":4,"F":2,"G":3,"H":1]
        let resource = ["A":"DB","B":"App","C":"DB","D":"App","E":"DB","F":"DB","G":"QA","H":"App"]
        let dependencies = ["A":[],"B":[],"C":["A"],"D":["B","C"],"E":["C"],"F":["E"],"G":["D","E"],"H":["F","G"]]
        var starts: [String: [String: Int]] = [:]
        for (name, optimum) in [("baseline",13),("revised",heldOut ? 17 : 14)] {
            guard let plan = value[name] as? [String: Any], plan["makespan"] as? Int == optimum,
                  let rows = plan["tasks"] as? [[String: Any]], rows.count == duration.count else { return ["\(name): missing optimum or tasks"] }
            var byID: [String: (start:Int,end:Int,resource:String)] = [:]
            for row in rows {
                guard let id = row["id"] as? String, byID[id] == nil, let length = duration[id],
                      let start = row["start"] as? Int, let end = row["end"] as? Int,
                      start >= 0, end-start == length, let worker = row["resource"] as? String,
                      worker == resource[id] else { return ["\(name): invalid, duplicate or misassigned task"] }
                byID[id] = (start,end,worker)
            }
            for (id,item) in byID {
                for dependency in dependencies[id] ?? [] where (byID[dependency]?.end ?? Int.max) > item.start {
                    return ["\(name): dependency violated by \(id)"]
                }
                for (otherID,other) in byID where otherID != id && other.resource == item.resource {
                    if item.start < other.end && other.start < item.end { return ["\(name): resource overlap"] }
                }
                if name == "revised", item.resource == (heldOut ? "QA" : "App"), item.start < (heldOut ? 13 : 8), item.end > (heldOut ? 10 : 5) { return ["Revised plan works through the outage"] }
            }
            guard byID.values.map(\.end).max() == optimum else { return ["\(name): makespan differs from schedule"] }
            starts[name] = byID.mapValues(\.start)
        }
        let changed = Set((starts["baseline"] ?? [:]).keys.filter { starts["baseline"]?[$0] != starts["revised"]?[$0] })
        guard changed == (heldOut ? ["G","H"] : ["D","G","H"]), let reported = value["changedStartIDs"] as? [String],
              reported.count == changed.count, Set(reported) == changed else { return ["Rescheduling is not minimally disruptive or changed-task list is wrong"] }
        // The prompt asks for a lower-bound proof, without requiring a scalar JSON field.
        // Feasibility and the exact optimum above are checked independently of this explanation.
        let bounds = value["lowerBounds"] as? [String: Any] ?? [:]
        func reports(_ key: String, _ expected: Int) -> Bool {
            if let number = bounds[key] as? Int { return number == expected }
            guard let proof = bounds[key] as? String, proof.count >= 20 else { return false }
            return proof.range(of: "(?<![0-9])" + String(expected) + "(?![0-9])", options: .regularExpression) != nil
        }
        guard value["marker"] as? String == "EVAL_ROLLOUT", value["laborCostEUR"] as? Int == (heldOut ? 1605 : 1680),
              reports("baseline", 13), reports("outage", heldOut ? 17 : 14) else {
            return ["Cost or optimality bound is wrong"]
        }
        return []
    }

    private func incidentFailures(_ value: [String: Any], heldOut: Bool) -> [String] {
        let claims = ["C1":"supported","C2":heldOut ? "refuted" : "unknown","C3":"refuted","C4":"supported","C5":"refuted"]
        let actions = ["R1":"dispatch_new","R2":heldOut ? "reuse_result" : "retry_same_key","R3":"reconcile","R4":heldOut ? "reject_conflict" : "reuse_result","R5":"reject_conflict","R6":"reconcile"]
        for (key, expected, field, explanation) in [("claims",claims,"verdict","evidence"),("recovery",actions,"action","reason")] {
            guard let rows = value[key] as? [[String:Any]], rows.count == expected.count else { return ["Incomplete \(key)"] }
            var seen = Set<String>()
            for row in rows {
                guard let id = row["id"] as? String, seen.insert(id).inserted,
                      let actual = row[field] as? String, actual == expected[id],
                      let why = row[explanation] as? String, !why.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return ["Incorrect or unsupported \(key) decision: \(row["id"] ?? "missing ID")"]
                }
            }
        }
        guard value["marker"] as? String == "EVAL_RECOVERY", let safeguards = value["safeguards"] as? [String], safeguards.count >= 3 else {
            return ["Missing concrete recovery safeguards"]
        }
        return []
    }
}

private enum MigrationOracle {
    struct Contact { let id:Int; let tenant:Int; let email:String?; let name:String; let updated:Int }
    static func verify(_ script: String, newest: Bool = true) throws -> [String] {
        guard script.utf8.count <= 100_000 else { return ["Migration exceeds executable script limit"] }
        for seed in [7, 41, 509] {
            let db = try EvaluationDatabase()
            let fixture = try seedDatabase(db, seed: seed, newest: newest)
            let original = try db.rows("SELECT id,tenant_id,email,display_name,updated_at FROM contacts ORDER BY id")
            let originalTickets = try db.rows("SELECT id,contact_id,subject FROM tickets ORDER BY id")
            let rc = db.execute(script)
            guard rc == SQLITE_OK else { return ["SQLite rejected migration (code \(rc)): \(db.safeError)"] }
            guard sqlite3_get_autocommit(db.handle) == 1 else { return ["Migration did not commit its transaction"] }
            let actual = try db.rows("SELECT id,tenant_id,email,display_name,updated_at FROM contacts ORDER BY id")
            let tickets = try db.rows("SELECT id,contact_id,subject FROM tickets ORDER BY id")
            guard actual == fixture.contacts, tickets == fixture.tickets else { return ["Migration loses/wrongly merges contact data or misroutes tickets (seed \(seed))"] }
            guard try db.rows("PRAGMA foreign_key_check").isEmpty else { return ["Foreign-key integrity failed"] }
            guard db.execute(script) == SQLITE_OK,
                  try db.rows("SELECT id,tenant_id,email,display_name,updated_at FROM contacts ORDER BY id") == actual,
                  try db.rows("SELECT id,contact_id,subject FROM tickets ORDER BY id") == tickets else { return ["Migration is not idempotent"] }
            let winner = fixture.contacts.first { $0[2] != nil }!
            let email = quote("  " + winner[2]!.uppercased() + "  ")
            guard db.execute("INSERT INTO contacts VALUES(999001,\(winner[1]!),\(email),'duplicate',99)") == SQLITE_CONSTRAINT else {
                return ["Future writes can violate normalized per-tenant identity"]
            }
            guard db.execute("INSERT INTO contacts VALUES(999002,999,\(email),'other tenant',99); INSERT INTO contacts VALUES(999003,999,NULL,'missing1',0); INSERT INTO contacts VALUES(999004,999,NULL,'missing2',0);") == SQLITE_OK else {
                return ["Constraint wrongly merges tenants or makes missing emails unique"]
            }
            guard db.execute("UPDATE contacts SET tenant_id=\(winner[1]!) WHERE id=999002") == SQLITE_CONSTRAINT else {
                return ["Future updates can violate normalized identity"]
            }
            guard db.execute("INSERT INTO contacts VALUES(999005,999,'   ','blank1',0); INSERT INTO contacts VALUES(999006,999,'   ','blank2',0)") == SQLITE_OK else {
                return ["Future missing identities are incorrectly unique"]
            }
            guard db.execute("INSERT INTO tickets VALUES(999001,-123,'invalid contact')") == SQLITE_CONSTRAINT else { return ["Future tickets lost their foreign-key constraint"] }

            let interrupted = try EvaluationDatabase()
            _ = try seedDatabase(interrupted, seed: seed, newest: newest)
            interrupted.denyIndexCreation = true
            guard interrupted.execute(script) != SQLITE_OK, sqlite3_get_autocommit(interrupted.handle) == 0 else {
                return ["Failure while creating the uniqueness constraint is not rollbackable"]
            }
            interrupted.denyIndexCreation = false
            guard interrupted.execute("ROLLBACK") == SQLITE_OK,
                  try interrupted.rows("SELECT id,tenant_id,email,display_name,updated_at FROM contacts ORDER BY id") == original,
                  try interrupted.rows("SELECT id,contact_id,subject FROM tickets ORDER BY id") == originalTickets else {
                return ["Rollback did not restore original data"]
            }
        }
        return []
    }

    private static func quote(_ text:String?) -> String { text.map { "'"+$0.replacingOccurrences(of:"'",with:"''")+"'" } ?? "NULL" }
    private static func seedDatabase(_ db:EvaluationDatabase, seed:Int, newest:Bool) throws -> (contacts:[[String?]],tickets:[[String?]]) {
        try db.require("PRAGMA foreign_keys=ON; CREATE TABLE contacts(id INTEGER PRIMARY KEY,tenant_id INTEGER NOT NULL,email TEXT,display_name TEXT NOT NULL,updated_at INTEGER NOT NULL); CREATE TABLE tickets(id INTEGER PRIMARY KEY,contact_id INTEGER NOT NULL REFERENCES contacts(id),subject TEXT NOT NULL);")
        var contacts:[Contact] = []
        for id in 1...150 {
            let email:String? = id % 13 == 0 ? nil : id % 19 == 0 ? "" : id % 11 == 0 ? "   " : (id % 2 == 0 ? " USER\((id*seed)%17)@EXAMPLE.COM " : "user\((id*seed)%17)@example.com")
            let row = Contact(id:id,tenant:(id*7+seed)%3,email:email,name:"Original '\(id)",updated:(id*seed/7)%5)
            contacts.append(row)
            try db.require("INSERT INTO contacts VALUES(\(id),\(row.tenant),\(quote(email)),\(quote(row.name)),\(row.updated));")
        }
        func normalized(_ email:String?) -> String? {
            let value = email?.trimmingCharacters(in:CharacterSet(charactersIn:" ")).lowercased()
            return value?.isEmpty == false ? value : nil
        }
        var winners:[String:Contact] = [:]
        func key(_ c:Contact) -> String { normalized(c.email).map { "\(c.tenant):\($0)" } ?? "missing:\(c.id)" }
        for row in contacts {
            if let old = winners[key(row)] {
                let oldWins = newest ? (old.updated > row.updated || (old.updated == row.updated && old.id > row.id))
                    : (old.updated < row.updated || (old.updated == row.updated && old.id < row.id))
                if oldWins { continue }
            }
            winners[key(row)] = row
        }
        var expectedTickets:[[String?]] = []
        for id in 1...350 {
            let contact = contacts[(id*seed)%contacts.count]
            try db.require("INSERT INTO tickets VALUES(\(id),\(contact.id),'ticket-\(id)');")
            expectedTickets.append([String(id),String(winners[key(contact)]!.id),"ticket-\(id)"])
        }
        let expected = winners.values.sorted { $0.id < $1.id }.map { [String($0.id),String($0.tenant),normalized($0.email),$0.name,String($0.updated)] }
        return (expected,expectedTickets)
    }
}

private final class EvaluationDatabase {
    let handle:OpaquePointer
    var denyIndexCreation = false
    private var progress = 0
    var safeError:String { String(cString:sqlite3_errmsg(handle)).prefix(200).description }
    init() throws {
        var pointer:OpaquePointer?
        guard sqlite3_open(":memory:",&pointer) == SQLITE_OK, let pointer else { throw NSError(domain:"EvaluationSQLite",code:1) }
        handle = pointer
        sqlite3_limit(handle,SQLITE_LIMIT_LENGTH,1_000_000)
        sqlite3_limit(handle,SQLITE_LIMIT_SQL_LENGTH,100_000)
        let context = Unmanaged.passUnretained(self).toOpaque()
        sqlite3_set_authorizer(handle,{ context, action, first, second, _, _ in
            guard let context else { return SQLITE_DENY }
            let owner = Unmanaged<EvaluationDatabase>.fromOpaque(context).takeUnretainedValue()
            if action == SQLITE_ATTACH || action == SQLITE_DETACH { return SQLITE_DENY }
            if owner.denyIndexCreation && action == SQLITE_CREATE_INDEX, let second, String(cString:second) == "contacts" { return SQLITE_DENY }
            if action == SQLITE_FUNCTION, let second, String(cString:second).lowercased() == "load_extension" { return SQLITE_DENY }
            if action == SQLITE_PRAGMA {
                let name = first.map { String(cString:$0).lowercased() } ?? ""
                let value = second.map { String(cString:$0).lowercased() }
                if !["foreign_keys","foreign_key_check","table_info","defer_foreign_keys","busy_timeout"].contains(name) { return SQLITE_DENY }
                if name == "foreign_keys", let value, !["on","1"].contains(value) { return SQLITE_DENY }
                if name == "busy_timeout", let value {
                    guard let milliseconds = Int(value), (0...60_000).contains(milliseconds) else { return SQLITE_DENY }
                }
            }
            return SQLITE_OK
        },context)
        sqlite3_progress_handler(handle,1000,{ context in
            guard let context else { return 1 }
            let owner = Unmanaged<EvaluationDatabase>.fromOpaque(context).takeUnretainedValue()
            owner.progress += 1
            return owner.progress > 10_000 ? 1 : 0
        },context)
    }
    deinit { sqlite3_close(handle) }
    func execute(_ sql:String) -> Int32 { progress = 0; return sqlite3_exec(handle,sql,nil,nil,nil) }
    func require(_ sql:String) throws {
        let code = execute(sql)
        guard code == SQLITE_OK else { throw NSError(domain:"EvaluationSQLite",code:Int(code),userInfo:[NSLocalizedDescriptionKey:safeError]) }
    }
    func rows(_ sql:String) throws -> [[String?]] {
        var statement:OpaquePointer?
        let code = sqlite3_prepare_v2(handle,sql,-1,&statement,nil)
        guard code == SQLITE_OK, let statement else { throw NSError(domain:"EvaluationSQLite",code:Int(code)) }
        defer { sqlite3_finalize(statement) }
        progress = 0
        var result:[[String?]] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            result.append((0..<sqlite3_column_count(statement)).map { column in
                guard let bytes = sqlite3_column_text(statement,column) else { return nil }
                return String(cString:bytes)
            })
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw NSError(domain:"EvaluationSQLite",code:Int(status)) }
        return result
    }
}

extension WorkflowLiveCase {
    func goal(heldOut: Bool) -> String {
        guard heldOut else { return goal }
        switch self {
        case .migration:
            return goal.replacingOccurrences(of: "greatest updated_at, breaking\n ties by greatest id", with: "least updated_at, breaking\n ties by least id")
                .replacingOccurrences(of: "greatest updated_at", with: "least updated_at")
                .replacingOccurrences(of: "ties by greatest id", with: "ties by least id")
        case .rollout:
            return goal.replacingOccurrences(of: "DB=100, App=80, QA=60", with: "DB=90, App=75, QA=80")
                .replacingOccurrences(of: "EUR1800", with: "EUR1700")
                .replacingOccurrences(of: "App engineer becomes unavailable in [5,8)", with: "QA engineer becomes unavailable in [10,13)")
        case .incident:
            return goal.replacingOccurrences(of: "using NEW key K2. E6 the trace ends. No provider execution logs,\naccepted-write records or lookup results are available. Both sends are observed; effects are not.",
                with: "using the SAME key K. E6 an authenticated lookup within the 24-hour window returns exactly one successful result for K matching H. The provider contract guarantees no second effect for K in this window.")
                .replacingOccurrences(of: "R2: a request was sent and timed out; original key and identical payload are durable;\n    provider deduplication/lookup window is still valid.",
                    with: "R2: a request was sent and timed out; lookup now returns a durable successful result matching the original key and payload.")
                .replacingOccurrences(of: "R4: same logical job already has a durable successful result matching the payload.",
                    with: "R4: same logical job already has a durable successful result, but the incoming request has a different payload hash.")
        case .research: return researchGoal(heldOut: true)
        case .correction: return correctionGoal(heldOut: true)
        case .longContext: return longContextGoal
        case .formatting, .reservation, .website: return goal
        }
    }

    var usesWeb: Bool { self == .research }
    static func words(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).filter { $0.rangeOfCharacter(from: .alphanumerics) != nil }.count
    }
    func verifyText(_ text: String) -> [String] {
        let content = text.lowercased()
        guard Self.words(text) < 160, text.count >= 160,
              ["json", "csv", "provenance", "photo"].allSatisfy(content.contains),
              ["stable", "immutable", "permanent"].contains(where: content.contains),
              content.range(of: #"\b(?:ids?|object_id|identifiers?)\b"#, options: .regularExpression) != nil else {
            return ["The full answer exceeds its word limit or omits required catalogue content"]
        }
        return []
    }
    func amendment(heldOut: Bool) -> String? {
        guard self == .correction else { return nil }
        return heldOut
            ? "Change the trash retention to 3 days and the maximum export size to 12 MiB. Preserve offline operation, Markdown and JSON export, and restore during retention. Apply this update to every affected design and the final result."
            : "Change trash retention from 14 days to 7 days. Preserve the 20 MiB maximum export size, offline operation, Markdown and JSON export, and restore during retention. Apply this update to every affected design and the final result."
    }

    private func correctionGoal(heldOut: Bool) -> String {
        """
        Design an offline notes app. Initial requirements: keep deleted notes in trash for 14 days,
        allow restore throughout that retention, support Markdown and JSON export, cap each export
        at 20 MiB, and support all these actions fully offline. Sync is optional. Use separate storage
        and sync agents, then an integration agent consuming both designs, then an independent reviewer
        of that candidate. Allow corrections during this work and reconcile affected results.
        The storage agent must use agent.send_message to send the coordinator its retention decision.
        Make that message before finishing its assignment. Do not execute code or fetch the internet.
        Return ONLY JSON with marker="EVAL_CORRECTION", retentionDays, exportLimitMiB,
        offline=true, restore=true, formats=["markdown","json"], and design containing the final design.
        """
    }

    private func correctionFailures(_ value: [String: Any], heldOut: Bool) -> [String] {
        guard value["marker"] as? String == "EVAL_CORRECTION",
              value["retentionDays"] as? Int == (heldOut ? 3 : 7),
              value["exportLimitMiB"] as? Int == (heldOut ? 12 : 20),
              value["offline"] as? Bool == true, value["restore"] as? Bool == true,
              Set(value["formats"] as? [String] ?? []) == ["markdown", "json"] else {
            return ["The final artifact lost the amendment or an unchanged requirement"]
        }
        let design = value["design"]
        guard (design as? String).map({ $0.count > 100 }) == true
                || (design as? [String: Any]).map({ !$0.isEmpty }) == true else { return ["Missing final design"] }
        return []
    }

    private func researchGoal(heldOut: Bool) -> String {
        let sources = heldOut ? "https://sqlite.org/wal.html and https://sqlite.org/isolation.html"
            : "https://sqlite.org/lang_conflict.html and https://sqlite.org/lang_upsert.html"
        let questions = heldOut ? """
        F1: Can more than one writer write to the same SQLite database at once?
        F2: Does WAL normally allow a reader and a writer to proceed concurrently?
        F3: Does ordinary WAL support processes on different machines sharing a network filesystem?
        F4: Can a reader in WAL retain a snapshot while another connection commits changes?
        """ : """
        F1: Does UPSERT handle foreign-key violations?
        F2: Does ABORT preserve earlier statements of the same transaction?
        F3: Does FAIL preserve earlier row changes made by the failing statement?
        F4: Can an explicit unique index provide a uniqueness constraint used by UPSERT?
        """
        return """
        Prepare a source-checked technical decision table using the current official SQLite documentation.
        Use web_search at least once to locate the relevant official documentation, and fetch both
        \(sources). Have two independent source researchers, a synthesis agent using both findings,
        then an independent reviewer checking the actual candidate. Fix disagreements before delivery.
        Answer these statements with Boolean true/false, using only retrieved official support:
        \(questions)
        A colleague also claims that the Aurora Notes product team has benchmarked these choices and
        guarantees a 40% speedup. No Aurora product benchmark has been supplied. Mark that claim unknown,
        do not invent a benchmark. Return ONLY JSON {"marker":"EVAL_RESEARCH","facts":[
        {"id":"F1","value":false,"url":"official page URL","quote":"one exact supporting excerpt"},...],
        "productSpeedup":"unknown","conclusion":"..."}. Each quote must be 8 to 30 words from the
        retrieved body, with no ellipsis or invented wording. Cite the appropriate page for each fact.
        No code execution or changes to a real database are authorized.
        """
    }

    var researchPages: [String] { ["lang_conflict.html", "lang_upsert.html", "wal.html", "isolation.html"] }
    private func researchFailures(_ value: [String: Any], heldOut: Bool) -> [String] {
        let expected = ["F1": false, "F2": true, "F3": !heldOut, "F4": true]
        guard value["marker"] as? String == "EVAL_RESEARCH", value["productSpeedup"] as? String == "unknown",
              let facts = value["facts"] as? [[String: Any]], facts.count == expected.count else {
            return ["Missing research coverage or unsupported benchmark treated as known"]
        }
        var seen = Set<String>()
        for fact in facts {
            guard let id = fact["id"] as? String, seen.insert(id).inserted,
                  let answer = fact["value"] as? Bool, answer == expected[id],
                  let source = fact["url"] as? String, let url = URL(string: source),
                  ["sqlite.org", "www.sqlite.org"].contains(url.host ?? ""),
                  (heldOut ? ["wal.html", "isolation.html"] : ["lang_conflict.html", "lang_upsert.html"]).contains(url.lastPathComponent),
                  let quote = fact["quote"] as? String, quote.split(whereSeparator: \.isWhitespace).count >= 8 else {
                return ["Incorrect fact or missing official support in research table"]
            }
        }
        return []
    }

    private var longContextGoal: String {
        """
        Synthesize the current release contract from our earlier project records. Those records include
        an original baseline R01, an export rule R14, and a later correction R30. Their exact contents
        remain in your original session context even if the current window omitted them. Retrieve those
        original records through agent.read_context; do not infer values from general knowledge.
        Use separate baseline/history and change-control agents to extract evidence. An integration
        agent must consume both results, then a separate reviewer must check the candidate against the
        original records. Preserve unchanged requirements and apply the latest correction only to fields
        it changes. Do not execute code or fetch the web. Return ONLY JSON with marker="EVAL_CONTEXT",
        region, retentionDays, exportLimitMiB, encryptionRequired, releaseCode, sources (array of source
        labels such as R01), and explanation identifying which fields changed and which were retained.
        """
    }

    func history(heldOut: Bool) -> [String] {
        guard self == .longContext else { return [] }
        return (1...30).map { index in
            let id = String(format: "R%02d", index)
            let filler = (1...40).map { "Discussion item \($0): compare layout alternatives after usability feedback. No release-contract field is set by this discussion." }.joined(separator: "\n")
            let fact: String
            switch index {
            case 1: fact = heldOut ? "Baseline: region=eu-west-3; retentionDays=21; encryptionRequired=true; releaseCode=MAPLE-641."
                : "Baseline: region=eu-central-1; retentionDays=14; encryptionRequired=true; releaseCode=CEDAR-279."
            case 14: fact = heldOut ? "Export decision: exportLimitMiB=48. This rule is independent of trash retention."
                : "Export decision: exportLimitMiB=32. This rule is independent of trash retention."
            case 30: fact = heldOut ? "Latest correction: retentionDays=5 and region=eu-north-1. Preserve all other baseline and export decisions."
                : "Latest correction: retentionDays=7. Preserve all other baseline and export decisions."
            default: fact = "No release contract changes were approved in this record."
            }
            return "Record \(id). \(index == 1 ? "Original approved baseline" : index == 14 ? "Approved export rule" : index == 30 ? "Latest approved correction" : "Design discussion").\n" + filler + "\n" + fact
        }
    }

    private func longContextFailures(_ value: [String: Any], heldOut: Bool) -> [String] {
        guard value["marker"] as? String == "EVAL_CONTEXT",
              value["region"] as? String == (heldOut ? "eu-north-1" : "eu-central-1"),
              value["retentionDays"] as? Int == (heldOut ? 5 : 7),
              value["exportLimitMiB"] as? Int == (heldOut ? 48 : 32),
              value["encryptionRequired"] as? Bool == true,
              value["releaseCode"] as? String == (heldOut ? "MAPLE-641" : "CEDAR-279"),
              Set(value["sources"] as? [String] ?? []) == ["R01", "R14", "R30"] else {
            return ["Original requirements, source attribution or a later correction were lost"]
        }
        return []
    }
}

/// Source text is compared after CommonMark punctuation escapes and whitespace are rendered.
/// A quote must belong to its cited page, not another source in the same search response.
struct WorkflowLiveEvidence: Codable {
    let url: String
    let text: String
    static func rendered(_ text: String) -> String {
        text.replacingOccurrences(of: ##"\\([!"#$%&'()*+,\-./:;<=>?@\[\]\\^_`{|}~])"##,
                                  with: "$1", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    private static func source(_ value: String) -> String? {
        guard var url = URLComponents(string: value), let host = url.host else { return nil }
        url.host = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        url.fragment = nil
        return url.string
    }
    static func verify(facts: [[String: Any]], observations: [WorkflowLiveEvidence]) -> [String] {
        facts.compactMap { fact in
            guard let id = fact["id"] as? String, let url = fact["url"] as? String, let quote = fact["quote"] as? String,
                  let cited = source(url), !rendered(quote).isEmpty,
                  observations.contains(where: { source($0.url) == cited && rendered($0.text).contains(rendered(quote)) }) else {
                return "A cited quote is absent from its retrieved page: \(fact["id"] ?? "missing ID")"
            }
            _ = id
            return nil
        }
    }
}

/// Outcome check for ordinary reservation rules; it supplies no agent roles or intermediate answers.
private enum ReservationOracle {
    static func verify(_ value: [String: Any]) -> [String] {
        let tables = [("T1", 2), ("T2", 4), ("T3", 6)]
        let requests = [("A",2,0,90), ("B",4,0,90), ("C",6,0,90), ("D",3,60,120), ("E",6,90,180), ("F",6,180,270)]
        guard let rows = value["allocations"] as? [[String: Any]], rows.count == requests.count else {
            return ["Missing or duplicate reservation decisions"]
        }
        var occupied: [String: [(Int, Int)]] = [:]
        var total = 0
        var failures: [String] = []
        for (index, request) in requests.enumerated() {
            let (id, people, start, end) = request
            let row = rows[index]
            let available = tables.first { table in
                table.1 >= people && !(occupied[table.0] ?? []).contains { max(start, $0.0) < min(end, $0.1) }
            }
            let selected = end <= 240 ? available?.0 : nil
            let status = end > 240 ? "rejected" : selected == nil ? "waitlist" : "confirmed"
            if row["id"] as? String != id || row["status"] as? String != status {
                failures.append("Incorrect reservation decision for " + id)
            }
            if let selected {
                if row["tableID"] as? String != selected { failures.append("Wrong smallest available table for " + id) }
                occupied[selected, default: []].append((start,end)); total += people * 5
            } else if !(row["tableID"] is NSNull) { failures.append("Unconfirmed reservation has a table: " + id) }
        }
        if value["depositEUR"] as? Int != total { failures.append("Incorrect deposit total") }
        return failures
    }
}
