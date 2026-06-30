# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Impulsa SLU

defmodule Burnerpad.Store do
  @moduledoc """
  In-memory, burn-on-read secret store. The **only** module that touches the secrets ETS table.

  A row is `{id, blob, mgmt_token_hash, expires_at}`:
    * `blob` — the opaque ciphertext envelope (never parsed here; the server is crypto-agnostic)
    * `mgmt_token_hash` — SHA-256 of a one-time management token (the raw token is never stored)
    * `expires_at` — absolute unix seconds

  Burn-on-read is `:ets.take/2` (atomic remove+return) → exactly-once under concurrency.
  Nothing is written to disk; everything is lost on restart by design.
  """
  use GenServer
  require Logger
  alias Burnerpad.Config

  @table :bp_secrets
  @metrics :bp_metrics
  @sweep_ms 60_000
  @alphabet ~c"0123456789ABCDEFGHJKMNPQRSTVWXYZ"
  @alphaset MapSet.new(@alphabet)

  ## ── Public API ──────────────────────────────────────────────────────────

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Store an opaque ciphertext blob. Returns `{:ok, id, mgmt_token_b64}` or `{:error, :full}`."
  def create(blob, ttl_seconds \\ nil) when is_binary(blob) do
    if count() >= Config.get(:max_secrets) do
      {:error, :full}
    else
      mgmt = :crypto.strong_rand_bytes(32)
      hash = :crypto.hash(:sha256, mgmt)
      expires_at = now() + clamp_ttl(ttl_seconds)
      id = insert_new(blob, hash, expires_at, 0)
      bump(:created)
      {:ok, id, Base.url_encode64(mgmt, padding: false)}
    end
  end

  @doc "Non-burning liveness check (used by the GET interstitial). `{:ok, :live}` or `:gone`."
  def peek(id) do
    with {:ok, id} <- normalize(id),
         [{^id, _blob, _hash, exp}] <- :ets.lookup(@table, id),
         true <- exp > now() do
      {:ok, :live}
    else
      _ -> :gone
    end
  end

  @doc "Atomic single-consume. `{:ok, blob}` exactly once, then `:gone`."
  def reveal(id) do
    with {:ok, id} <- normalize(id),
         [{^id, blob, _hash, exp}] <- :ets.take(@table, id),
         true <- exp > now() do
      bump(:revealed)
      {:ok, blob}
    else
      _ -> :gone
    end
  end

  @doc "Revoke via the management token. `:ok` or `:error`."
  def burn(id, mgmt_b64) when is_binary(mgmt_b64) do
    with {:ok, id} <- normalize(id),
         {:ok, tok} <- Base.url_decode64(mgmt_b64, padding: false),
         hash = :crypto.hash(:sha256, tok),
         n when n > 0 <- :ets.select_delete(@table, [{{id, :_, hash, :_}, [], [true]}]) do
      bump(:burned)
      :ok
    else
      _ -> :error
    end
  end

  def burn(_, _), do: :error

  @doc """
  Operator takedown: delete a secret by id **without** the management token, for actioning an abuse /
  illegal-content notice (DSA Art. 16). Counts under its own `:purged` metric — NOT `:revealed` — so the
  public transparency stats are not skewed by a takedown. `:ok` if a row was removed, else `:gone`.
  """
  def purge(id) do
    with {:ok, id} <- normalize(id),
         [_row] <- :ets.take(@table, id) do
      bump(:purged)
      :ok
    else
      _ -> :gone
    end
  end

  @doc "Live secret count."
  def count, do: :ets.info(@table, :size)

  @doc "Delete expired rows. Returns the number swept. Runs periodically; safe to call directly."
  def sweep do
    n = :ets.select_delete(@table, [{{:_, :_, :_, :"$1"}, [{:"=<", :"$1", now()}], [true]}])
    if n > 0, do: bump(:expired, n)
    n
  end

  @doc """
  Aggregate, privacy-safe metrics for the public stats page. Contains only counts/timestamps — nothing
  about any secret's contents, id, or any user. Counters reset on restart (in-memory).
  """
  def metrics do
    now = System.system_time(:second)
    started = :persistent_term.get({__MODULE__, :started_at}, now)

    %{
      stored: count(),
      capacity: Config.get(:max_secrets),
      created: ctr(:created),
      revealed: ctr(:revealed),
      burned: ctr(:burned),
      purged: ctr(:purged),
      expired: ctr(:expired),
      started_at: started,
      uptime_seconds: max(now - started, 0)
    }
  end

  @doc """
  Normalize a user-supplied id to its canonical form (upper-case, Crockford alias folding
  `I`/`L`→`1`, `O`→`0`, separators stripped) and validate the alphabet. `{:ok, id}` or `:error`.
  """
  def normalize(id) when is_binary(id) do
    norm =
      id
      |> String.upcase()
      |> String.replace("-", "")
      |> String.replace(["I", "L"], "1")
      |> String.replace("O", "0")

    if norm != "" and byte_size(norm) <= 64 and valid?(norm), do: {:ok, norm}, else: :error
  end

  def normalize(_), do: :error

  @doc false
  def table, do: @table

  @doc false
  def reset do
    :ets.delete_all_objects(@table)
    :ets.delete_all_objects(@metrics)
    :ok
  end

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
    schedule()
    {:ok, %{}}
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

  # Crockford base32, `id_length` chars. 32 divides 256, so `rem(byte, 32)` is unbiased.
  defp gen_id do
    Config.get(:id_length)
    |> :crypto.strong_rand_bytes()
    |> :binary.bin_to_list()
    |> Enum.map(fn b -> Enum.at(@alphabet, rem(b, 32)) end)
    |> List.to_string()
  end

  defp clamp_ttl(nil), do: Config.get(:ttl_seconds)
  defp clamp_ttl(n) when is_integer(n), do: n |> max(60) |> min(Config.get(:ttl_seconds))
  defp clamp_ttl(_), do: Config.get(:ttl_seconds)

  defp valid?(s), do: s |> String.to_charlist() |> Enum.all?(&MapSet.member?(@alphaset, &1))

  defp bump(key, n \\ 1), do: :ets.update_counter(@metrics, key, {2, n}, {key, 0})

  defp ctr(key),
    do:
      (case :ets.lookup(@metrics, key) do
         [{^key, v}] -> v
         _ -> 0
       end)

  defp now, do: System.system_time(:second)
  defp schedule, do: Process.send_after(self(), :sweep, @sweep_ms)
end
