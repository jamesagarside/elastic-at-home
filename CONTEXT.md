# Context: Elastic at Home

A Docker Compose deployment of the Elastic Stack for self-hosting ("Elastic at Home").

## Glossary

### Elastic Stack version
The single version, stored as `STACK_VERSION` in `.env.example`, that pins **all**
Elastic product images used by this project: Elasticsearch, Kibana, and Elastic Agent
(`docker.elastic.co/...:${STACK_VERSION}`). There is no separate version per product —
one knob moves them together. `.env.example` is the single source of truth; test
workflows resolve `STACK_VERSION` from it at runtime.

> **Not ECK.** This project does **not** use ECK (Elastic Cloud on Kubernetes) or any
> Kubernetes operator. It is Docker Compose only. "ECK Operator" is not a concept in
> this repo — when tracking "Elastic product versions" we mean the `STACK_VERSION`
> images above.

### Version update workflow
The scheduled GitHub Actions workflow (`version-update.yml`) that detects new upstream
releases of the tracked components — the **Elastic Stack version** and **Traefik** — and
drives them through the pipeline: bump → PR → CI → Go/No-Go review → merge → Release.

### Release
A GitHub release + tag, named `v<elastic-version>` (e.g. `v9.3.3`), marking the repo as
targeting that Elastic Stack version. Cut automatically once a bump's PR passes CI and
merges. A **Traefik-only** bump does **not** get its own release — it merges without a
tag and rides along in the notes of the next Elastic release.

### Broken release
A candidate Elastic version that **fails to start up or fails the CI tests**. CI is the
sole arbiter of "broken" — if a breakage slips past CI, the response is to harden the
tests, not to add a parallel notion of broken. A broken release triggers the escalation
path: a `version-update-failure` issue (one per version), tagging the maintainer, with a
**Copilot coding agent** task launched to investigate a fix.

### Go/No-Go review
An automated review step that runs after CI, evaluates the check results and the diff
with a model, and gates the merge. A **GO** casts the approving review that lets the
merge proceed; a **NO_GO** means the diff doesn't look like a clean version bump — it
blocks the merge and pings the maintainer for a human look (distinct from the
broken-release path; nothing for an agent to "fix"). The verdict model runs on
**GitHub Models** (`openai/gpt-5`, reached with `GITHUB_TOKEN` + `models: read`, no API
key). Note: GitHub Models carries no Anthropic/Claude models, so the gate does not use
Claude; the Claude-backed **Copilot coding agent** is used only on the broken-release
path, where its code-fixing ability matters.
