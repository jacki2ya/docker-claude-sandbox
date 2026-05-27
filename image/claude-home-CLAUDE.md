# claude-sandbox environment

You are running inside an **ephemeral `claude-sandbox` Docker container**, not
on the user's host. This file is baked into the image and loaded into every
session regardless of which project is mounted. Internalise the operational
facts below — they change what actions are sensible, and you should not need
the user to remind you of them.

## Filesystem

- **`/workspace`** is a bind-mount of one project directory from the host.
  Writes here land directly on the host's filesystem — treat it as trusted but
  mutable, and the user's actual work.
- **`~/.claude/projects/-workspace/`** is *also* bind-mounted from the host.
  Auto-memory (`MEMORY.md` + memory notes) and conversation transcripts
  (`*.jsonl`) saved here persist across container runs and are **shared with
  the user's native host Claude Code sessions for the same project**. Save
  durable cross-session knowledge here as usual.
- **Everything else** in the container — the rest of `~`, `/etc`, installed
  apt/npm/pip packages, anything outside the two mounts above — is **discarded
  when the container exits**. If you need a dependency to survive, install it
  *into the project* (`node_modules/`, a Python venv, etc.), not globally.
- Nothing on the host outside `/workspace` is visible. There is no `/Users`,
  no host home dir, no Keychain, no host `~/.ssh`.

## Privileges and tooling

- You have **NOPASSWD sudo**. `sudo apt-get install …` works mid-session for
  ad-hoc tooling, but the install will not survive the next container start.
- `--dangerously-skip-permissions` is **on** by design. The container is the
  safety boundary, not the permission prompt.
- Outbound network is unrestricted.

## Git: commit yes, push no

- No SSH keys or host git credentials are mounted. `git commit` works
  (author identity is forwarded from the host). **`git push` will fail** —
  do not attempt it. The user will push from the host themselves.
- The repo in `/workspace` IS the host's working tree (same inode), so
  commits you create are immediately visible on the host.

## What this changes about your behaviour

- Don't suggest "I'll install X globally so it's always available" — it won't
  be next session. Install into the project or document the apt command.
- Don't try to push branches, open PRs via SSH remotes, or configure git
  credentials. Hand off to the user for anything that requires auth to a
  remote.
- Don't worry about polluting the user's host home directory by writing to
  `~` — it's ephemeral. But auto-memory under `~/.claude/projects/-workspace`
  IS visible to host sessions, so keep entries useful and project-relevant.
- If the user asks "what environment are you in?" or "are you in the
  sandbox?", answer concretely from the facts above.
