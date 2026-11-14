#!/bin/sh
# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
#
# SYP-354 P10a disposable cloud setup: POSIX shell edge (S1-S4) only.
# Transitional and outside the support matrix; see README "Cloud/Linux setup".
#
#   sh scripts/setup-agent-environment.sh --expected-commit <40-hex> (--prepare | --offline)
#
# S1 host RID, HOME and link-free, safely owned ancestors; K4 pinned revision
# and dependencies; S2 canonical runtime location; S3 verified official
# PowerShell archive in the setup cache; S4 hand-off to
# setup-agent-environment.ps1 with a bootstrap pwsh and an allowlisted
# environment. The setup never elevates privileges, never installs system
# packages and never edits shell start-up files. Exit codes are the shared
# table in scripts/agent-environment-setup.psm1 (README lists them).
set -eu
umask 077

EXIT_SUCCESS=0
EXIT_INTERNAL_ERROR=1
EXIT_USAGE=10
EXIT_UNSUPPORTED_PLATFORM=11
EXIT_HOME_INVALID=12
EXIT_UNSAFE_PATH=13
EXIT_MISSING_DEPENDENCY=14
EXIT_COMMIT_MISMATCH=15
EXIT_POLICY_INVALID=16
EXIT_DOWNLOAD_FAILED=17
EXIT_ARCHIVE_HASH_MISMATCH=18
EXIT_ARCHIVE_UNSAFE=19
EXIT_CACHE_MISSING=20
EXIT_RUNTIME_MISSING=21
EXIT_RUNTIME_INCOMPLETE=22
EXIT_RUNTIME_VERIFICATION_FAILED=23
EXIT_RUNTIME_BASELINE_UNAVAILABLE=24
EXIT_CAPABILITY_UNAVAILABLE=25
EXIT_CONCURRENT=26
EXIT_INTERRUPTED_INSTALL=27
EXIT_CODEX_HOME_CONFLICT=28

BOUND_FILES='scripts/setup-agent-environment.policy.json scripts/setup-agent-environment.policy.tsv scripts/setup-agent-environment.policy.schema.json scripts/setup-agent-environment.sh scripts/setup-agent-environment.ps1 scripts/agent-environment-setup.psm1'
PLATFORM_BOUND_FILES='scripts/platform-runtime.psd1 scripts/platform-runtime.psm1 scripts/installer-safe-mutation.psm1 scripts/WindowsDacl.psm1 scripts/Resolve-StandardValidationTool.ps1 scripts/platform/PlatformNative.cs scripts/platform/UnixNative.cs scripts/platform/WindowsNative.cs scripts/platform/WindowsInstallerMutation.cs scripts/platform/OwnedProcess.cs scripts/platform/UnixProcess.cs scripts/platform/WindowsProcess.cs scripts/platform/Unix.psm1 scripts/platform/RuntimePreparation.psm1 scripts/platform/Windows.psm1 scripts/platform/Linux.psm1 scripts/platform/MacOS.psm1'

run_tmp=''
setup_root=''
receipt_mode='null'

refuse() {
    printf 'setup-agent-environment: %s\n' "$3" >&2
    recover_command=${4-}
    if [ -n "$recover_command" ]; then recover_json="\"$recover_command\""; else recover_json=null; fi
    printf '{"schemaVersion":1,"kind":"agent-environment-setup-receipt","phase":"p10a","mode":%s,"result":"refused","code":"%s","exitCode":%s,"os":null,"architecture":null,"rid":null,"setupCommit":null,"runtimeCommit":null,"policySha256":null,"setupRoot":null,"codexHome":null,"powerShell":null,"dotNetVersion":null,"capabilities":[],"steps":[],"recoverCommand":%s}\n' "$receipt_mode" "$1" "$2" "$recover_json"
    exit "$2"
}

cleanup() {
    if [ -n "$run_tmp" ] && [ -n "$setup_root" ] && [ -d "$run_tmp" ] && [ ! -L "$run_tmp" ]; then
        case "$run_tmp" in
            "$setup_root"/tmp/run.*)
                chmod -R u+rwx "$run_tmp" 2>/dev/null || :
                rm -rf "$run_tmp" ;;
        esac
    fi
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

usage_text() {
    printf '%s\n' 'usage: sh scripts/setup-agent-environment.sh --expected-commit <40-hex> (--prepare | --offline)'
}

expected_commit=''
mode=''
while [ "$#" -gt 0 ]; do
    case "$1" in
        --expected-commit)
            [ "$#" -ge 2 ] || refuse usage "$EXIT_USAGE" '--expected-commit requires a value.'
            expected_commit=$2
            shift 2 ;;
        --expected-commit=*)
            expected_commit=${1#--expected-commit=}
            shift ;;
        --prepare|--offline)
            [ -z "$mode" ] || refuse usage "$EXIT_USAGE" 'Specify exactly one of --prepare or --offline.'
            mode=${1#--}
            shift ;;
        -h|--help)
            usage_text
            exit "$EXIT_SUCCESS" ;;
        *)
            usage_text >&2
            refuse usage "$EXIT_USAGE" "Unknown argument." ;;
    esac
done
[ -n "$mode" ] || refuse usage "$EXIT_USAGE" 'Specify exactly one of --prepare or --offline.'
receipt_mode='"'"$mode"'"'
case "$expected_commit" in
    ''|*[!0-9a-f]*) refuse usage "$EXIT_USAGE" '--expected-commit must be a 40-character lowercase hexadecimal commit.' ;;
esac
[ "${#expected_commit}" -eq 40 ] || refuse usage "$EXIT_USAGE" '--expected-commit must be a 40-character lowercase hexadecimal commit.'

have() { command -v "$1" >/dev/null 2>&1; }
for tool in uname id awk sed find mkdir mv rm chmod env dirname cp; do
    have "$tool" || refuse missing-dependency "$EXIT_MISSING_DEPENDENCY" "Required tool '$tool' is not available; setup does not install system packages."
done

# --- S1: RID, HOME, ancestors (M7) ------------------------------------------
case "$(uname -s)" in
    Linux) os_token=linux ;;
    Darwin) os_token=osx ;;
    *) refuse unsupported-platform "$EXIT_UNSUPPORTED_PLATFORM" 'The host OS has no pinned PowerShell asset.' ;;
esac
case "$(uname -m)" in
    x86_64|amd64) arch_token=x64 ;;
    aarch64|arm64) arch_token=arm64 ;;
    *) refuse unsupported-platform "$EXIT_UNSUPPORTED_PLATFORM" 'The host architecture has no pinned PowerShell asset.' ;;
esac
if [ "$os_token" = linux ]; then
    musl_loader=$(find /lib /usr/lib -maxdepth 1 -name 'ld-musl-*' -print -quit 2>/dev/null || :)
    [ -z "$musl_loader" ] || refuse unsupported-platform "$EXIT_UNSUPPORTED_PLATFORM" 'musl-based Linux has no pinned PowerShell asset.'
fi
rid="$os_token-$arch_token"
uid=$(id -u)

check_owner_mode() {
    if [ -z "$(find "$1" -prune \( -user 0 -o -user "$uid" \) -print)" ]; then
        refuse unsafe-path "$EXIT_UNSAFE_PATH" "$2 has an ancestor owned by another user: $1"
    fi
    if [ -n "$(find "$1" -prune \( -perm -0020 -o -perm -0002 \) ! -perm -1000 -print)" ]; then
        refuse unsafe-path "$EXIT_UNSAFE_PATH" "$2 has a group- or world-writable ancestor without the sticky bit: $1"
    fi
}

# Walk from / without following links. Any symbolic link (dangling included)
# refuses; setup never resolves a link and continues.
check_ancestors() {
    ca_rest=${1#/}
    ca_current=''
    check_owner_mode / "$2"
    while [ -n "$ca_rest" ]; do
        ca_part=${ca_rest%%/*}
        case "$ca_rest" in
            */*) ca_rest=${ca_rest#*/} ;;
            *) ca_rest='' ;;
        esac
        [ -n "$ca_part" ] || continue
        case "$ca_part" in
            .|..) refuse unsafe-path "$EXIT_UNSAFE_PATH" "$2 contains a dot segment." ;;
        esac
        ca_current="$ca_current/$ca_part"
        if [ -L "$ca_current" ]; then
            refuse unsafe-path "$EXIT_UNSAFE_PATH" "$2 has a symbolic link ancestor: $ca_current"
        fi
        if [ ! -e "$ca_current" ]; then
            return 0
        fi
        [ -d "$ca_current" ] || refuse unsafe-path "$EXIT_UNSAFE_PATH" "$2 has a non-directory ancestor: $ca_current"
        check_owner_mode "$ca_current" "$2"
    done
    return 0
}

home=${HOME-}
case "$home" in
    /*) ;;
    *) refuse home-invalid "$EXIT_HOME_INVALID" 'HOME must be an absolute path.' ;;
esac
case "$home" in
    *'
'*) refuse home-invalid "$EXIT_HOME_INVALID" 'HOME must not contain a newline.' ;;
esac
while [ "$home" != / ]; do
    case "$home" in
        */) home=${home%/} ;;
        *) break ;;
    esac
done
[ "$home" != / ] || refuse home-invalid "$EXIT_HOME_INVALID" 'HOME must not be the filesystem root.'
check_ancestors "$home" HOME
[ -d "$home" ] || refuse home-invalid "$EXIT_HOME_INVALID" 'HOME must be an existing directory.'
[ -w "$home" ] || refuse home-invalid "$EXIT_HOME_INVALID" 'HOME must be writable.'

codex_home="$home/.codex"
if [ -n "${CODEX_HOME-}" ]; then
    case "$CODEX_HOME" in
        "$codex_home"|"$codex_home/") ;;
        *) refuse codex-home-conflict "$EXIT_CODEX_HOME_CONFLICT" 'CODEX_HOME is set to a different location; setup only uses ~/.codex.' ;;
    esac
fi
check_ancestors "$codex_home" CODEX_HOME
setup_root="$home/.local/share/ai-instructions-setup"
check_ancestors "$setup_root" 'The setup root'

# --- K4: pinned revision and dependencies -----------------------------------
for tool in git tar gzip; do
    have "$tool" || refuse missing-dependency "$EXIT_MISSING_DEPENDENCY" "Required tool '$tool' is not available; setup does not install system packages."
done
if have sha256sum; then
    hash_tool=sha256sum
elif have shasum; then
    hash_tool=shasum
else
    refuse missing-dependency "$EXIT_MISSING_DEPENDENCY" 'sha256sum or shasum is required; setup does not install system packages.'
fi
downloader=''
if [ "$mode" = prepare ]; then
    if have curl; then
        downloader=curl
    elif have wget; then
        downloader=wget
    else
        refuse missing-dependency "$EXIT_MISSING_DEPENDENCY" 'curl or wget is required for --prepare; setup does not install system packages.'
    fi
fi

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P) || refuse internal-error "$EXIT_INTERNAL_ERROR" 'Cannot locate the setup script directory.'
repo_root=$(CDPATH='' cd -- "$script_dir/.." && pwd -P) || refuse internal-error "$EXIT_INTERNAL_ERROR" 'Cannot locate the repository root.'

git_in_repo() {
    git -c core.fsmonitor=false -C "$repo_root" "$@"
}
top=$(git_in_repo rev-parse --show-toplevel 2>/dev/null) || refuse commit-mismatch "$EXIT_COMMIT_MISMATCH" 'The setup script is not inside a git checkout.'
top=$(CDPATH='' cd -- "$top" && pwd -P) || refuse commit-mismatch "$EXIT_COMMIT_MISMATCH" 'The git top level is not accessible.'
[ "$top" = "$repo_root" ] || refuse commit-mismatch "$EXIT_COMMIT_MISMATCH" 'The setup script is not at the top level of its git checkout.'
head_commit=$(git_in_repo rev-parse --verify 'HEAD^{commit}' 2>/dev/null) || refuse commit-mismatch "$EXIT_COMMIT_MISMATCH" 'HEAD is not a commit.'
[ "$head_commit" = "$expected_commit" ] || refuse commit-mismatch "$EXIT_COMMIT_MISMATCH" 'HEAD does not equal --expected-commit.'
for bound in $BOUND_FILES $PLATFORM_BOUND_FILES; do
    if [ -L "$repo_root/$bound" ] || [ ! -f "$repo_root/$bound" ]; then
        refuse commit-mismatch "$EXIT_COMMIT_MISMATCH" "Bound setup file is missing or not a regular file: $bound"
    fi
    git_in_repo ls-files --error-unmatch -- "$bound" >/dev/null 2>&1 || refuse commit-mismatch "$EXIT_COMMIT_MISMATCH" "Bound setup file is not tracked: $bound"
    untracked=$(git_in_repo ls-files --others -- "$bound") || refuse commit-mismatch "$EXIT_COMMIT_MISMATCH" "Cannot inspect untracked state: $bound"
    [ -z "$untracked" ] || refuse commit-mismatch "$EXIT_COMMIT_MISMATCH" "An untracked substitute exists: $bound"
    git_in_repo diff --cached --quiet HEAD -- "$bound" 2>/dev/null || refuse commit-mismatch "$EXIT_COMMIT_MISMATCH" "Bound setup file has a staged difference: $bound"
    git_in_repo diff --quiet -- "$bound" 2>/dev/null || refuse commit-mismatch "$EXIT_COMMIT_MISMATCH" "Bound setup file has a working-tree difference: $bound"
    git_in_repo diff --quiet HEAD -- "$bound" 2>/dev/null || refuse commit-mismatch "$EXIT_COMMIT_MISMATCH" "Bound setup file differs from --expected-commit: $bound"
done

# G3/G5: before mutation, refuse only external K7 state. Setup-owned WAL is
# handed to the verified PowerShell entry for lock-held recovery.
if [ -e "$codex_home/.ai-instructions-txn" ] || [ -L "$codex_home/.ai-instructions-txn" ]; then
    refuse interrupted-install "$EXIT_INTERRUPTED_INSTALL" 'An interrupted install transaction exists in CODEX_HOME; recover it before rerunning setup.' \
        'pwsh -NoProfile -NonInteractive -File scripts/install-ai-instructions-bootstrap.ps1 -CodexHome ~/.codex'
fi
if [ -e "$home/.ai-instructions-txn" ] || [ -L "$home/.ai-instructions-txn" ]; then
    refuse interrupted-install "$EXIT_INTERRUPTED_INSTALL" 'An interrupted USER agent-environment transaction exists; recover it before rerunning setup.' \
        'pwsh -NoProfile -NonInteractive -File ~/.codex/hooks/update-agent-environment.ps1 -Recover'
fi
for residue in "$codex_home"/.ai-instructions-install-* "$codex_home"/.ai-instructions-backup-*; do
    if [ -e "$residue" ] || [ -L "$residue" ]; then
        refuse interrupted-install "$EXIT_INTERRUPTED_INSTALL" 'Legacy install residue exists in CODEX_HOME; inspect it before rerunning setup.' \
            'pwsh -NoProfile -NonInteractive -File scripts/install-ai-instructions-bootstrap.ps1 -CodexHome ~/.codex'
    fi
done

# --- Policy (derived TSV, K2) ------------------------------------------------
tsv="$script_dir/setup-agent-environment.policy.tsv"
tsv_value() {
    awk -v key="$1" 'BEGIN { FS = "\t" } $1 == key { print $2 }' "$tsv"
}
[ "$(tsv_value '#schemaVersion')" = 1 ] || refuse policy-invalid "$EXIT_POLICY_INVALID" 'The policy TSV schemaVersion is unknown.'
version=$(tsv_value '#version')
url_template=$(tsv_value '#downloadUrlTemplate')
case "$version" in
    ''|*[!0-9.]*|.*|*.|*..*) refuse policy-invalid "$EXIT_POLICY_INVALID" 'The policy TSV version is invalid.' ;;
esac
[ "$url_template" = 'https://github.com/PowerShell/PowerShell/releases/download/v{version}/{assetName}' ] ||
    refuse policy-invalid "$EXIT_POLICY_INVALID" 'The policy TSV download URL template must exactly name the official PowerShell GitHub release endpoint.'
rows=$(awk -v key="$rid" 'BEGIN { FS = "\t"; n = 0 } $1 == key { n++ } END { print n }' "$tsv")
[ "$rows" = 1 ] || refuse unsupported-platform "$EXIT_UNSUPPORTED_PLATFORM" "The policy has no single asset for $rid."
asset_name=$(awk -v key="$rid" 'BEGIN { FS = "\t" } $1 == key { print $2 }' "$tsv")
asset_sha=$(awk -v key="$rid" 'BEGIN { FS = "\t" } $1 == key { print $3 }' "$tsv")
[ "$asset_name" = "powershell-$version-$rid.tar.gz" ] || refuse policy-invalid "$EXIT_POLICY_INVALID" 'The policy asset name does not match its version and RID.'
case "$asset_sha" in
    ''|*[!0-9a-f]*) refuse policy-invalid "$EXIT_POLICY_INVALID" 'The policy SHA-256 must be lowercase hexadecimal.' ;;
esac
[ "${#asset_sha}" -eq 64 ] || refuse policy-invalid "$EXIT_POLICY_INVALID" 'The policy SHA-256 must have 64 characters.'

hash_file() {
    if [ "$hash_tool" = sha256sum ]; then
        sha256sum "$1" | awk '{ print $1 }'
    else
        shasum -a 256 "$1" | awk '{ print $1 }'
    fi
}

# F2 metadata refusal is also pre-mutation. A cache owned by another uid,
# broad-mode, linked, or substituted by a symlink never causes tmp/root writes.
archive="$setup_root/cache/$asset_name"
cache_present=0
if [ -L "$archive" ]; then
    refuse unsafe-path "$EXIT_UNSAFE_PATH" 'The cached archive is a symbolic link.'
fi
if [ -e "$archive" ]; then
    [ -f "$archive" ] || refuse unsafe-path "$EXIT_UNSAFE_PATH" 'The cached archive is not a regular file.'
    [ -n "$(find "$archive" -prune -type f -user "$uid" -links 1 -perm 0600 -print)" ] || refuse unsafe-path "$EXIT_UNSAFE_PATH" 'The cached archive must be owned by the current uid, single-link and mode 0600.'
    cache_present=1
elif [ "$mode" = offline ]; then
    refuse cache-missing "$EXIT_CACHE_MISSING" 'The verified archive cache is missing; rerun with --prepare while network access is allowed.'
fi

# --- Setup root and per-run temp (M4, M7, M8) --------------------------------
mkdir -p "$setup_root" || refuse unsafe-path "$EXIT_UNSAFE_PATH" 'Cannot create the setup root.'
check_ancestors "$setup_root" 'The setup root'
for sub in cache tmp; do
    if [ -L "$setup_root/$sub" ]; then
        refuse unsafe-path "$EXIT_UNSAFE_PATH" "The setup $sub directory is a symbolic link."
    fi
    mkdir -p "$setup_root/$sub" || refuse unsafe-path "$EXIT_UNSAFE_PATH" "Cannot create the setup $sub directory."
    check_owner_mode "$setup_root/$sub" "The setup $sub directory"
done
attempt=0
run_tmp="$setup_root/tmp/run.$$"
while ! mkdir "$run_tmp" 2>/dev/null; do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 100 ] || { run_tmp=''; refuse internal-error "$EXIT_INTERNAL_ERROR" 'Cannot create a private setup temp directory.'; }
    run_tmp="$setup_root/tmp/run.$$.$attempt"
done

# --- S2: canonical runtime location (verified later by pwsh, K15) -----------
canonical_dir="$setup_root/pwsh/$version-$rid"
if [ -L "$setup_root/pwsh" ] || [ -L "$canonical_dir" ]; then
    refuse unsafe-path "$EXIT_UNSAFE_PATH" 'The canonical runtime location is a symbolic link.'
fi

# --- S3: verified official archive in the cache ------------------------------
if [ "$cache_present" -eq 0 ]; then
    url=$(printf '%s\n' "$url_template" | sed -e "s/{version}/$version/g" -e "s/{assetName}/$asset_name/g")
    mkdir "$run_tmp/download"
    download="$run_tmp/download/$asset_name"
    if [ "$downloader" = curl ]; then
        curl --proto '=https' --proto-redir '=https' --tlsv1.2 --fail --location --silent --show-error \
            --connect-timeout 30 --max-time 900 --retry 2 --output "$download" "$url" \
            || refuse download-failed "$EXIT_DOWNLOAD_FAILED" 'The official PowerShell archive download failed.'
    else
        wget --https-only --secure-protocol=TLSv1_2 --timeout=30 --tries=3 --quiet \
            --output-document="$download" "$url" \
            || refuse download-failed "$EXIT_DOWNLOAD_FAILED" 'The official PowerShell archive download failed.'
    fi
    [ -f "$download" ] && [ ! -L "$download" ] || refuse download-failed "$EXIT_DOWNLOAD_FAILED" 'The download did not produce a regular file.'
    [ "$(hash_file "$download")" = "$asset_sha" ] || refuse archive-hash-mismatch "$EXIT_ARCHIVE_HASH_MISMATCH" 'The downloaded archive SHA-256 does not match the policy.'
    chmod 0600 "$download" || refuse unsafe-path "$EXIT_UNSAFE_PATH" 'The verified download cannot be made private.'
    # Same filesystem: the per-run temp directory lives below the setup root.
    mv -f "$download" "$archive" || refuse internal-error "$EXIT_INTERNAL_ERROR" 'Cannot move the verified archive into the cache.'
    [ -n "$(find "$archive" -prune -type f -user "$uid" -links 1 -perm 0600 -print)" ] || refuse unsafe-path "$EXIT_UNSAFE_PATH" 'The published cache file is not private and single-link.'
fi

# F2: copy without following a final symlink into this run's private directory.
# Hashing, tar listing/extraction and the PowerShell OfflineCache all use only
# this immutable-for-the-run snapshot, never the cache pathname again.
archive_snapshot="$run_tmp/$asset_name"
cp -P "$archive" "$archive_snapshot" || refuse unsafe-path "$EXIT_UNSAFE_PATH" 'The cached archive cannot be copied without following links.'
if [ -L "$archive_snapshot" ] || [ ! -f "$archive_snapshot" ]; then
    refuse unsafe-path "$EXIT_UNSAFE_PATH" 'The private archive snapshot is not a regular file.'
fi
chmod 0600 "$archive_snapshot" || refuse unsafe-path "$EXIT_UNSAFE_PATH" 'The private archive snapshot cannot be protected.'
[ -n "$(find "$archive_snapshot" -prune -type f -user "$uid" -links 1 -perm 0600 -print)" ] || refuse unsafe-path "$EXIT_UNSAFE_PATH" 'The private archive snapshot is not owned, single-link and mode 0600.'
[ "$(hash_file "$archive_snapshot")" = "$asset_sha" ] || refuse archive-hash-mismatch "$EXIT_ARCHIVE_HASH_MISMATCH" 'The private archive snapshot SHA-256 does not match the policy.'
archive="$archive_snapshot"

# Defence in depth (M9): member names and types are checked before extraction,
# and the extracted tree must contain only single-link files and directories.
# Resolve-PlatformPowerShell (TarReader) remains the trust baseline.
# GNU tar strips a leading / from listed names unless -P is given; bsdtar lists
# names verbatim. Both strip it again on extraction.
tar_list_flag=''
if tar --version 2>/dev/null | awk 'NR == 1 && /GNU tar/ { found = 1 } END { exit !found }'; then
    tar_list_flag='-P'
fi
tar -t $tar_list_flag -z -f "$archive" > "$run_tmp/members" 2>/dev/null || refuse archive-unsafe "$EXIT_ARCHIVE_UNSAFE" 'The archive cannot be listed.'
unsafe_member=$(awk '
    {
        name = $0
        if (name == "." || name == "./") next
        sub(/^\.\//, "", name)
        if (name == "" || substr(name, 1, 1) == "/") { print "unsafe"; exit }
        wrapped = "/" name "/"
        if (wrapped ~ /\/\.\.\// || wrapped ~ /\/\.\//) { print "unsafe"; exit }
    }' "$run_tmp/members")
[ -z "$unsafe_member" ] || refuse archive-unsafe "$EXIT_ARCHIVE_UNSAFE" 'The archive contains an absolute or traversal member path.'
tar -t -v $tar_list_flag -z -f "$archive" > "$run_tmp/verbose" 2>/dev/null || refuse archive-unsafe "$EXIT_ARCHIVE_UNSAFE" 'The archive cannot be listed.'
unsafe_type=$(awk '
    {
        kind = substr($0, 1, 1)
        if ((kind != "-" && kind != "d") || index($0, " link to ") > 0 || index($0, " -> ") > 0) { print "unsafe"; exit }
    }' "$run_tmp/verbose")
[ -z "$unsafe_type" ] || refuse archive-unsafe "$EXIT_ARCHIVE_UNSAFE" 'The archive contains a link, device or other non-regular member.'
bootstrap="$run_tmp/bootstrap"
mkdir "$bootstrap"
tar -xzf "$archive" -C "$bootstrap" 2>/dev/null || refuse archive-unsafe "$EXIT_ARCHIVE_UNSAFE" 'The archive could not be extracted.'
[ -z "$(find "$bootstrap" ! -type f ! -type d -print)" ] || refuse archive-unsafe "$EXIT_ARCHIVE_UNSAFE" 'The extracted tree contains a non-regular entry.'
[ -z "$(find "$bootstrap" -type f -links +1 -print)" ] || refuse archive-unsafe "$EXIT_ARCHIVE_UNSAFE" 'The extracted tree contains a hard-linked file.'
if [ -L "$bootstrap/pwsh" ] || [ ! -f "$bootstrap/pwsh" ]; then
    refuse archive-unsafe "$EXIT_ARCHIVE_UNSAFE" 'The archive does not contain a regular pwsh executable.'
fi
chmod -R go-rwx "$bootstrap"
chmod 0700 "$bootstrap/pwsh"

# --- S4: hand-off with an explicit environment allowlist (M5) ----------------
if [ "$os_token" = osx ]; then default_lang=en_US.UTF-8; else default_lang=C.UTF-8; fi
set -- "HOME=$home" "PATH=${PATH-/usr/bin:/bin}" "LANG=${LANG:-$default_lang}" "TMPDIR=$run_tmp" "PSModulePath=$bootstrap/Modules"
if [ -n "${LC_ALL+x}" ]; then set -- "$@" "LC_ALL=$LC_ALL"; fi
if [ -n "${HTTPS_PROXY+x}" ]; then set -- "$@" "HTTPS_PROXY=$HTTPS_PROXY"; fi
if [ -n "${HTTP_PROXY+x}" ]; then set -- "$@" "HTTP_PROXY=$HTTP_PROXY"; fi
if [ -n "${NO_PROXY+x}" ]; then set -- "$@" "NO_PROXY=$NO_PROXY"; fi
if [ -n "${https_proxy+x}" ]; then set -- "$@" "https_proxy=$https_proxy"; fi
if [ -n "${http_proxy+x}" ]; then set -- "$@" "http_proxy=$http_proxy"; fi
if [ -n "${no_proxy+x}" ]; then set -- "$@" "no_proxy=$no_proxy"; fi
if [ -n "${SSL_CERT_FILE+x}" ]; then set -- "$@" "SSL_CERT_FILE=$SSL_CERT_FILE"; fi
if [ -n "${SSL_CERT_DIR+x}" ]; then set -- "$@" "SSL_CERT_DIR=$SSL_CERT_DIR"; fi
if [ -n "${CODEX_HOME+x}" ]; then set -- "$@" "CODEX_HOME=$CODEX_HOME"; fi
if [ "$mode" = prepare ]; then mode_flag=-Prepare; else mode_flag=-Offline; fi
cd "$setup_root"
status=0
env -i "$@" "$bootstrap/pwsh" -NoLogo -NoProfile -NonInteractive -File "$script_dir/setup-agent-environment.ps1" \
    "$mode_flag" -ExpectedCommit "$expected_commit" -ArchivePath "$archive" || status=$?
exit "$status"
