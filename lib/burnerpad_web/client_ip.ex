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

  @doc "Return the `/32` (IPv4) or `/64` (IPv6) key string for the client."
  def get(conn), do: conn |> resolve() |> key()

  defp resolve(conn) do
    if trusted?(conn.remote_ip) do
      case get_req_header(conn, Config.real_ip_header()) do
        [v | _] when is_binary(v) and v != "" ->
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
  defp key({a, b, c, d, _, _, _, _}), do: "#{hx(a)}:#{hx(b)}:#{hx(c)}:#{hx(d)}::/64"
  defp key(_), do: "unknown"

  defp hx(n), do: n |> Integer.to_string(16) |> String.downcase()

  ## ── trusted-proxy CIDR matching (parsed CIDRs memoized per config value) ──

  defp trusted?(ip) do
    Enum.any?(cidrs(), fn {net, prefix, bits} -> in_cidr?(ip, net, prefix, bits) end)
  end

  defp cidrs do
    raw = Config.trusted_proxies()

    case :persistent_term.get({__MODULE__, raw}, nil) do
      nil ->
        parsed = parse(raw)
        :persistent_term.put({__MODULE__, raw}, parsed)
        parsed

      parsed ->
        parsed
    end
  end

  defp parse(raw) do
    raw
    |> String.split(",", trim: true)
    |> Enum.flat_map(&parse_cidr/1)
  end

  defp parse_cidr(str) do
    with [addr, pre] <- String.split(String.trim(str), "/"),
         {:ok, ip} <- :inet.parse_address(String.to_charlist(addr)),
         {prefix, ""} <- Integer.parse(pre) do
      [{to_int(ip), prefix, bits(ip)}]
    else
      _ -> []
    end
  end

  defp bits(ip) when tuple_size(ip) == 4, do: 32
  defp bits(ip) when tuple_size(ip) == 8, do: 128

  defp in_cidr?(ip, net, prefix, 32) when tuple_size(ip) == 4,
    do: masked_eq(to_int(ip), net, prefix, 32)

  defp in_cidr?(ip, net, prefix, 128) when tuple_size(ip) == 8,
    do: masked_eq(to_int(ip), net, prefix, 128)

  defp in_cidr?(_, _, _, _), do: false

  defp masked_eq(a, b, prefix, total) do
    mask = ((1 <<< prefix) - 1) <<< (total - prefix)
    (a &&& mask) == (b &&& mask)
  end

  defp to_int(tuple) do
    unit = if tuple_size(tuple) == 4, do: 8, else: 16
    tuple |> Tuple.to_list() |> Enum.reduce(0, fn x, acc -> acc <<< unit ||| x end)
  end
end
