defmodule Burnerpad.MixProject do
  use Mix.Project

  def project do
    [
      app: :burnerpad,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  # `mix setup` fetches the crypto submodule then deps. `mix test.crypto` runs the vendored bundle's own
  # conformance test under Node (so the pinned bytes are verified in place); `mix test.core` unit-tests the
  # DOM-free `Core` of the page driver (crypto-app.js) under Node. Both require Node ≥ 20.
  defp aliases do
    [
      setup: ["cmd git submodule update --init --recursive", "deps.get"],
      "test.crypto": ["cmd node priv/static/vendor/crypto-js/test/conformance.mjs"],
      "test.core": ["cmd node --test test/crypto/core_test.cjs"]
    ]
  end

  # The only browser JS is the audited @burnerpad/crypto bundle, vendored as a git submodule under
  # priv/static/vendor/crypto-js (github.com/burnerpad/crypto-js). Run `mix setup` after cloning to fetch it.
  # The server itself depends on Bandit and the Elixir/Erlang standard library only
  # (`:crypto`/`Base` for hashing/random; the stdlib `JSON` module for the API).
  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Burnerpad.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:bandit, "~> 1.5"}
    ]
  end
end
