#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Impulsa SLU

# Keep .tool-versions authoritative for parent CI while verifying the explicit Docker bootstrap image.
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_dir=$(cd "$script_dir/../.." && pwd)
versions_file="$repo_dir/.tool-versions"
dockerfile="$repo_dir/Dockerfile"
workflow_dir="$repo_dir/.github/workflows"

tool_version() {
  local tool=$1

  awk -v tool="$tool" '
    $1 == tool { count += 1; version = $2 }
    END {
      if (count != 1 || version == "") exit 1
      print version
    }
  ' "$versions_file"
}

if ! erlang_version=$(tool_version erlang); then
  echo ".tool-versions must contain exactly one Erlang version" >&2
  exit 1
fi
if ! elixir_spec=$(tool_version elixir); then
  echo ".tool-versions must contain exactly one Elixir version" >&2
  exit 1
fi
if ! node_version=$(tool_version nodejs); then
  echo ".tool-versions must contain exactly one Node.js version" >&2
  exit 1
fi

if [[ ! $erlang_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo ".tool-versions must pin one exact Erlang version" >&2
  exit 1
fi
if [[ ! $elixir_spec =~ ^([0-9]+\.[0-9]+\.[0-9]+)-otp-([0-9]+)$ ]]; then
  echo ".tool-versions must pin Elixir as X.Y.Z-otp-N" >&2
  exit 1
fi
elixir_version=${BASH_REMATCH[1]}
elixir_otp_major=${BASH_REMATCH[2]}
if [[ ! $node_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo ".tool-versions must pin one exact Node.js version" >&2
  exit 1
fi

erlang_major=${erlang_version%%.*}
if [ "$elixir_otp_major" != "$erlang_major" ]; then
  echo "Elixir OTP suffix does not match the pinned Erlang major" >&2
  exit 1
fi

builder_tag=$(
  sed -nE \
    's|^FROM[[:space:]]+hexpm/elixir:([^@[:space:]]+)@sha256:[0-9a-f]{64}[[:space:]]+AS[[:space:]]+build$|\1|p' \
    "$dockerfile"
)
expected_builder_prefix="$elixir_version-erlang-$erlang_version-ubuntu-noble-"
case "$builder_tag" in
  "$expected_builder_prefix"*) ;;
  *)
    echo "Dockerfile builder '$builder_tag' does not match $elixir_version / Erlang $erlang_version" >&2
    exit 1
    ;;
esac

literal_pins=$(grep -R -nE \
  '^[[:space:]]+(node-version|otp-version|elixir-version):[[:space:]]' \
  "$workflow_dir" --include='*.yml' --include='*.yaml' || true)
if [ -n "$literal_pins" ]; then
  echo "Parent workflows must read runtime versions from .tool-versions:" >&2
  echo "$literal_pins" >&2
  exit 1
fi

setup_node_count=$(grep -R -h 'uses: actions/setup-node@' "$workflow_dir" --include='*.yml' --include='*.yaml' | wc -l)
node_file_count=$(grep -R -hE '^[[:space:]]+node-version-file: \.tool-versions$' "$workflow_dir" --include='*.yml' --include='*.yaml' | wc -l)
setup_beam_count=$(grep -R -h 'uses: erlef/setup-beam@' "$workflow_dir" --include='*.yml' --include='*.yaml' | wc -l)
beam_file_count=$(grep -R -hE '^[[:space:]]+version-file: \.tool-versions$' "$workflow_dir" --include='*.yml' --include='*.yaml' | wc -l)

if [ "$setup_node_count" -ne "$node_file_count" ]; then
  echo "Every parent setup-node step must use node-version-file: .tool-versions" >&2
  exit 1
fi
if [ "$setup_beam_count" -ne "$beam_file_count" ]; then
  echo "Every parent setup-beam step must use version-file: .tool-versions" >&2
  exit 1
fi

echo "toolchain pins agree: Elixir $elixir_version, Erlang $erlang_version, Node.js $node_version"
