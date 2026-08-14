/**
 * Watch a chunk, and be told when its answer changes.
 *
 * The browser opens an EventSource here; this opens a websocket to the cluster
 * and pipes what arrives back down as events. Nothing about the cluster's
 * credential leaves the control plane, which is the same reason `run` is
 * proxied — see `lib/control/phoenix.ts` for why this shape and not the two
 * cheaper ones.
 */

import { refuse, unauthenticated } from "@/lib/control/answer"
import { one, presenting } from "@/lib/control/clusters"
import type { Control } from "@/lib/control/model"
import {
  HEARTBEAT_MS,
  event,
  heartbeat,
  joining,
  readFrame,
  socketUrl,
} from "@/lib/control/phoenix"
import { whoIs } from "@/lib/control/session"

export const onRequestGet: PagesFunction<Control> = async ({ env, request, params }) => {
  const session = await whoIs(env, request)
  if (!session) return unauthenticated()

  const cluster = await one(env, session.login, String(params.id))
  if (!cluster) return refuse("no_such_cluster", "You hold no cluster with that id.", 404)

  const asked = new URL(request.url).searchParams
  const world = asked.get("world")
  const source = asked.get("source")

  if (!world || !source) {
    return refuse("incomplete", "Watching needs `world` and `source`: where, and the Lua to keep answering.", 400)
  }

  const token = presenting(cluster, asked.get("studio"))

  if (!token) {
    return refuse("no_such_studio", `${cluster.name} holds no studio with that id.`, 404)
  }

  let upstream: Response

  try {
    upstream = await fetch(socketUrl(cluster.address, token), {
      headers: { Upgrade: "websocket" },
    })
  } catch {
    return refuse("unreachable", `${cluster.name} did not answer.`, 502)
  }

  const socket = upstream.webSocket

  if (!socket) {
    return refuse(
      "no_socket",
      `${cluster.name} answered ${upstream.status} to a websocket upgrade. A cluster that cannot be watched is usually one that is still opening.`,
      502,
    )
  }

  socket.accept()

  const topic = `watch:${crypto.randomUUID()}`
  const out = new TextEncoder()

  const stream = new ReadableStream({
    start(controller) {
      let beat = 2

      // Phoenix drops a socket that stops talking, so this is not optional. It
      // is started below and cleared here, and `close` is declared first
      // because both the socket's own events and the stream's cancel reach it.
      const beating = setInterval(() => {
        try {
          socket.send(heartbeat(beat++))
        } catch {
          close()
        }
      }, HEARTBEAT_MS) as unknown as number

      const close = () => {
        clearInterval(beating)
        try {
          controller.close()
        } catch {
          // Already closed, which is one of the two ways this ends.
        }
      }

      socket.addEventListener("message", (said) => {
        const frame = readFrame(String(said.data))
        if (!frame) return

        const [, , at, name, payload] = frame

        // The chunk answered again, because something it read moved. This is
        // the whole point of the endpoint.
        if (at === topic && name === "answer") {
          controller.enqueue(out.encode(event("answer", payload)))
          return
        }

        // The join was refused — a world this caller may not name, or Lua that
        // will not compile. Passed through with its repair rather than becoming
        // a closed connection the browser has to guess about.
        if (at === topic && name === "phx_reply") {
          const reply = payload as { status?: string; response?: unknown }

          if (reply?.status === "error") {
            controller.enqueue(out.encode(event("refused", reply.response)))
            close()
            return
          }

          controller.enqueue(out.encode(event("watching", { world, topic })))
        }
      })

      socket.addEventListener("close", () => {
        controller.enqueue(out.encode(event("ended", { why: "the cluster closed the socket" })))
        close()
      })

      socket.addEventListener("error", () => {
        controller.enqueue(out.encode(event("ended", { why: "the socket errored" })))
        close()
      })

      socket.send(joining(topic, world, source))
    },

    cancel() {
      // The browser navigated away. Let the cluster stop answering rather than
      // leaving it re-running a chunk for nobody.
      try {
        socket.close(1000, "the watcher went away")
      } catch {
        // Already gone.
      }
    },
  })

  return new Response(stream, {
    headers: {
      "content-type": "text/event-stream",
      "cache-control": "no-cache",
      // Nothing between here and the browser should buffer a stream whose
      // entire value is that it arrives when it happens.
      "x-accel-buffering": "no",
    },
  })
}
