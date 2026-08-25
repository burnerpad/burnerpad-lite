# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Impulsa SLU

defmodule Burnerpad.AbuseTest do
  use ExUnit.Case
  import Burnerpad.Support
  alias Burnerpad.Abuse

  setup do
    reset()
    :ok
  end

  test "allows under the per-IP limit, then rate-limits" do
    put_config(:rate_limit, 3)
    put_config(:ban_threshold, 1000)
    k = "1.1.1.1"
    assert :ok = Abuse.check(k)
    assert :ok = Abuse.check(k)
    assert :ok = Abuse.check(k)
    assert {:rate_limited, ms} = Abuse.check(k)
    assert ms > 0
  end

  test "bans after crossing the ban threshold; the ban short-circuits subsequent requests" do
    put_config(:rate_limit, 1)
    put_config(:ban_threshold, 2)
    k = "2.2.2.2"
    assert :ok = Abuse.check(k)
    assert {:rate_limited, _} = Abuse.check(k)
    assert {:banned, ms} = Abuse.check(k)
    assert ms > 14 * 60_000
    assert {:banned, _} = Abuse.check(k)
  end

  test "the ban path is reachable at the smallest valid threshold ordering" do
    put_config(:rate_limit, 1)
    put_config(:ban_threshold, 2)
    put_config(:global_ceiling, 3)
    key = "2.2.2.3"

    assert :ok = Abuse.check(key)
    assert {:rate_limited, _} = Abuse.check(key)
    assert {:banned, _} = Abuse.check(key)
    assert Abuse.metrics().active_bans == 1
  end

  test "ban duration escalates on repeat offenses (strike 2 -> 1 h)" do
    put_config(:rate_limit, 1)
    put_config(:ban_threshold, 1)
    k = "3.3.3.3"
    # a prior, already-expired ban with one strike on record
    now = System.monotonic_time(:millisecond)
    :ets.insert(:bp_ban, {Abuse.table_key(k, :ban), {now - 1000, 1, now + 60_000, false}})
    assert :ok = Abuse.check(k)
    assert {:banned, ms} = Abuse.check(k)
    assert ms > 59 * 60_000 and ms <= 60 * 60_000
  end

  test "ETS tables retain only keyed source tokens, never raw IP prefixes" do
    key = "203.0.113.99"
    assert :ok = Abuse.check(key)
    assert {:ok, _reservation} = Abuse.admit_create(key, 1, 3600)

    dump = :erlang.term_to_binary([:ets.tab2list(:bp_rl), :ets.tab2list(:bp_budget)])
    refute dump =~ key
  end

  test "global ceiling sheds load from many distinct IPs (a distributed flood)" do
    put_config(:rate_limit, 1000)
    put_config(:ban_threshold, 10_000)
    put_config(:global_ceiling, 3)
    assert :ok = Abuse.check("10.0.0.1")
    assert :ok = Abuse.check("10.0.0.2")
    assert :ok = Abuse.check("10.0.0.3")
    assert {:global, ms} = Abuse.check("10.0.0.4")
    assert ms > 0
  end

  test "global create ceiling sheds valid distributed creation before Store work" do
    put_config(:global_create_ceiling, 2)

    assert {:ok, _} = Abuse.admit_create("10.1.0.1", 1, 60)
    assert {:ok, _} = Abuse.admit_create("10.1.0.2", 1, 60)
    assert {:error, {:global_create, retry_ms}} = Abuse.admit_create("10.1.0.3", 1, 60)
    assert retry_ms > 0
    assert Abuse.metrics().creation_shed_total == 1
  end

  test "rejected source admissions do not consume the global valid-create ceiling" do
    put_config(:global_create_ceiling, 2)
    put_config(:per_ip_row_budget, 1)

    assert {:ok, _} = Abuse.admit_create("10.1.1.1", 1, 60)
    assert {:error, :over_budget} = Abuse.admit_create("10.1.1.1", 1, 60)
    assert {:ok, _} = Abuse.admit_create("10.1.1.2", 1, 60)
  end

  test "global create rejection rolls back the exact source reservation" do
    put_config(:global_create_ceiling, 1)
    put_config(:per_ip_row_budget, 1)

    assert {:ok, _} = Abuse.admit_create("10.1.2.1", 1, 60)
    assert {:error, {:global_create, _}} = Abuse.admit_create("10.1.2.2", 1, 60)
    assert :ets.info(:bp_budget_total, :size) == 1

    :ets.delete_all_objects(:bp_create_global)

    assert {:ok, _} = Abuse.admit_create("10.1.2.2", 1, 60)
    assert :ets.info(:bp_budget_total, :size) == 2
  end

  test "concurrent creates cannot overshoot global or per-source admission ceilings" do
    put_config(:global_create_ceiling, 10)
    put_config(:per_ip_row_budget, 2)
    put_config(:per_ip_budget, 1_000_000)

    results =
      1..200
      |> Task.async_stream(
        fn n -> Abuse.admit_create("10.1.3.#{rem(n, 10)}", 1, 60) end,
        max_concurrency: 50,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 10

    rows = for {_token, count, _bytes} <- :ets.tab2list(:bp_budget_total), do: count
    assert Enum.sum(rows) == 10
    assert Enum.all?(rows, &(&1 <= 2))
  end

  test "weighted previous window prevents a fixed-window boundary burst (L1)" do
    now = System.monotonic_time(:millisecond)
    win = max(abs(now) * 2, 60_000)
    ws = Integer.floor_div(now, win) * win
    key = "4.4.4.4"

    put_config(:window_ms, win)
    put_config(:rate_limit, 3)
    put_config(:ban_threshold, 1000)
    :ets.insert(:bp_rl, {{Abuse.table_key(key), ws - win}, 10})

    assert {:rate_limited, _} = Abuse.check(key)
  end

  test "per-source byte budget cannot be raced by concurrent creates" do
    put_config(:per_ip_budget, 100)

    admitted =
      1..50
      |> Task.async_stream(fn _ -> Abuse.admit_create("6.6.6.6", 60, 3600) end,
        max_concurrency: 50,
        ordered: false
      )
      |> Enum.count(fn {:ok, result} -> match?({:ok, _reservation}, result) end)

    assert admitted == 1
  end

  test "an opaque rollback handle releases its exact byte-budget reservation" do
    put_config(:per_ip_budget, 100)
    key = "6.6.6.7"

    assert {:ok, reservation} = Abuse.admit_create(key, 60, 3600)
    assert :ok = Abuse.rollback_create(reservation)
    assert {:ok, _reservation} = Abuse.admit_create(key, 100, 3600)
  end

  test "an opaque rollback handle preserves its source without caller-supplied accounting fields" do
    put_config(:per_ip_budget, 100)

    assert {:ok, first_source} = Abuse.admit_create("6.6.6.70", 60, 3600)
    assert {:ok, _second_source} = Abuse.admit_create("6.6.6.71", 80, 3600)

    assert :ok = Abuse.rollback_create(first_source)
    assert {:ok, _reservation} = Abuse.admit_create("6.6.6.70", 100, 3600)
    assert {:error, :over_budget} = Abuse.admit_create("6.6.6.71", 21, 3600)
  end

  test "per-source row budget prevents tiny ciphertexts from exhausting the store" do
    put_config(:per_ip_budget, 1_000_000)
    put_config(:per_ip_row_budget, 2)
    key = "6.6.6.8"

    assert {:ok, _reservation} = Abuse.admit_create(key, 1, 3600)
    assert {:ok, _reservation} = Abuse.admit_create(key, 1, 3600)
    assert {:error, :over_budget} = Abuse.admit_create(key, 1, 3600)
    assert {:ok, _reservation} = Abuse.admit_create("6.6.6.9", 1, 3600)
  end

  test "an opaque rollback handle releases one row-budget reservation" do
    put_config(:per_ip_budget, 1_000_000)
    put_config(:per_ip_row_budget, 1)
    key = "6.6.6.10"

    assert {:ok, reservation} = Abuse.admit_create(key, 1, 3600)
    assert :ok = Abuse.rollback_create(reservation)
    assert {:ok, _reservation} = Abuse.admit_create(key, 1, 3600)
  end

  test "expired budget slots remove their O(1) per-source aggregate" do
    assert {:ok, _reservation} = Abuse.admit_create("6.6.6.11", 10, 60)
    [{{token, slot}, rows, bytes}] = :ets.tab2list(:bp_budget)
    :ets.delete(:bp_budget, {token, slot})
    :ets.insert(:bp_budget, {{token, slot - 10}, rows, bytes})

    send(Abuse, :sweep)
    :sys.get_state(Abuse)

    assert :ets.tab2list(:bp_budget) == []
    assert :ets.tab2list(:bp_budget_total) == []
  end

  test "a stalled admission owner times out and cannot later reserve capacity" do
    put_config(:state_call_timeout_ms, 100)
    :sys.suspend(Abuse)

    on_exit(fn ->
      try do
        :sys.resume(Abuse)
      catch
        :exit, _ -> :ok
      end
    end)

    assert {:error, :busy} = Abuse.admit_create("6.6.6.12", 1, 60)
    :sys.resume(Abuse)
    :sys.get_state(Abuse)
    assert :ets.tab2list(:bp_budget) == []
    assert Abuse.metrics().admission_busy_total >= 1
  end

  test "byte-budget metadata is hard-capped independently of create/reveal churn" do
    put_config(:max_secrets, 1)
    put_config(:per_ip_budget, 1_000)

    assert {:ok, _reservation} = Abuse.admit_create("198.51.100.1", 1, 3600)
    assert {:error, :over_budget} = Abuse.admit_create("198.51.100.2", 1, 3600)
    assert :ets.info(:bp_budget, :size) == 1
  end

  test "metrics expose aggregate throttle/ban counts and active bans (no keys)" do
    put_config(:rate_limit, 1)
    put_config(:ban_threshold, 2)
    k = "5.5.5.5"
    Abuse.check(k)
    Abuse.check(k)
    Abuse.check(k)

    m = Abuse.metrics()
    assert m.throttled_total >= 1
    assert m.banned_total >= 1
    assert m.active_bans >= 1
    refute Map.has_key?(m, :key)
  end

  test "global overload is rejected before allocating more per-source rows" do
    put_config(:rate_limit, 1000)
    put_config(:ban_threshold, 10_000)
    put_config(:global_ceiling, 1)

    assert :ok = Abuse.check("198.51.100.1")
    initial_rows = :ets.info(:bp_rl, :size)

    for n <- 2..100 do
      assert {:global, _} = Abuse.check("198.51.100.#{n}")
    end

    assert :ets.info(:bp_rl, :size) == initial_rows
  end

  test "source tokens are purpose-separated across rate, ban, and byte-budget state" do
    key = "203.0.113.9"
    tokens = for purpose <- [:rate, :ban, :budget], do: Abuse.table_key(key, purpose)
    assert length(Enum.uniq(tokens)) == 3
  end
end
