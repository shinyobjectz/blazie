"use client"

import {
  Activity,
  Bot,
  HardDrive,
  LogOut,
  Globe,
  Orbit,
  Settings,
  SquareTerminal,
  Table2,
  User,
} from "lucide-react"
import Link from "next/link"
import { usePathname } from "next/navigation"
import { useState } from "react"

import { ClusterSwitcher } from "@/components/dashboard/cluster-switcher"
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu"
import { signOut } from "@/lib/blazie"
import { at, under } from "@/lib/path"
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
 * The nav, in two groups, because it was answering two different questions.
 *
 * One flat list of nine put "worlds" — the thing a cluster is FOR — in the
 * middle of a run of instruments, where it read as the fifth tool rather than
 * the subject the tools operate on. Splitting them says which is which without
 * a word of explanation.
 *
 * Clusters is in neither, and not in the nav at all. A cluster is not a page in
 * this console — it is what the console is pointed AT, chosen in the switcher
 * above, and every item here is a question asked of whichever one that is.
 * Listing it alongside them made it look like one more thing to go and look at
 * rather than the thing that decides what the others are about. Managing them
 * is still reachable from the switcher, which is where somebody thinking about
 * clusters already is.
 *
 * An earlier version grouped these by what a thing IS in blazie's own terms —
 * read / declared / the node — which is a fine way to organise a reference and
 * a confusing way to organise a screen.
 */
type Item = { href: string; label: string; icon: typeof Table2 }

/**
 * What the cluster holds: the orbit over it, the worlds in it, and what acts on
 * them. These three are the subject — the reason there is a cluster at all.
 */
const holds: Item[] = [
  { href: "/dashboard", label: "orbit", icon: Orbit },
  { href: "/dashboard/worlds", label: "worlds", icon: Globe },
  { href: "/dashboard/agents", label: "agents", icon: Bot },
]

/**
 * Ways of working on it. Instruments rather than subjects: each one is a view
 * onto the same worlds above, which is why they sit apart from them rather than
 * in one list of nine where the distinction was invisible.
 */
const tools: Item[] = [
  { href: "/dashboard/data", label: "data", icon: Table2 },
  { href: "/dashboard/editor", label: "editor", icon: SquareTerminal },
  { href: "/dashboard/storage", label: "storage", icon: HardDrive },
  { href: "/dashboard/activity", label: "activity", icon: Activity },
]

// Settings is deliberately not above. It is not a place you work, it is where
// you go to change who you are and what this console may do — which is what the
// account block at the bottom is for, and it is already there. Listing it twice
// made the nav answer two different questions in one column.

export function AppSidebar({ login }: { login: string | null }) {
  const pathname = usePathname()

  return (
    <Sidebar collapsible="icon">
      {/* Matches the content header's height so the rule under the wordmark and
          the one under the snapshot bar are the same line across the page. That
          only reads correctly now that a border is the border token rather than
          currentColor — as a white stroke it was a highlight, not a hairline. */}
      {/* The switcher, where the wordmark was. A console holding several
          clusters has to say which one is on screen somewhere every page
          shares, and this is the only such place. */}
      <SidebarHeader className="h-14 justify-center border-b px-1">
        <ClusterSwitcher />
      </SidebarHeader>

      <SidebarContent>
        <Group items={holds} pathname={pathname} />
        <Group items={tools} pathname={pathname} separated />
      </SidebarContent>

      <SidebarFooter className="border-t border-sidebar-border">
        <SidebarMenu>
          <SidebarMenuItem>
            <Account login={login} />
          </SidebarMenuItem>
        </SidebarMenu>
      </SidebarFooter>
    </Sidebar>
  )
}

function Group({
  items,
  pathname,
  separated,
}: {
  items: Item[]
  pathname: string
  separated?: boolean
}) {
  return (
    <SidebarGroup className={separated ? "border-t border-sidebar-border pt-2" : undefined}>
      <SidebarGroupContent>
        <SidebarMenu>
          {items.map((item) => (
            <SidebarMenuItem key={item.href}>
              <SidebarMenuButton
                asChild
                // `/dashboard` prefixes every other route, so it is the one that
                // has to match exactly or it is always active. Both comparisons
                // go through `lib/path` because this pathname carries a trailing
                // slash and these literals do not — the orbit never lit up,
                // which was the harmless half of the bug that also made
                // onboarding unreachable.
                isActive={
                  item.href === "/dashboard"
                    ? at(pathname, item.href)
                    : under(pathname, item.href)
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
  )
}

/**
 * Who you are signed in as, and the two things you can do about it.
 *
 * It was a link to settings wearing a fingerprint icon, which said your handle
 * without ever showing you — and put signing out two navigations away, on a
 * page reachable only from inside the console. Somebody testing whether auth
 * works needs to see who they are and get back out, and neither was true here.
 *
 * The picture comes from github, which is who told us the handle in the first
 * place. It is the one image on the page that is not derived, so it is also the
 * one that can fail — a blocked request, a handle with no picture — and it
 * falls back to an initial rather than to a broken frame.
 */
function Account({ login }: { login: string | null }) {
  const [shown, setShown] = useState(true)

  return (
    <DropdownMenu>
      <DropdownMenuTrigger className="flex w-full items-center gap-2 rounded-md px-2 py-1.5 text-left transition-colors hover:bg-raised">
        <span className="flex size-6 shrink-0 items-center justify-center overflow-hidden rounded-full border border-border bg-muted">
          {login && shown ? (
            // The image optimiser is off for a static export, so `next/image`
            // would emit this same tag — minus the `onError` fallback, which is
            // the whole reason a remote picture is safe to use here.
            // eslint-disable-next-line @next/next/no-img-element
            <img
              src={`https://github.com/${encodeURIComponent(login)}.png?size=48`}
              alt=""
              width={24}
              height={24}
              className="size-full object-cover"
              onError={() => setShown(false)}
            />
          ) : (
            <User className="size-3.5 text-muted-foreground" />
          )}
        </span>

        <span className="font-mono min-w-0 flex-1 truncate text-sm text-white">
          {login ?? "this caller"}
        </span>
      </DropdownMenuTrigger>

      <DropdownMenuContent align="start" side="top" className="w-56">
        <DropdownMenuLabel className="font-mono text-xs text-muted-foreground">
          {login ? `signed in as ${login}` : "signed in"}
        </DropdownMenuLabel>

        <DropdownMenuSeparator />

        <DropdownMenuItem asChild className="gap-2">
          <Link href="/dashboard/settings">
            <Settings className="size-3.5" />
            settings
          </Link>
        </DropdownMenuItem>

        <DropdownMenuItem
          className="gap-2 text-flame focus:text-flame"
          onSelect={() => {
            // In `finally` rather than `then`: if the control plane is what is
            // unreachable, signing out still has to leave.
            void signOut().finally(() => window.location.replace("/dashboard/"))
          }}
        >
          <LogOut className="size-3.5" />
          sign out
        </DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  )
}
