# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Impulsa SLU

defmodule Burnerpad.DailyStatsTest do
  use ExUnit.Case
  import Burnerpad.Support
  alias Burnerpad.{DailyStats, Store}

  setup do
    reset()
    :ok
  end

  test "keeps independent anonymous homepage and secret-creation totals for each UTC day" do
    assert :ok = DailyStats.record_homepage_view()
    assert :ok = DailyStats.record_homepage_view()
    assert {:ok, _id, _mgmt} = Store.create(<<1>>)

    assert %{visits: 2, secrets_created: 1, date: date} = List.last(DailyStats.daily())
    assert {:ok, %Date{}} = Date.from_iso8601(date)
  end

  test "returns a zero-filled window and resets all daily aggregates" do
    assert length(DailyStats.daily(31)) == 31
    assert Enum.all?(DailyStats.daily(3), &match?(%{visits: 0, secrets_created: 0}, &1))

    DailyStats.record_homepage_view()
    assert :ok = DailyStats.reset()
    assert %{visits: 0, secrets_created: 0} = List.last(DailyStats.daily())
  end

  test "counts only successful Store insertions" do
    put_config(:max_secrets, 1)
    assert {:ok, _id, _mgmt} = Store.create(<<1>>)
    assert {:error, :full} = Store.create(<<2>>)
    assert %{secrets_created: 1} = List.last(DailyStats.daily())
  end

  test "counter updates are atomic under concurrency" do
    1..200
    |> Task.async_stream(fn _ -> DailyStats.record_homepage_view() end,
      max_concurrency: 50,
      ordered: false
    )
    |> Stream.run()

    assert %{visits: 200, secrets_created: 0} = List.last(DailyStats.daily())
  end
end
