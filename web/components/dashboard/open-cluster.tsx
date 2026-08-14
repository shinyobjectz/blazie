"use client"

import { Server } from "lucide-react"
import { useCallback, useState } from "react"

import { useCluster } from "@/app/dashboard/cluster"
import { RefusalNote } from "@/components/ui/refusal-note"
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select"
import { openCluster } from "@/lib/blazie"
import { cn } from "@/lib/utils"

/**
 * Opening a cluster — the form, rather than the page it used to be part of.
 *
 * It was written inline on the clusters page, and that is why onboarding was a
 * redirect: the only way to get a first cluster was to be standing on that
 * route. Onboarding is not somewhere you navigate to, so the form had to stop
 * being one page's private markup before it could be anywhere else.
 */

export const ZONES = [
  { id: "uk-lon1", label: "London" },
  { id: "de-fra1", label: "Frankfurt" },
  { id: "us-nyc1", label: "New York" },
  { id: "sg-sin1", label: "Singapore" },
]

export const PLANS = [
  { id: "1xCPU-2GB", label: "1 CPU · 2 GB", monthly: 9 },
  { id: "2xCPU-4GB", label: "2 CPU · 4 GB", monthly: 18 },
  { id: "4xCPU-8GB", label: "4 CPU · 8 GB", monthly: 44 },
]

export function OpenCluster({
  className,
  onOpening,
}: {
  className?: string
  /**
   * Called the instant the button is pressed, with the name asked for — and
   * called again with `null` if the request comes back refused.
   *
   * Opening makes a tunnel, a dns record and a machine before it answers, which
   * is several seconds of a form sitting there saying "opening…". The screen
   * that shows what is happening should be up for those seconds too — they are
   * the ones where somebody is most likely to press the button again.
   *
   * The `null` matters as much as the name. Showing a timeline optimistically
   * means a refusal — a name already taken, no room on the account — would
   * otherwise leave somebody watching the progress of a machine that was never
   * made, with the reason why hidden behind the screen replacing the form.
   */
  onOpening?: (name: string | null) => void
}) {
  const { who, refresh, chooseCluster } = useCluster()

  const [name, setName] = useState("")
  const [zone, setZone] = useState(ZONES[0].id)
  const [plan, setPlan] = useState(PLANS[0].id)
  const [opening, setOpening] = useState(false)
  const [error, setError] = useState<unknown>(null)

  const open = useCallback(
    async (event: React.FormEvent) => {
      event.preventDefault()
      if (opening || !name.trim()) return

      setOpening(true)
      setError(null)
      onOpening?.(name.trim())

      try {
        const { cluster: made } = await openCluster({ name: name.trim(), zone, plan })
        setName("")
        await refresh()
        chooseCluster(made.id)
      } catch (thrown) {
        setError(thrown)
        onOpening?.(null)
      } finally {
        setOpening(false)
      }
    },
    [name, zone, plan, opening, refresh, chooseCluster, onOpening],
  )

  if (!who.can.open_clusters) {
    return (
      <p className="font-mono max-w-2xl rounded-lg border border-ember/30 bg-ember/5 p-4 text-xs leading-relaxed text-ember">
        this deployment cannot open clusters yet — it has no credentials to make
        a machine with. set UPCLOUD_TOKEN, CLOUDFLARE_API_TOKEN,
        CLOUDFLARE_ACCOUNT_ID and CLOUDFLARE_ZONE_ID with `wrangler pages secret
        put`. clusters already open still work.
      </p>
    )
  }

  return (
    <div className={className}>
      <form onSubmit={open} className="flex flex-wrap items-end gap-4">
        <label className="block">
          <span className="font-mono mb-1.5 block text-xs text-muted-foreground">
            name
          </span>
          <input
            value={name}
            onChange={(event) => setName(event.target.value)}
            placeholder="atlas"
            autoFocus
            className="font-mono w-52 rounded-md border border-border bg-muted px-3 py-2 text-sm text-white placeholder:text-muted-foreground focus:border-white/30 focus:outline-none"
          />
        </label>

        <Choice label="where" value={zone} onChange={setZone} options={ZONES} />

        <Choice
          label="size"
          value={plan}
          onChange={setPlan}
          options={PLANS.map((p) => ({ id: p.id, label: `${p.label} · $${p.monthly}/mo` }))}
        />

        <button
          type="submit"
          disabled={opening || !name.trim()}
          className={cn(
            "inline-flex items-center gap-2 rounded-md bg-white px-5 py-2 text-sm font-semibold tracking-tight text-black transition-transform",
            "hover:scale-[1.02] disabled:opacity-40 disabled:hover:scale-100",
          )}
        >
          <Server className="size-4" />
          {opening ? "opening…" : "open"}
        </button>
      </form>

      {error ? <RefusalNote error={error} className="mt-8" /> : null}
    </div>
  )
}

/**
 * One choice, drawn by us rather than by the operating system.
 *
 * A native `<select>` renders its list in the platform's own widget, which does
 * not read the page's palette or its font — so the two places this console asks
 * you to pick something were the two that looked like a different application.
 * Radix keeps the keyboard and screen-reader behaviour that makes a native
 * select worth using, and lets the list be ours.
 */
function Choice({
  label,
  value,
  onChange,
  options,
}: {
  label: string
  value: string
  onChange: (next: string) => void
  options: { id: string; label: string; hint?: string }[]
}) {
  return (
    <div className="block">
      <span className="font-mono mb-1.5 block text-xs text-muted-foreground">
        {label}
      </span>
      <Select value={value} onValueChange={onChange}>
        <SelectTrigger className="font-mono h-auto min-w-44 rounded-md border-border bg-muted px-3 py-2 text-sm text-white">
          <SelectValue />
        </SelectTrigger>
        <SelectContent className="font-mono">
          {options.map((option) => (
            <SelectItem key={option.id} value={option.id} className="text-sm">
              {option.label}
              {option.hint ? (
                <span className="ml-2 text-xs text-muted-foreground">
                  {option.hint}
                </span>
              ) : null}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>
    </div>
  )
}
