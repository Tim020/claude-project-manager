# Contributing

## Workflow

Work on a feature branch and open a pull request into `main`; don't push to `main` directly. Name branches by kind: `feature/…`, `fix/…`, `ci/…`, `docs/…`.

CI runs on every pull request (and again on `main` after merging). Check the PR's checks before merging, the macOS job in particular: it's the only place the SwiftUI layer compiles — see [Testing](docs/testing.md). Each run uploads the built `Claudio.zip`, so a PR can be tried before it merges. Merge once both CI jobs pass.

Keep `README.md` and `docs/features.md` current when behaviour changes. Log user-visible actions and CLI commands in the Activity Log (`log.append`), but never account details.

## Code conventions

- Logic lives in `ClaudioCore`, with tests; the SwiftUI layer stays a thin view over `AppModel`. See [Architecture](docs/architecture.md).
- There's no linter — keep builds warning-free.
- The package is `swift-tools-version:5.10`, in Swift 5 language mode. SwiftTerm is pinned to `exact: "1.20.0"`, because newer versions need tools 6.2; it's a macOS-only dependency of the `Claudio` target.
- Don't mark an `XCTestCase` subclass `@MainActor`: it breaks test discovery on Linux. See [Testing](docs/testing.md) for the full set of testing conventions.

## Build and sign locally

```sh
swift run Claudio                 # run directly from the package (no notifications; see below)
./scripts/build-app.sh            # build/Claudio.app (+ .zip), then open it
./scripts/build-app.sh --no-open  # build only
```

`build-app.sh` signs the app with your Apple Development (or Developer ID) certificate if you have one, so macOS remembers the folder and notification permissions you grant between builds. Without one it signs ad hoc, and macOS asks again after each rebuild. To get a certificate, sign in to Xcode with your Apple ID (Settings → Accounts). To choose one, set `CODESIGN_IDENTITY`.

Notifications need the bundled `.app`, not `swift run`.

## Verifying Claude Code CLI behaviour

Any claim about what the `claude` CLI does should be backed by a real run, not assumption — Claude Code's own behaviour has changed under us before. To check without touching your own setup, install it in a container:

```sh
docker run --rm node:22-slim bash -c 'npm i -g @anthropic-ai/claude-code@<version> && claude …'
```

A fresh container is signed out, with an empty config. Verified behaviour (and the fixtures it produced) is recorded in `CLAUDE.md`, which also has the full, version-pinned account of CLI quirks Claudio depends on — read it before changing anything that drives `claude` directly.
