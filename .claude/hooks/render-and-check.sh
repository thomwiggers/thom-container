#!/bin/bash
# PostToolUse (Edit|Write): after a change to a template, config.toml,
# render.py or the tests, re-render the generated files and run the same
# checks as CI. Exit 2 feeds the output back to Claude.
set -o pipefail
file=$(jq -r '.tool_input.file_path // empty')
root=${CLAUDE_PROJECT_DIR:?}
case $file in
    "$root"/templates/* | "$root"/config.toml | "$root"/render.py | "$root"/tests/*) ;;
    *) exit 0 ;;
esac
cd "$root" || exit 0

check() {
    if [ "$file" = "$root/render.py" ]; then
        uvx ruff check --fix --quiet render.py || return
        uvx ruff format --quiet render.py || return
    fi
    uv run --quiet render.py || return
    uvx --from shellcheck-py shellcheck entrypoint.sh tests/smoke.sh || return
    zsh -n bin/devbox || return
    zsh -n install.sh || return
    # Only the failures are interesting.
    tests/smoke.sh | grep -v '^  ok '
}

if ! out=$(check 2>&1); then
    printf 'render/check failed after editing %s:\n%s\n' "${file#"$root"/}" "$out" >&2
    exit 2
fi
