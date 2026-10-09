# thom-container

Debian 13 development container for [Apple's `container`](https://github.com/apple/container),
with [my dotfiles](https://github.com/thomwiggers/chezmoi-dotfiles), Homebrew,
Claude Code and the GitHub CLI.

## Usage

```sh
ln -s "$PWD/bin/devbox" ~/.local/bin/devbox
container registry login ghcr.io   # only if the package is private

devbox                      # current folder at /project, "private" profile
devbox -p work ~/src/foo    # other folder, "work" profile
devbox --pull               # pull the latest image first
devbox -- claude            # run a command instead of a login shell
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

## Layout

`Containerfile`, `entrypoint.sh` and `bin/devbox` are generated from
`templates/*.j2` and `config.toml` so paths stay in sync. Edit those, then:

```sh
uv run render.py          # regenerate
uv run render.py --check  # what CI runs
```

Local build: `container build -f Containerfile -t ghcr.io/thomwiggers/thom-container:latest .`

## CI

`.github/workflows/build.yml` builds `linux/arm64` natively and pushes to
`ghcr.io/thomwiggers/thom-container` on `main`, weekly, and on demand.
Layer cache is stored in the registry (`:buildcache`). The Homebrew layer is
keyed on the dotfiles' `.chezmoidata.toml`, so other dotfiles commits don't
rebuild it.
