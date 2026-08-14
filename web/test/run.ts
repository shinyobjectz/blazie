/** Registers the resolver, then runs. Kept apart so `--import` stays one flag. */
import { register } from "node:module"

register("./resolve.ts", import.meta.url)
