# Automated version-update release pipeline

## Status

accepted

## Context & Decision

We want new Elastic Stack (and Traefik) releases to flow into the repo automatically:
detect → bump → test → release, hands-off, with escalation when something breaks. The
question was how much machinery to stand up versus pushing straight to `main`.

We chose a **PR-gated, branch-protected, auto-merge** pipeline rather than the simpler
"run tests inline and push to `main`" approach. The version-update workflow opens a PR;
the repo's existing CI workflows run as **required status checks**; an automated
**Go/No-Go review** approves; auto-merge merges; a **Release** (`v<elastic-version>`) is
cut. On CI failure the pipeline opens a `version-update-failure` issue, tags the
maintainer, and assigns the Copilot coding agent to investigate.

## Considered options

- **Direct pipeline (no PR):** run tests inline, push to `main`, tag. Simplest, but no
  durable record, no place for a review gate, and no natural artifact for an agent to fix.
- **PR + branch protection + auto-merge (chosen):** more moving parts, but every bump has
  a reviewable PR, CI is the real gate, and failures leave a branch + issue to act on.

## Consequences / things a future reader will wonder about

- **A GitHub App authors the PR, not `GITHUB_TOKEN`.** A PR opened with `GITHUB_TOKEN`
  does *not* trigger other workflows, so the required CI checks would never run and the PR
  would hang forever. The PR is therefore created with a GitHub App installation token
  (`APP_ID` + `APP_PRIVATE_KEY` secrets), which makes CI fire and gives the routine bump
  PRs a clean bot identity (`…[bot]`).
- **One narrow PAT remains, for the Copilot dispatch only.** The Copilot coding-agent
  assignment API **rejects server-to-server tokens** (GitHub App installation tokens and
  `GITHUB_TOKEN`) — it requires a human fine-grained PAT with Copilot access. So the
  failure-path "assign the agent" step uses a separate narrow PAT (`COPILOT_AGENT_PAT`),
  exercised only when a release breaks. The App can't carry a Copilot seat, which is why
  this one credential can't be folded into it.
- **`github-actions[bot]` casts the approval.** The Go/No-Go review approves using
  `GITHUB_TOKEN` (a different identity from the App author, so the approval counts toward
  the required-review rule). This requires the repo setting *"Allow GitHub Actions to
  create and approve pull requests"* to be enabled. Yes, the automation approves the
  automation — acceptable on a single-maintainer repo; that is exactly what the setting
  exists for.
- **The Go/No-Go verdict is a deterministic diff check, not a model call.** The rule it
  enforces is mechanical — the diff must be *exactly* the expected version strings, in
  exactly the files implied by the PR metadata, and nothing else — and the workflow
  already parses the expected old/new versions out of the PR body. So it is checked
  directly against `gh pr diff`: the changed-file set must equal the expected set, every
  `+`/`-` line must match the one edit its file is permitted to contain, and every
  claimed change must actually be present. Anything unaccounted for is NO_GO.

  This *was* a GitHub Models call (`openai/gpt-5`, reachable with `GITHUB_TOKEN` +
  `models: read`, chosen because GitHub Models carries no Anthropic/Claude models). That
  endpoint is being retired: on 2026-08-08 it returned `github_models_retirement_brownout`
  to all three attempts, the fail-safe held the verdict at NO_GO, and a green,
  provably-clean 9.5.0 bump was blocked with the misleading message "the diff doesn't
  look like a clean version bump" — when in truth no verdict had been reached at all.
  A decidable check should not have an availability dependency, a per-call cost, or a
  nondeterministic answer. The rewrite also tightened the rule: the old prompt allowed a
  static list of three files, whereas the check now requires the changed set to *match*
  what the metadata claims, so a Traefik-only bump that also edits `.env.example` is
  caught. Claude remains on the broken-release path via the Copilot coding agent, where
  code-fixing judgement genuinely is needed and it runs server-side on the maintainer's
  Copilot Pro license (no key). The gate result is cast as an *approving review*, not
  Copilot's native code review — Copilot's review is comment-only and cannot satisfy a
  required-review rule. NO_GO blocks the merge and pings the maintainer; it is not the
  broken-release path (nothing for an agent to fix).
- **Merge is gated by a required *approval*, not by required *status checks*.** Branch
  protection on `main` requires one approving review (dismissed on new commits); it does
  **not** list the `test-*` workflows as required status checks. This is deliberate: those
  workflows carry path filters, and a required check with a path filter wedges any PR that
  doesn't touch those paths (including the maintainer's manual PRs) — it waits forever on a
  check that never runs. Instead, the gate workflow itself confirms every version-update CI
  check is green (via `gh pr checks`) *before* it approves, so CI still hard-gates the
  merge — the enforcement just lives in the gate logic rather than in branch protection.
- **`test-letsencrypt` is deliberately not run on PRs.** It issues real Let's Encrypt
  certificates and would burn rate limits on every bump, so it stays on its weekly
  schedule. A lightweight `validate-letsencrypt-config` check (compose parsing + ACME
  resolver presence, no real certs) runs on PRs in its place.
- **Major version bumps still auto-ship** but always open a heads-up issue tagging the
  maintainer, so a major is never merged silently.
