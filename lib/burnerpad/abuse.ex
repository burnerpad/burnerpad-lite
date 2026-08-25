# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Impulsa SLU

defmodule Burnerpad.Abuse do
  @moduledoc """
  Proactive, in-memory abuse control. Seven ETS tables, all owned by this process:

    * `@rl`     `{token, window} => count`  — per-source two-window weighted counter
    * `@global` `window => count`         — server-wide aggregate counter (distributed-flood defense)
    * `@create_global` `window => count`  — server-wide valid-create admission counter
    * `@ban`    `token => {until_ms, strikes, forget_ms}` — escalating temp-bans, self-expiring
    * `@ametrics` `metric => count`       — lifetime aggregate counters for the public stats page
    * `@budget` `{token, expiry_slot} => {rows, bytes}` — count-only capacity budget
    * `@budget_total` `token => {rows, bytes}` — O(1) live aggregate for admission

  Source addresses are converted immediately to purpose-separated HMAC tokens using a random,
  VM-local RAM key. The tables never retain a raw IP prefix and cannot be joined to one another by token,
  while requests from the same source still share each necessary counter. Everything disappears on restart.

  `check/1` runs on every request (in the request process, against the public tables — no GenServer
  bottleneck). The GenServer owns and sweeps the tables, and serializes byte-budget reservations.
  """
  use GenServer
  require Logger
  alias Burnerpad.{Config, ProcessMetrics}

  @rl :bp_rl
  @global :bp_global
  @create_global :bp_create_global
  @ban :bp_ban
  @ametrics :bp_abuse_metrics
  # Per-source capacity budget: `{token, expiry_slot} => {rows, bytes}`. Buckets are keyed by the secret's
  # approximate expiry — aggregate counts only, never a secret id.
  @budget :bp_budget
  @budget_total :bp_budget_total
  @budget_slot_ms 900_000
  @sweep_ms 60_000
  @strike_retention_ms 24 * 60 * 60_000
  @anon_key {__MODULE__, :source_hmac_key}

  @opaque reservation :: {:create_admission, binary(), integer(), pos_integer()}
  @type admission_error :: :over_budget | :busy | {:global_create, non_neg_integer()}

  ## ── Public API ──────────────────────────────────────────────────────────

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Decide a request from `key` (an IP prefix from `BurnerpadWeb.ClientIP`):
  `:ok` | `{:rate_limited, ms}` | `{:global, ms}` | `{:banned, ms}`.
  """
  def check(key) do
    rate_key = anonymize(:rate, key)
    ban_key = anonymize(:ban, key)
    now = ms()

    case ban_remaining(ban_key, now) do
      n when n > 0 -> {:banned, n}
      _ -> count_and_decide(rate_key, ban_key, now)
    end
  end

  @doc """
  Admit a create of `bytes` ciphertext from `key`, with the secret's effective `ttl_seconds` (M13).
  `{:ok, reservation}` if the source is under its per-IP row and byte budgets, else
  `{:error, :over_budget}`. The opaque reservation is used only to roll back a failed store operation.
  Count-only, expiry-bucketed, no `IP <-> secret` link — the bytes age out with the secret's TTL bucket.
  """
  @spec admit_create(binary(), pos_integer(), pos_integer()) ::
          {:ok, reservation()} | {:error, admission_error()}
  def admit_create(key, bytes, ttl_seconds) do
    # The sum + reservation must be serialized. With direct ETS operations, concurrent creates from one
    # source could all pass the same pre-check and overrun the per-IP memory budget.
    # Avoid a timed-out reservation being applied after the caller has abandoned the request. These
    # callbacks do bounded ETS work; a server crash still fails linked calls immediately.
    timeout = Config.get(:state_call_timeout_ms)
    deadline = ms() + timeout

    token = anonymize(:budget, key)

    case safe_call({:admit_create, token, bytes, ttl_seconds, deadline}, timeout) do
      {:ok, slot} -> {:ok, {:create_admission, token, slot, bytes}}
      error -> error
    end
  end

  @doc false
  @spec rollback_create(reservation()) :: :ok | {:error, :busy}
  def rollback_create({:create_admission, token, slot, bytes})
      when is_binary(token) and is_integer(slot) and is_integer(bytes) and bytes > 0 do
    timeout = Config.get(:state_call_timeout_ms)
    safe_call({:rollback_create, token, slot, bytes}, timeout)
  end

  @doc "Bounded readiness probe for the state owner and its private ETS tables; never waits longer than 500 ms."
  def ready? do
    GenServer.call(__MODULE__, :ready, min(Config.get(:state_call_timeout_ms), 500)) == :ok
  catch
    :exit, _ -> false
  end

  defp do_admit_create(key, bytes, ttl_seconds) do
    now = ms()
    slot = expiry_slot(now + ttl_seconds * 1000)

    {live_rows, live_bytes} =
      case :ets.lookup(@budget_total, key) do
        [{^key, rows, stored_bytes}] -> {rows, stored_bytes}
        [] -> {0, 0}
      end

    if live_rows + 1 <= Config.per_ip_row_budget() and
         live_bytes + bytes <= Config.per_ip_budget() and
         budget_slot_available?(key, slot) do
      reserve_budget(key, slot, bytes)

      case admit_global_create(now) do
        :ok ->
          {:ok, slot}

        {:error, retry_ms} ->
          rollback_budget(key, slot, bytes)
          increment_metric(:global_create)
          {:error, {:global_create, retry_ms}}
      end
    else
      increment_metric(:over_budget)
      {:error, :over_budget}
    end
  end

  defp reserve_budget(key, slot, bytes) do
    :ets.update_counter(
      @budget,
      {key, slot},
      [{2, 1}, {3, bytes}],
      {{key, slot}, 0, 0}
    )

    :ets.update_counter(@budget_total, key, [{2, 1}, {3, bytes}], {key, 0, 0})
  end

  defp admit_global_create(now) do
    win = Config.get(:window_ms)
    ws = Integer.floor_div(now, win) * win
    elapsed = now - ws
    count = :ets.update_counter(@create_global, ws, {2, 1}, {ws, 0})
    weighted = weighted_count(@create_global, ws - win, count, win, elapsed)

    if weighted > Config.get(:global_create_ceiling) * win,
      do: {:error, conservative_retry(win, elapsed)},
      else: :ok
  end

  defp expiry_slot(ms), do: Integer.floor_div(ms, @budget_slot_ms)

  # A reveal can remove a Store row long before its original TTL, while its unlinkable budget count stays
  # conservative until that TTL bucket expires. Cap the auxiliary table independently so repeated
  # create/reveal cycles cannot turn those count-only rows into an unbounded metadata DoS.
  defp budget_slot_available?(key, slot) do
    :ets.member(@budget, {key, slot}) or
      :ets.info(@budget, :size) < Config.get(:max_secrets)
  end

  @doc "Aggregate, privacy-safe abuse counts for the public stats page (no IPs, no keys)."
  def metrics do
    %{
      throttled_total:
        metric_value(:rate_limited) + metric_value(:global) + metric_value(:global_create),
      creation_shed_total: metric_value(:global_create),
      banned_total: metric_value(:banned),
      active_bans: metric_value(:active_bans),
      admission_busy_total: metric_value(:admission_busy),
      admission_queue: ProcessMetrics.queue_length(__MODULE__)
    }
  end

  @doc false
  def reset do
    for t <- [@rl, @global, @create_global, @ban, @ametrics, @budget, @budget_total],
        do: :ets.delete_all_objects(t)

    :ok
  end

  ## ── GenServer (table owner + sweeper) ───────────────────────────────────

  @impl true
  def init(_opts) do
    :persistent_term.put(@anon_key, :crypto.strong_rand_bytes(32))
    opts = [:named_table, :public, :set, read_concurrency: true, write_concurrency: true]

    for t <- [@rl, @global, @create_global, @ban, @ametrics, @budget, @budget_total],
        do: :ets.new(t, opts)

    schedule()
    {:ok, %{}}
  end

  # Admission messages contain purpose-separated source tokens. They are not reversible without the
  # VM-local key, but still do not belong in OTP crash/termination reports.
  @impl true
  def format_status(status), do: Map.merge(status, %{message: :redacted, log: []})

  @impl true
  def handle_call(:ready, _from, state) do
    tables = [@rl, @global, @create_global, @ban, @ametrics, @budget, @budget_total]
    ready? = Enum.all?(tables, &(:ets.info(&1) != :undefined))
    {:reply, if(ready?, do: :ok, else: :not_ready), state}
  end

  def handle_call({:admit_create, key, bytes, ttl_seconds, deadline}, _from, state) do
    if ms() > deadline do
      increment_metric(:admission_busy)
      {:reply, {:error, :busy}, state}
    else
      {:reply, do_admit_create(key, bytes, ttl_seconds), state}
    end
  end

  def handle_call({:rollback_create, key, slot, bytes}, _from, state) do
    rollback_budget(key, slot, bytes)
    {:reply, :ok, state}
  end

  defp rollback_budget(key, slot, bytes) do
    case :ets.lookup(@budget, {key, slot}) do
      [{{^key, ^slot}, rows, count}] when rows > 1 and count > bytes ->
        :ets.insert(@budget, {{key, slot}, rows - 1, count - bytes})
        decrement_budget_total(key, 1, bytes)

      [{{^key, ^slot}, _rows, _count}] ->
        :ets.delete(@budget, {key, slot})
        decrement_budget_total(key, 1, bytes)

      [] ->
        :ok
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    now = ms()
    old = now - 2 * Config.get(:window_ms)
    :ets.select_delete(@rl, [{{{:_, :"$1"}, :_}, [{:<, :"$1", old}], [true]}])
    :ets.select_delete(@global, [{{:"$1", :_}, [{:<, :"$1", old}], [true]}])
    :ets.select_delete(@create_global, [{{:"$1", :_}, [{:<, :"$1", old}], [true]}])
    :ets.select_delete(@ban, [{{:_, {:_, :_, :"$1", :_}}, [{:"=<", :"$1", now}], [true]}])
    cur = expiry_slot(now)
    expire_active_bans(now)
    expire_budget_slots(cur)

    schedule()
    {:noreply, state}
  end

  ## ── decision logic ──────────────────────────────────────────────────────

  defp count_and_decide(rate_key, ban_key, now) do
    win = Config.get(:window_ms)
    ws = Integer.floor_div(now, win) * win
    elapsed = now - ws

    gcount = :ets.update_counter(@global, ws, {2, 1}, {ws, 0})
    gweighted = weighted_count(@global, ws - win, gcount, win, elapsed)

    if gweighted > Config.get(:global_ceiling) * win do
      # Reject before allocating a per-source row: a distributed flood cannot grow @rl without bound once
      # the global admission ceiling has been reached. Aggregate metrics replace one warning per rejection.
      increment_metric(:global)
      {:global, conservative_retry(win, elapsed)}
    else
      count = :ets.update_counter(@rl, {rate_key, ws}, {2, 1}, {{rate_key, ws}, 0})
      weighted = weighted_count(@rl, {rate_key, ws - win}, count, win, elapsed)

      cond do
        weighted > Config.get(:ban_threshold) * win ->
          dur = ban!(ban_key, now)
          increment_metric(:banned)
          Logger.warning("abuse threshold exceeded -> BAN #{sec(dur)}s")
          {:banned, dur}

        weighted > Config.get(:rate_limit) * win ->
          increment_metric(:rate_limited)
          {:rate_limited, conservative_retry(win, elapsed)}

        true ->
          :ok
      end
    end
  end

  # Two-window weighted counter. At a boundary, the previous bucket starts at full weight and fades out
  # over the new window, preventing the ~2x burst that a flat fixed window permits (L1).
  defp weighted_count(table, previous_key, current, win, elapsed) do
    previous =
      case :ets.lookup(table, previous_key) do
        [{^previous_key, n}] -> n
        _ -> 0
      end

    current * win + previous * (win - elapsed)
  end

  defp ban!(key, now), do: ban_cas(key, now)

  defp ban_cas(key, now) do
    case :ets.lookup(@ban, key) do
      [] ->
        new_ban = new_ban(key, now, 1)

        if :ets.insert_new(@ban, new_ban) do
          increment_metric(:active_bans)
          elem(elem(new_ban, 1), 0) - now
        else
          ban_cas(key, now)
        end

      [{^key, {until, _strikes, _forget, true}}] when until > now ->
        until - now

      [{^key, {_until, strikes, forget, active}} = old] ->
        next_strike = if forget > now, do: strikes + 1, else: 1
        new_ban = new_ban(key, now, next_strike)

        if replace_exact(old, new_ban) do
          if not active, do: increment_metric(:active_bans)
          elem(elem(new_ban, 1), 0) - now
        else
          ban_cas(key, now)
        end
    end
  end

  defp new_ban(key, now, strikes) do
    sched = Config.ban_schedule_ms()
    dur = Enum.at(sched, min(strikes - 1, length(sched) - 1))
    {key, {now + dur, strikes, now + dur + @strike_retention_ms, true}}
  end

  defp ban_remaining(key, now) do
    case :ets.lookup(@ban, key) do
      [{^key, {until, _s, _forget, true}}] when until > now ->
        until - now

      [{^key, {until, strikes, forget, true}} = old] ->
        inactive = {key, {until, strikes, forget, false}}
        if replace_exact(old, inactive), do: increment_metric(:active_bans, -1)
        0

      _ ->
        0
    end
  end

  defp replace_exact(old, new),
    do: :ets.select_replace(@ban, [{old, [], [{:const, new}]}]) == 1

  defp expire_active_bans(now) do
    :ets.select(@ban, [{{:"$1", {:"$2", :_, :_, true}}, [{:"=<", :"$2", now}], [:"$1"]}])
    |> Enum.each(&ban_remaining(&1, now))
  end

  defp expire_budget_slots(cur) do
    expired =
      :ets.select(@budget, [
        {{{:"$1", :"$2"}, :"$3", :"$4"}, [{:<, :"$2", cur}], [{{:"$1", :"$2", :"$3", :"$4"}}]}
      ])

    Enum.each(expired, fn {key, slot, rows, bytes} ->
      :ets.delete(@budget, {key, slot})
      decrement_budget_total(key, rows, bytes)
    end)
  end

  defp decrement_budget_total(key, rows, bytes) do
    case :ets.lookup(@budget_total, key) do
      [{^key, current_rows, current_bytes}] when current_rows > rows ->
        :ets.insert(@budget_total, {key, current_rows - rows, max(current_bytes - bytes, 0)})

      _ ->
        :ets.delete(@budget_total, key)
    end
  end

  # HMAC (rather than a plain hash) prevents offline reversal of the small IPv4 address space from an ETS
  # snapshot. The random key is RAM-only and changes on every VM boot.
  # Purpose separation prevents an ETS snapshot from joining a rate bucket, a ban, and a byte budget for
  # the same source. All tokens still use the one RAM-only random key and disappear on restart.
  defp anonymize(purpose, key),
    do:
      :crypto.mac(:hmac, :sha256, :persistent_term.get(@anon_key), [
        Atom.to_string(purpose),
        0,
        key
      ])

  @doc false
  def table_key(key, purpose \\ :rate), do: anonymize(purpose, key)

  defp increment_metric(key, amount \\ 1),
    do: :ets.update_counter(@ametrics, key, {2, amount}, {key, 0})

  defp metric_value(key) do
    case :ets.lookup(@ametrics, key) do
      [{^key, v}] -> v
      _ -> 0
    end
  end

  defp ms, do: System.monotonic_time(:millisecond)
  defp conservative_retry(win, elapsed), do: 2 * win - elapsed

  defp safe_call(message, timeout) do
    GenServer.call(__MODULE__, message, timeout)
  catch
    :exit, _ ->
      increment_metric(:admission_busy)
      {:error, :busy}
  end

  defp sec(ms), do: div(ms, 1000)
  defp schedule, do: Process.send_after(self(), :sweep, @sweep_ms)
end
