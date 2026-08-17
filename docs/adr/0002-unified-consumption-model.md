# Unified consumption model: quota and spend as "progress toward a limit"

Our eight plans split into two consumption kinds that the reference projects can't both express. Quota plans (Claude, Codex, Copilot, Gemini, OpenCode Go) carry provider-imposed limits that reset on fixed windows; spend plans (Mistral, Scaleway, OpenCode Zen) are pay-as-you-go with no ceiling. Both reference projects model only quota percentages, which cannot represent spend.

We decided on a single unified view: every plan renders a normalized **Progress** (0–1), where the denominator is a provider-imposed limit for quota plans and a user-set **Budget** for spend plans. Raw currency is always shown for spend plans, so an unset budget still surfaces a useful figure.

**Consequences**: a spend plan with no budget shows only its raw currency figure and no progress bar (acceptable); the menu bar's "most urgent plan" logic must compare across kinds, which we resolve by treating an unset budget as "no urgency."
