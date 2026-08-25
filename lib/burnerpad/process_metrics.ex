# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Impulsa SLU

defmodule Burnerpad.ProcessMetrics do
  @moduledoc false

  @doc "Return a process's current mailbox length, or zero when it is absent or exits during inspection."
  @spec queue_length(pid() | atom()) :: non_neg_integer()
  def queue_length(process) do
    with pid when is_pid(pid) <- resolve(process),
         {:message_queue_len, length} <- Process.info(pid, :message_queue_len) do
      length
    else
      _ -> 0
    end
  end

  defp resolve(pid) when is_pid(pid), do: pid
  defp resolve(name) when is_atom(name), do: Process.whereis(name)
end
