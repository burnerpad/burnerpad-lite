# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Impulsa SLU

defmodule BurnerpadWeb.ClientIP do
  @moduledoc """
  Resolve the abuse key for a request: an **IPv4 `/32`** or **IPv6 `/64`** prefix string.

  The real client IP comes from `REAL_IP_HEADER` (default `cf-connecting-ip`) **only when the socket
  peer is a configured trusted proxy** (`TRUSTED_PROXIES`); otherwise the raw socket peer is used. This
  prevents an attacker reaching the origin directly from spoofing the header to forge bans or evade them.
  With no proxy (`TRUSTED_PROXIES=""`, the default) the socket peer is always used — no spoofable header.

  IPv6 is aggregated to `/64` because a single host typically owns a whole `/64`; per-address keying
  would let it rotate freely to evade limits/bans.
  """
  import Bitwise
  import Plug.Conn
  alias Burnerpad.Config

  @doc "Return the transient `/32` (IPv4) or `/64` (IPv6) source key; Abuse HMACs it before storage."
  def get(conn), do: conn |> resolve() |> key()

  @doc """
  Compare the resolved source key with a caller-supplied IP without returning either normalized value.

  This is the narrow interface used by the public edge contract: `:match` proves that the deployed
  trusted-proxy path resolved the same source Cloudflare observed, while `:mismatch` reveals no address.
  """
  @spec compare(Plug.Conn.t(), term()) :: :match | :mismatch | :invalid
  def compare(conn, expected) when is_binary(expected) and byte_size(expected) <= 64 do
    if String.valid?(expected) do
      case :inet.parse_address(String.to_charlist(expected)) do
        {:ok, ip} -> if get(conn) == key(ip), do: :match, else: :mismatch
        {:error, _reason} -> :invalid
      end
    else
      :invalid
    end
  end

  def compare(_conn, _expected), do: :invalid

  defp resolve(conn) do
    if trusted?(conn.remote_ip) do
      case get_req_header(conn, Config.real_ip_header()) do
        [v] when is_binary(v) and v != "" ->
          case :inet.parse_address(String.to_charlist(String.trim(v))) do
            {:ok, ip} -> ip
            _ -> conn.remote_ip
          end

        _ ->
          conn.remote_ip
      end
    else
      conn.remote_ip
    end
  end

  # IPv4 -> /32 (the full address). IPv6 -> /64 (first four groups).
  defp key({_, _, _, _} = ip), do: ip |> :inet.ntoa() |> to_string()

  # Treat IPv4-mapped IPv6 as its actual IPv4 /32; otherwise every mapped address would collapse under
  # the same `0:0:0:0::/64` rate-limit key.
  defp key({0, 0, 0, 0, 0, 0xFFFF, a, b}),
    do: "#{a >>> 8}.#{a &&& 255}.#{b >>> 8}.#{b &&& 255}"

  defp key({a, b, c, d, _, _, _, _}), do: "#{hx(a)}:#{hx(b)}:#{hx(c)}:#{hx(d)}::/64"
  defp key(_), do: "unknown"

  defp hx(n), do: n |> Integer.to_string(16) |> String.downcase()

  defp trusted?(ip) do
    Enum.any?(Config.trusted_proxies(), fn {net, prefix} -> in_cidr?(ip, net, prefix) end)
  end

  defp bits(ip) when tuple_size(ip) == 4, do: 32
  defp bits(ip) when tuple_size(ip) == 8, do: 128

  defp in_cidr?(ip, net, prefix) when tuple_size(ip) == tuple_size(net),
    do: masked_eq(to_int(ip), to_int(net), prefix, bits(net))

  defp in_cidr?(_, _, _), do: false

  defp masked_eq(a, b, prefix, total) do
    mask = ((1 <<< prefix) - 1) <<< (total - prefix)
    (a &&& mask) == (b &&& mask)
  end

  defp to_int(tuple) do
    unit = if tuple_size(tuple) == 4, do: 8, else: 16
    tuple |> Tuple.to_list() |> Enum.reduce(0, fn x, acc -> acc <<< unit ||| x end)
  end
end
