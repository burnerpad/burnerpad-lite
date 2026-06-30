# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Impulsa SLU

defmodule Burnerpad.Abuse do
  @moduledoc """
  Proactive, in-memory abuse control. Four ETS tables, all owned by this process:

    * `@rl`     `{key, window} => count`  — per-IP fixed-window counter
    * `@global` `window => count`         — server-wide aggregate counter (distributed-flood defense)
    * `@ban`    `key => {until_ms, strikes}` — escalating temp-bans, self-expiring
    * `@ametrics` `metric => count`       — lifetime aggregate counters for the public stats page

  `check/1` runs on every request (in the request process, against the public tables — no GenServer
  bottleneck). The GenServer only owns the tables and sweeps them.
  """
  use GenServer
  require Logger
  alias Burnerpad.Config

  @rl :bp_rl
  @global :bp_global
  @ban :bp_ban
  @ametrics :bp_abuse_metrics
  @sweep_ms 60_000

  ## ── Public API ──────────────────────────────────────────────────────────

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Decide a request from `key` (an IP prefix from `BurnerpadWeb.ClientIP`):
  `:ok` | `{:rate_limited, ms}` | `{:global, ms}` | `{:banned, ms}`.
  """
  def check(key) do
    now = ms()

    case ban_remaining(key, now) do
      n when n > 0 -> {:banned, n}
      _ -> count_and_decide(key, now)
    end
  end

  @doc "Aggregate, privacy-safe abuse counts for the public stats page (no IPs, no keys)."
  def metrics do
    now = ms()
    active = :ets.select_count(@ban, [{{:_, {:"$1", :_}}, [{:>, :"$1", now}], [true]}])

    %{
      throttled_total: actr(:rate_limited) + actr(:global),
      banned_total: actr(:banned),
      active_bans: active
    }
  end

  @doc false
  def reset do
    for t <- [@rl, @global, @ban, @ametrics], do: :ets.delete_all_objects(t)
    :ok
  end

  ## ── GenServer (table owner + sweeper) ───────────────────────────────────

  @impl true
  def init(_opts) do
    opts = [:named_table, :public, :set, read_concurrency: true, write_concurrency: true]
    for t <- [@rl, @global, @ban, @ametrics], do: :ets.new(t, opts)
    schedule()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = ms()
    old = now - 2 * Config.get(:window_ms)
    :ets.select_delete(@rl, [{{{:_, :"$1"}, :_}, [{:<, :"$1", old}], [true]}])
    :ets.select_delete(@global, [{{:"$1", :_}, [{:<, :"$1", old}], [true]}])
    :ets.select_delete(@ban, [{{:_, {:"$1", :_}}, [{:"=<", :"$1", now}], [true]}])

    schedule()
    {:noreply, state}
  end

  ## ── decision logic ──────────────────────────────────────────────────────

  defp count_and_decide(key, now) do
    win = Config.get(:window_ms)
    ws = now - rem(now, win)

    count = :ets.update_counter(@rl, {key, ws}, {2, 1}, {{key, ws}, 0})
    gcount = :ets.update_counter(@global, ws, {2, 1}, {ws, 0})

    cond do
      count > Config.get(:ban_threshold) ->
        dur = ban!(key, now)
        ametric(:banned)
        Logger.warning("abuse key=#{key} win=#{count}/#{sec(win)}s -> BAN #{sec(dur)}s")
        {:banned, dur}

      count > Config.get(:rate_limit) ->
        ametric(:rate_limited)
        Logger.warning("abuse key=#{key} win=#{count}/#{sec(win)}s RATE_LIMITED")
        {:rate_limited, ws + win - now}

      gcount > Config.get(:global_ceiling) ->
        ametric(:global)
        Logger.warning("abuse GLOBAL ceiling #{gcount}/#{sec(win)}s (key=#{key})")
        {:global, ws + win - now}

      true ->
        :ok
    end
  end

  defp ban!(key, now) do
    strikes =
      case :ets.lookup(@ban, key) do
        [{^key, {_until, s}}] -> s + 1
        _ -> 1
      end

    sched = Config.ban_schedule_ms()
    dur = Enum.at(sched, min(strikes - 1, length(sched) - 1))
    :ets.insert(@ban, {key, {now + dur, strikes}})
    dur
  end

  defp ban_remaining(key, now) do
    case :ets.lookup(@ban, key) do
      [{^key, {until, _s}}] when until > now -> until - now
      _ -> 0
    end
  end

  defp ametric(key), do: :ets.update_counter(@ametrics, key, {2, 1}, {key, 0})

  defp actr(key) do
    case :ets.lookup(@ametrics, key) do
      [{^key, v}] -> v
      _ -> 0
    end
  end

  defp ms, do: System.system_time(:millisecond)
  defp sec(ms), do: div(ms, 1000)
  defp schedule, do: Process.send_after(self(), :sweep, @sweep_ms)
end
