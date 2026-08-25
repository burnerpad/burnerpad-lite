# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Impulsa SLU

defmodule BurnerpadWeb.CryptoAssetsTest do
  use ExUnit.Case, async: false

  alias BurnerpadWeb.CryptoAssets

  test "the committed registry matches every served asset" do
    for {relative_path, expected_hash} <- CryptoAssets.expected() do
      assert CryptoAssets.compute(relative_path) == expected_hash
    end
  end

  test "the registry-driven generator is idempotent" do
    source_path = "lib/burnerpad_web/crypto_assets.ex"
    before = File.read!(source_path)
    on_exit(fn -> File.write!(source_path, before) end)

    Mix.Tasks.Bp.Sri.run([])

    assert File.read!(source_path) == before
  end
end
