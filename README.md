# docker-claude-sandbox

A containerised equivalent of Docker Desktop's sandbox feature for running
Claude Code with `--dangerously-skip-permissions`, for environments where the
native sandbox isn't available.

The container is the safety boundary: Claude can read and write the project
directory you mount in, but nothing else on the host. Auth flows through a
long-lived OAuth token rather than the macOS Keychain, so there's no bridging
required.

## Requirements

- Docker Desktop (Intel or Apple Silicon — works on both)
- Claude Code installed on the host (only needed once, to mint the OAuth token)

## Install

```sh
./install.sh
```

This builds the `claude-sandbox:latest` image and symlinks the `claude-sandbox`
launcher into `/usr/local/bin`.

## First-time setup

The container authenticates via `CLAUDE_CODE_OAUTH_TOKEN`. Generate one on the
host:

```sh
claude setup-token
```

Save the token where the launcher expects it:

```sh
mkdir -p ~/.claude-sandbox && chmod 700 ~/.claude-sandbox
printf '%s' 'PASTE_TOKEN' > ~/.claude-sandbox/oauth-token
chmod 600 ~/.claude-sandbox/oauth-token
```

## Verify

```sh
./test.sh              # full check, makes one live API call (~cents)
SKIP_AUTH=1 ./test.sh  # everything except the live API call
```

## Usage

```sh
# Launch Claude inside the current directory
claude-sandbox

# Launch against a specific project
claude-sandbox ~/code/some-project

# Drop into bash instead of Claude (useful for debugging the image)
claude-sandbox --shell

# Pass an arbitrary command through to the entrypoint
claude-sandbox -- claude --help
```

### Environment overrides

| Variable | Default | Purpose |
|---|---|---|
| `CLAUDE_SANDBOX_IMAGE` | `claude-sandbox:latest` | Image tag to run |
| `CLAUDE_SANDBOX_TOKEN_FILE` | `~/.claude-sandbox/oauth-token` | Host path to the OAuth token |
| `CLAUDE_SANDBOX_MEMORY` | `8g` | Container memory limit |
| `CLAUDE_SANDBOX_CPUS` | `4` | Container CPU limit |
| `CLAUDE_SANDBOX_PIDS` | `1024` | Max processes in the container (fork-bomb cap) |

## What's in the image

- Debian bookworm-slim base
- Node.js LTS, Python 3, build-essential
- git, curl, wget, jq, ripgrep, fd, vim-tiny, nano, openssh-client
- `@anthropic-ai/claude-code` (npm global)
- Non-root user `claude` (UID 1000) with NOPASSWD sudo for installing packages
  mid-session
- `DISABLE_AUTOUPDATER=1` and `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` set
  by default

## Threat model

**The sandbox prevents:**

- Reading or writing host files outside the mounted project directory
- Reading the macOS Keychain or any host credential store
- Escaping the container via the Docker socket (not mounted)
- The initial `claude` process from running as root (Claude Code refuses
  `--dangerously-skip-permissions` as root; the entrypoint enforces this)
- Leaking the OAuth token to the host process list (the launcher exports
  the token rather than inlining its value on the `docker run` command line)

**The sandbox does NOT prevent:**

- **Network exfiltration** — outbound is unrestricted by design. Anything
  Claude or its dependencies can reach, they can reach. If this matters,
  layer an egress proxy or revisit the network policy.
- **Destructive changes to your project** — files Claude writes to
  `/workspace` land directly on the host. Use git, commit often, and treat
  the workspace as trusted-but-mutable.
- **OAuth token exfiltration via the network or `/proc`** — the token is
  passed into a container with unrestricted network and is readable from
  `/proc/<pid>/environ` by anything running inside. Env-var auth is
  inherent here. Rotate via `claude setup-token` if you suspect leakage.
- **In-container privilege escalation** — the `claude` user has NOPASSWD
  sudo, so anything inside the container can become root-in-container.
  This is deliberate (it lets Claude `apt-get install` mid-session).
  Container root is not host root: no privileged mode, no added
  capabilities, no Docker socket. We intentionally don't apply
  `--security-opt=no-new-privileges` because it would break sudo. If you
  want stricter isolation, drop sudo in the Dockerfile and pre-bake any
  tools you need into the image.

This mirrors the warning in
[Anthropic's dev container docs](https://code.claude.com/docs/en/devcontainer):
the container is a strong filesystem boundary, not a network or supply-chain
boundary. Use only with trusted repositories.

## Persistence

State inside the container is fully ephemeral. Each `claude-sandbox` run
launches a fresh `/home/claude` and discards it on exit. Only `/workspace`
(your bind-mounted project) persists. If you `npm install` or `pip install`
something inside the container, it goes away — install into the project
directory (`node_modules/`, a venv) so it survives.

## Pushing to git

There is intentionally no `~/.ssh` mount and no host credential helper inside
the container. Commit inside the sandbox; push from the host. If this gets
annoying, the cleanest next step is a short-lived GitHub token passed as an
env var rather than mounting SSH keys.

## Troubleshooting

**`ERROR: CLAUDE_CODE_OAUTH_TOKEN is not set`** — Token file is missing or
empty. Re-run `claude setup-token` and re-save.

**`ERROR: Docker image not found: claude-sandbox:latest`** — Run `./install.sh`
from this directory, or `docker build -t claude-sandbox .`.

**Claude says `--dangerously-skip-permissions` is refused** — The container is
running as root for some reason. Check that the image build didn't fail at the
`USER claude` step.

**Slow file access** — macOS Docker Desktop bind mounts go through VirtioFS;
projects with many small files (huge `node_modules` trees) may feel slow.
Mostly unavoidable on macOS.

**iCloud Drive paths** — Docker Desktop's file sharing handles
`~/Library/Mobile Documents/...` paths inconsistently. If a mount fails or
files appear missing inside the container, move the project to a path under
`~/` that isn't synced.

## License

MIT — see [LICENSE](LICENSE).

---

Built with AI assistance (Claude Code).
