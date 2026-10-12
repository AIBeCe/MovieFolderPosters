# Movie Folder Posters — Agent Instructions

@/Users/davidalarcon/.codex/RTK.md

## Scope and authorization

- Build a native macOS utility that gives movie folders persistent poster icons in Finder.
- Use Swift, AppKit, Finder Sync, and shared Swift Core logic. Do not use SwiftUI.
- Finder remains the movie browsing interface. The host app provides configuration only.
- Never rename, move, delete, or modify movie contents.
- Custom-icon filesystem metadata changes require an approved implementation point.
- Do not add daemons, launch agents, watchers, polling, or additional services without explicit approval.
- Completed scope includes Finder lifecycle, parsing, matching, processing, and Phase 6 configuration.
- Keep fixtures explicitly opt-in in Debug; Release uses the configured TMDb read access token.
- Creating or approving the project plan does not authorize further product implementation.

## Proposal before implementation

- Inspect the relevant existing code, configuration, tests, and documentation first.
- Work phase by phase and implementation point by implementation point.
- Before changing files, present the intended changes, affected files, design decisions, and verification.
- Include the actual proposed code or a focused diff.
- Wait for explicit approval before implementation. Do not batch points without permission.
- Implement exactly the approved proposal.
- Stop and explain new evidence that invalidates the approved approach.
- Update durable project documentation with decisions, completed work, limitations, and remaining work.

## Architecture

- Apply SOLID principles where they improve correctness and maintainability; avoid speculative abstractions.

- Use MVVM-C for the AppKit configuration interface when that interface is implemented.
- Views and view controllers render state and forward user actions.
- View models own presentation state and depend on narrowly scoped service interfaces.
- Coordinators own navigation, window presentation, and flow lifetime.
- Core logic owns parsing, matching, metadata, caching, and processing decisions.
- Keep Core logic independent of AppKit where practical.
- Isolate AppKit icon assignment behind a focused adapter.
- Keep Finder Sync a thin integration layer.
- Do not introduce empty layers, speculative protocols, or a separate coordinator for every view.

## Modules and services

- Organize reusable functionality into local Swift Package Manager modules.
- Each module provides an in-process service with a narrow public API and its own tests.
- Start with Network and FileSystem; introduce Persistence when durable storage is needed.
- The application coordinates services and owns movie-specific decisions and workflows.
- Services must not depend on the application.
- Add dependencies between services only when a demonstrated need justifies them.
- Services do not imply separate processes, background daemons, or global singletons.
- Prefer Apple frameworks and the fewest possible third-party SPM dependencies.
- Propose and justify additional modules and third-party dependencies before adding them.

## Testing and verification

- Use TDD wherever meaningful: write a failing behavioral test, implement the minimum, then refactor.
- Prefer Swift Testing for new unit tests and XCTest for UI tests.
- Test parsing, matching, processing decisions, failures, cancellation, and scope boundaries independently.
- Avoid tests that merely mirror implementation details or assert mocked behavior.
- For OS callbacks, signing, sandbox permissions, and icon persistence, use integration or manual checks.
- Document why a platform probe cannot be verified by unit tests.
- Run relevant verification after each approved implementation point.
- Distinguish builds, test passes, and runtime observations. Never infer one from another.
- Record blocked and unperformed checks explicitly.

## GitFlow

- Inspect Git status before changes and preserve user edits.
- Use main for releases, develop for integration, and feature/* for normal development.
- Branch new features from develop once the repository has an established commit history.
- Use release/* and hotfix/* only for explicitly authorized release or hotfix work.
- Do not implement directly on main or develop.
- Do not reset history, discard changes, merge, push, or publish without explicit authorization.
- Automatically commit approved work after relevant verification and required review pass.
- Use focused commits; exclude signing secrets, user-specific Xcode data, and build artifacts.
- The initial lifecycle probe uses feature/finder-lifecycle.

## Swift style and concurrency

- Keep Swift source lines at or below 120 characters.
- Prefer readable single lines up to that limit; avoid unnecessarily narrow wrapping.
- Use programmatic AppKit for new UI.
- Prefer Swift 6 language mode and complete concurrency checking.
- Keep UI work on the main actor and callbacks responsive.
- Perform networking and potentially expensive filesystem work away from UI callbacks.
- Bound concurrent work, deduplicate requests, and handle cancellation.
- Account for multiple Finder Sync processes; process-local state is not global coordination.
- Use diagnostic logging sparingly and keep user paths private.

## Permissions and safety

- Operate only within explicitly configured directories; initially inspect immediate children only.
- Registering a Finder directory does not establish filesystem read or write permission.
- Validate sandbox access and persistent authorization before filesystem mutation.
- Never hardcode API credentials or store them in Git.
- Prefer missing posters over incorrect matches.
- Preserve existing icons unless replacement is explicitly authorized.
- Treat unavailable volumes and failed operations as recoverable conditions.

## Agent workflow

- Prefer direct evidence from this repository and runtime over assumptions.
- Separate observations, assumptions, proposals, and unresolved uncertainty.
- Reuse established context and read the smallest relevant sections.
- Delegate only when bounded exploration, verbose verification, or independent review adds material value.
- Keep architectural authority and user approval cycles with the primary agent.
- Preserve worker/reviewer ownership through review and fix cycles.
- Report what changed, what was tested, and what remains unverified.

## Model and Reasoning Selection

Model names are indicative, not mandatory. Use an equivalent available model when it better fits the task,
balancing capability, reliability, and cost.

| Phase | Model | Reasoning Effort | Recommendation |
| --- | --- | --- | --- |
| Planning / Proposal | GPT-6.1 Sol | Medium | Architecture, technical design, dependency analysis, and implementation planning. Escalate to High for complex architectural decisions. |
| Complex Implementation | GPT-6.1 Sol | Medium | Architectural changes, complex logic, concurrency, and implementations requiring significant design decisions. |
| Standard Implementation | GPT-6 Luna | Medium | Implementing approved, well-defined plans and routine refactoring. |
| Testing | GPT-6 Luna | Low | Running tests, builds, linters, and investigating straightforward failures. Escalate for complex debugging. |
| Documentation | GPT-6 Luna | Low | Updating technical documentation, implementation plans, and progress summaries. |
| Code Review | GPT-6.1 Sol | Medium | Semantic correctness, regression analysis, and architectural consistency. Escalate to High for critical or complex reviews. |

**General principle:** Start with the least expensive model capable of reliably completing the task.
Increase reasoning effort or switch models only when task complexity justifies it.
