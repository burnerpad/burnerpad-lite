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

  test "ban duration escalates on repeat offenses (strike 2 -> 1 h)" do
    put_config(:rate_limit, 1)
    put_config(:ban_threshold, 1)
    k = "3.3.3.3"
    # a prior, already-expired ban with one strike on record
    :ets.insert(:bp_ban, {k, {System.system_time(:millisecond) - 1000, 1}})
    assert :ok = Abuse.check(k)
    assert {:banned, ms} = Abuse.check(k)
    assert ms > 59 * 60_000 and ms <= 60 * 60_000
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
end
