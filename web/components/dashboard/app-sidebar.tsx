"use client"

import {
  Activity,
  BookMarked,
  Clock,
  Fingerprint,
  KeyRound,
  Layers,
  Rows3,
  Sparkles,
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
  SidebarGroupLabel,
  SidebarHeader,
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem,
} from "@/components/ui/sidebar"

/**
 * The nav, grouped by what a thing *is* rather than by which screen it lives on.
 *
 * "read" is the four operations pointed at facts. "declared" is the things
 * somebody wrote down that the cluster then acts on — an attribute, a job. They
 * are separated because the second group is the only one where what you see is
 * something a person decided, and that is worth being able to see at a glance.
 */

const groups: {
  label: string
  items: { href: string; label: string; icon: typeof Rows3 }[]
}[] = [
  {
    label: "read",
    items: [
      { href: "/dashboard", label: "overview", icon: Layers },
      { href: "/dashboard/facts", label: "facts", icon: Rows3 },
      { href: "/dashboard/produced", label: "produced", icon: Sparkles },
    ],
  },
  {
    label: "declared",
    items: [
      { href: "/dashboard/attributes", label: "attributes", icon: BookMarked },
      { href: "/dashboard/jobs", label: "jobs", icon: Clock },
    ],
  },
  {
    label: "the node",
    items: [
      { href: "/dashboard/vitals", label: "vitals", icon: Activity },
      { href: "/dashboard/access", label: "access", icon: KeyRound },
    ],
  },
]

export function AppSidebar({ login }: { login: string | null }) {
  const pathname = usePathname()

  return (
    <Sidebar collapsible="icon">
      <SidebarHeader className="border-b border-sidebar-border">
        <Link href="/" className="flex items-center px-2 py-1.5">
          <Wordmark size="sm" />
        </Link>
      </SidebarHeader>

      <SidebarContent>
        {groups.map((group) => (
          <SidebarGroup key={group.label}>
            <SidebarGroupLabel>{group.label}</SidebarGroupLabel>
            <SidebarGroupContent>
              <SidebarMenu>
                {group.items.map((item) => (
                  <SidebarMenuItem key={item.href}>
                    <SidebarMenuButton
                      asChild
                      // `/dashboard` prefixes every other route, so it is the
                      // one that has to match exactly or it is always active.
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
        ))}
      </SidebarContent>

      <SidebarFooter className="border-t border-sidebar-border">
        <SidebarMenu>
          <SidebarMenuItem>
            <SidebarMenuButton asChild tooltip={login ?? "this caller"}>
              <Link href="/dashboard/access">
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
