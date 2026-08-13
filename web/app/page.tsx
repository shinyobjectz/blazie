import Link from "next/link";

import { GradientBackground } from "@/components/ui/paper-design-shader-background";
import { Wordmark } from "@/components/ui/wordmark";

const capabilities = [
  {
    title: "memory that keeps being wrong",
    body: "nothing is ever rewritten. a correction is a later fact, and the earlier one still answers where it was written — so “what did it believe on tuesday” is a question, not a log search.",
  },
  {
    title: "every fact knows what made it",
    body: "provenance is a slot in the row, not a convention. an answer either came from outside or names the code that produced it, and there is no third option to forget.",
  },
  {
    title: "a graph you did not have to model",
    body: "an edge is a fact whose value is another id. there is no node type and no edge type because there is nothing left to add — and no second store to keep in step.",
  },
  {
    title: "code runs where it cannot reach",
    body: "agent code runs in lua or webassembly with no clock, no network and no filesystem. isolation is the absence of anything to reach, so there is no rule to misconfigure.",
  },
  {
    title: "one line touches the outside world",
    body: "a job is the only thing handed the network, and the only thing a schedule attaches to. what an agent did to the world is a list you can read, with its failures on it.",
  },
  {
    title: "it tells you when something changed",
    body: "watch a question and it answers again as facts land — the same question, not a different mechanism. an agent reacts instead of polling.",
  },
];

const operations = [
  ["open", "which ledgers", "a snapshot name"],
  ["ask", "name, question", "facts"],
  ["watch", "name, question", "facts again as the name advances"],
  ["write", "name, facts", "a new name"],
];

export default function Home() {
  return (
    <>
      <header className="relative z-10 flex items-center justify-between px-6 py-5 sm:px-10">
        <Wordmark size="sm" />
        <nav className="flex items-center gap-6 text-sm text-white/70">
          <a
            href="https://github.com/shinyobjectz/blazie"
            className="transition-colors hover:text-white"
          >
            source
          </a>
          <Link
            href="/login"
            className="rounded-md border border-white/20 px-4 py-1.5 text-sm font-medium tracking-tight text-white transition-colors hover:border-white/50 hover:bg-white/5"
          >
            sign in
          </Link>
        </nav>
      </header>

      <main className="relative flex min-h-[82vh] w-full flex-1 items-center justify-center overflow-hidden">
        <GradientBackground />
        <div className="absolute inset-0 -z-10 bg-black/40" />

        <section className="px-6 pb-24 text-center">
          <Wordmark size="lg" className="mb-8 justify-center" />

          <h1 className="mx-auto max-w-3xl text-balance text-4xl font-medium leading-[1.1] tracking-tight text-white sm:text-6xl">
            the backend agents run on
          </h1>

          <p className="mx-auto mt-6 max-w-xl text-balance text-base leading-relaxed text-white/70">
            durable memory that records where every fact came from, a graph you
            did not have to model, and sandboxes to run agent code in. deploy an
            agent, give it a cadence, and read back everything it did.
          </p>

          <div className="mt-10 flex flex-wrap items-center justify-center gap-3">
            <Link
              href="/login"
              className="rounded-md bg-white px-6 py-3 text-sm font-semibold tracking-tight text-black transition-transform hover:scale-[1.02]"
            >
              open a cluster
            </Link>
            <code className="font-mono rounded-md border border-white/20 bg-black/50 px-4 py-3 text-sm text-white/80 backdrop-blur">
              brew install blazie
            </code>
          </div>
        </section>
      </main>

      <section className="border-t border-border px-6 py-20 sm:px-10">
        <div className="mx-auto max-w-5xl">
          <h2 className="mb-3 text-3xl font-medium tracking-tight text-white">
            what an agent gets
          </h2>
          <p className="mb-12 max-w-2xl text-sm text-muted-foreground">
            not a database with an agent story bolted on. the parts an agent
            needs, in one runtime, where they already agree with each other.
          </p>

          <div className="grid gap-x-10 gap-y-10 sm:grid-cols-2">
            {capabilities.map(({ title, body }) => (
              <div key={title} className="border-l-2 border-flame/50 pl-5">
                <h3 className="text-base font-medium tracking-tight text-white">
                  {title}
                </h3>
                <p className="mt-2 text-sm leading-relaxed text-muted-foreground">
                  {body}
                </p>
              </div>
            ))}
          </div>
        </div>
      </section>

      <section className="border-t border-border px-6 py-20 sm:px-10">
        <div className="mx-auto max-w-5xl">
          <h2 className="mb-3 text-3xl font-medium tracking-tight text-white">
            an answer you can cite
          </h2>
          <p className="mb-10 max-w-2xl text-sm text-muted-foreground">
            a caller holds the snapshot&apos;s name, never its bytes. the same
            question at the same name gives the same facts forever — so an agent
            can cite what it read, and the citation still holds next month.
          </p>

          <div className="overflow-x-auto">
            <table className="w-full min-w-[34rem] text-left text-sm">
              <tbody>
                {operations.map(([op, takes, gives]) => (
                  <tr key={op} className="border-b border-border/60">
                    <td className="font-pixel py-3 pr-8 text-lg lowercase text-flame">
                      {op}
                    </td>
                    <td className="font-mono py-3 pr-8 text-muted-foreground">{takes}</td>
                    <td className="font-mono py-3 text-white/80">→ {gives}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          <p className="mt-8 max-w-2xl text-sm text-muted-foreground">
            authorization is which ledgers a caller may name. not row rules, not
            predicates — so an agent&apos;s reach is a list you can read.
          </p>
        </div>
      </section>

      <footer className="flex flex-col items-center gap-3 border-t border-border px-6 py-10 text-sm text-muted-foreground sm:flex-row sm:justify-between sm:px-10">
        <Wordmark size="sm" className="opacity-70" />
        <p>blazie.dev</p>
      </footer>
    </>
  );
}
