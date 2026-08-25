#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Impulsa SLU

set -euo pipefail

test_dir=$(cd "$(dirname "$0")" && pwd)
repo_dir=$(cd "$test_dir/../.." && pwd)
installer="$repo_dir/ops/install-requirements-locked.sh"
scratch=$(mktemp -d)

cleanup() {
  find "$scratch" -depth -delete
}
trap cleanup EXIT

fixture="$scratch/repo"
fake_bin="$scratch/bin"
fixture_tmp="$scratch/tmp"
mkdir -p "$fixture/ops" "$fake_bin" "$fixture_tmp"
cp "$installer" "$fixture/ops/install-requirements-locked.sh"

printf '%s\n' \
  'collections: []' \
  'roles:' \
  '  - { name: geerlingguy.docker, version: "8.0.0" }' \
  > "$fixture/ops/requirements.yml"
cat > "$fixture/ops/requirements.lock.sha256" <<'LOCK'
6698325a6eb5d2d66130a0647ad61a8459d827a6d67a318420844fbcf4aef73f  test-fixture-1.0.0.tar.gz
ededd86eae8e309527384e2faa02f979a8e8f73da12106ab3062875d39cf03d6  geerlingguy.docker-8.0.0.tar.gz
LOCK

cat > "$fake_bin/ansible-galaxy" <<'FAKE_GALAXY'
#!/usr/bin/env bash
set -euo pipefail

kind=$1
action=$2
shift 2

option_value() {
  local wanted=$1
  shift
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "$wanted" ]; then
      printf '%s\n' "$2"
      return
    fi
    shift
  done
  return 1
}

case "$kind:$action" in
  collection:download)
    destination=$(option_value -p "$@")
    printf 'collection fixture\n' > "$destination/test-fixture-1.0.0.tar.gz"
    ;;
  collection:install)
    printf '%s\n' "$*" | grep -Fq -- '--offline'
    printf '%s\n' "$*" | grep -Fq -- '--no-deps'
    if printf '%s\n' "$*" | grep -Eq -- '(^| )(-r|--requirements-file)( |$)'; then
      echo 'collection install resolved requirements instead of using verified archives' >&2
      exit 1
    fi
    destination=$(option_value --collections-path "$@")
    archive_seen=0
    for argument in "$@"; do
      case "$argument" in
        *.tar.gz)
          archive_seen=1
          test -f "$argument"
          case "$argument" in
            "$TMPDIR"/*) ;;
            *) echo 'collection install received an archive outside the verified directory' >&2; exit 1 ;;
          esac
          ;;
      esac
    done
    test "$archive_seen" -eq 1
    mkdir -p "$destination/ansible_collections/test/fixture"
    printf 'installed\n' > "$destination/ansible_collections/test/fixture/LOCKED"
    ;;
  role:install)
    printf '%s\n' "$*" | grep -Fq -- '--no-deps'
    if printf '%s\n' "$*" | grep -Eq -- '(^| )(-r|--role-file)( |$)'; then
      echo 'role install resolved requirements instead of using a verified archive' >&2
      exit 1
    fi
    destination=$(option_value --roles-path "$@")
    role_spec=${!#}
    case "$role_spec" in
      *',8.0.0,geerlingguy.docker') ;;
      *) echo 'verified role was not installed under its locked version and playbook name' >&2; exit 1 ;;
    esac
    role_archive=${role_spec%%,*}
    test -f "$role_archive"
    case "$role_archive" in
      "$TMPDIR"/*) ;;
      *) echo 'role install received an archive outside the verified directory' >&2; exit 1 ;;
    esac
    mkdir -p "$destination/geerlingguy.docker"
    printf 'installed\n' > "$destination/geerlingguy.docker/LOCKED"
    ;;
  *)
    echo "unexpected ansible-galaxy invocation: $kind $action $*" >&2
    exit 1
    ;;
esac
FAKE_GALAXY

cat > "$fake_bin/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
set -euo pipefail

while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then
    destination=$2
    break
  fi
  shift
done
test -n "${destination:-}"
printf 'role fixture\n' > "$destination"
FAKE_CURL

chmod +x "$fake_bin/ansible-galaxy" "$fake_bin/curl"
mkdir -p "$fixture/ops/.collections" "$fixture/ops/.roles"
printf 'stale\n' > "$fixture/ops/.collections/STALE"
printf 'stale\n' > "$fixture/ops/.roles/STALE"

PATH="$fake_bin:$PATH" TMPDIR="$fixture_tmp" "$fixture/ops/install-requirements-locked.sh"

test -f "$fixture/ops/.collections/ansible_collections/test/fixture/LOCKED"
test -f "$fixture/ops/.roles/geerlingguy.docker/LOCKED"
test ! -e "$fixture/ops/.collections/STALE"
test ! -e "$fixture/ops/.roles/STALE"

echo "locked Galaxy installer tests passed"
