import { GradientBackground } from "@/components/ui/paper-design-shader-background";
import { Wordmark } from "@/components/ui/wordmark";

/**
 * The README banner, rendered rather than drawn.
 *
 * It exists as a route so the image can be regenerated from the same shader and
 * the same wordmark the site uses — a banner exported once from a design tool
 * is a second source that drifts the moment the palette moves.
 *
 * Capture it at 2400×840 and downsample; see `just banner` in the repo root.
 */
export default function Banner() {
  return (
    <main className="relative flex h-screen w-full items-center justify-center overflow-hidden">
      <GradientBackground />
      <div className="absolute inset-0 -z-10 bg-black/35" />

      <section className="px-6 text-center">
        <Wordmark size="lg" className="mb-6 scale-125 justify-center" />
        <p className="text-2xl font-medium tracking-tight text-white sm:text-3xl">
          the backend agents run on
        </p>
        <p className="mt-4 font-mono text-sm text-white/60">blazie.dev</p>
      </section>
    </main>
  );
}
