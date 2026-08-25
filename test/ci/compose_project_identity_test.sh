#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Impulsa SLU

set -euo pipefail

test_dir=$(cd "$(dirname "$0")" && pwd)
repo_dir=$(cd "$test_dir/../.." && pwd)
vars_file="$repo_dir/ops/group_vars/all/vars.yml"
deploy_tasks="$repo_dir/ops/roles/deploy/tasks/main.yml"
diagnostic="$repo_dir/ops/roles/monitor/templates/bp-diag.sh.j2"
compliance="$repo_dir/ops/step_3_compliance.yml"

grep -Eq '^compose_project_name:[[:space:]]+"?[a-z0-9][a-z0-9_-]*"?([[:space:]]*(#.*)?)$' "$vars_file"
grep -Fq -- '--filter label=com.docker.compose.project={{ compose_project_name }}' "$deploy_tasks"
test "$(grep -Fc -- '--project-name {{ compose_project_name }}' "$deploy_tasks")" -ge 2
grep -Fq -- 'project_name: "{{ compose_project_name }}"' "$deploy_tasks"
test "$(grep -Fc -- 'docker compose --project-name {{ compose_project_name }}' "$diagnostic")" -ge 2
grep -Fq -- '--project-name {{ compose_project_name }}' "$compliance"

if rg -n -- 'com[.]docker[.]compose[.]project=burnerpad|remote_dir[[:space:]]*[|][[:space:]]*basename' \
  "$deploy_tasks" "$diagnostic" "$compliance"; then
  echo "Compose project identity is hard-coded or derived from remote_dir" >&2
  exit 1
fi

echo "Compose project identity contract tests passed"
