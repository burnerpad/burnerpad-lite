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

  test "create returns an 8-char Crockford-base32 id and a base64url management token" do
    {:ok, id, mgmt} = Store.create(<<1, 2, 3, 4>>)
    assert id =~ ~r/^[0-9A-HJKMNP-TV-Z]{8}$/
    assert {:ok, _} = Base.url_decode64(mgmt, padding: false)
  end

  test "peek does not burn; reveal burns exactly once" do
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
  end

  test "ids are case-insensitive and tolerate dashes and Crockford aliases" do
    {:ok, id, _} = Store.create(<<7>>)
    # lower-case + a dash in the middle still resolves to the same secret
    mangled =
      id |> String.downcase() |> String.slice(0, 4) |> Kernel.<>("-" <> String.slice(id, 4, 4))

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

  test "TTL is clamped to >= 60s (cannot create an already-expired secret via the API path)" do
    {:ok, id, _} = Store.create(<<1>>, -100)
    assert {:ok, :live} = Store.peek(id)
  end

  test "TTL is clamped to <= TTL_SECONDS (a huge client ttl cannot pin a secret in memory)" do
    put_config(:ttl_seconds, 120)
    before = System.system_time(:second)
    {:ok, id, _} = Store.create(<<1>>, 10 * 365 * 24 * 3600)
    after_ = System.system_time(:second)
    [{^id, _blob, _hash, expires_at}] = :ets.lookup(Store.table(), id)
    # pinned to the 120s ceiling, not ~10 years out
    assert expires_at >= before + 120
    assert expires_at <= after_ + 120
  end

  test "expired rows are not revealable and are swept" do
    # insert an already-expired row directly (the API clamps TTL, so we bypass it for the test)
    :ets.insert(Store.table(), {"EXPIRED01", <<1>>, <<>>, System.system_time(:second) - 10})
    assert :gone = Store.reveal("EXPIRED01")

    :ets.insert(Store.table(), {"EXPIRED02", <<1>>, <<>>, System.system_time(:second) - 10})
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

  test "metrics count created / revealed / burned and live stored" do
    {:ok, id1, _} = Store.create(<<1>>)
    {:ok, id2, mgmt2} = Store.create(<<2>>)
    {:ok, <<1>>} = Store.reveal(id1)
    :ok = Store.burn(id2, mgmt2)

    m = Store.metrics()
    assert m.created == 2
    assert m.revealed == 1
    assert m.burned == 1
    assert m.stored == 0
    assert m.capacity == Burnerpad.Config.get(:max_secrets)
    assert is_integer(m.uptime_seconds) and m.uptime_seconds >= 0
  end

  test "sweep increments the expired metric" do
    :ets.insert(Store.table(), {"EXP00001", <<1>>, <<>>, System.system_time(:second) - 5})
    assert Store.sweep() >= 1
    assert Store.metrics().expired >= 1
  end
end
