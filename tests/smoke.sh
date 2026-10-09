#!/bin/bash
# shellcheck disable=SC2015,SC2016  # stub bodies are literal; pass/fail never fail
# Smoke tests for the generated scripts, runnable on Linux without Apple's
# container: `container`, `sysctl`, `git`, `curl` and `chezmoi` are replaced
# by stubs that log their arguments.
#
# Usage: tests/smoke.sh   (render first: uv run render.py)
# No -e: a failing command under test should be reported, not abort the run.
set -uo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd -P)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

failures=0
pass() { printf '  ok    %s\n' "$1"; }
fail() {
    printf '  FAIL  %s\n' "$1"
    printf '%s\n' "$2" | sed 's/^/        | /'
    failures=$((failures + 1))
}
# check NAME OUTPUT [!]SUBSTRING...  (a leading ! means "must not contain")
check() {
    local name=$1 out=$2 pat
    shift 2
    for pat in "$@"; do
        if [[ $pat == !* ]]; then
            if grep -qF -- "${pat#!}" <<<"$out"; then
                fail "$name" "unexpected: ${pat#!}"$'\n'"$out"
                return
            fi
        elif ! grep -qF -- "$pat" <<<"$out"; then
            fail "$name" "missing: $pat"$'\n'"$out"
            return
        fi
    done
    pass "$name"
}

stub() {
    printf '#!/bin/sh\n%s\n' "$2" >"$work/bin/$1"
    chmod +x "$work/bin/$1"
}

mkdir -p "$work/bin" "$work/home/.config/chezmoi" "$work/My Proj"
: >"$work/home/.config/chezmoi/key.txt"
mkdir -p "$work/home/.ssh"
echo "github.com ssh-ed25519 AAAA" >"$work/home/.ssh/known_hosts"
stub container 'echo "container $*"; [ "$1" = inspect ] && { [ -n "${RUNNING:-}" ] || exit 1; }; [ "$1 $2" = "system status" ] && exit 1; exit 0'
stub sysctl 'echo 10'
stub uname 'case "$1" in -s) echo Darwin ;; -m) echo arm64 ;; esac'
stub git 'echo "git $*"'
# Host side: `gh auth token [--user U]`. Container side: `gh auth login`
# echoes the token it read from stdin.
# Host knows xterm only; container-side tic echoes what it would compile.
stub infocmp '[ "$2" = xterm ] && echo fake-entry || exit 1'
stub tic 'echo "tic $* stdin=$(cat)"'
fake_terminfo=$(printf fake-entry | base64)
stub gh 'case "$1 $2" in
    "auth token") [ -n "${GH_FAIL:-}" ] && exit 1; [ "${3:-}" = --user ] && echo "tok-$4" || echo tok ;;
    "auth login") echo "gh $* stdin=$(cat)"; [ -z "${GH_FAIL:-}" ] ;;
esac'
stub curl 'while [ $# -gt 1 ]; do [ "$1" = -o ] && { cp "$FAKE_DOWNLOAD" "$2"; exit 0; }; shift; done; exit 22'
command -v shasum >/dev/null || stub shasum 'sha256sum'

export PATH="$work/bin:$PATH" HOME="$work/home" SSH_AUTH_SOCK=/agent.sock TERM=xterm
unset COLORTERM THOM_CONTAINER_PROFILE THOM_CONTAINER_IMAGE THOM_CONTAINER_DOCKER \
    THOM_CONTAINER_NO_GH THOM_CONTAINER_GH_TOKEN

devbox() { (cd "$work/My Proj" && zsh -f "$repo/bin/devbox" "$@" 2>&1); }
state="$work/home/.cache/thom-containers"
proj="$work/My Proj"
claude_dir=$(printf '%s' "$proj" | tr -c 'A-Za-z0-9' '-')

echo "devbox"
out=$(devbox)
check "run with defaults" "$out" \
    "container run -i -e TERM=xterm " "--rm --init --name dev-private-my-proj-" \
    "--cpus 10 --memory 8G" \
    "--volume $state/private:/home/thom" \
    "--volume $state/private/.claude/projects/$claude_dir:/home/thom/.claude/projects/-project" \
    "--volume $proj:/project --workdir /project" \
    "--tmpfs /home/thom/.ssh/sockets" \
    "--tmpfs /home/thom/.config/gh" \
    "-e THOM_CONTAINER_GH_TOKEN=tok " \
    "-e THOM_CONTAINER_TERMINFO=$fake_terminfo " \
    "--ssh" \
    "--volume $work/home/.config/chezmoi:/run/host-chezmoi:ro" \
    "--volume $work/home/.ssh/known_hosts:/run/host-ssh/known_hosts:ro" \
    "ghcr.io/thomwiggers/thom-container:latest" \
    "!--cap-add"
[[ -d "$state/private/.claude/projects/$claude_dir" ]] \
    && pass "creates per-project Claude dir" \
    || fail "creates per-project Claude dir" "$state/private/.claude/projects/$claude_dir missing"

out=$(devbox -p work --docker .. -- ls -la)
check "profile, DIR, --docker and command" "$out" \
    "--name dev-work-" "-e THOM_CONTAINER_PROFILE=work" "--volume $state/work:/home/thom" "--volume $work:/project" \
    "--cap-add ALL -e THOM_CONTAINER_DOCKER=1" "latest ls -la"

out=$(RUNNING=1 devbox)
check "attaches to running container" "$out" \
    "container exec -i -e TERM=xterm -e THOM_CONTAINER_PROFILE=private -e SSH_AUTH_SOCK=/var/host-services/ssh-auth.sock -e HOME=/home/thom --user thom --workdir /project dev-private-my-proj-" \
    "/usr/bin/zsh -l" "!container run" "!THOM_CONTAINER_GH_TOKEN" "!THOM_CONTAINER_TERMINFO"

out=$(SSH_AUTH_SOCK='' devbox)
check "no SSH agent" "$out" "warning: SSH_AUTH_SOCK not set" "!--ssh"

mv "$work/home/.ssh/known_hosts" "$work/known_hosts.bak"
out=$(devbox)
check "no known_hosts on the host" "$out" "container run" "!/run/host-ssh"
mv "$work/known_hosts.bak" "$work/home/.ssh/known_hosts"

out=$(TERM=unknown-term devbox)
check "terminal unknown to the host" "$out" "container run" "!THOM_CONTAINER_TERMINFO"

out=$(devbox --no-gh)
check "--no-gh" "$out" "container run" "!THOM_CONTAINER_GH_TOKEN"

out=$(THOM_CONTAINER_NO_GH=1 devbox)
check "THOM_CONTAINER_NO_GH" "$out" "container run" "!THOM_CONTAINER_GH_TOKEN"

out=$(GH_FAIL=1 devbox)
check "host gh not logged in" "$out" \
    "warning: 'gh auth token' failed" "container run" "!THOM_CONTAINER_GH_TOKEN"

out=$(devbox -p nope) && fail "rejects unknown profile" "exit 0" \
    || check "rejects unknown profile" "$out" "unknown profile 'nope'"

out=$(devbox --bogus) && fail "rejects unknown option" "exit 0" \
    || check "rejects unknown option" "$out" "unknown option: --bogus"

out=$(devbox --self-update)
check "self-update in a clone pulls" "$out" "Updating clone in $repo" "git -C $repo pull --ff-only"

cp "$repo/bin/devbox" "$work/devbox-copy"
printf '#!/bin/zsh -f\necho new\n' >"$work/new-devbox"
out=$(cd "$work" && FAKE_DOWNLOAD="$work/new-devbox" zsh -f "$work/devbox-copy" --self-update 2>&1)
check "self-update standalone replaces itself" "$out" "Updated $work/devbox-copy"
cmp -s "$work/new-devbox" "$work/devbox-copy" \
    && pass "standalone copy has new contents" \
    || fail "standalone copy has new contents" "content differs"

echo "install.sh"
out=$(zsh -f "$repo/install.sh" 2>&1)
check "install from clone" "$out" \
    "symlinked to $repo/bin/devbox" \
    "container system start --enable-kernel-install" \
    "container image pull ghcr.io/thomwiggers/thom-container:latest" \
    "!warning: devbox is meant for macOS"
[[ $(readlink "$work/home/.local/bin/devbox") == "$repo/bin/devbox" ]] \
    && pass "devbox symlink" || fail "devbox symlink" "$(ls -l "$work/home/.local/bin")"
[[ -d $state/private && -d $state/work ]] \
    && pass "profile homes created" || fail "profile homes created" "$(ls "$state")"

rm -f "$work/home/.local/bin/devbox"
out=$(cd "$work" && FAKE_DOWNLOAD="$repo/bin/devbox" zsh -f -s -- --no-pull <"$repo/install.sh" 2>&1)
check "install piped from curl" "$out" "downloaded from" "!container image pull"
[[ -f $work/home/.local/bin/devbox && ! -L $work/home/.local/bin/devbox ]] \
    && pass "devbox downloaded" || fail "devbox downloaded" "$(ls -l "$work/home/.local/bin")"

echo "entrypoint.sh (user stage)"
ep="$work/ep"
mkdir -p "$ep/home" "$ep/seed/.config" "$ep/key"
echo img1 >"$ep/seed/.thom-container-image"
echo seeded >"$ep/seed/file"
echo hidden >"$ep/seed/.hidden"
echo secret >"$ep/key/key.txt"
sed -e "s#^home_dir=.*#home_dir=$ep/home#" \
    -e "s#^home_seed=.*#home_seed=$ep/seed#" \
    -e "s#^key_src=.*#key_src=$ep/key/key.txt#" \
    "$repo/entrypoint.sh" >"$ep/entrypoint.sh"
entry() {
    local cmd=("$@")
    [ $# -gt 0 ] || cmd=(echo DONE)
    (cd "$ep" && bash "$ep/entrypoint.sh" --user-stage "${cmd[@]}" 2>&1)
}

stub chezmoi 'echo "chezmoi $*"'
out=$(entry)
check "first start seeds and applies with key" "$out" \
    "seeding $ep/home" "chezmoi update --init --force --keep-going" "DONE" \
    "!--exclude encrypted" "!delete-bucket"
[[ $(cat "$ep/home/file") == seeded && $(cat "$ep/home/.hidden") == hidden && $(readlink "$ep/home/.config/chezmoi/key.txt") == "$ep/key/key.txt" ]] \
    && pass "home seeded, key linked" || fail "home seeded, key linked" "$(ls -la "$ep/home" "$ep/home/.config/chezmoi")"

echo img2 >"$ep/seed/.thom-container-image"
rm "$ep/key/key.txt"
stub chezmoi 'echo "chezmoi $*"; [ "$1" = update ] && exit 1; exit 0'
out=$(entry)
check "new image, no key, offline" "$out" \
    "image changed (img1 -> img2)" "chezmoi state delete-bucket --bucket=entryState" \
    "chezmoi update --init --force --keep-going --exclude encrypted" \
    "applying without pulling" "chezmoi apply --force --keep-going --exclude encrypted" "DONE" \
    "!seeding"
[[ ! -e $ep/home/.config/chezmoi/key.txt ]] \
    && pass "stale key link removed" || fail "stale key link removed" "still there"

out=$(THOM_CONTAINER_SKIP_APPLY=1 entry)
check "THOM_CONTAINER_SKIP_APPLY" "$out" "DONE" "!chezmoi update"

# shellcheck disable=SC2016  # expanded by the inner sh
out=$(THOM_CONTAINER_GH_TOKEN=secret entry sh -c 'echo "leak=${THOM_CONTAINER_GH_TOKEN:-none}"')
check "logs in to GitHub, token not leaked to the shell" "$out" \
    "gh auth login --hostname github.com --with-token stdin=secret" "leak=none"

out=$(GH_FAIL=1 THOM_CONTAINER_GH_TOKEN=secret entry)
check "gh login failure does not block start" "$out" "warning: gh auth login failed" "DONE"

# A copy error (here: an unreadable file) must warn, not stop the start.
rm "$ep/home/.thom-container-image"
echo nope >"$ep/seed/unreadable"
chmod 000 "$ep/seed/unreadable"
out=$(entry)
check "seeding error is not fatal" "$out" "seeding $ep/home" "warning: some files could not be copied" "DONE"
chmod 600 "$ep/seed/unreadable"

# shellcheck disable=SC2016  # expanded by the inner sh
out=$(THOM_CONTAINER_PROFILE=work entry sh -c 'echo "profile=$THOM_CONTAINER_PROFILE"')
check "profile reaches the shell" "$out" "profile=work"

# shellcheck disable=SC2016  # expanded by the inner sh
out=$(entry sh -c 'echo "profile=$THOM_CONTAINER_PROFILE"')
check "profile defaults to unknown" "$out" "profile=unknown"

out=$(entry)
check "no token, no login" "$out" "DONE" "!gh auth login" "!tic"

# shellcheck disable=SC2016  # expanded by the inner sh
out=$(THOM_CONTAINER_TERMINFO=$fake_terminfo entry sh -c 'echo "leak=${THOM_CONTAINER_TERMINFO:-none}"')
check "installs host terminfo" "$out" "tic -x -o $ep/home/.terminfo - stdin=fake-entry" "leak=none"

stub tic 'exit 1'
out=$(THOM_CONTAINER_TERMINFO=$fake_terminfo entry)
check "terminfo failure does not block start" "$out" "warning: could not install terminfo" "DONE"

echo
if ((failures)); then
    echo "$failures check(s) failed"
    exit 1
fi
echo "all checks passed"
