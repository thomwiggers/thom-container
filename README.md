# thom-container

Debian 13 development container for [Apple's `container`](https://github.com/apple/container),
with [my dotfiles](https://github.com/thomwiggers/home-manager-config) (Nix and
Home Manager), Claude Code and the GitHub CLI.

## Usage

```sh
container registry login ghcr.io   # only if the package is private
./install.sh                       # from a clone: symlinks bin/devbox
# or, without a clone:
curl -fsSL https://raw.githubusercontent.com/thomwiggers/thom-container/main/install.sh | zsh

devbox                      # current folder at /project, "private" profile
devbox -p work ~/src/foo    # other folder, "work" profile
devbox --pull               # pull the latest image first
devbox --attach             # new shell in the running container; fail if none
devbox --code               # open VS Code on /project in the running container (Remote-SSH)
devbox --reset              # wipe the profile's persisted home and Nix store (asks first)
devbox --self-update        # update devbox itself (git pull, or re-download)
devbox -- claude            # run a command instead of a login shell
devbox --docker             # also start dockerd inside (grants all capabilities)
devbox -c 4 -m 16G          # 4 CPUs, 16 GiB (default: all CPUs, 8G); new containers only
devbox -p work --register-claude-token  # store a `claude setup-token` token for the profile
```

Running `devbox` again for the same folder and profile attaches a new shell
to the running container.

A folder can pick its profile with a `.thom-container-profile` file (profile
name on the first line) in it or any parent. Precedence: `-p`,
`$THOM_CONTAINER_PROFILE`, the file, then the default.

- **Home directory** (`/home/thom`) is persisted per profile in
  `~/.cache/thom-containers/<profile>`. On first start it is seeded from the
  image.
  Inside, `$THOM_CONTAINER_PROFILE` says which profile is active.
- **Nix store** (`/nix`) is persisted per profile too, in the container
  volume `dev-<profile>-nix` (ext4: the store has paths differing only in
  case, which a case-insensitive macOS folder can't hold), so `nix profile
  add` and Home Manager builds survive the container. The entrypoint seeds it from the
  image's `/nix` (slow, once) and bind-mounts it. The store is replaced when
  the image's `/nix` changes (the dotfiles hash, so not on every rebuild),
  dropping what was added since. Don't use two containers of one
  profile for Nix at the same time: single-user Nix has no cross-container
  locking. Nothing garbage-collects it; run `nix-collect-garbage -d`.
  After the dotfiles switch, the entrypoint warns and suggests `devbox --reset`
  if `~/.nix-profile` dangles or `nix store ping` fails. The store is only
  keyed on the dotfiles hash, so a rebuild that changes `/nix` otherwise (say
  a new Nix version) keeps the old store until you `--reset`.
- **Dotfiles**: the image is built without the age key. When
  `~/.config/age/keys.txt` exists on the host, it is mounted read-only and
  linked to the same path in the container, so the switch decrypts the
  secrets. The flake is checked out at `~/.config/home-manager`.
- **SSH agent** is forwarded with `container run --ssh`. The host's
  `~/.ssh/known_hosts` is mounted read-only as an extra `GlobalKnownHostsFile`.
- **Terminfo**: `devbox` sends `infocmp -x $TERM` from the host (Ghostty.app
  ships `xterm-ghostty`), and the entrypoint compiles it into `~/.terminfo`.
- **GitHub**: `devbox` passes the host's `gh auth token` in; the entrypoint
  runs `gh auth login --with-token` and unsets the variable. `~/.config/gh` is
  a tmpfs, so the token is never written to the persisted home. Pick an
  account per profile under `[host.github_users]` in `config.toml`; skip with
  `--no-gh`.
- **Claude Code login**: the host's `claude` can only hand out a token for
  the account it is signed in to, so tokens are registered per profile by
  hand: run `claude setup-token` signed in to that profile's account, then
  `devbox -p <profile> --register-claude-token` and paste it. It goes in the
  login Keychain (service `thom-container-claude`, account = profile; delete
  with `security delete-generic-password -s thom-container-claude -a
  <profile>`). It is never put in an environment variable on the way in:
  `devbox` writes it to a private directory under `$TMPDIR`, mounted at
  `/run/host-claude`, and the entrypoint moves it to `/run/user/<uid>` (not
  persisted) and deletes the host's copy. Claude Code reads it from a file
  descriptor: the entrypoint (and the dotfiles' zshenv, for attach and ssh
  shells) opens it on fd 9 and exports
  `CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR=9`, so no environment variable
  holds the token itself.
- **Claude Code** per-project state: every folder is mounted at `/project`, so
  the entrypoint bind-mounts `~/.claude/projects/<host path>` over
  `~/.claude/projects/-project` to keep projects apart.
- **Ephemeral paths** (`~/.ssh/sockets`, `~/.config/gh`) are a fresh tmpfs per container.
- **On every start** the entrypoint pulls the dotfiles and runs
  `home-manager switch` (with `--offline` when the pull fails). When the image
  has changed, the Nix profile links in the persisted home are first replaced
  by the image's.
- **Hostname** is `devbox-<folder>`. `container run` has no `--hostname`, so
  the launcher adds `CAP_SYS_ADMIN` and the entrypoint sets it, then drops
  the capability before starting the shell.
- **SSH / VS Code**: the image runs `sshd` (key-only, user `thom`), and the
  entrypoint authorizes the public keys of the forwarded SSH agent
  (`ssh-add -L`). `devbox` prints `ssh: thom@<name>.devbox` when it starts a
  container; connect with `ssh` or VS Code's Remote-SSH, which installs its
  server in the persisted home. The container is `--rm` and ends with its
  main process, but when the shell or command exits the entrypoint waits
  while ssh sessions (VS Code) are open; Ctrl-C stops it anyway.
  See [SSH access](#ssh-access) for the one-time setup on the Mac.
- **Docker**: `--docker` adds `--cap-add ALL` and starts `dockerd`. Each Apple
  container is its own VM, so this doesn't loosen isolation from the Mac.
  Images live on the container's root filesystem and are lost on exit.

## SSH access

Containers are reachable from the Mac as `<container name>.devbox` through
`container`'s DNS service. One-time setup (the domain name is
`host.dns_domain` in `config.toml`):

```sh
sudo container system dns create devbox
# ~/.config/container/config.toml:
#   [dns]
#   domain = "devbox"
container system stop && container system start   # stops running containers
```

`install.sh` warns if the domain is not registered
(`container system dns list -q`). Then add this to `~/.ssh/config`; the
snippet is printed for every registered domain:

```sh
for d in $(container system dns list -q); do
    printf 'Host *.%s\n    User thom\n    StrictHostKeyChecking accept-new\n' "$d"
done
```

```
Host *.devbox
    User thom
    StrictHostKeyChecking accept-new
```

The host key is generated once per profile and kept in the persisted home
(`~/.local/state/sshd`), so it stays valid across containers. Find the name
with `container ls` or the `ssh:` line `devbox` prints; in VS Code use
"Remote-SSH: Connect to Host…" with `dev-private-<folder>-<hash>.devbox`, or
run `devbox --code` from the folder (needs the `code` command in `PATH`;
override with `$THOM_CONTAINER_CODE`).

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
Layer cache is stored in the registry (`:buildcache`). The Home Manager layer
is rebuilt whenever the dotfiles' `HEAD` changes.
