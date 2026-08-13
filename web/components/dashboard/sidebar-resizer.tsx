"use client"

import { useCallback, useEffect, useRef, useState } from "react"

import { useSidebar } from "@/components/ui/sidebar"
import { useRemembered } from "@/hooks/use-remembered"
import { cn } from "@/lib/utils"

/**
 * Drag the sidebar's edge.
 *
 * shadcn ships `SidebarRail`, which is a click target that toggles — useful,
 * but not a resizer. This is the resizer: it drives `--sidebar-width` on the
 * provider, which is the same variable the sidebar and its spacer already read,
 * so nothing has to be told the width changed.
 *
 * It sits exactly on top of the sidebar's own edge and draws nothing of its own
 * at rest, so the hairline you see there is the border every other panel uses.
 * That line IS the affordance: something permanently visible marks where the
 * handle is, and hovering brightens the line already there rather than
 * revealing one that was not. A handle discoverable only by hovering over the
 * right two pixels is a handle nobody finds.
 */

export const DEFAULT_WIDTH = 208
const MIN = 168
const MAX = 384
const REMEMBERED = "blazie.sidebar-width"

export function useSidebarWidth() {
  // Read rather than copied into state. This layout is prerendered by the
  // static export, so a server render that guessed a remembered width would not
  // match the one in this browser — which is why it used to be an effect that
  // corrected the width after mount, and why the sidebar visibly jumped.
  const held = Number(useRemembered(REMEMBERED))
  const remembered = held >= MIN && held <= MAX ? held : DEFAULT_WIDTH

  // What this drag has made it, if there has been one. Layered over the
  // remembered width rather than replacing it, so there is one source for each:
  // the browser remembers, the hand overrides.
  const [dragged, setDragged] = useState<number | null>(null)

  const remember = useCallback((next: number) => {
    window.localStorage.setItem(REMEMBERED, String(next))
  }, [])

  return { width: dragged ?? remembered, setWidth: setDragged, remember }
}

export function SidebarResizer({
  width,
  onWidth,
  onSettled,
}: {
  width: number
  onWidth: (next: number) => void
  onSettled: (next: number) => void
}) {
  const { state, isMobile } = useSidebar()
  const [dragging, setDragging] = useState(false)
  const latest = useRef(width)

  // While dragging, the pointer is over the page and everything under it would
  // otherwise select. Cleared on release, and on unmount in case a drag is
  // interrupted by a route change.
  useEffect(() => {
    if (!dragging) return
    const previous = document.body.style.userSelect
    document.body.style.userSelect = "none"
    document.body.style.cursor = "col-resize"
    return () => {
      document.body.style.userSelect = previous
      document.body.style.cursor = ""
    }
  }, [dragging])

  // Collapsed, the width is the icon rail and dragging it would fight the
  // toggle. On mobile the sidebar is a sheet and has no edge to hold.
  if (isMobile || state === "collapsed") return null

  return (
    <div
      role="separator"
      aria-orientation="vertical"
      aria-label="resize the sidebar"
      className={cn(
        "fixed inset-y-0 z-20 hidden w-2 -translate-x-1/2 cursor-col-resize md:block",
        // Transparent at rest: the sidebar's own border is under here and is
        // what should show. Hover and drag brighten that same line in place.
        "after:absolute after:inset-y-0 after:left-1/2 after:w-px after:-translate-x-1/2 after:transition-colors",
        dragging ? "after:bg-flame" : "after:bg-transparent hover:after:bg-white/25",
      )}
      style={{ left: `${width}px` }}
      onPointerDown={(event) => {
        event.preventDefault()
        event.currentTarget.setPointerCapture(event.pointerId)
        setDragging(true)
      }}
      onPointerMove={(event) => {
        if (!dragging) return
        const next = Math.min(MAX, Math.max(MIN, Math.round(event.clientX)))
        latest.current = next
        onWidth(next)
      }}
      onPointerUp={(event) => {
        event.currentTarget.releasePointerCapture(event.pointerId)
        setDragging(false)
        onSettled(latest.current)
      }}
      onDoubleClick={() => {
        latest.current = DEFAULT_WIDTH
        onWidth(DEFAULT_WIDTH)
        onSettled(DEFAULT_WIDTH)
      }}
    />
  )
}
