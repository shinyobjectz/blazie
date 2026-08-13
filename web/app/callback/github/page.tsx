"use client"

import Link from "next/link"
import { useRouter } from "next/navigation"
import { useEffect, useRef, useState } from "react"

import { GradientBackground } from "@/components/ui/paper-design-shader-background"
import { RefusalNote } from "@/components/ui/refusal-note"
import { Wordmark } from "@/components/ui/wordmark"
import { Refusal, authGithub, storeToken } from "@/lib/blazie"

/**
 * Where github lands. This is a static page — the code is read off the URL in
 * the browser and traded for a token there too, because there is no server in
 * this deployment to trade it on the page's behalf.
 *
 * The search string is read from `window.location` rather than
 * `useSearchParams` so the route stays a plain static export with no CSR
 * bailout, and so it works whether github's redirect landed on
 * `/callback/github` or the trailing-slash form the host redirects it to.
 */
/**
 * Read the code off the URL and trade it. Every way this can fail is a refusal
 * with a repair, including the two github itself causes, so the page has one
 * failure path rather than three.
 */
async function exchange(): Promise<string> {
  const params = new URLSearchParams(window.location.search)

  const denied = params.get("error")
  if (denied) {
    throw new Refusal(
      denied,
      params.get("error_description") ??
        "github did not authorize this sign-in. Start again and approve the read:user scope.",
      403,
    )
  }

  const code = params.get("code")
  if (!code) {
    throw new Refusal(
      "no_code",
      "github redirected here without a code. Start the sign-in again from /login — this page is only ever reached from github.",
      422,
    )
  }

  const { token, login } = await authGithub(code)
  storeToken(token)
  return login
}

export default function GithubCallback() {
  const router = useRouter()
  const [error, setError] = useState<unknown>(null)
  const [login, setLogin] = useState<string | null>(null)

  // A github code is single-use. React may run this effect twice in dev, and
  // the second exchange would fail against a code already spent.
  const started = useRef(false)

  useEffect(() => {
    if (started.current) return
    started.current = true

    exchange()
      .then((who) => {
        setLogin(who)
        router.replace("/dashboard")
      })
      .catch(setError)
  }, [router])

  return (
    <main className="relative flex min-h-screen w-full flex-1 flex-col overflow-hidden">
      <GradientBackground />
      <div className="absolute inset-0 -z-10 bg-black/60" />

      <header className="relative z-10 px-6 py-5 sm:px-10">
        <Link href="/">
          <Wordmark size="sm" />
        </Link>
      </header>

      <div className="relative z-10 flex flex-1 items-center justify-center px-6 pb-24">
        <section className="w-full max-w-lg">
          {error ? (
            <>
              <h1 className="mb-5 text-2xl font-medium tracking-tight text-white">
                that sign-in did not complete
              </h1>
              <RefusalNote error={error} className="bg-black/40 backdrop-blur" />
              <Link
                href="/login"
                className="mt-6 inline-block text-sm text-white underline decoration-white/30 underline-offset-4 transition-colors hover:decoration-white"
              >
                start again
              </Link>
            </>
          ) : (
            <div className="text-center">
              <h1 className="text-2xl font-medium tracking-tight text-white">
                {login ? `signed in as ${login}` : "trading the code for a token"}
              </h1>
              <p className="font-mono mt-4 text-sm text-muted-foreground">
                {login ? "opening the console…" : "POST /auth/github"}
              </p>
              <div className="mx-auto mt-8 h-px w-40 overflow-hidden bg-white/10">
                <div className="h-full w-1/3 animate-[slide_1.1s_ease-in-out_infinite] bg-flame" />
              </div>
            </div>
          )}
        </section>
      </div>

      <style>{`
        @keyframes slide {
          0%   { transform: translateX(-100%); }
          100% { transform: translateX(300%); }
        }
      `}</style>
    </main>
  )
}
