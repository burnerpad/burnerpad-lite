# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Impulsa SLU

# Keep test output focused on failures and intentional abuse-ban events.
Logger.configure(level: :warning)
ExUnit.start()
