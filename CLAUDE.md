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

`tests/smoke.sh` stubs `container`, `nix`, etc. (see the `smoke-test`
skill). Nothing here can run Apple's runtime or the entrypoint's root
stage; the image only builds in CI (`ubuntu-24.04-arm`, ~5 min). Say what
was not tested.

## Gotchas

- The image's `/nix` holds the store; home only has links into it. On an
  image change the entrypoint swaps `container.nix_state` for the image's
  copies, or `nix` itself would be a dangling `~/.nix-profile/bin` link.
- Every project is mounted at `/project`, so the entrypoint bind-mounts
  `~/.claude/projects/<host path slug>` (named by the launcher) over
  `~/.claude/projects/-project` to keep Claude's per-project state apart.
  Not a `--volume` nested in the home: Apple's runtime doesn't reliably
  mount it after the home, and then it is hidden.
- zsh replaces symlinked target files rather than writing through them;
  persist directories, not single files.
- `astral-sh/setup-uv` has no floating major tags (`@v10` fails); pin the
  full version. Other actions do have `@vN`.
- Docker actions and GitHub's own actions are on Node 24 majors; check
  `using:` in `action.yml` when bumping.
