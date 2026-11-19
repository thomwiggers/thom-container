# Per-folder home

## Intent

A profile's folders share one home on the host but each has its own `/nix`.
Every container start runs `home-manager switch`, which points the home's
links (`~/.zshrc`, `~/.config/*`, `~/.claude/CLAUDE.md`, `~/.claude/skills`)
into that folder's store. A second container on the same profile therefore
leaves the first one's links dangling. The `--relink` hook only repairs them
when a new shell starts, and repairing them breaks the other container again.

Nothing in the shared home is relied on across folders, `~/.claude` included.
We give each folder its own home, next to its `/nix`.

## Goals

- Containers of one profile on different folders never touch each other's
  home or store.
- Existing Claude Code state for a folder (sessions, memory, plugins,
  settings) carries over once.

## Non-goals

- Sharing anything between folders of a profile.
- Deleting the old per-profile host homes.

## Approaches

- **A. Home on the folder's volume (chosen).** The per-folder ext4 volume
  holds the home next to the `/nix` overlay. Home and store live and reset
  together, the home is off virtiofs (faster, case-sensitive), and an image
  change restarts only the overlay. The home is not visible from Finder.
- **B. Host directory per folder.** Smaller launcher change and visible from
  the Mac, but stays on slow, case-insensitive virtiofs, and reset has to
  clean directories and volumes separately.
- **Shared `~/.claude`.** Rejected: Home Manager's store links inside it
  dangle across folders in the same way. Sharing only parts of it fails
  because Claude replaces `settings.json` and `~/.claude.json` on write.

## Design

**Volume.** One volume per (profile, folder), `<container name>-state`,
mounted at `container.state_mount` (`/run/devbox-state`, replacing
`nix_state_mount`). Layout:

- `nix/upper`, `nix/work`, `nix/.thom-container-nix`: the `/nix` overlay and
  its marker. On a marker change, only `nix/` starts over.
- `home/`: bound over `/home/thom` by the entrypoint's root stage.

The launcher no longer mounts a host directory at the home. It deletes the
folder's old `<name>-nix` volume and the profile's older `-nix` volume, as it
does for earlier layouts today.

**Entrypoint root stage**, in order: mount the overlay, bind `home/` over
the home, then mount the `container.ephemeral` tmpfs paths itself (the
launcher's nested `--tmpfs` would be hidden under the bind). The home's Nix
state is no longer bound from the overlay: the home is per folder, so it
holds that state directly. The existing refresh of `container.nix_state` on
a marker change stays, in the user stage.

If the volume is missing or a mount fails, warn and run on the image's own
home (not persisted).

**Seeding.** A new `home/` is seeded from `container.home_seed` as today.
Once, before that, `~/.claude` and `~/.claude.json` are copied from the old
profile home when it exists. The launcher mounts that home read-only at a
side path for this. Of `~/.claude/projects`, only the folder's own directory
is copied, renamed to `-project`.

**Claude per-project bind.** Removed: `~/.claude` is per folder, so
`~/.claude/projects/-project` already belongs to the folder.
`THOM_CONTAINER_CLAUDE_PROJECT` stays, only to name the directory to migrate.

**Relink.** `entrypoint --relink`, `hm_links_dangle` and the
`/etc/zsh/zshenv` hook are removed.

**Reset.** Both options now act on the current folder only.
- `--reset`: the launcher passes `THOM_CONTAINER_RESET=1` to the new
  container. Before mounting, the entrypoint empties `nix/` and everything in
  `home/` except `container.claude.state`, then seeds as usual. It refuses
  if that folder's container is running.
- `--reset-all`: the launcher deletes the volume.

**Docs.** Update README.md (home, Nix store, reset, Claude per-project
state) and CLAUDE.md's Gotchas (drop the relink and per-project bind
entries).

## Left to the builder

- Exact config key names and their comments in `config.toml`.
- Smoke-test coverage for the new launcher arguments and the reset flag.
