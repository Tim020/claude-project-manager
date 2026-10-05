import XCTest
@testable import ClaudioCore

/// Step 5: lessons, signatures, skill text and the draft checks (no model).
final class SkillDraftTests: XCTestCase {
    // MARK: - Evidence in the digest

    private let lines = [
        History.prompt("Fix the shell height"),
        History.tool("t1", "Bash", ["command": "cd /code/app && swift test --filter ShellPanelTests"]),
        History.result("t1", "Exit code 1\nerror: 2 tests failed in /code/app/Tests/ShellPanelTests.swift", error: true),
        History.tool("t2", "Edit", ["file_path": "/code/app/Sources/ClaudioCore/ShellPanel.swift"]),
        History.result("t2", "String to replace not found in file.", error: true),
        History.prompt("No, don't use swift test here, remember to run ./scripts/test-linux.sh instead"),
    ]

    func testTheDigestGivesFailuresAndCorrectionsRefs() throws {
        let digest = SessionDigest.build(lines: lines, projectPath: "/code/app")
        XCTAssertEqual(digest.evidence.map(\.ref), ["f1", "f2", "c1"])
        XCTAssertEqual(digest.evidence[0].tool, "Bash")
        XCTAssertEqual(digest.evidence[0].command, "cd /code/app && swift test --filter ShellPanelTests")
        XCTAssertEqual(digest.evidence[1].file, "Sources/ClaudioCore/ShellPanel.swift", "relative to the project")
        XCTAssertEqual(digest.evidence[2].kind, .correction)
        let json = digest.json(withTranscripts: true)
        XCTAssertEqual(json["failures"]?.arrayValue?.first?["ref"]?.stringValue, "f1")
        XCTAssertEqual(json["corrections"]?.arrayValue?.first?["ref"]?.stringValue, "c1")
        XCTAssertNil(digest.json(withTranscripts: false)["failures"])

        let request = FollowUpJob.request(digest: digest, mark: FollowUpMark(conversationID: "c", offset: 0), sessionName: "s",
                                          items: [], sessionItem: nil, sessionNotes: [], memoryIndex: nil)
        XCTAssertEqual(Set(request.evidence.keys), ["f1", "f2", "c1"])
        XCTAssertTrue(request.call.schema.contains("\"lessons\""))
        let private_ = FollowUpJob.request(digest: digest, mark: FollowUpMark(conversationID: "c", offset: 0), sessionName: "s",
                                           items: [], sessionItem: nil, sessionNotes: [], memoryIndex: nil, withTranscripts: false)
        XCTAssertTrue(private_.evidence.isEmpty, "without transcripts there's nothing to cite, so no lessons")
    }

    // MARK: - Signatures

    func testSignaturesComeFromWhatHappened() {
        XCTAssertEqual(LessonSignature.commandHead("cd /code/app && swift test --filter X"), "swift test")
        XCTAssertEqual(LessonSignature.commandHead("FOO=1 sudo ./scripts/test-linux.sh --filter X"), "test-linux.sh")
        XCTAssertEqual(LessonSignature.commandHead("git worktree add ../w"), "git worktree")
        XCTAssertEqual(LessonSignature.errorHead("Exit code 128\nfatal: '/tmp/a/b' is already checked out at '/x/y' (3 times, abc1234def)"),
                       "fatal: '<path>' is already checked out at '<path>' (# times, #)")
        func failure(_ command: String, _ error: String) -> SessionDigest.Evidence {
            SessionDigest.Evidence(ref: "f1", kind: .failure, tool: "Bash", command: command, text: error)
        }
        XCTAssertEqual(LessonSignature.of(failure("git worktree add /tmp/one", "fatal: '/tmp/one' already exists (12)")),
                       LessonSignature.of(failure("cd /code && git worktree add /var/two -b x", "fatal: '/var/two' already exists (7)")),
                       "the same failure in two sessions, with different paths and numbers")
        XCTAssertEqual(LessonSignature.of(SessionDigest.Evidence(ref: "f2", kind: .failure, tool: "Edit", file: "Sources/a.swift", text: "x")),
                       "edit Sources/a.swift")
        XCTAssertEqual(LessonSignature.of(SessionDigest.Evidence(ref: "c1", kind: .correction, text: "No, don't use the swift test command!")),
                       "correction use swift test command")
        XCTAssertEqual(LessonSignature.of([SessionDigest.Evidence(ref: "c1", kind: .correction, text: "no"),
                                           failure("make", "boom")]), "bash make | boom", "a failure comes first")
    }

    // MARK: - Lessons in a reply

    func testLessonsMustCiteRealEvidence() throws {
        let digest = SessionDigest.build(lines: lines, projectPath: "/code/app")
        let evidence = Dictionary(uniqueKeysWithValues: digest.evidence.map { ($0.ref, $0) })
        let reply = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
            {"notes":[],"planChanges":[],"lessons":[
              {"summary":"Run the Linux script, not swift test.","evidence":["f1","c1","c1"],"remember":true},
              {"summary":"Made up.","evidence":["f9"],"remember":false},
              {"summary":"Edit fails on that file.","evidence":["f2"],"remember":true},
              {"summary":"","evidence":["f1"],"remember":false}
            ]}
            """#.utf8))
        let lessons = FollowUpJob.lessons(from: reply, evidence: evidence)
        XCTAssertEqual(lessons.map(\.summary), ["Run the Linux script, not swift test.", "Edit fails on that file."],
                       "invented refs and empty summaries are dropped")
        XCTAssertEqual(lessons[0].evidence.map(\.ref), ["f1", "c1"], "each cited once")
        XCTAssertTrue(lessons[0].remember, "a cited correction says remember")
        XCTAssertFalse(lessons[1].remember, "no correction says so, whatever the model claims")
        XCTAssertEqual(lessons[0].signature, "bash swift test | error: # tests failed in <path>")
        XCTAssertEqual(FollowUpJob.lessons(from: .object(["notes": .array([])]), evidence: evidence), [], "no lessons key")
    }

    // MARK: - Candidates

    private func finding(_ signature: String, remember: Bool = false) -> LessonFinding {
        LessonFinding(summary: "Use the script.", evidence: [SessionDigest.Evidence(ref: "f1", kind: .failure, text: "boom")],
                      remember: remember, signature: signature)
    }

    func testCandidatesGatherBySignatureAcrossSessions() {
        var data = SkillsData()
        let one = UUID(), two = UUID(), date = Date(timeIntervalSince1970: 1000)
        data.add([finding("a")], sessionID: one, sessionName: "One", at: date)
        data.add([finding("a")], sessionID: one, sessionName: "One", at: date)
        XCTAssertEqual(data.candidates.count, 1)
        XCTAssertEqual(data.candidates[0].evidence.count, 1, "the same evidence isn't added twice")
        XCTAssertFalse(data.candidates[0].qualifies, "one session")
        data.add([finding("a"), finding("b")], sessionID: two, sessionName: "Two", at: date)
        XCTAssertEqual(data.candidates.count, 2)
        XCTAssertTrue(data.candidates[0].qualifies, "two sessions")
        XCTAssertFalse(data.candidates[1].qualifies)
        data.candidates[0].holdBack(more: 2)
        XCTAssertFalse(data.candidates[0].qualifies, "Not Now: two more sessions first")
        XCTAssertEqual(data.candidates[0].heldUntilSessions, 4)
        data.add([finding("c", remember: true)], sessionID: one, sessionName: "One", at: date)
        XCTAssertTrue(data.candidates[2].qualifies, "remember this: straight away")
    }

    func testCandidatesSurviveSavingAndUnknownStates() throws {
        var data = SkillsData()
        data.add([finding("a")], sessionID: UUID(), sessionName: "One", at: Date(timeIntervalSince1970: 1000))
        data.proposals = [SkillProposal(candidateID: data.candidates[0].id, name: "x", text: "t", previousText: nil, why: "w",
                                        createdAt: Date(timeIntervalSince1970: 1000), model: "Sonnet")]
        let again = try JSONFileStore.decoder.decode(SkillsData.self, from: JSONFileStore.encoder.encode(data))
        XCTAssertEqual(again, data)
        var json = String(decoding: try JSONFileStore.encoder.encode(data), as: UTF8.self)
        json = json.replacingOccurrences(of: "\"collecting\"", with: "\"someLaterState\"")
        let later = try JSONFileStore.decoder.decode(SkillsData.self, from: Data(json.utf8))
        XCTAssertEqual(later.candidates.first?.state, .collecting, "a state from a later build goes back to gathering")
        let broken = #"{"usage":{},"candidates":[{"oops":1}],"proposals":[],"records":[]}"#
        let kept = try JSONFileStore.decoder.decode(SkillsData.self, from: Data(broken.utf8))
        XCTAssertEqual(kept.unreadableCount, 1)
        XCTAssertTrue(String(decoding: try JSONFileStore.encoder.encode(kept), as: UTF8.self).contains("oops"), "kept as it was")
    }

    // MARK: - Skill text

    func testComposedTextReadsBack() {
        let text = SkillText.compose(name: "linux-tests", description: "Run the \"Linux\" tests.\nAlways.", whenToUse: "Before a PR",
                                     paths: ["Tests/**/*.swift"], body: "\n# Linux tests\n\nRun it.\n",
                                     metadata: [("claudio-id", "6f9619ff-8b86-d011-b42d-00c04fc964ff"), ("claudio-version", "2")])
        let skill = SkillFiles.skill(fromSkillFile: text, folderName: "x")
        XCTAssertEqual(skill.name, "linux-tests")
        XCTAssertEqual(skill.description, "Run the 'Linux' tests. Always.")
        XCTAssertEqual(skill.paths, ["Tests/**/*.swift"])
        XCTAssertEqual(skill.version, 2)
        XCTAssertEqual(skill.claudioID, UUID(uuidString: "6f9619ff-8b86-d011-b42d-00c04fc964ff"))
        XCTAssertEqual(SkillText.body(of: text), "# Linux tests\n\nRun it.")
        let bumped = SkillText.settingMetadata(text, [("claudio-version", "3"), ("claudio-new", "y")])
        XCTAssertEqual(SkillFiles.skill(fromSkillFile: bumped, folderName: "x").version, 3)
        XCTAssertTrue(bumped.contains("  claudio-new: y"))
        let added = SkillText.settingMetadata("---\nname: a\n---\nBody", [("claudio-version", "1")])
        XCTAssertEqual(added, "---\nname: a\nmetadata:\n  claudio-version: 1\n---\nBody")
        XCTAssertEqual(SkillText.hash("abc"), SkillText.hash("abc"))
        XCTAssertNotEqual(SkillText.hash("abc"), SkillText.hash("abd"))
        XCTAssertEqual(SkillText.hash(""), "cbf29ce484222325", "FNV-1a's offset basis")
    }

    // MARK: - Checks

    private func text(name: String = "linux-tests", description: String = "Run the tests on Linux.", paths: [String] = [],
                      body: String = "Run `scripts/test-linux.sh`.\n\n```bash\n./scripts/test-linux.sh --filter X\nswift test | grep x\n```") -> String {
        SkillText.compose(name: name, description: description, whenToUse: "", paths: paths, body: body, metadata: [])
    }

    private func context(existing: Set<String> = [], patching: String? = nil, commands: ((String) -> Bool)? = { _ in true }) -> SkillCheck.Context {
        SkillCheck.Context(projectPath: "/code/app", existingNames: existing, patching: patching, commandExists: commands,
                           fileExists: { $0 == "/code/app/scripts/test-linux.sh" })
    }

    func testAGoodDraftPasses() {
        XCTAssertEqual(SkillCheck.problems(text(), context: context()), [])
    }

    func testNamesAreChecked() {
        XCTAssertEqual(SkillCheck.problems(text(name: "Linux Tests"), context: context()),
                       ["the name isn't a lower-case slug of up to 64 characters"])
        XCTAssertEqual(SkillCheck.problems(text(name: "debug"), context: context()), ["debug is one of Claude Code's own names"])
        XCTAssertEqual(SkillCheck.problems(text(), context: context(existing: ["linux-tests"])), ["a skill named linux-tests already exists"])
        XCTAssertEqual(SkillCheck.problems(text(), context: context(existing: ["linux-tests"], patching: "linux-tests")), [],
                       "a change keeps its name")
        XCTAssertEqual(SkillCheck.problems(text(name: "other"), context: context(patching: "linux-tests")), ["a change renames the skill"])
    }

    func testClaudeCodesOwnNamesAreReserved() throws {
        for version in ["2.1.169", "2.1.289"] {
            let json = try JSONDecoder().decode(JSONValue.self, from: Data(try Fixtures.string("init-builtins-\(version).json").utf8))
            let names = ((json["skills"]?.arrayValue ?? []) + (json["slash_commands"]?.arrayValue ?? [])).compactMap(\.stringValue)
                .filter { !$0.hasPrefix("_") }
            XCTAssertFalse(names.isEmpty)
            for name in names { XCTAssertTrue(SkillCheck.reservedNames.contains(name), "\(name) (\(version))") }
        }
    }

    func testLengthsAndPathsAreChecked() {
        XCTAssertEqual(SkillCheck.problems(text(description: String(repeating: "a", count: 1600)), context: context()),
                       ["the description and when_to_use are over 1536 characters"])
        XCTAssertEqual(SkillCheck.problems(text(paths: ["/etc/*"]), context: context()), ["a paths glob isn't relative to the repository"])
        XCTAssertEqual(SkillCheck.problems(text(body: ""), context: context()), ["no instructions"])
        XCTAssertEqual(SkillCheck.problems(text(body: Array(repeating: "line", count: 501).joined(separator: "\n")), context: context()),
                       ["the instructions are over 500 lines or 20000 characters"])
        XCTAssertEqual(SkillCheck.problems("No frontmatter at all", context: context()).first, "no frontmatter")
    }

    func testReferencedFilesMustExist() {
        XCTAssertEqual(SkillCheck.referencedPaths(in: "See `Sources/a.swift:42`, `README.md`, `https://x.io/a`, `Tests/**`, `--flag`, `~/x/y`, `./scripts/b.sh`, `$HOME/a`, `origin/main`"),
                       ["Sources/a.swift", "README.md", "scripts/b.sh"])
        XCTAssertEqual(SkillCheck.problems(text(body: "Edit `Sources/Missing.swift`."), context: context()),
                       ["it refers to Sources/Missing.swift, which isn't in the repository"])
    }

    func testCommandsMustBeOnThePath() {
        let body = """
            ```bash
            $ FOO=1 sudo gh pr view 12 | jq .title && cd x; echo hi
            # a comment
            ./scripts/test-linux.sh
            ```
            ```swift
            notACommand()
            ```
            """
        XCTAssertEqual(SkillCheck.commands(in: body), ["gh", "jq"])
        XCTAssertEqual(SkillCheck.problems(text(body: body), context: context(commands: { $0 == "gh" })),
                       ["it runs jq, which isn't on the PATH"], "a script run by its path isn't looked for on the PATH")
        XCTAssertEqual(SkillCheck.problems(text(body: body), context: context(commands: nil)), [],
                       "no PATH to check against: the check is skipped, not failed")
    }

    func testSecretsAreRefused() {
        let secrets = [
            "sk-ant-api03-" + String(repeating: "a", count: 30),
            "ghp_" + String(repeating: "b", count: 36),
            "AKIA" + "ABCDEFGHIJKLMNOP",
            "-----BEGIN OPENSSH PRIVATE KEY-----",
            "password: hunter2hunter2",
            "xoxb-1234567890-abcdef",
        ]
        for secret in secrets {
            XCTAssertFalse(SecretPatterns.matches(in: "Use \(secret) here").isEmpty, secret)
            XCTAssertTrue(SkillCheck.problems(text(body: "Use \(secret) here."), context: context())
                .contains { $0.hasPrefix("it looks like it holds a secret") }, secret)
        }
        XCTAssertEqual(SecretPatterns.matches(in: "Set the password: in Keychain, or use $TOKEN"), [], "words alone aren't secrets")
    }

    // MARK: - The draft reply

    func testDraftRepliesAreRead() throws {
        let skills = [ApprovedSkill(name: "linux-tests")]
        func reply(_ json: String) throws -> SkillDraft? {
            SkillDraftJob.draft(from: try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)), skills: skills)
        }
        let patch = try XCTUnwrap(try reply(#"{"action":"patch","skill":"linux-tests","name":"renamed","description":"d","whenToUse":"","paths":["a/*"," "],"body":"b","why":"stops a failing run"}"#))
        XCTAssertEqual(patch.action, .patch("linux-tests"))
        XCTAssertEqual(patch.name, "linux-tests", "a patch keeps the skill's name")
        XCTAssertEqual(patch.paths, ["a/*"])
        XCTAssertEqual(patch.why, "Stops a failing run.")
        XCTAssertEqual(try reply(#"{"action":"patch","skill":"unknown","name":"n","description":"d","whenToUse":"","paths":[],"body":"b","why":""}"#)?.action,
                       .new, "a patch to a skill that isn't there is new")
        XCTAssertEqual(try reply(#"{"action":"none","skill":null,"name":"","description":"","whenToUse":"","paths":[],"body":"","why":""}"#)?.action, SkillDraft.Action.none)
        XCTAssertNil(try reply(#"{"action":"maybe"}"#))
        let call = SkillDraftJob.request(candidate: LessonCandidate(signature: "s", summary: "Use the script.", evidence: [], remember: false,
                                                                    at: Date()), projectName: "App", skills: skills, model: .sonnet)
        XCTAssertEqual(call.model, "sonnet")
        XCTAssertEqual(call.maxBudgetUSD, SkillDraftJob.budgetUSD * AssistantModel.sonnet.budgetFactor, accuracy: 0.0001)
        XCTAssertTrue(call.input.contains("\"approvedSkills\""))
    }

    // MARK: - Recorded Sonnet replies (2.1.289)

    func testARecordedFollowUpsLessonIsRead() throws {
        let result = CommandResult(exitCode: 0, output: try Fixtures.string("assistant-followup-lessons.json"), errorOutput: "")
        guard case .success(let reply) = AssistantReplyParser.parse(result, timeout: 120) else { return XCTFail("expected a reply") }
        let correction = "No, don't run swift test on this Mac for the Linux checks, remember to use ./scripts/test-linux.sh next time"
        let evidence = ["c1": SessionDigest.Evidence(ref: "c1", kind: .correction, text: correction),
                        "f1": SessionDigest.Evidence(ref: "f1", kind: .failure, tool: "Bash", command: "swift test", text: "boom")]
        let lessons = FollowUpJob.lessons(from: reply.output, evidence: evidence)
        XCTAssertEqual(lessons.count, 1)
        XCTAssertTrue(lessons[0].remember, "it cited the correction that says remember")
        XCTAssertEqual(lessons[0].signature, "correction run swift test on this mac")
        XCTAssertEqual(reply.costUSD ?? 0, 0.010222, accuracy: 0.000001)
    }

    func testARecordedDraftPassesTheChecks() throws {
        let result = CommandResult(exitCode: 0, output: try Fixtures.string("assistant-skill-draft.json"), errorOutput: "")
        guard case .success(let reply) = AssistantReplyParser.parse(result, timeout: 120) else { return XCTFail("expected a reply") }
        let draft = try XCTUnwrap(SkillDraftJob.draft(from: reply.output, skills: [ApprovedSkill(name: "worktree-setup")]))
        XCTAssertEqual(draft.action, .new)
        XCTAssertEqual(draft.name, "linux-test-checks")
        let text = SkillText.compose(name: draft.name, description: draft.description, whenToUse: draft.whenToUse, paths: draft.paths,
                                     body: draft.body, metadata: [("claudio-version", "1")])
        let context = SkillCheck.Context(projectPath: "/code/app", existingNames: ["worktree-setup"], patching: nil,
                                         commandExists: { _ in true }, fileExists: { $0 == "/code/app/scripts/test-linux.sh" })
        XCTAssertEqual(SkillCheck.problems(text, context: context), [])
        XCTAssertEqual(SkillFiles.skill(fromSkillFile: text, folderName: "x").paths, ["Tests/**/*.swift", "scripts/test-linux.sh"])
        XCTAssertEqual(reply.durationMS, 5232)
    }
}
