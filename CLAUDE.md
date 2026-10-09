# thom-container

Debian 13 dev image for Apple's `container` plus the macOS-side `devbox`
launcher and installer. See README.md for usage.

## Generated files

`Containerfile`, `entrypoint.sh`, `bin/devbox` and `install.sh` are rendered
from `templates/*.j2` + `config.toml` by `render.py`. Never edit them
directly (a PreToolUse hook blocks it); edit the template, and the
PostToolUse hook re-renders and runs the checks. They stay committed:
`curl | zsh` and `devbox --self-update` download them from GitHub, and CI's
`render.py --check` keeps them in sync. Use the `add-config-option` skill
for new settings.

## Shells

- `bin/devbox`, `install.sh`: zsh (`#!/bin/zsh -f`), run on macOS. Lint
  with `zsh -n`. `$0` inside a function is the function name, and a
  function's EXIT trap runs after its locals are gone.
- `entrypoint.sh`, `tests/smoke.sh`: bash, linted with shellcheck.

## Testing

`tests/smoke.sh` stubs `container`, `chezmoi`, etc. (see the `smoke-test`
skill). Nothing here can run Apple's runtime or the entrypoint's root
stage; the image only builds in CI (`ubuntu-24.04-arm`, ~5 min). Say what
was not tested.

## Gotchas

- The dotfiles' decrypt script checks `.chezmoi.args` for the literal
  `--exclude encrypted` (two words); without the key, chezmoi must get it
  in that form or it prompts for a passphrase.
- Every project is mounted at `/project`, so the launcher mounts
  `~/.claude/projects/<host path slug>` over `~/.claude/projects/-project`
  to keep Claude's per-project state apart.
- chezmoi and zsh both replace symlinked target files rather than writing
  through them; persist directories, not single files.
- `astral-sh/setup-uv` has no floating major tags (`@v10` fails); pin the
  full version. Other actions do have `@vN`.
- Docker actions and GitHub's own actions are on Node 24 majors; check
  `using:` in `action.yml` when bumping.
