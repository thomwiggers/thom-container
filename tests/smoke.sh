#!/bin/bash
# shellcheck disable=SC2015,SC2016  # stub bodies are literal; pass/fail never fail
# Smoke tests for the generated scripts, runnable on Linux without Apple's
# container: `container`, `sysctl`, `git`, `curl` and `nix` are replaced
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

mkdir -p "$work/bin" "$work/home/.config/age" "$work/My Proj"
: >"$work/home/.config/age/keys.txt"
mkdir -p "$work/home/.ssh"
echo "github.com ssh-ed25519 AAAA" >"$work/home/.ssh/known_hosts"
stub container 'echo "container $*"; [ "$1" = list ] && echo "${LISTED:-}"; [ "$1" = inspect ] && { [ -n "${RUNNING:-}" ] || exit 1; }; [ "$1 $2" = "system status" ] && exit 1; [ "$1 $2 $3" = "system dns list" ] && echo "${DNS_DOMAINS:-}"; exit 0'
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
stub ssh-add 'if [ -n "${AGENT_EMPTY:-}" ]; then echo "The agent has no identities."; exit 1; fi
echo "ssh-ed25519 AAAAkey1 first"; echo "ssh-ed25519 AAAAkey2 second"'
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
    "--volume $work/home/.config/age:/run/host-age:ro" \
    "--volume $work/home/.ssh/known_hosts:/run/host-ssh/known_hosts:ro" \
    "--cap-add CAP_SYS_ADMIN" \
    "-e THOM_CONTAINER_HOSTNAME=devbox-my-proj " \
    "ghcr.io/thomwiggers/thom-container:latest" \
    "!--cap-add ALL" \
    "ssh: thom@dev-private-my-proj-" ".devbox"
[[ -d "$state/private/.claude/projects/$claude_dir" ]] \
    && pass "creates per-project Claude dir" \
    || fail "creates per-project Claude dir" "$state/private/.claude/projects/$claude_dir missing"

out=$(devbox -p work --docker .. -- ls -la)
check "profile, DIR, --docker and command" "$out" \
    "--name dev-work-" "-e THOM_CONTAINER_PROFILE=work" "--volume $state/work:/home/thom" "--volume $work:/project" \
    "--cap-add ALL -e THOM_CONTAINER_DOCKER=1" "!CAP_SYS_ADMIN" \
    "-e THOM_CONTAINER_HOSTNAME=devbox-" "latest ls -la"

out=$(RUNNING=1 devbox)
check "attaches to running container" "$out" \
    "container exec -i -e TERM=xterm -e THOM_CONTAINER_PROFILE=private -e SSH_AUTH_SOCK=/var/host-services/ssh-auth.sock -e HOME=/home/thom --user thom --workdir /project dev-private-my-proj-" \
    "/usr/bin/zsh -l" "!container run" "!THOM_CONTAINER_GH_TOKEN" "!THOM_CONTAINER_TERMINFO"

out=$(devbox --attach) && fail "--attach without a container fails" "exit 0" \
    || check "--attach without a container fails" "$out" "no running container" "!container run"
out=$(RUNNING=1 devbox --attach -- ls)
check "--attach with a running container" "$out" "container exec" "dev-private-my-proj-" " ls" "!container run"

stub code 'echo "code $*"'
out=$(RUNNING=1 devbox --code)
check "--code opens VS Code over Remote-SSH" "$out" \
    "code --remote ssh-remote+thom@dev-private-my-proj-" ".devbox /project" "!container run" "!container exec"
out=$(devbox --code) && fail "--code without a container fails" "exit 0" \
    || check "--code without a container fails" "$out" "no running container" "!code --remote"
out=$(RUNNING=1 devbox --code --attach) && fail "--code with --attach fails" "exit 0" \
    || check "--code with --attach fails" "$out" "cannot be combined"
out=$(RUNNING=1 THOM_CONTAINER_CODE=nope devbox --code) && fail "--code without the code command fails" "exit 0" \
    || check "--code without the code command fails" "$out" "'nope' not found"

echo "profile file"
printf '  work  \n' >"$proj/.thom-container-profile"
out=$(devbox)
check "profile from file" "$out" "--name dev-work-" "-e THOM_CONTAINER_PROFILE=work"
mkdir -p "$proj/sub"
out=$(cd "$proj/sub" && zsh -f "$repo/bin/devbox" 2>&1)
check "profile file found in a parent" "$out" "--name dev-work-"
out=$(THOM_CONTAINER_PROFILE=private devbox)
check "env beats profile file" "$out" "--name dev-private-"
out=$(devbox -p private)
check "-p beats profile file" "$out" "--name dev-private-"
printf 'nope\n' >"$proj/.thom-container-profile"
out=$(devbox) && fail "unknown profile in file" "exit 0" \
    || check "unknown profile in file" "$out" "unknown profile 'nope'"
rm "$proj/.thom-container-profile"

echo "--reset"
out=$(LISTED=$'dev-work-x-1\ndev-private-other-1' devbox --reset </dev/null) && fail "--reset refuses while running" "exit 0" \
    || check "--reset refuses while running" "$out" "dev-private-other-1" "!dev-work-x-1" "are running"
touch "$state/private/marker"
out=$(devbox --reset <<<n) && fail "--reset aborts on no" "exit 0" \
    || check "--reset aborts on no" "$out" "aborted"
[[ -e $state/private/marker ]] && pass "home kept on abort" || fail "home kept on abort" "marker gone"
out=$(devbox --reset <<<y)
check "--reset wipes and restarts" "$out" "Reset $state/private" "container run"
[[ ! -e $state/private/marker ]] && pass "home wiped" || fail "home wiped" "marker still there"

out=$(SSH_AUTH_SOCK='' devbox)
check "no SSH agent" "$out" "warning: SSH_AUTH_SOCK not set" "!--ssh" "!ssh: thom@"

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

out=$(DNS_DOMAINS=devbox zsh -f "$repo/install.sh" --no-pull 2>&1)
check "install with the devbox DNS domain registered" "$out" "!is not registered" "!sudo container system dns create"
out=$(DNS_DOMAINS=other zsh -f "$repo/install.sh" --no-pull 2>&1)
check "install without the devbox DNS domain" "$out" \
    "DNS domain 'devbox' is not registered" "sudo container system dns create devbox" \
    "[dns]  domain = \"devbox\"" "container system stop"

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
echo secret >"$ep/key/keys.txt"
sed -e "s#^home_dir=.*#home_dir=$ep/home#" \
    -e "s#^home_seed=.*#home_seed=$ep/seed#" \
    -e "s#^key_src=.*#key_src=$ep/key/keys.txt#" \
    -e "s#^authorized_keys=.*#authorized_keys=$ep/authorized_keys#" \
    "$repo/entrypoint.sh" >"$ep/entrypoint.sh"
entry() {
    local cmd=("$@")
    [ $# -gt 0 ] || cmd=(echo DONE)
    (cd "$ep" && bash "$ep/entrypoint.sh" --user-stage "${cmd[@]}" 2>&1)
}

stub nix 'echo "nix $*"'
out=$(entry)
check "first start pulls and switches with key" "$out" \
    "seeding $ep/home" "git -C $ep/home/.config/home-manager pull --ff-only" \
    "nix run $ep/home/.config/home-manager#home-manager -- switch --flake $ep/home/.config/home-manager#thom@linux-arm -b hm-bak" \
    "DONE" "!--offline" "!refreshing Nix profiles"
[[ $(cat "$ep/home/file") == seeded && $(cat "$ep/home/.hidden") == hidden && $(readlink "$ep/home/.config/age/keys.txt") == "$ep/key/keys.txt" ]] \
    && pass "home seeded, key linked" || fail "home seeded, key linked" "$(ls -la "$ep/home" "$ep/home/.config/age")"

# New image with a stale profile link in the persisted home; offline.
echo img2 >"$ep/seed/.thom-container-image"
ln -s /nix/store/new-profile "$ep/seed/.nix-profile"
ln -s /nix/store/old-profile "$ep/home/.nix-profile"
rm "$ep/key/keys.txt"
stub git 'echo "git $*"; [ "$3" = pull ] && exit 1; exit 0'
out=$(entry)
check "new image, no key, offline" "$out" \
    "image changed (img1 -> img2)" "refreshing Nix profiles" \
    "git -C $ep/home/.config/home-manager pull --ff-only" "dotfiles pull failed" \
    "-b hm-bak --offline" "DONE" "!seeding"
[[ $(readlink "$ep/home/.nix-profile") == /nix/store/new-profile ]] \
    && pass "stale profile link replaced" || fail "stale profile link replaced" "$(readlink "$ep/home/.nix-profile")"
[[ ! -e $ep/home/.config/age/keys.txt && ! -L $ep/home/.config/age/keys.txt ]] \
    && pass "stale key link removed" || fail "stale key link removed" "still there"

[[ $(cat "$ep/authorized_keys") == $'ssh-ed25519 AAAAkey1 first\nssh-ed25519 AAAAkey2 second' && $(stat -c %a "$ep/authorized_keys") == 600 ]] \
    && pass "agent keys authorized for sshd" || fail "agent keys authorized for sshd" "$(cat "$ep/authorized_keys" 2>&1)"
rm "$ep/authorized_keys"
out=$(AGENT_EMPTY=1 entry)
check "empty agent warns, start continues" "$out" "warning: no keys in the SSH agent" "DONE"
[[ ! -e $ep/authorized_keys ]] && pass "no authorized_keys without agent keys" || fail "no authorized_keys without agent keys" "exists"
out=$(SSH_AUTH_SOCK='' entry)
check "no agent socket warns, start continues" "$out" "warning: no keys in the SSH agent" "DONE"

out=$(THOM_CONTAINER_SKIP_APPLY=1 entry)
check "THOM_CONTAINER_SKIP_APPLY" "$out" "DONE" "!pull" "!nix run"

stub nix 'echo "nix $*"; exit 1'
out=$(entry)
check "failed switch does not stop the shell" "$out" "home-manager switch failed" "DONE"
stub nix 'echo "nix $*"'
stub git 'echo "git $*"'

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
