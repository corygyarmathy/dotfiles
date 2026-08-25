# Runbook template

Copy this shape for each `## <AlertName>` section. Keep it short enough to
read on a phone at 3am; link out for depth instead of inlining it.

```markdown
## <AlertName>

**Severity:** warning | critical · **Lane:** push (buzzes / silent) + email
**Fires when:** one sentence restating the expression in plain language.

### Do now
- Exact command(s) that answer "how bad is it".
- The single most likely cause, if there is one.

### Dig deeper
- Second looks, dashboards, related alerts to check.

### Fix
- The usual resolutions, most common first.
- When it is safe to silence and walk away.
```

Notes:

- "Fires when" should restate the PromQL honestly - the alert's own comment in
  `alert-rules.yml` is usually a good source.
- If the alert can fire while everything is actually fine (threshold quirks,
  maintenance windows), say so under "Fires when". An honest false-positive
  note saves a future you from rediscovering it at night.
