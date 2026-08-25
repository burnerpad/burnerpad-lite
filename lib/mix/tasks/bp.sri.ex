# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Impulsa SLU

defmodule Mix.Tasks.Bp.Sri do
  @shortdoc "Regenerate the committed SRI hashes (CryptoAssets.@expected) from the files on disk"
  @moduledoc "Run after a legitimate change to a pinned crypto asset, then commit `crypto_assets.ex`."
  use Mix.Task
  alias BurnerpadWeb.CryptoAssets

  @source "lib/burnerpad_web/crypto_assets.ex"

  @impl true
  def run(_args) do
    hashes =
      CryptoAssets.expected()
      |> Map.keys()
      |> Enum.sort()
      |> Map.new(fn rel ->
        {rel, CryptoAssets.compute(rel)}
      end)

    rows =
      hashes
      |> Enum.sort_by(fn {rel, _hash} -> rel end)
      |> Enum.map_join(",\n", fn {rel, hash} ->
        "    #{inspect(rel)} =>\n      #{inspect(hash)}"
      end)

    block = "  @expected %{\n" <> rows <> "\n  }"

    source = File.read!(@source)
    expected_block = ~r/  @expected %\{.*?\n  \}/s

    if !Regex.match?(expected_block, source),
      do: Mix.raise("could not locate @expected in #{@source}")

    new = Regex.replace(expected_block, source, block, global: false)

    result =
      if new == source do
        "Verified"
      else
        File.write!(@source, new)
        "Updated"
      end

    Mix.shell().info("#{result} @expected in #{@source}:")
    for {rel, hash} <- Enum.sort(hashes), do: Mix.shell().info("  #{rel} -> #{hash}")
  end
end
