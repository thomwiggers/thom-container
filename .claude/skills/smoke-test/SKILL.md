---
name: smoke-test
description: Run and extend the stub-based smoke tests for bin/devbox, install.sh and entrypoint.sh. Use after changing templates or config.toml, when adding launcher/installer/entrypoint behaviour that needs a test, or when asked whether the scripts still work. Apple's container CLI is not available here, so this is the only runtime check short of a Mac.
---

# Smoke tests

`tests/smoke.sh` exercises the generated scripts on Linux. It puts stubs for
`container`, `sysctl`, `uname`, `git`, `curl` and `chezmoi` in front of
`PATH`; each prints its arguments, so a test asserts on the exact command
lines the scripts would run.

## Run

```sh
uv run render.py && tests/smoke.sh
```

CI runs the same thing in the `lint` job, and the PostToolUse hook runs it
after every edit to `templates/`, `config.toml`, `render.py` or `tests/`.

## What it can and cannot tell you

- Can: argument parsing, the `container run`/`exec` flags (mounts, tmpfs,
  caps, SSH, key mount), container naming, profile checks, `--self-update`
  paths, installer behaviour, the entrypoint's user stage (seeding, image
  change handling, key link, `chezmoi update` fallback).
- Cannot: the entrypoint's root stage (needs root), the image build, or
  anything Apple's runtime actually does (virtiofs ownership, nested mounts,
  `--ssh` socket permissions, dockerd). Say so when reporting.

## Adding a test

Follow the existing pattern in `tests/smoke.sh`:

```bash
out=$(devbox --some-flag)
check "description" "$out" \
    "substring that must appear" \
    "!substring that must not appear"
```

- `devbox` runs `bin/devbox` with zsh from the `My Proj` folder; `entry`
  runs the entrypoint's user stage with paths rewritten into the temp dir.
- To make a stub behave differently for one case, re-`stub` it (see the
  failing `chezmoi update` case) or pass an env var the stub reads
  (`RUNNING`, `FAKE_DOWNLOAD`).
- For expected failures use `out=$(...) && fail ... || check ...`.
- Keep stubs POSIX sh; keep the harness passing `shellcheck`.
