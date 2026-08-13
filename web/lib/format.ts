import type { Fact, SnapshotName, Value } from "@/lib/blazie"

/**
 * How a fact's value is shown. Scalars go out as themselves; a symbol is
 * summarised rather than printed, because nobody reads 768 floats.
 */
export function showValue(value: Value): string {
  if (value === null) return "null"
  if (value === undefined) return "—"

  if (typeof value === "object" && value !== null && "$symbol" in value) {
    const symbol = (
      value as { $symbol?: { space?: string; values?: unknown[] } }
    ).$symbol
    const space = symbol?.space ?? "?"
    const width = Array.isArray(symbol?.values) ? symbol.values.length : 0
    return `$symbol ${space} · ${width}d`
  }

  if (typeof value === "string") return value
  if (typeof value === "number" || typeof value === "boolean")
    return String(value)
  return JSON.stringify(value)
}

/** A snapshot name as something a caller could paste into a request. */
export function showName(name: SnapshotName): string {
  return JSON.stringify(name)
}

export function showBytes(bytes: number): string {
  if (!Number.isFinite(bytes)) return "—"
  const units = ["b", "kb", "mb", "gb", "tb"]
  let size = bytes
  let unit = 0
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024
    unit += 1
  }
  return `${unit === 0 ? size : size.toFixed(size < 10 ? 1 : 0)}${units[unit]}`
}

export function showCount(n: number): string {
  return Number.isFinite(n) ? n.toLocaleString("en-US") : "—"
}

/** A unix second, as a distance and as a date. Both, because both get asked. */
export function showWhen(seconds: number, now = Date.now()): string {
  if (!Number.isFinite(seconds)) return "—"
  const ago = Math.max(0, Math.round(now / 1000 - seconds))

  const scale =
    ago < 60
      ? `${ago}s ago`
      : ago < 3600
        ? `${Math.round(ago / 60)}m ago`
        : ago < 86400
          ? `${Math.round(ago / 3600)}h ago`
          : `${Math.round(ago / 86400)}d ago`

  return `${scale} · ${new Date(seconds * 1000).toISOString().replace("T", " ").slice(0, 19)}z`
}

/**
 * The latest fact for an attribute on an id. A ledger keeps every reading, so
 * "current" is just the highest transaction — no separate current-value store.
 */
export function latest(facts: Fact[], attribute: string): Fact | undefined {
  let best: Fact | undefined
  for (const fact of facts) {
    if (fact.attribute !== attribute) continue
    if (!best || fact.tx > best.tx) best = fact
  }
  return best
}

/** The latest numeric reading, or undefined if it was never written. */
export function latestNumber(
  facts: Fact[],
  attribute: string,
): number | undefined {
  const fact = latest(facts, attribute)
  return typeof fact?.value === "number" ? fact.value : undefined
}

/** Everything on a row, flattened, for the client-side narrow box. */
export function factHaystack(fact: Fact): string {
  return `${fact.id} ${fact.attribute} ${showValue(fact.value)} ${fact.tx} ${
    fact.by ?? "outside"
  }`.toLowerCase()
}
