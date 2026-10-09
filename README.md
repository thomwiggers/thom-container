# thom-container

Debian 13 development container for [Apple's `container`](https://github.com/apple/container),
with [my dotfiles](https://github.com/thomwiggers/chezmoi-dotfiles), Homebrew,
Claude Code and the GitHub CLI.

## Usage

```sh
container registry login ghcr.io   # only if the package is private
./install.sh                       # from a clone: symlinks bin/devbox
# or, without a clone:
curl -fsSL https://raw.githubusercontent.com/thomwiggers/thom-container/main/install.sh | zsh

devbox                      # current folder at /project, "private" profile
devbox -p work ~/src/foo    # other folder, "work" profile
devbox --pull               # pull the latest image first
devbox --self-update        # update devbox itself (git pull, or re-download)
devbox -- claude            # run a command instead of a login shell
devbox --docker             # also start dockerd inside (grants all capabilities)
```

Running `devbox` again for the same folder and profile attaches a new shell
to the running container.

- **Home directory** (`/home/thom`) is persisted per profile in
  `~/.cache/thom-containers/<profile>`. On first start it is seeded from the
  image.
- **Dotfiles**: the image is built without the age key. When
  `~/.config/chezmoi/key.txt` exists on the host, it is mounted read-only and
  the entrypoint runs `chezmoi apply` with encrypted files included.
- **SSH agent** is forwarded with `container run --ssh`.
- **GitHub**: `devbox` passes the host's `gh auth token` in; the entrypoint
  runs `gh auth login --with-token` and unsets the variable. `~/.config/gh` is
  a tmpfs, so the token is never written to the persisted home. Pick an
  account per profile under `[host.github_users]` in `config.toml`; skip with
  `--no-gh`.
- **Claude Code** per-project state: every folder is mounted at `/project`, so
  the launcher mounts `~/.claude/projects/<host path>` over
  `~/.claude/projects/-project` to keep projects apart.
- **Ephemeral paths** (`~/.ssh/sockets`, `~/.config/gh`) are a fresh tmpfs per container.
- **On every start** the entrypoint runs `chezmoi update --force` (falls back to
  `chezmoi apply` when offline).
- **Docker**: `--docker` adds `--cap-add ALL` and starts `dockerd`. Each Apple
  container is its own VM, so this doesn't loosen isolation from the Mac.
  Images live on the container's root filesystem and are lost on exit.

## Layout

`Containerfile`, `entrypoint.sh`, `bin/devbox` and `install.sh` are generated from
`templates/*.j2` and `config.toml` so paths stay in sync. Edit those, then:

```sh
uv run render.py          # regenerate
uv run render.py --check  # what CI runs
tests/smoke.sh            # stub-based tests of the scripts
```

Local build: `container build -f Containerfile -t ghcr.io/thomwiggers/thom-container:latest .`

## CI

`.github/workflows/build.yml` builds `linux/arm64` natively and pushes to
`ghcr.io/thomwiggers/thom-container` on `main`, weekly, and on demand.
Layer cache is stored in the registry (`:buildcache`). The Homebrew layer is
keyed on the dotfiles' `.chezmoidata.toml`, so other dotfiles commits don't
rebuild it.
