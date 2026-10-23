// SPDX-License-Identifier: MIT

import Foundation
import SQLite3

/// Task outputs are checked by executable invariants, independently of the model's self-assessment.
/// SQL runs only in an in-memory database with file attachment, extensions and unsafe pragmas denied.
enum WorkflowLiveCase: String {
    case migration, rollout, incident

    var goal: String {
        switch self {
        case .migration:
            return """
            Deliver a production SQLite 3.45+ migration script for this legacy help-desk database.
            Existing schema, with foreign_keys=ON:
            CREATE TABLE contacts(id INTEGER PRIMARY KEY, tenant_id INTEGER NOT NULL,
              email TEXT, display_name TEXT NOT NULL, updated_at INTEGER NOT NULL);
            CREATE TABLE tickets(id INTEGER PRIMARY KEY, contact_id INTEGER NOT NULL
              REFERENCES contacts(id), subject TEXT NOT NULL);
            Legacy contacts may duplicate an email within one tenant. Identity is tenant_id plus
            lower(trim(email)), where trim removes ordinary ASCII spaces. NULL or all-space emails
            are missing identities; preserve each such contact separately and normalize its email to NULL.
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

    var usesCalculator: Bool { self == .rollout }

    func verify(_ value: [String: Any]) throws -> [String] {
        switch self {
        case .migration:
            guard value["marker"] as? String == "EVAL_MIGRATION", let sql = value["sql"] as? String, !sql.isEmpty else {
                return ["Missing migration JSON/script"]
            }
            return try MigrationOracle.verify(sql)
        case .rollout: return rolloutFailures(value)
        case .incident: return incidentFailures(value)
        }
    }

    private func rolloutFailures(_ value: [String: Any]) -> [String] {
        let duration = ["A":3,"B":2,"C":2,"D":2,"E":4,"F":2,"G":3,"H":1]
        let resource = ["A":"DB","B":"App","C":"DB","D":"App","E":"DB","F":"DB","G":"QA","H":"App"]
        let dependencies = ["A":[],"B":[],"C":["A"],"D":["B","C"],"E":["C"],"F":["E"],"G":["D","E"],"H":["F","G"]]
        var starts: [String: [String: Int]] = [:]
        for (name, optimum) in [("baseline",13),("revised",14)] {
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
                if name == "revised", item.resource == "App", item.start < 8, item.end > 5 { return ["Revised plan works through the outage"] }
            }
            guard byID.values.map(\.end).max() == optimum else { return ["\(name): makespan differs from schedule"] }
            starts[name] = byID.mapValues(\.start)
        }
        let changed = Set((starts["baseline"] ?? [:]).keys.filter { starts["baseline"]?[$0] != starts["revised"]?[$0] })
        guard changed == ["D","G","H"], let reported = value["changedStartIDs"] as? [String],
              reported.count == changed.count, Set(reported) == changed else { return ["Rescheduling is not minimally disruptive or changed-task list is wrong"] }
        guard value["marker"] as? String == "EVAL_ROLLOUT", value["laborCostEUR"] as? Int == 1680,
              let bounds = value["lowerBounds"] as? [String:Int], bounds["baseline"] == 13, bounds["outage"] == 14 else {
            return ["Cost or optimality bound is wrong"]
        }
        return []
    }

    private func incidentFailures(_ value: [String: Any]) -> [String] {
        let claims = ["C1":"supported","C2":"unknown","C3":"refuted","C4":"supported","C5":"refuted"]
        let actions = ["R1":"dispatch_new","R2":"retry_same_key","R3":"reconcile","R4":"reuse_result","R5":"reject_conflict","R6":"reconcile"]
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
    static func verify(_ script: String) throws -> [String] {
        guard script.utf8.count <= 100_000 else { return ["Migration exceeds executable script limit"] }
        for seed in [7, 41, 509] {
            let db = try EvaluationDatabase()
            let fixture = try seedDatabase(db, seed: seed)
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
            _ = try seedDatabase(interrupted, seed: seed)
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
    private static func seedDatabase(_ db:EvaluationDatabase, seed:Int) throws -> (contacts:[[String?]],tickets:[[String?]]) {
        try db.require("PRAGMA foreign_keys=ON; CREATE TABLE contacts(id INTEGER PRIMARY KEY,tenant_id INTEGER NOT NULL,email TEXT,display_name TEXT NOT NULL,updated_at INTEGER NOT NULL); CREATE TABLE tickets(id INTEGER PRIMARY KEY,contact_id INTEGER NOT NULL REFERENCES contacts(id),subject TEXT NOT NULL);")
        var contacts:[Contact] = []
        for id in 1...150 {
            let email:String? = id % 13 == 0 ? nil : id % 11 == 0 ? "   " : (id % 2 == 0 ? " USER\((id*seed)%17)@EXAMPLE.COM " : "user\((id*seed)%17)@example.com")
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
            if let old = winners[key(row)], old.updated > row.updated || (old.updated == row.updated && old.id > row.id) { continue }
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
                if !["foreign_keys","foreign_key_check","table_info","defer_foreign_keys"].contains(name) { return SQLITE_DENY }
                if name == "foreign_keys", let value, !["on","1"].contains(value) { return SQLITE_DENY }
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
