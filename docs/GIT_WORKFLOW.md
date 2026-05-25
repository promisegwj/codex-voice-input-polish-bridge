# Git Workflow

## Branches

- `main`: stable publish branch. Keep it buildable.
- `feature/<short-name>`: feature or behavior change.
- `fix/<short-name>`: bug fix.
- `docs/<short-name>`: documentation-only change.

## Pull Requests

Every PR should include:

- What changed.
- Why it changed.
- How it was verified.
- Privacy and local-data impact.
- Rollback notes when the change touches scripts, settings, or回填 behavior.

## Merge Rules

- Prefer squash merge for small focused PRs.
- Preserve merge commits only for larger coordinated branches.
- Do not merge if generated build output, `.codex-tmp/`, logs, personal paths, or credentials are present.
- Do not merge behavior changes without updating the relevant docs.

## Release Flow

1. Update `CHANGELOG.md`.
2. Run the release checklist in `docs/RELEASE_CHECKLIST.md`.
3. Commit with a version tag, for example `v0.1.0`.
4. Push tag and branch.
5. Attach binaries to GitHub Releases only if intentionally distributing built artifacts.
