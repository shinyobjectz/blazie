"use client"

import Link from "next/link"
import { useRouter } from "next/navigation"
import { useEffect } from "react"

import { GradientBackground } from "@/components/ui/paper-design-shader-background"
import { Wordmark } from "@/components/ui/wordmark"
import { readToken } from "@/lib/blazie"

const CLIENT_ID =
  process.env.NEXT_PUBLIC_GITHUB_CLIENT_ID ?? "Ov23liU8M5D4hy3RFrRM"

const REDIRECT_URI = "https://blazie.dev/callback/github"

const AUTHORIZE =
  "https://github.com/login/oauth/authorize" +
  `?client_id=${encodeURIComponent(CLIENT_ID)}` +
  `&redirect_uri=${encodeURIComponent(REDIRECT_URI)}` +
  "&scope=read:user"

export default function Login() {
  const router = useRouter()

  // A token in hand means there is nothing to ask for.
  useEffect(() => {
    if (readToken()) router.replace("/dashboard")
  }, [router])

  return (
    <main className="relative flex min-h-screen w-full flex-1 flex-col overflow-hidden">
      <GradientBackground />
      <div className="absolute inset-0 -z-10 bg-black/55" />

      <header className="relative z-10 px-6 py-5 sm:px-10">
        <Link href="/">
          <Wordmark size="sm" />
        </Link>
      </header>

      <div className="relative z-10 flex flex-1 items-center justify-center px-6 pb-24">
        <section className="w-full max-w-md text-center">
          <h1 className="text-balance text-3xl font-medium leading-tight tracking-tight text-white sm:text-4xl">
            open a cluster
          </h1>

          <p className="mx-auto mt-5 max-w-sm text-balance text-sm leading-relaxed text-white/70">
            github says who you are. what you may read is which ledgers this
            caller was granted — a list, not a rule, and you can see it once
            you are in.
          </p>

          <a
            href={AUTHORIZE}
            className="mt-9 inline-flex w-full items-center justify-center gap-3 rounded-md bg-white px-6 py-3.5 text-sm font-semibold tracking-tight text-black transition-transform hover:scale-[1.02]"
          >
            <GithubMark />
            continue with github
          </a>

          <p className="mt-6 text-xs leading-relaxed text-white/45">
            read:user only. blazie records the login your token was minted
            under and nothing else about the account.
          </p>

          <p className="font-mono mt-10 text-xs text-white/35">
            no account yet? there is no signup — a caller is granted, not
            registered.
          </p>
        </section>
      </div>
    </main>
  )
}

function GithubMark() {
  return (
    <svg
      viewBox="0 0 16 16"
      aria-hidden="true"
      className="h-4 w-4 fill-current"
    >
      <path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.01 8.01 0 0 0 16 8c0-4.42-3.58-8-8-8Z" />
    </svg>
  )
}
