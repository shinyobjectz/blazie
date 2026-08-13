"use client"

import {
  Activity,
  Bot,
  Database,
  Fingerprint,
  HardDrive,
  Settings,
  SquareTerminal,
  Table2,
} from "lucide-react"
import Link from "next/link"
import { usePathname } from "next/navigation"

import { Wordmark } from "@/components/ui/wordmark"
import {
  Sidebar,
  SidebarContent,
  SidebarFooter,
  SidebarGroup,
  SidebarGroupContent,
  SidebarHeader,
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem,
} from "@/components/ui/sidebar"

/**
 * The nav, in the order somebody uses it.
 *
 * Data first, because that is what anybody opening a backend console came to
 * see. An earlier version grouped these by what a thing IS in blazie's own
 * terms — read / declared / the node — which is a fine way to organise a
 * reference and a confusing way to organise a screen.
 */

const items: { href: string; label: string; icon: typeof Table2 }[] = [
  { href: "/dashboard", label: "data", icon: Table2 },
  { href: "/dashboard/editor", label: "editor", icon: SquareTerminal },
  { href: "/dashboard/agents", label: "agents", icon: Bot },
  { href: "/dashboard/worlds", label: "worlds", icon: Database },
  { href: "/dashboard/storage", label: "storage", icon: HardDrive },
  { href: "/dashboard/activity", label: "activity", icon: Activity },
  { href: "/dashboard/settings", label: "settings", icon: Settings },
]

export function AppSidebar({ login }: { login: string | null }) {
  const pathname = usePathname()

  return (
    <Sidebar collapsible="icon">
      {/* Matches the content header's height so the rule under the wordmark and
          the one under the snapshot bar are the same line across the page. That
          only reads correctly now that a border is the border token rather than
          currentColor — as a white stroke it was a highlight, not a hairline. */}
      <SidebarHeader className="h-14 justify-center border-b">
        <Link href="/" className="flex items-center px-2 py-1.5">
          <Wordmark size="sm" />
        </Link>
      </SidebarHeader>

      <SidebarContent>
        <SidebarGroup>
          <SidebarGroupContent>
            <SidebarMenu>
              {items.map((item) => (
                <SidebarMenuItem key={item.href}>
                  <SidebarMenuButton
                    asChild
                    // `/dashboard` prefixes every other route, so it is the one
                    // that has to match exactly or it is always active.
                    isActive={
                      item.href === "/dashboard"
                        ? pathname === "/dashboard"
                        : pathname.startsWith(item.href)
                    }
                    tooltip={item.label}
                  >
                    <Link href={item.href}>
                      <item.icon />
                      <span>{item.label}</span>
                    </Link>
                  </SidebarMenuButton>
                </SidebarMenuItem>
              ))}
            </SidebarMenu>
          </SidebarGroupContent>
        </SidebarGroup>
      </SidebarContent>

      <SidebarFooter className="border-t border-sidebar-border">
        <SidebarMenu>
          <SidebarMenuItem>
            <SidebarMenuButton asChild tooltip={login ?? "this caller"}>
              <Link href="/dashboard/settings">
                <Fingerprint />
                <span className="font-mono truncate">
                  {login ?? "this caller"}
                </span>
              </Link>
            </SidebarMenuButton>
          </SidebarMenuItem>
        </SidebarMenu>
      </SidebarFooter>
    </Sidebar>
  )
}
