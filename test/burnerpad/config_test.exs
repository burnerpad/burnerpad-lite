# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Impulsa SLU

defmodule Burnerpad.ConfigTest do
  use ExUnit.Case, async: false
  alias Burnerpad.Config

  setup do
    # restore anything load!/0 might change during a test
    app_keys = [
      :port,
      :max_secrets,
      :ttl_seconds,
      :rate_limit,
      :global_ceiling,
      :global_create_ceiling,
      :ban_threshold,
      :per_ip_budget,
      :per_ip_row_budget,
      :state_call_timeout_ms,
      :real_ip_header,
      :trusted_proxies,
      :operator_name,
      :abuse_email,
      :jurisdiction,
      :security_email,
      :security_policy_url,
      :release_revision,
      :image_digest
    ]

    env_keys = [
      "PORT",
      "MAX_SECRETS",
      "TTL_SECONDS",
      "RATE_LIMIT",
      "GLOBAL_CEILING",
      "GLOBAL_CREATE_CEILING",
      "BAN_THRESHOLD",
      "PER_IP_BUDGET",
      "PER_IP_ROW_BUDGET",
      "STATE_CALL_TIMEOUT_MS",
      "REAL_IP_HEADER",
      "TRUSTED_PROXIES",
      "OPERATOR_NAME",
      "ABUSE_EMAIL",
      "JURISDICTION",
      "SECURITY_EMAIL",
      "SECURITY_POLICY_URL",
      "BURNERPAD_REVISION",
      "BURNERPAD_IMAGE_DIGEST"
    ]

    saved_app =
      for k <- app_keys,
          do: {k, Application.get_env(:burnerpad, k)}

    saved_env = for key <- env_keys, do: {key, System.get_env(key)}

    on_exit(fn ->
      for {k, v} <- saved_app do
        if v,
          do: Application.put_env(:burnerpad, k, v),
          else: Application.delete_env(:burnerpad, k)
      end

      for {key, value} <- saved_env do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end
    end)

    :ok
  end

  test "an out-of-range numeric env var fails the boot (M5)" do
    System.put_env("RATE_LIMIT", "0")
    assert_raise RuntimeError, ~r/RATE_LIMIT.*expected an integer/, fn -> Config.load!() end
  end

  test "a non-integer numeric env var fails the boot (M5)" do
    System.put_env("PORT", "not-a-port")
    assert_raise RuntimeError, ~r/PORT.*expected an integer/, fn -> Config.load!() end
  end

  test "a valid numeric env var is accepted" do
    System.put_env("RATE_LIMIT", "500")
    assert Config.load!() == :ok
    assert Config.get(:rate_limit) == 500
  end

  test "secret retention cannot be configured beyond 24 hours" do
    System.put_env("TTL_SECONDS", Integer.to_string(7 * 86_400))
    assert_raise RuntimeError, ~r/TTL_SECONDS.*60\.\.86400/, fn -> Config.load!() end
  end

  test "proxy CIDRs are parsed once at boot and malformed entries fail closed" do
    System.put_env("TRUSTED_PROXIES", "10.0.0.0/8, 2001:db8::/32")
    assert Config.load!() == :ok

    assert [{{10, 0, 0, 0}, 8}, {{0x2001, 0xDB8, 0, 0, 0, 0, 0, 0}, 32}] =
             Config.trusted_proxies()

    System.put_env("TRUSTED_PROXIES", "10.0.0.0/33")
    assert_raise RuntimeError, ~r/Invalid TRUSTED_PROXIES/, fn -> Config.load!() end
  end

  test "an invalid real-IP header name fails at boot" do
    System.put_env("REAL_IP_HEADER", "bad header")
    assert_raise RuntimeError, ~r/Invalid REAL_IP_HEADER/, fn -> Config.load!() end
  end

  test "the per-source budget cannot exceed the whole store" do
    System.put_env("MAX_SECRETS", "1")
    System.put_env("PER_IP_BUDGET", "65537")
    assert_raise RuntimeError, ~r/PER_IP_BUDGET.*cannot exceed/, fn -> Config.load!() end
  end

  test "the per-source byte budget must admit one maximum-size secret" do
    System.put_env("PER_IP_BUDGET", "65535")

    assert_raise RuntimeError, ~r/PER_IP_BUDGET.*at least.*65536/, fn -> Config.load!() end
  end

  test "the per-source byte budget accepts the maximum blob size" do
    System.put_env("PER_IP_BUDGET", "65536")

    assert Config.load!() == :ok
    assert Config.per_ip_budget() == 65_536
  end

  test "the per-source byte budget accepts a larger value within the store capacity" do
    System.put_env("PER_IP_BUDGET", "65537")

    assert Config.load!() == :ok
    assert Config.per_ip_budget() == 65_537
  end

  test "the per-source row budget cannot exceed the whole store" do
    System.put_env("MAX_SECRETS", "10")
    System.put_env("PER_IP_ROW_BUDGET", "11")

    assert_raise RuntimeError, ~r/PER_IP_ROW_BUDGET.*cannot exceed/, fn -> Config.load!() end
  end

  test "default per-source budgets admit at least one maximum-size secret" do
    Application.put_env(:burnerpad, :max_secrets, 1)
    Application.delete_env(:burnerpad, :per_ip_budget)
    Application.delete_env(:burnerpad, :per_ip_row_budget)

    assert Config.per_ip_budget() == Config.get(:max_blob)
    assert Config.per_ip_row_budget() == 1
  end

  test "unsafe store capacities fail instead of allowing an accidental multi-terabyte bound" do
    System.put_env("MAX_SECRETS", "100001")
    assert_raise RuntimeError, ~r/MAX_SECRETS.*1\.\.100000/, fn -> Config.load!() end
  end

  test "abuse thresholds are ordered so rate limiting and banning remain reachable" do
    System.put_env("RATE_LIMIT", "600")
    System.put_env("BAN_THRESHOLD", "600")

    assert_raise RuntimeError, ~r/RATE_LIMIT < BAN_THRESHOLD < GLOBAL_CEILING/, fn ->
      Config.load!()
    end

    System.put_env("RATE_LIMIT", "240")
    System.put_env("BAN_THRESHOLD", "600")
    System.put_env("GLOBAL_CEILING", "599")

    assert_raise RuntimeError, ~r/RATE_LIMIT < BAN_THRESHOLD < GLOBAL_CEILING/, fn ->
      Config.load!()
    end

    System.put_env("BAN_THRESHOLD", "600")
    System.put_env("GLOBAL_CEILING", "600")

    assert_raise RuntimeError, ~r/RATE_LIMIT < BAN_THRESHOLD < GLOBAL_CEILING/, fn ->
      Config.load!()
    end
  end

  test "global valid-create admission is a distinct ceiling below the all-request ceiling" do
    System.put_env("GLOBAL_CREATE_CEILING", "30000")

    assert_raise RuntimeError, ~r/GLOBAL_CREATE_CEILING < GLOBAL_CEILING/, fn ->
      Config.load!()
    end
  end

  test "operator identity is present (dev placeholder in test, required in prod build — M7)" do
    assert Config.load!() == :ok
    assert is_binary(Config.operator_name())
    assert Config.operator_name() != ""
  end

  test "version combines the application version with a validated release revision" do
    System.put_env("BURNERPAD_REVISION", "abcdef1")
    assert Config.load!() == :ok
    assert Config.version() == "1.0.0+abcdef1"
  end

  test "an unsafe release revision fails the boot instead of reaching HTML" do
    System.put_env("BURNERPAD_REVISION", "<script>")
    assert_raise RuntimeError, ~r/Invalid BURNERPAD_REVISION/, fn -> Config.load!() end
  end

  test "production provenance requires a full lowercase revision" do
    for invalid <- ["dev", "unknown", "abcdef1", String.duplicate("A", 40)] do
      assert_raise RuntimeError, ~r/production requires a full 40-character/, fn ->
        Config.validate_release_revision!(invalid, :prod)
      end
    end

    assert :ok == Config.validate_release_revision!(String.duplicate("a", 40), :prod)
  end

  test "operator text is nonblank and contact values are validated" do
    System.put_env("OPERATOR_NAME", "   ")
    assert_raise RuntimeError, ~r/Invalid OPERATOR_NAME/, fn -> Config.load!() end

    System.put_env("OPERATOR_NAME", "Test operator")
    System.put_env("ABUSE_EMAIL", "not-an-email")
    assert_raise RuntimeError, ~r/Invalid ABUSE_EMAIL/, fn -> Config.load!() end

    System.put_env("ABUSE_EMAIL", "abuse@example.com")
    System.put_env("SECURITY_POLICY_URL", "http://example.com/policy")
    assert_raise RuntimeError, ~r/Invalid SECURITY_POLICY_URL/, fn -> Config.load!() end
  end

  test "security policy URL rejects embedded ASCII controls and whitespace" do
    for forbidden <- ["\n", "\r", "\t", " ", <<31>>, <<127>>] do
      System.put_env("SECURITY_POLICY_URL", "https://example.com/policy#{forbidden}injected")

      assert_raise RuntimeError, ~r/Invalid SECURITY_POLICY_URL/, fn ->
        Config.load!()
      end
    end
  end
end
