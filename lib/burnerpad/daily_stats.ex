# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Impulsa SLU

defmodule Burnerpad.DailyStats do
  @moduledoc """
  Privacy-preserving, in-memory daily activity counts.

  Each ETS row is only `{utc_day_number, homepage_views, secrets_created}`. No cookie, fingerprint,
  network identifier, secret id, or secret contents ever enter this table, so there is nothing at the
  visitor or secret level to inspect or correlate. Counts reset on restart and rows older than the chart
  window are discarded.
  """
  use GenServer

  @table :bp_daily_activity
  @retention_days 31
  @sweep_ms 60 * 60 * 1000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Count one successful homepage response. Stores only UTC day + aggregate counts."
  def record_homepage_view, do: increment(2)

  @doc "Count one successfully stored secret. Stores only UTC day + aggregate counts."
  def record_secret_created, do: increment(3)

  @doc "Daily aggregate activity, oldest first, including zero-count days."
  def daily(days \\ 14) when is_integer(days) and days >= 1 and days <= @retention_days do
    today = utc_day()

    for day <- (today - days + 1)..today do
      {homepage_views, secrets_created} = counts(day)

      %{
        date: day |> Date.from_gregorian_days() |> Date.to_iso8601(),
        visits: homepage_views,
        secrets_created: secrets_created
      }
    end
  end

  @doc false
  def reset do
    :ets.delete_all_objects(@table)
    :ok
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    schedule()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    cutoff = utc_day() - @retention_days + 1
    :ets.select_delete(@table, [{{:"$1", :_, :_}, [{:<, :"$1", cutoff}], [true]}])
    schedule()
    {:noreply, state}
  end

  # Analytics must never make a homepage request or a successful secret insertion fail. The supervisor
  # starts this owner before either can receive traffic, but tolerate the tiny table-recreation window if
  # this process is independently restarted.
  defp increment(position) do
    day = utc_day()
    :ets.update_counter(@table, day, {position, 1}, {day, 0, 0})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp counts(day) do
    case :ets.lookup(@table, day) do
      [{^day, homepage_views, secrets_created}] -> {homepage_views, secrets_created}
      _ -> {0, 0}
    end
  end

  defp utc_day, do: Date.utc_today() |> Date.to_gregorian_days()
  defp schedule, do: Process.send_after(self(), :sweep, @sweep_ms)
end
