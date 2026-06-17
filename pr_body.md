## Automated version update

- Elastic Stack: `9.3.2` → `9.4.2`
- Traefik: `3.6.4` → `3.7.5`

CI runs on this PR. Once all checks pass, an automated Go/No-Go review approves and the change auto-merges; an Elastic version change then cuts a `v9.4.2` release. A CI failure opens a tracking issue and dispatches the Copilot coding agent.

<!-- version-update-meta
{"elastic_old":"9.3.2","elastic_new":"9.4.2","elastic_changed":true,"traefik_old":"3.6.4","traefik_new":"3.7.5","traefik_changed":true,"is_major":false}
-->
