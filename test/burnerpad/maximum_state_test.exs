# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Impulsa SLU

defmodule Burnerpad.MaximumStateTest do
  use ExUnit.Case, async: false
  import Burnerpad.Support
  alias Burnerpad.{Abuse, Store}

  setup do
    reset()
    :ok
  end

  test "default production-sized tables keep full/admission/metrics paths bounded" do
    rows = 10_000
    put_config(:max_secrets, rows)
    put_config(:per_ip_row_budget, rows)
    put_config(:per_ip_budget, rows)
    put_config(:global_create_ceiling, rows)

    expires = System.monotonic_time(:second) + 3_600
    hash = :crypto.hash(:sha256, "load-test-token")
    store_rows = for n <- 1..rows, do: {n, <<1>>, hash, expires}
    true = :ets.insert(Store.table(), store_rows)

    assert {:error, :full} = Store.create(<<1>>, 60)
    assert :ets.info(Store.table(), :size) == rows

    reset()
    key = "192.0.2.1"
    assert {:ok, _reservation} = Abuse.admit_create(key, 1, 3_600)
    [{{token, slot}, 1, 1}] = :ets.tab2list(:bp_budget)

    filler =
      for n <- 1..(rows - 1),
          do: {{<<n::unsigned-32>>, slot + n + 1}, 1, 1}

    true = :ets.insert(:bp_budget, filler)
    assert :ets.info(:bp_budget, :size) == rows

    # The same source/slot remains O(1) and admissible even when the auxiliary table is at its hard cap.
    assert {:ok, _reservation} = Abuse.admit_create(key, 1, 3_600)
    assert [{{^token, ^slot}, 2, 2}] = :ets.lookup(:bp_budget, {token, slot})
    assert %{admission_queue: queue, active_bans: 0} = Abuse.metrics()
    assert is_integer(queue) and queue >= 0
  end
end
