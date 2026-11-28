# Wallpier engineering workflow

Use a fresh branch and isolated checkout for each change. Keep the accepted baseline on `main`; never collect unrelated dirty worktrees into a commit. Preserve existing local branches and recovery material outside the published repository.

1. Describe a small issue with a reproducible trigger and acceptance criteria.
2. Opus implements on `codex/opus/<issue>-<topic>`, branched from the current accepted `main`. Create a draft PR to `main` after the owner has authorized remote writes. Link the issue and describe behavior, tests, and known gaps.
3. Sol reviews and tests a separate clean checkout of the exact PR head. Sol does not implement changes while acting as the independent acceptance reviewer. Send findings back to Opus; review the resulting new head again.
4. Record Sol's acceptance against the full commit SHA, CI URLs, local hardware/toolchain versions, and the checks performed. Earlier acceptance expires whenever implementation changes.
5. Mark the PR ready only after acceptance. The owner authorizes merging; disable automatic merging. Use a merge commit when retaining the reviewed series matters. Use a squash only for a small change with redundant fixup commits, preserving the issue and acceptance record in the PR.

The current RC1 import is a separate bootstrap operation. Reconstruct its accepted source layers in an isolated publication repository, preserve the earlier milestone history, and remove historical Xcode user state before the first push. Do not force-push the shared local repository or push every branch/ref.

While the RC1 import PR is in draft, branch its P1 and P2 fixes from `codex/opus/rc1-import` and target that import branch with separate draft PRs. CI includes this temporary target. After independent Sol acceptance and owner merge authorization for each fix, review the complete updated import head before accepting it into `main`. This keeps the accepted baseline intact while the RC1 blockers are resolved.

When repository plan support permits it, protect `main` and active `release/*` branches: require PRs, current successful checks, resolved conversations, dismiss stale approvals, and prohibit force pushes/deletion. Keep the owner responsible for exceptional bootstrap operations. Configure required checks only after the first real runs establish their exact names.

Opus and Sol are agent roles, not distinct GitHub identities. If both use the owner's account, Sol's independent report is still required, but it is not a GitHub approval by another collaborator. Enforced approval requires a separate eligible collaborator account. Until then, use the SHA-bound report and owner merge decision; do not claim self-review satisfies a required approval.

## CI scope

The proposed macOS matrix uses explicit `macos-15-intel` and `macos-15` labels. Record the actual Xcode version and architecture in every run. The project uses Swift 5 language mode and a macOS 12 deployment target; a newer SDK build does not establish macOS 12 runtime compatibility.

`Scripts/ci-core-tests.txt` is a reviewed allowlist of deterministic state, provider, file-retention, geometry/options, and mocked rotation tests. Tests use generated images, isolated storage, fake networking and a recording wallpaper service. Keep capture environment variables unset. Changes to the list require review; a green allowlist is not a pass of the entire test target.

The full `WallpierTests` target contains activation, key-window, menu and keyboard-dispatch checks. The `WallpierUITests` target currently contains launch/performance/screenshot templates. Neither is a required hosted-runner proof of interactive behavior. The full suite and capture helpers are retained in source for local acceptance.

The Release job builds the private test package and inspects its actual signature, entitlement, architecture slices and coverage markers. It never publishes a ZIP or release. The RC1 packaging defect is expected to fail this gate until fixed. A passing signature verification alone does not prove safe Release entitlements.

## Local acceptance

The Intel Ventura / Xcode 15.2 baseline remains local. Check actual Fit/Fill/Center rendering, Undo/relaunch after a controlled cache purge, multi-display unplug/reconnect, Spaces, sleep/wake, real elapsed rotation, keyboard/menu focus, accessibility, light/dark contrast and minimum-window layout on appropriate physical Macs. Record any missing hardware or OS coverage. Apple Silicon runtime and macOS 12 runtime claims require their own devices/OS environments.

Run wallpaper-changing checks only with the owner's authorization, isolated fixtures and a documented restoration procedure. Never make the owner's desktop a self-hosted runner. Signing/notarization credentials belong in approved secret storage; they are unnecessary for the initial build/test pipeline.

RC1 has two open release blockers: durable retention can fall back to purgeable storage on budget/I/O failure, and the current private package includes a debugging entitlement plus LLVM coverage instrumentation. Preserve this baseline for review without treating it as a release-ready build.
