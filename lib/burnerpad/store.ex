# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Impulsa SLU

defmodule Burnerpad.Store do
  @moduledoc """
  In-memory, burn-on-read secret store. The **only** module that touches the secrets ETS table.

  A row is `{id, blob, mgmt_token_hash, expires_at}`:
    * `blob` — the opaque ciphertext envelope (never parsed here; the server is crypto-agnostic)
    * `mgmt_token_hash` — SHA-256 of a one-time management token (the raw token is never stored)
    * `expires_at` — process-local monotonic deadline in seconds

  Burn-on-read is `:ets.take/2` (atomic remove+return) → at most one successful server claim under concurrency.
  Nothing is written to disk; everything is lost on restart by design.
  """
  use GenServer
  require Logger
  alias Burnerpad.{Config, DailyStats, Encoding, ProcessMetrics}

  @table :bp_secrets
  @metrics :bp_metrics
  @sweep_ms 60_000
  @id_length 26
  @alphabet ~c"0123456789ABCDEFGHJKMNPQRSTVWXYZ"
  @alphaset MapSet.new(@alphabet)

  ## ── Public API ──────────────────────────────────────────────────────────

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Store an opaque ciphertext blob. Returns `{:ok, id, mgmt_token_b64}` or `{:error, :full}`."
  def create(blob, ttl_seconds \\ nil) do
    # Serialize creates through the table owner so the capacity check + insert is one critical section.
    # The previous direct ETS path allowed concurrent requests to all observe one free slot and exceed the
    # documented hard MAX_SECRETS cap. Reveals remain direct and atomic via :ets.take/2.
    # A client-side call timeout could leave an inserted but unreachable "ghost" secret after the caller
    # gives up. The owner callback is bounded CPU/memory work; if it dies, linked calls fail immediately.
    with :ok <- validate_blob(blob),
         {:ok, ttl_seconds} <- validate_ttl(ttl_seconds) do
      timeout = Config.get(:state_call_timeout_ms)
      deadline = now_ms() + timeout
      safe_create_call({:create, blob, ttl_seconds, deadline}, timeout)
    end
  end

  @doc "Non-burning liveness check (used by the GET interstitial). `{:ok, :live}` or `:gone`."
  def peek(id) do
    with {:ok, id} <- normalize(id),
         [{^id, _blob, _hash, exp}] <- :ets.lookup(@table, id),
         true <- exp > now() do
      {:ok, :live}
    else
      _ ->
        expire_id(id)
        :gone
    end
  end

  @doc "Atomic single-consume. At most one caller receives `{:ok, blob}`, then all receive `:gone`."
  def reveal(id) do
    with {:ok, id} <- normalize(id) do
      deadline = now()

      case :ets.take(@table, id) do
        [{^id, blob, _hash, exp}] when exp > deadline ->
          bump(:claimed)
          {:ok, blob}

        [_expired] ->
          bump(:expired)
          :gone

        [] ->
          :gone
      end
    else
      _ -> :gone
    end
  end

  @doc "Revoke via the management token. `:ok` or `:error` (wrong, malformed, and absent are identical)."
  def burn(id, mgmt_b64) when is_binary(mgmt_b64) do
    with {:ok, id} <- normalize(id),
         {:ok, tok} <- Encoding.decode64url(mgmt_b64, 32),
         hash = :crypto.hash(:sha256, tok) do
      deadline = now()

      case :ets.select_delete(@table, [
             {{id, :_, hash, :"$1"}, [{:>, :"$1", deadline}], [true]}
           ]) do
        n when n > 0 ->
          bump(:burned)
          :ok

        0 ->
          # Do not disclose whether `id` is currently live, and do not imply that an absent id once
          # existed. Once its row is gone, the management-token hash is gone too, so it cannot be
          # authenticated as a formerly valid capability.
          expire_id(id, deadline)
          :error
      end
    else
      _ -> :error
    end
  end

  def burn(_, _), do: :error

  @doc """
  Operator takedown: delete a secret by id **without** the management token, for actioning an abuse /
  illegal-content notice (DSA Art. 16). Counts under its own `:purged` metric — NOT `:claimed` — so the
  public transparency stats are not skewed by a takedown. `:ok` if a row was removed, else `:gone`.
  """
  def purge(id) do
    with {:ok, id} <- normalize(id) do
      deadline = now()

      case :ets.take(@table, id) do
        [{^id, _blob, _hash, exp}] when exp > deadline ->
          bump(:purged)
          :ok

        [_expired] ->
          bump(:expired)
          :gone

        [] ->
          :gone
      end
    else
      _ -> :gone
    end
  end

  @doc "Resident row count, including rows awaiting expiry sweep."
  def count, do: :ets.info(@table, :size)

  @doc "Delete expired rows. Returns the number swept. Runs periodically; safe to call directly."
  def sweep do
    n = :ets.select_delete(@table, [{{:_, :_, :_, :"$1"}, [{:"=<", :"$1", now()}], [true]}])
    if n > 0, do: bump(:expired, n)
    n
  end

  @doc """
  Exact, live, capability-free aggregate metrics for the public stats page. Contains only counts/timestamps
  — nothing about any secret's contents, id, or any user. Counters reset on restart (in-memory).
  """
  def metrics do
    wall_now = System.system_time(:second)
    mono_now = System.monotonic_time(:second)
    started = :persistent_term.get({__MODULE__, :started_at}, wall_now)
    started_mono = :persistent_term.get({__MODULE__, :started_mono}, mono_now)

    %{
      # `resident` is precise: it includes an expired row until access or the periodic sweep removes it.
      # Keep `stored` as a compatibility alias, but never label it "live" in the UI/docs.
      resident: count(),
      stored: count(),
      capacity: Config.get(:max_secrets),
      created: ctr(:created),
      claimed: ctr(:claimed),
      burned: ctr(:burned),
      purged: ctr(:purged),
      expired: ctr(:expired),
      started_at: started,
      uptime_seconds: max(mono_now - started_mono, 0),
      create_busy_total: ctr(:create_busy),
      create_queue: ProcessMetrics.queue_length(__MODULE__),
      internal_errors_total: ctr(:internal_errors)
    }
  end

  @doc """
  Normalize a user-supplied id to its canonical form (upper-case, Crockford alias folding
  `I`/`L`→`1`, `O`→`0`, separators stripped) and validate the alphabet. `{:ok, id}` or `:error`.
  """
  def normalize(id) when is_binary(id) do
    # Reject non-ASCII BEFORE upcasing (L10): `String.upcase/1` is Unicode-aware and folds characters like
    # dotless-ı, the Kelvin sign, and fullwidth forms into the Crockford alphabet, which would let
    # different-looking inputs alias to the same id. An id only ever contains ASCII to begin with.
    if ascii?(id) do
      norm =
        id
        |> String.upcase()
        |> String.replace("-", "")
        |> String.replace(["I", "L"], "1")
        |> String.replace("O", "0")

      if byte_size(norm) == @id_length and valid?(norm), do: {:ok, norm}, else: :error
    else
      :error
    end
  end

  def normalize(_), do: :error

  # Internal test seam for expiry/capacity cases that must arrange otherwise unreachable table states.
  # Production callers use the Store interface and never inspect this table.
  @doc false
  def table, do: @table

  @doc "Bounded readiness probe for the state owner and its private ETS tables; never waits longer than 500 ms."
  def ready? do
    GenServer.call(__MODULE__, :ready, min(Config.get(:state_call_timeout_ms), 500)) == :ok
  catch
    :exit, _ -> false
  end

  @doc false
  def reset do
    :ets.delete_all_objects(@table)
    :ets.delete_all_objects(@metrics)
    :ok
  end

  @doc false
  def record_internal_error, do: bump(:internal_errors)

  ## ── GenServer (table owner + sweeper) ───────────────────────────────────

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    :ets.new(@metrics, [:named_table, :public, :set, write_concurrency: true])
    :persistent_term.put({__MODULE__, :started_at}, System.system_time(:second))
    :persistent_term.put({__MODULE__, :started_mono}, System.monotonic_time(:second))
    schedule()
    {:ok, %{}}
  end

  # A failed create callback would otherwise put the opaque blob from the GenServer message into OTP's
  # termination report (and therefore the container log). Redact both the current message and any sys log.
  @impl true
  def format_status(status), do: Map.merge(status, %{message: :redacted, log: []})

  @impl true
  def handle_call(:ready, _from, state) do
    ready? = Enum.all?([@table, @metrics], &(:ets.info(&1) != :undefined))
    {:reply, if(ready?, do: :ok, else: :not_ready), state}
  end

  def handle_call({:create, blob, ttl_seconds, deadline}, _from, state) do
    result =
      if now_ms() > deadline do
        bump(:create_busy)
        {:error, :busy}
      else
        do_create(blob, ttl_seconds)
      end

    {:reply, result, state}
  end

  defp do_create(blob, ttl_seconds) do
    if full?() do
      {:error, :full}
    else
      mgmt = :crypto.strong_rand_bytes(32)
      hash = :crypto.hash(:sha256, mgmt)
      expires_at = now() + clamp_ttl(ttl_seconds)
      id = insert_new(blob, hash, expires_at, 0)
      bump(:created)
      DailyStats.record_secret_created()
      {:ok, id, Base.url_encode64(mgmt, padding: false)}
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    case sweep() do
      0 -> :ok
      n -> Logger.info("Store swept #{n} expired secrets")
    end

    schedule()
    {:noreply, state}
  end

  ## ── helpers ─────────────────────────────────────────────────────────────

  defp insert_new(_blob, _hash, _exp, tries) when tries > 5,
    do: raise("Burnerpad.Store: id collision retries exhausted")

  defp insert_new(blob, hash, exp, tries) do
    id = gen_id()

    if :ets.insert_new(@table, {id, blob, hash, exp}),
      do: id,
      else: insert_new(blob, hash, exp, tries + 1)
  end

  # 26 Crockford-base32 characters = 130 random bits. 32 divides 256, so rem/2 is unbiased.
  defp gen_id do
    @id_length
    |> :crypto.strong_rand_bytes()
    |> :binary.bin_to_list()
    |> Enum.map(fn b -> Enum.at(@alphabet, rem(b, 32)) end)
    |> List.to_string()
  end

  defp clamp_ttl(nil), do: Config.get(:ttl_seconds)
  defp clamp_ttl(n), do: n |> max(60) |> min(Config.get(:ttl_seconds))

  defp validate_blob(blob) when is_binary(blob) and byte_size(blob) > 0 do
    if byte_size(blob) <= Config.get(:max_blob), do: :ok, else: {:error, :invalid_blob}
  end

  defp validate_blob(_), do: {:error, :invalid_blob}

  defp validate_ttl(nil), do: {:ok, nil}
  defp validate_ttl(ttl) when is_integer(ttl), do: {:ok, ttl}
  defp validate_ttl(_), do: {:error, :invalid_ttl}

  # Expiry cleanup is periodic. A full store may conservatively reject until the next sweep rather than
  # turning attacker-driven capacity errors into repeated full-table scans.
  defp full?, do: count() >= Config.get(:max_secrets)

  defp expire_id(id, deadline \\ now()) do
    with {:ok, id} <- normalize(id) do
      case :ets.select_delete(@table, [
             {{id, :_, :_, :"$1"}, [{:"=<", :"$1", deadline}], [true]}
           ]) do
        n when n > 0 -> bump(:expired, n)
        0 -> :ok
      end
    end
  end

  defp ascii?(s), do: :binary.bin_to_list(s) |> Enum.all?(&(&1 < 128))

  defp valid?(s), do: s |> String.to_charlist() |> Enum.all?(&MapSet.member?(@alphaset, &1))

  defp bump(key, n \\ 1), do: :ets.update_counter(@metrics, key, {2, n}, {key, 0})

  defp ctr(key),
    do:
      (case :ets.lookup(@metrics, key) do
         [{^key, v}] -> v
         _ -> 0
       end)

  # TTLs must not lengthen if the wall clock moves backwards.
  defp now, do: System.monotonic_time(:second)
  defp now_ms, do: System.monotonic_time(:millisecond)

  defp safe_create_call(message, timeout) do
    GenServer.call(__MODULE__, message, timeout)
  catch
    :exit, _ ->
      if :ets.whereis(@metrics) != :undefined, do: bump(:create_busy)
      {:error, :busy}
  end

  defp schedule, do: Process.send_after(self(), :sweep, @sweep_ms)
end
