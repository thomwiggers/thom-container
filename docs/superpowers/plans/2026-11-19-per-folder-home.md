# Per-folder Home Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Each (profile, folder) container keeps its whole home on its own volume, next to its `/nix` overlay, so containers never break each other's Home Manager links.

**Architecture:** The launcher stops mounting the per-profile host home and mounts one `<name>-state` volume. The entrypoint's root stage overlays `nix/` on `/nix`, binds `home/` over the home and mounts the ephemeral tmpfs paths. The user stage migrates Claude state once from the old profile home, mounted read-only. The relink machinery and the per-project Claude bind go away.

**Tech Stack:** Jinja2 templates rendered by `render.py` from `config.toml`. zsh for the launcher and the smoke tests, bash for the entrypoint.

**Spec:** `docs/superpowers/specs/2026-11-19-per-folder-home-design.md`

## Global Constraints

- Never edit `Containerfile`, `entrypoint.sh`, `bin/devbox` or `install.sh` directly. Edit `templates/*.j2` and `config.toml`. The PostToolUse hook re-renders and runs the checks. Otherwise run `uv run render.py && tests/smoke.sh`.
- Volume name: `<container name>-state`. Mount point: `container.state_mount = "/run/devbox-state"`, replacing `nix_state_mount`.
- Volume layout: `nix/upper`, `nix/work`, `nix/.thom-container-nix`, `home/`.
- Old profile home mount: `container.old_home = "/run/devbox-old-home"`, read-only, only when `$state_root/<profile>` exists.
- Reset flag: `THOM_CONTAINER_RESET=1`.
- The launcher is `#!/bin/zsh -f`, linted with `zsh -n`, and must run on macOS. The entrypoint is bash, linted with shellcheck.
- Commit messages end with the attribution lines from the session.

## Review Focus

1. **An existing `<name>-nix` volume.** The launcher deletes it and creates `<name>-state`. Test: "old per-folder volume removed" (Task 1).
2. **Migration when the old home has no directory for this folder.** Copy `~/.claude` without a `projects/` entry, and copy `~/.claude.json`. Do not fail. Test: "migration without this folder's projects" (Task 3).
3. **A second start of a migrated folder.** It does not copy again, even if the folder's own Claude state was changed meanwhile. Test: "migration runs once" (Task 3).
4. **`--reset` while this folder's container runs.** Refuse, but do not refuse because of another folder's running container. Test: "--reset refuses only for this folder" (Task 1).
5. **No old profile home on the Mac.** The launcher adds no `/run/devbox-old-home` mount, and seeding proceeds. Tests: "no old home, no mount" (Task 1) and "first start without old home" (Task 3).

---

### Task 1: Launcher and config

**Files:**
- Modify: `config.toml` (`[container]`: replace `nix_state_mount` with `state_mount`; add `old_home`; reword the `home`, `nix_state` and `ephemeral` comments)
- Modify: `templates/devbox.j2`
- Test: `tests/smoke.sh` ("devbox" and "--reset" sections)

**Interfaces:**
- Produces: `container run` gets `--volume <name>-state:/run/devbox-state`, `--volume $state_root/<profile>:/run/devbox-old-home:ro` when that directory exists, `-e THOM_CONTAINER_CLAUDE_PROJECT=<host slug>`, and `-e THOM_CONTAINER_RESET=1` after `--reset`. It no longer gets `--volume …:/home/thom` or `--tmpfs /home/thom/…`.

- [ ] **Step 1: Update the tests in `tests/smoke.sh`**

In "run with defaults", replace the home, nix-volume and tmpfs expectations with:
```zsh
"--volume dev-private-my-proj-$hash-state:/run/devbox-state" \
"container volume create dev-private-my-proj-$hash-state" \
"!:/home/thom " "!--tmpfs" "!THOM_CONTAINER_RESET" \
"-e THOM_CONTAINER_CLAUDE_PROJECT=$claude_dir " \
```
Drop the "creates per-project Claude dir" assertion and add `[[ ! -e $state/private ]]` → "no profile home created".

Add:
- "no old home, no mount": `!/run/devbox-old-home` with no `$state/private`.
- "old home mounted read-only": after `mkdir -p $state/private`, expect `--volume $state/private:/run/devbox-old-home:ro`.
- "old per-folder volume removed": with `VOLUMES=dev-private-my-proj-$hash-nix`, expect `container volume delete dev-private-my-proj-$hash-nix`.

Replace the "--reset" section:
- "--reset refuses only for this folder": with `LISTED=dev-private-other-1`, expect `container run`. With `RUNNING`/`LISTED` naming this folder's container (match how the stub marks `container inspect` as running), expect a nonzero exit and "is running".
- "--reset passes the flag": with `<<<y`, expect `-e THOM_CONTAINER_RESET=1` and `!volume delete`. On `<<<n`, expect "aborted" and no `container run`.
- "--reset-all deletes the volume": with `VOLUMES=dev-private-my-proj-$hash-state` and `<<<y`, expect `container volume delete dev-private-my-proj-$hash-state`, `!dev-private-other`, `!THOM_CONTAINER_RESET` and `container run`.
- Keep "old shared volume removed" (`dev-private-nix`) and the `private.nix` directory cleanup.

- [ ] **Step 2: Run the tests and confirm the new ones fail**

Run: `uv run render.py && tests/smoke.sh`
Expected: the cases above FAIL, the others pass.

- [ ] **Step 3: Implement in `templates/devbox.j2`**

- `state_volume="$name-state"`. Delete `$name-nix` and `<prefix>-$profile-nix` when present, with the existing warning style.
- Stop `mkdir -p "$home_state"` and the per-project Claude dir. Add the old-home mount only when `-d $home_state`.
- `--reset`: refuse when `container inspect "$name"` succeeds. Ask "Reset the home and Nix store of $dir (profile '$profile', keeping ~/.claude, ~/.claude.json)? [y/N]", then add `-e THOM_CONTAINER_RESET=1`.
- `--reset-all`: ask, then `container volume delete "$state_volume"` when it exists.
- Both fall through to starting the container, as today. Update `usage` for the per-folder scope.

- [ ] **Step 4: Run the tests**

Run: `uv run render.py && tests/smoke.sh && zsh -n bin/devbox`
Expected: all pass, except the entrypoint cases that Task 2 rewrites (`relink`, and any that need `relink_lock`).

- [ ] **Step 5: Commit**

```bash
git add config.toml templates/devbox.j2 bin/devbox tests/smoke.sh
git commit   # "Give each folder its own state volume in the launcher"
```

### Task 2: Entrypoint root stage and image

**Files:**
- Modify: `templates/entrypoint.sh.j2` (`mount_nix` → `mount_state`; remove `mount_claude_project`, `hm_links_dangle`, `relink`, `relink_lock`, the `--relink` dispatch and the `nix_home` binds)
- Modify: `templates/Containerfile.j2:187-197` (remove the `/etc/zsh/zshenv` relink hook)
- Test: `tests/smoke.sh` (remove the relink cases and the `relink_lock` sed line)

**Interfaces:**
- Consumes: Task 1's mounts and `THOM_CONTAINER_RESET`.
- Produces: `state_vol={{ container.state_mount }}` and `old_home={{ container.old_home }}` variables. On return from the root stage, `$home_dir` is the folder's `home/` (or the image's home on failure) with the ephemeral tmpfs paths mounted.

- [ ] **Step 1: Remove the relink tests and the `relink_lock` sed rewrite from `tests/smoke.sh`**

- [ ] **Step 2: Implement `mount_state` in `templates/entrypoint.sh.j2`, called first in `root_stage`**

1. Return 0 if `$state_vol` is not a mountpoint. Warn "no state volume; the home is not persisted".
2. If `THOM_CONTAINER_RESET` is set: log "resetting the home and Nix store". Delete `$state_vol/nix`, and everything in `$state_vol/home` except `{% for p in claude.state %}`. Unset the variable.
3. The current marker and overlay logic, rebased on `$state_vol/nix`. On a mismatch, only `nix/` starts over. A volume with a top-level `upper`, or a marker at `$state_vol/.thom-container-nix`, is a pre-rename layout; it cannot occur under the new name, so do not handle it.
4. `mkdir -p "$state_vol/home"`, `chown "$user_uid:$user_gid"` it, then `mount --bind "$state_vol/home" "$home_dir"`. On failure, warn "using the image's home; not persisted" and continue.
5. For each `container.ephemeral` path: `mount -t tmpfs -o mode=0700,uid=$user_uid,gid=$user_gid tmpfs "$home_dir/<p>"`, after creating the directory as the user. Replace the existing chown loop.

Remove `mount_claude_project` and its call. Keep `THOM_CONTAINER_CLAUDE_PROJECT` set for the user stage.

- [ ] **Step 3: Remove the zshenv hook from `templates/Containerfile.j2`**

- [ ] **Step 4: Run the checks**

Run: `uv run render.py && tests/smoke.sh && shellcheck entrypoint.sh && uv run render.py --check`
Expected: all pass. The root stage itself is not exercised here.

- [ ] **Step 5: Commit**

```bash
git add templates/entrypoint.sh.j2 templates/Containerfile.j2 entrypoint.sh Containerfile tests/smoke.sh
git commit   # "Bind the folder's home from its volume; drop relink"
```

### Task 3: Migrate Claude state from the old profile home

**Files:**
- Modify: `templates/entrypoint.sh.j2` (`user_stage`, before seeding)
- Test: `tests/smoke.sh` (entrypoint section; add `-e "s#^old_home=.*#old_home=$ep/old#"` to the sed rewrite)

**Interfaces:**
- Consumes: `old_home`, `THOM_CONTAINER_CLAUDE_PROJECT`.
- Produces: `migrate_claude()` in the entrypoint. It runs only when `$home_dir/$marker` is absent and `$old_home` is a directory, and it unsets `THOM_CONTAINER_CLAUDE_PROJECT` afterwards.

- [ ] **Step 1: Write the tests**

Before the first `entry` call, create `$ep/old/.claude/{history.jsonl,projects/-Users-x-proj/s.jsonl,projects/-Users-x-other/o.jsonl}` and `$ep/old/.claude.json`.

- "first start migrates Claude state": `THOM_CONTAINER_CLAUDE_PROJECT=-Users-x-proj entry`. Expect "copying Claude Code state from". Then assert that `$ep/home/.claude/history.jsonl`, `$ep/home/.claude.json` and `$ep/home/.claude/projects/-project/s.jsonl` exist, and that `$ep/home/.claude/projects/-Users-x-other` and `$ep/home/.claude/projects/-Users-x-proj` do not.
- "migration runs once": edit `$ep/home/.claude.json`, run `entry` again, and assert the edit survives and the log lacks "copying Claude".
- "migration without this folder's projects": on a fresh home with `THOM_CONTAINER_CLAUDE_PROJECT=-Users-x-none`, expect "DONE", and `$ep/home/.claude/history.jsonl` exists.
- "first start without old home": with `$ep/old` absent, expect "seeding" and "!copying Claude".
- "bad project name": with `THOM_CONTAINER_CLAUDE_PROJECT=../x`, expect a warning and no `-project` directory.

Keep the existing first-start test working: run it with `$ep/old` absent, or reorder.

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `uv run render.py && tests/smoke.sh`

- [ ] **Step 3: Implement `migrate_claude`**

- Copy `.claude.json` and `.claude/`, excluding `projects/`, with `cp -a --update=none`.
- Copy `.claude/projects/$name` to `.claude/projects/-project`. Validate `$name` against `*[!A-Za-z0-9-]*` as `mount_claude_project` did.
- Copy errors warn and continue. Seeding runs after it, and its `--update=none` keeps the migrated files.

- [ ] **Step 4: Run the tests**

Run: `uv run render.py && tests/smoke.sh && shellcheck entrypoint.sh`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add templates/entrypoint.sh.j2 entrypoint.sh tests/smoke.sh
git commit   # "Copy a folder's Claude state from the old profile home once"
```

### Task 4: Docs

**Files:**
- Modify: `README.md` (Home directory, Nix store, `--reset`/`--reset-all` lines, Claude per-project state, Ephemeral paths, the SSH host-key paragraph: now per folder)
- Modify: `CLAUDE.md` Gotchas (drop the shared-home relink entry and the `~/.claude/projects` bind entry; add: the home is bound from the state volume in the root stage, so nested runtime mounts under the home are hidden and tmpfs paths are mounted by the entrypoint)
- Modify: `.claude/skills/smoke-test/SKILL.md` only if it names removed behavior

- [ ] **Step 1: Edit the docs in the user's voice (short declarative sentences, no em-dashes)**
- [ ] **Step 2: Run `uv run render.py --check && tests/smoke.sh`**
- [ ] **Step 3: Commit** (`git add README.md CLAUDE.md`, "Document the per-folder home")
