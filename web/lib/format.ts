/**
 * Rendering numbers a person has to read.
 *
 * This file used to be mostly fact helpers — pick the latest fact for an
 * attribute, flatten a fact into a search haystack, summarise a fact's value.
 * None of that exists on the surface any more: a chunk of Lua returns a table,
 * and "latest" is what reading a field already means. What is left is the part
 * that was never about facts, which is making bytes and timestamps legible.
 */

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
