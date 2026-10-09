---
name: add-config-option
description: Checklist for adding or changing a setting that flows from config.toml through the Jinja2 templates into the Containerfile, entrypoint, devbox launcher and installer.
disable-model-invocation: true
---

# Add or change a config option

Every path, name and default shared between the image and the host scripts
lives in `config.toml`. Generated files are never edited by hand (a hook
blocks it).

1. **config.toml**: add the key to the right table (`image`, `user`,
   `dotfiles`, `container`, `claude`, `host`, `repo`) with a comment saying
   what it is for. Host paths may start with `~/`; templates expand them via
   the `host_path` macro in `templates/_macros.j2`.
2. **Templates**: use it everywhere it applies. Check each one:
   - `templates/Containerfile.j2`: build-time paths, packages, user.
   - `templates/entrypoint.sh.j2`: bash, runs in Debian as root then as the
     user.
   - `templates/devbox.j2`: zsh (`#!/bin/zsh -f`), runs on macOS. Also
     update its `usage` text if the option is user-visible.
   - `templates/install.sh.j2`: zsh, runs on macOS, may be piped from curl.
   - `render.py`: only if the value needs validation or a new filter.
3. **Render and check**: the PostToolUse hook does this after each edit.
   To run it by hand: `uv run render.py && tests/smoke.sh`.
4. **Test**: add a `check` to `tests/smoke.sh` for the new behaviour (see
   the `smoke-test` skill).
5. **CI**: if the value is needed at build time from outside the
   Containerfile (e.g. a build arg), read it from `config.toml` in
   `.github/workflows/build.yml` the way `image.name` is read.
6. **README.md**: document user-visible options and environment variables.
7. **Commit** the template, `config.toml` and the regenerated files
   together; CI's `render.py --check` fails otherwise.
