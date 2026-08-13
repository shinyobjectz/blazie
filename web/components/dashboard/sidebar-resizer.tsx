"use client"

import { useCallback, useEffect, useRef, useState } from "react"

import { useSidebar } from "@/components/ui/sidebar"
import { cn } from "@/lib/utils"

/**
 * Drag the sidebar's edge.
 *
 * shadcn ships `SidebarRail`, which is a click target that toggles — useful,
 * but not a resizer. This is the resizer: it drives `--sidebar-width` on the
 * provider, which is the same variable the sidebar and its spacer already read,
 * so nothing has to be told the width changed.
 *
 * It is invisible until you are near it. A console is a thing you look at for a
 * long time and a permanent vertical line down the left is one more edge to
 * read past; the handle only exists while the pointer is on it or dragging.
 */

export const DEFAULT_WIDTH = 208
const MIN = 168
const MAX = 384
const REMEMBERED = "blazie.sidebar-width"

export function useSidebarWidth() {
  const [width, setWidth] = useState(DEFAULT_WIDTH)

  // Read after mount rather than in the initial state: this layout is
  // pre-rendered by the static export, and a server render that guessed a
  // remembered width would not match the one in this browser.
  useEffect(() => {
    const held = Number(window.localStorage.getItem(REMEMBERED))
    if (held >= MIN && held <= MAX) setWidth(held)
  }, [])

  const remember = useCallback((next: number) => {
    window.localStorage.setItem(REMEMBERED, String(next))
  }, [])

  return { width, setWidth, remember }
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
        "after:absolute after:inset-y-0 after:left-1/2 after:w-px after:-translate-x-1/2 after:transition-colors",
        dragging ? "after:bg-flame" : "hover:after:bg-white/20",
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
