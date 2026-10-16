# Testing

The project is built test-first. All logic lives in the platform-independent `ClaudioCore` target, and the SwiftUI layer stays a thin view over `AppModel`, so almost everything is covered by `Tests/ClaudioCoreTests` without needing a Mac. Coverage spans workspace operations; hook event parsing and status reduction (using fixtures recorded from real `claude` runs); JSONL history parsing and transcript building; terminal launch commands, including shell quoting; `claude agents --json` parsing and the agent lifecycle; session discovery; persistence; notification rules; the Project Assistant, pull requests and usage; and `AppModel` itself.

```sh
swift test                                    # full suite (macOS, or Linux with a toolchain)
swift test --filter EnvironmentCheckTests     # one test class
swift test --filter EnvironmentCheckTests/testSignedOut   # one test
./scripts/test-linux.sh                       # no local toolchain: runs the suite in the swift:6.1-noble Docker image
./scripts/test-linux.sh --filter TitleSyncTests          # extra args are passed to `swift test`
```

GitHub Actions (`.github/workflows/ci.yml`) runs the suite on Linux and on macOS for every pull request and every push to `main`. On macOS it also builds the `.app` bundle and uploads it as an artifact, so a pull request's build can be downloaded and tried before merging. The macOS job is the only place the SwiftUI layer gets compiled, so when working without a Mac, check its result after pushing UI changes.

## Conventions

- **Don't mark an `XCTestCase` subclass `@MainActor`: it breaks test discovery on Linux.** Hop inside the test instead: `try MainActor.assumeIsolated { … }`, `await MainActor.run { … }`, or a `@MainActor` helper method.
- `AppModel` is fully injectable: store, discovery home, hook log URL, command runner, `locateClaude`, `now`, `home`. Use `MemoryStore`, `FakeRunner` (canned CLI output, and it records the arguments it was called with) and `FakeTerminals`. Both are defined in `AgentModelTests.swift` and `AppModelTests.swift`.
- `model.terminals` is a weak reference, so keep `FakeTerminals` in a stored property.
- Some `internal` helpers exist only for tests: `applyStatus`, `applyNeedsAction`, `applyAgentLink`, `applyTestSession`.
- `AppModel` resets Working sessions to Completed at launch. Tests that need a non-completed session after init should use Awaiting Input.
- Claims about real Claude Code CLI behaviour are backed by output recorded in `Tests/ClaudioCoreTests/Fixtures`, from a real run in a container — see [Verifying CLI behaviour](../CLAUDE.md#claude-code-cli-behaviour-claudio-depends-on) in `CLAUDE.md`.
