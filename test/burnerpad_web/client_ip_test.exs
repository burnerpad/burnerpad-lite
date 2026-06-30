# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Impulsa SLU

defmodule BurnerpadWeb.ClientIPTest do
  @moduledoc """
  The abuse key resolved for a request is a security control: it decides whose rate-limit/ban counter a
  request counts against. The one rule that MUST hold is that an attacker reaching the origin directly
  cannot set `REAL_IP_HEADER` to (a) forge a ban on a victim's IP or (b) evade their own limit. The header
  is honored ONLY when the socket peer is a configured trusted proxy. These tests exercise that rule
  through the module's interface — `ClientIP.get/1` — exactly as the abuse plug calls it.
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn
  import Burnerpad.Support, only: [put_config: 2]
  alias Burnerpad.Config
  alias BurnerpadWeb.ClientIP

  # Build a conn with a chosen socket peer and (optionally) a forwarded-IP header, then resolve the key.
  defp key(remote_ip, header \\ nil) do
    conn = %{conn(:get, "/") | remote_ip: remote_ip}
    conn = if header, do: put_req_header(conn, Config.real_ip_header(), header), else: conn
    ClientIP.get(conn)
  end

  describe "with no trusted proxy (TRUSTED_PROXIES empty — the default, most trustworthy setup)" do
    setup do
      put_config(:trusted_proxies, "")
      :ok
    end

    test "uses the socket peer and IGNORES a forwarded-IP header" do
      assert key({203, 0, 113, 7}, "9.9.9.9") == "203.0.113.7"
    end

    test "a direct attacker cannot spoof the header to forge a ban on a victim" do
      # Attacker at 198.51.100.5 sets the header to the victim 1.1.1.1 — the header is ignored, so the
      # request counts against the attacker's own IP, never the victim's.
      assert key({198, 51, 100, 5}, "1.1.1.1") == "198.51.100.5"
    end

    test "nor can an attacker spoof the header to dodge their own limit" do
      assert key({198, 51, 100, 5}, "203.0.113.7") == "198.51.100.5"
    end

    test "keys IPv4 to the full /32 address" do
      assert key({192, 168, 1, 50}) == "192.168.1.50"
    end

    test "keys IPv6 to the /64 prefix, so a host cannot rotate within its /64 to evade" do
      lo = {0x2001, 0x0DB8, 0x1, 0x2, 0x3, 0x4, 0x5, 0x6}
      hi = {0x2001, 0x0DB8, 0x1, 0x2, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF}
      assert key(lo) == "2001:db8:1:2::/64"
      assert key(lo) == key(hi)
    end
  end

  describe "behind a configured trusted proxy (TRUSTED_PROXIES=\"10.0.0.0/8\")" do
    setup do
      put_config(:trusted_proxies, "10.0.0.0/8")
      :ok
    end

    test "honors the forwarded-IP header when the socket peer is the trusted proxy" do
      assert key({10, 1, 2, 3}, "203.0.113.7") == "203.0.113.7"
    end

    test "STILL ignores the header from a peer outside the trusted range" do
      # Even with a proxy configured, only the proxy itself is trusted — a direct hit is keyed by its peer.
      assert key({8, 8, 8, 8}, "203.0.113.7") == "8.8.8.8"
    end

    test "falls back to the peer when the header is absent" do
      assert key({10, 1, 2, 3}) == "10.1.2.3"
    end

    test "falls back to the peer when the header is not a parseable IP" do
      assert key({10, 1, 2, 3}, "not-an-ip") == "10.1.2.3"
    end

    test "a forwarded IPv6 client is keyed to its /64" do
      assert key({10, 0, 0, 1}, "2001:db8:1:2:3:4:5:6") == "2001:db8:1:2::/64"
    end
  end
end
