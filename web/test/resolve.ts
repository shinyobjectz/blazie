/**
 * Let node resolve the extensionless imports the bundlers already resolve.
 *
 * `lib/control/*` imports `./model` rather than `./model.ts`, which is what
 * Next and wrangler expect and what node's ESM resolver refuses. Rather than put
 * extensions through the source to suit the test runner — changing shipped code
 * to make a test run is how a test stops testing what ships — the runner is
 * taught the same rule the bundlers use.
 */

import { existsSync } from "node:fs"
import { fileURLToPath } from "node:url"

export async function resolve(
  specifier: string,
  context: { parentURL?: string },
  next: (s: string, c: unknown) => Promise<unknown>,
) {
  if (specifier.startsWith(".") && !/\.[a-z]+$/.test(specifier)) {
    const guess = new URL(`${specifier}.ts`, context.parentURL)

    if (existsSync(fileURLToPath(guess))) {
      return next(`${specifier}.ts`, context)
    }
  }

  return next(specifier, context)
}
