# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Impulsa SLU

defmodule Burnerpad.Encoding do
  @moduledoc "Strict canonical unpadded base64url transport decoding."

  @pattern ~r/\A[A-Za-z0-9_-]*\z/

  @doc "Decode exactly one canonical unpadded base64url representation, optionally requiring byte length."
  def decode64url(value, expected_bytes \\ :any)

  def decode64url(value, expected_bytes) when is_binary(value) do
    with true <- Regex.match?(@pattern, value),
         false <- rem(byte_size(value), 4) == 1,
         {:ok, decoded} <- Base.url_decode64(value, padding: false),
         true <- Base.url_encode64(decoded, padding: false) == value,
         true <- expected_bytes == :any or byte_size(decoded) == expected_bytes do
      {:ok, decoded}
    else
      _ -> :error
    end
  end

  def decode64url(_, _), do: :error
end
