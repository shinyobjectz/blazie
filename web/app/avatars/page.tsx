"use client"

import { WorldAvatar, WorldOrbit } from "@/components/ui/world-avatar"

const NAMES = [
  "main",
  "orders",
  "$vitals",
  "$storage",
  "$backup",
  "tickets",
  "ada",
  "grace",
]

export default function Avatars() {
  return (
    <main className="space-y-10 p-10">
      <div className="flex flex-wrap gap-6">
        {NAMES.map((n) => (
          <div key={n} className="space-y-2">
            <WorldOrbit world={n} agents={n.length % 5} jobs={n.length % 3} live />
            <p className="font-mono text-xs text-muted-foreground">{n}</p>
          </div>
        ))}
      </div>
      <div className="flex flex-wrap items-center gap-3">
        {NAMES.map((n) => (
          <WorldAvatar key={n} world={n} size="sm" />
        ))}
        {NAMES.map((n) => (
          <WorldAvatar key={`m-${n}`} world={n} />
        ))}
      </div>
    </main>
  )
}
