# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Impulsa SLU

defmodule Burnerpad.StoreTest do
  use ExUnit.Case
  import Burnerpad.Support
  alias Burnerpad.Store

  setup do
    reset()
    :ok
  end

  test "create returns a 130-bit Crockford-base32 id and a base64url management token" do
    {:ok, id, mgmt} = Store.create(<<1, 2, 3, 4>>)
    assert id =~ ~r/^[0-9A-HJKMNPQRSTVWXYZ]{26}$/
    assert {:ok, _} = Base.url_decode64(mgmt, padding: false)
  end

  test "peek does not burn; reveal has at most one successful claimant" do
    {:ok, id, _} = Store.create(<<9, 9>>)
    assert {:ok, :live} = Store.peek(id)
    assert {:ok, :live} = Store.peek(id)
    assert {:ok, <<9, 9>>} = Store.reveal(id)
    assert :gone = Store.reveal(id)
    assert :gone = Store.peek(id)
  end

  test "concurrent reveal yields exactly one winner" do
    {:ok, id, _} = Store.create(:crypto.strong_rand_bytes(64))

    winners =
      1..100
      |> Task.async_stream(fn _ -> Store.reveal(id) end, max_concurrency: 50, ordered: false)
      |> Enum.count(fn {:ok, r} -> match?({:ok, _}, r) end)

    assert winners == 1
  end

  test "burn revokes with the right token and rejects a wrong one" do
    {:ok, id, mgmt} = Store.create(<<3>>)

    assert :error =
             Store.burn(id, Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false))

    assert {:ok, :live} = Store.peek(id)
    assert :ok = Store.burn(id, mgmt)
    assert :gone = Store.reveal(id)
    assert :error = Store.burn(id, mgmt)
  end

  test "purge deletes a secret by id without the management token (operator takedown)" do
    {:ok, id, _mgmt} = Store.create(<<1, 2>>)
    assert :ok = Store.purge(id)
    assert :gone = Store.reveal(id)
    assert :gone = Store.purge(id)
    assert Store.metrics().purged >= 1
  end

  test "ids are case-insensitive and tolerate dashes and Crockford aliases" do
    {:ok, id, _} = Store.create(<<7>>)
    # lower-case + a dash in the middle still resolves to the same secret
    mangled =
      id |> String.downcase() |> String.slice(0, 4) |> Kernel.<>("-" <> String.slice(id, 4, 22))

    assert {:ok, :live} = Store.peek(mangled)
  end

  test "rejects malformed ids without hitting a real secret" do
    assert :gone = Store.peek("not valid!")
    assert :gone = Store.reveal("////")
    assert :error = Store.burn("nope", "x")
  end

  test "is crypto-agnostic: any blob (incl. a suite-0x02 / PSK envelope) round-trips verbatim" do
    psk_blob = <<0x02>> <> :crypto.strong_rand_bytes(16 + 12 + 40)
    {:ok, id, _} = Store.create(psk_blob)
    assert {:ok, ^psk_blob} = Store.reveal(id)
  end

  test "enforces the MAX_SECRETS cap by rejecting new creates (never evicting)" do
    put_config(:max_secrets, 2)
    {:ok, _, _} = Store.create(<<1>>)
    {:ok, keep_id, _} = Store.create(<<2>>)
    assert {:error, :full} = Store.create(<<3>>)
    # the existing secrets are untouched
    assert {:ok, :live} = Store.peek(keep_id)
  end

  test "a full store rejects in O(1) until the periodic expiry sweep creates room" do
    put_config(:max_secrets, 1)

    :ets.insert(
      Store.table(),
      {String.duplicate("D", 26), <<1>>, <<>>, System.monotonic_time(:second) - 1}
    )

    assert {:error, :full} = Store.create(<<2>>)
    assert Store.sweep() == 1
    assert {:ok, fresh_id, _} = Store.create(<<2>>)
    assert {:ok, <<2>>} = Store.reveal(fresh_id)
    assert Store.metrics().expired >= 1
  end

  test "MAX_SECRETS remains a hard cap under concurrent creates" do
    put_config(:max_secrets, 1)

    results =
      1..50
      |> Task.async_stream(fn _ -> Store.create(<<1>>) end, max_concurrency: 50, ordered: false)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :full})) == 49
    assert Store.count() == 1
  end

  test "TTL is clamped to >= 60s (cannot create an already-expired secret via the API path)" do
    {:ok, id, _} = Store.create(<<1>>, -100)
    assert {:ok, :live} = Store.peek(id)
  end

  test "TTL is clamped to <= TTL_SECONDS (a huge client ttl cannot pin a secret in memory)" do
    put_config(:ttl_seconds, 120)
    before = System.monotonic_time(:second)
    {:ok, id, _} = Store.create(<<1>>, 10 * 365 * 24 * 3600)
    after_ = System.monotonic_time(:second)
    [{^id, _blob, _hash, expires_at}] = :ets.lookup(Store.table(), id)
    # pinned to the 120s ceiling, not ~10 years out
    assert expires_at >= before + 120
    assert expires_at <= after_ + 120
  end

  test "create enforces blob and TTL invariants below the HTTP router" do
    assert {:error, :invalid_blob} = Store.create(<<>>)
    assert {:error, :invalid_blob} = Store.create(:binary.copy(<<0>>, 65_537))
    assert {:error, :invalid_blob} = Store.create("not a binary" |> String.to_charlist())
    assert {:error, :invalid_ttl} = Store.create(<<1>>, "60")
    assert {:error, :invalid_ttl} = Store.create(<<1>>, 60.0)
    assert Store.count() == 0
  end

  test "management tokens require canonical unpadded base64url and exactly 32 bytes" do
    {:ok, id, mgmt} = Store.create(<<1>>)

    assert :error = Store.burn(id, mgmt <> "=")
    assert :error = Store.burn(id, "AQ")
    assert {:ok, :live} = Store.peek(id)
    assert :ok = Store.burn(id, mgmt)
  end

  test "a stalled owner times out safely and cannot later insert a ghost secret" do
    put_config(:state_call_timeout_ms, 100)
    :sys.suspend(Store)

    on_exit(fn ->
      if Process.alive?(Process.whereis(Store)) do
        try do
          :sys.resume(Store)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    assert {:error, :busy} = Store.create(<<1>>)
    :sys.resume(Store)
    :sys.get_state(Store)
    assert Store.count() == 0
  end

  test "expired rows are not revealable and are swept" do
    # Use a normalize-STABLE id (no I/L/O). "EXPIRED01" contained an "I", which normalize rewrites to "1",
    # so reveal() would look up a DIFFERENT id and return :gone regardless of expiry — a vacuous test.
    id = String.duplicate("A", 26)

    # Positive control: with the SAME id and a FUTURE expiry, the row IS revealable (proves the lookup hits).
    :ets.insert(Store.table(), {id, <<1>>, <<>>, System.monotonic_time(:second) + 100})
    assert {:ok, <<1>>} = Store.reveal(id)

    # Now the SAME id with a PAST expiry is :gone specifically *because it expired*.
    expired_before = Store.metrics().expired
    :ets.insert(Store.table(), {id, <<1>>, <<>>, System.monotonic_time(:second) - 10})
    assert :gone = Store.reveal(id)
    assert Store.metrics().expired == expired_before + 1

    :ets.insert(
      Store.table(),
      {String.duplicate("B", 26), <<1>>, <<>>, System.monotonic_time(:second) - 10}
    )

    assert Store.sweep() >= 1
    assert Store.count() == 0
  end

  test "generated ids are unique across many creates" do
    ids =
      for _ <- 1..500,
          do:
            (fn ->
               {:ok, id, _} = Store.create(<<0>>)
               id
             end).()

    assert length(Enum.uniq(ids)) == 500
  end

  test "metrics count terminal states and name resident rows honestly" do
    {:ok, id1, _} = Store.create(<<1>>)
    {:ok, id2, mgmt2} = Store.create(<<2>>)
    {:ok, <<1>>} = Store.reveal(id1)
    :ok = Store.burn(id2, mgmt2)

    m = Store.metrics()
    assert m.created == 2
    assert m.revealed == 1
    assert m.burned == 1
    assert m.stored == 0
    assert m.resident == 0
    assert m.capacity == Burnerpad.Config.get(:max_secrets)
    assert is_integer(m.uptime_seconds) and m.uptime_seconds >= 0
  end

  test "expired rows are never counted as burned or purged" do
    id = String.duplicate("C", 26)
    token = :crypto.strong_rand_bytes(32)
    hash = :crypto.hash(:sha256, token)
    expired_at = System.monotonic_time(:second) - 1
    :ets.insert(Store.table(), {id, <<1>>, hash, expired_at})

    assert :error = Store.burn(id, Base.url_encode64(token, padding: false))
    assert Store.metrics().expired == 1
    assert Store.metrics().burned == 0

    :ets.insert(Store.table(), {id, <<1>>, hash, expired_at})
    assert :gone = Store.purge(id)
    assert Store.metrics().expired == 2
    assert Store.metrics().purged == 0
  end

  test "sweep increments the expired metric" do
    :ets.insert(
      Store.table(),
      {String.duplicate("C", 26), <<1>>, <<>>, System.monotonic_time(:second) - 5}
    )

    assert Store.sweep() >= 1
    assert Store.metrics().expired >= 1
  end

  test "normalize/1 rejects non-ASCII ids so Unicode can't alias into a real id (L10)" do
    # dotless-ı upcases to "I" (→ folds to "1"); the Kelvin sign K upcases to "K" — both would alias
    assert Burnerpad.Store.normalize("\u0131" <> String.duplicate("A", 25)) == :error
    assert Burnerpad.Store.normalize("\u212A" <> String.duplicate("A", 25)) == :error
    # a normal ASCII id still works
    id = "K7P2Q9RX" <> String.duplicate("A", 18)
    assert Burnerpad.Store.normalize(id) == {:ok, id}
  end

  test "GenServer status never exposes a create blob through OTP diagnostics" do
    marker = "STATUS-SECRET-DO-NOT-LOG"
    status = %{state: %{}, message: {:create, marker, nil}, reason: :forced, log: [marker]}
    refute inspect(Store.format_status(status)) =~ marker
  end
end
