#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Impulsa SLU

# Download, checksum, and install the exact Galaxy artifact set without resolving dependencies twice.
set -euo pipefail

root=$(cd "$(dirname "$0")" && pwd)
lock_file="$root/requirements.lock.sha256"
requirements_file="$root/requirements.yml"
artifact_root=$(mktemp -d "${TMPDIR:-/tmp}/burnerpad-galaxy-artifacts.XXXXXX")
stage_root=$(mktemp -d "$root/.galaxy-install.XXXXXX")
collections_target="$root/.collections"
roles_target="$root/.roles"
collections_backup="$stage_root/previous.collections"
roles_backup="$stage_root/previous.roles"
promotion_active=0
promotion_committed=0
collections_promoted=0
roles_promoted=0

cleanup() {
  local status=$?
  set +e

  if [ "$promotion_active" -eq 1 ] && [ "$promotion_committed" -eq 0 ]; then
    if [ "$collections_promoted" -eq 1 ]; then
      rm -rf -- "$collections_target"
    fi
    if [ -e "$collections_backup" ] || [ -L "$collections_backup" ]; then
      mv -- "$collections_backup" "$collections_target"
    fi

    if [ "$roles_promoted" -eq 1 ]; then
      rm -rf -- "$roles_target"
    fi
    if [ -e "$roles_backup" ] || [ -L "$roles_backup" ]; then
      mv -- "$roles_backup" "$roles_target"
    fi
  fi

  rm -rf -- "$artifact_root" "$stage_root"
  return "$status"
}
trap cleanup EXIT

while read -r checksum filename extra; do
  if [[ ! "$checksum" =~ ^[0-9a-f]{64}$ ]] ||
    [[ ! "$filename" =~ ^[A-Za-z0-9._-]+[.]tar[.]gz$ ]] ||
    [ -n "${extra:-}" ]; then
    echo "Invalid Galaxy lock entry: $checksum ${filename:-} ${extra:-}" >&2
    exit 1
  fi
done < "$lock_file"

mapfile -t role_archives < <(
  awk '$2 ~ /^geerlingguy[.]docker-[0-9][A-Za-z0-9._-]*[.]tar[.]gz$/ { print $2 }' "$lock_file"
)
if [ "${#role_archives[@]}" -ne 1 ]; then
  echo "Galaxy lock must contain exactly one geerlingguy.docker role archive" >&2
  exit 1
fi

role_filename=${role_archives[0]}
role_version=${role_filename#geerlingguy.docker-}
role_version=${role_version%.tar.gz}
if ! grep -Fq -- "name: geerlingguy.docker, version: \"$role_version\"" "$requirements_file"; then
  echo "geerlingguy.docker version differs between requirements.yml and the Galaxy lock" >&2
  exit 1
fi

ansible-galaxy collection download -r "$requirements_file" -p "$artifact_root" >/dev/null
curl -fsSL "https://github.com/geerlingguy/ansible-role-docker/archive/$role_version.tar.gz" \
  -o "$artifact_root/$role_filename"

(cd "$artifact_root" && sha256sum --check --strict "$lock_file")

actual=$(find "$artifact_root" -maxdepth 1 -type f -name '*.tar.gz' -printf '%f\n' | sort)
expected=$(awk '{ print $2 }' "$lock_file" | sort)
if [ "$actual" != "$expected" ]; then
  echo "Galaxy artifact set differs from requirements.lock.sha256" >&2
  exit 1
fi

collection_archives=()
while read -r filename; do
  if [ "$filename" != "$role_filename" ]; then
    collection_archives+=("$artifact_root/$filename")
  fi
done < <(awk '{ print $2 }' "$lock_file" | sort)
if [ "${#collection_archives[@]}" -eq 0 ]; then
  echo "Galaxy lock contains no collection archives" >&2
  exit 1
fi

collections_stage="$stage_root/collections"
roles_stage="$stage_root/roles"
mkdir -p "$collections_stage" "$roles_stage"

ANSIBLE_COLLECTIONS_PATH="$collections_stage" ansible-galaxy collection install \
  --offline \
  --no-deps \
  --collections-path "$collections_stage" \
  "${collection_archives[@]}" >/dev/null
ansible-galaxy role install \
  --no-deps \
  --roles-path "$roles_stage" \
  "$artifact_root/$role_filename,$role_version,geerlingguy.docker" >/dev/null

# A full staged install exists before either generated dependency directory is replaced. The EXIT trap
# restores both prior directories if promotion fails between these moves.
promotion_active=1
if [ -e "$collections_target" ] || [ -L "$collections_target" ]; then
  mv -- "$collections_target" "$collections_backup"
fi
collections_promoted=1
mv -- "$collections_stage" "$collections_target"

if [ -e "$roles_target" ] || [ -L "$roles_target" ]; then
  mv -- "$roles_target" "$roles_backup"
fi
roles_promoted=1
mv -- "$roles_stage" "$roles_target"
promotion_committed=1

echo "installed checksum-locked Galaxy collections and roles"
