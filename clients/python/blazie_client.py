"""A blazie cluster, from the outside, in Python.

Thin on purpose: the cluster's surface is three routes — run Lua against a
world, claim a world, ask who you are — and this speaks exactly those.
Anything cleverer belongs on the cluster, where it can be checked; a fat
client is a second implementation of the rules that drifts from the first.

Names, and what may be cached: a run pinned to a ``name`` answers the same
forever, **or erased** — erasure is the one event that changes what an old
name answers. So the client caches pinned runs on ``(name, source)`` when
given a cache, and ``Cache.flush()`` exists because flushing outside caches
after an erasure is the deployment's job: the cluster cannot reach a copy it
never knew was taken. An unpinned run reads *now* and is never cached.

Refusals arrive as ``Refused`` carrying the cluster's own ``problem`` and
``repair`` — passed through rather than translated, because the repair is
written for whoever is going to act on it.

Standard library only. A checkpointing agent should not have to solve
dependency resolution before it can save its own state.

    client = Client("https://demo.blazie.dev", token)
    answer = client.run("return 1 + 1", world="main")
    pinned = client.run(source, world="main", name=answer["name"], cache=cache)
"""

from __future__ import annotations

import json
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from typing import Any, Optional


class Refused(Exception):
    """The cluster said no, and said how to comply."""

    def __init__(self, problem: str, repair: str):
        self.problem = problem
        self.repair = repair
        super().__init__(f"{problem}: {repair}")


class Unreachable(Refused):
    """Nothing answered. Not a refusal from the cluster — there was none."""

    def __init__(self, address: str, why: str):
        super().__init__(
            "unreachable",
            f"Nothing answered at {address}: {why}. If the cluster was opened "
            "moments ago it may still be installing.",
        )


@dataclass
class Cache:
    """Pinned answers, held until somebody decides otherwise.

    ``flush()`` is the erasure caveat made operable: an answer at a name is
    the same answer forever or erased, and after an erasure the copies out
    here are the deployment's to flush.
    """

    held: dict = field(default_factory=dict)

    def get(self, name: Any, source: str) -> Optional[dict]:
        return self.held.get((_frozen(name), source))

    def put(self, name: Any, source: str, answer: dict) -> None:
        self.held[(_frozen(name), source)] = answer

    def flush(self) -> None:
        self.held.clear()


def _frozen(name: Any) -> Any:
    """A snapshot name is a dict on the wire and a dict cannot key a dict."""
    if isinstance(name, dict):
        return tuple(sorted(name.items()))
    return name


class Client:
    def __init__(self, address: str, token: str, timeout: float = 30.0):
        self.address = address.rstrip("/")
        self.token = token
        self.timeout = timeout

    def run(
        self,
        source: str,
        *,
        world: str,
        also: Optional[list] = None,
        name: Optional[dict] = None,
        as_job: bool = False,
        cache: Optional[Cache] = None,
    ) -> dict:
        """Run Lua against a world. Answers the cluster's own shape:
        ``{"value": ..., "name": {...}, "wrote": n}``."""
        if cache is not None and name is not None:
            kept = cache.get(name, source)
            if kept is not None:
                return kept

        body = {"world": world, "source": source}
        if also:
            body["also"] = also
        if name is not None:
            body["name"] = name
        if as_job:
            body["as"] = "job"

        answer = self._post("/run", body)

        if cache is not None and name is not None:
            cache.put(name, source, answer)

        return answer

    def claim(self, world: str) -> dict:
        """Claim a world name and hold it. First-come; a taken name refuses."""
        return self._post("/worlds", {"world": world})

    def me(self) -> dict:
        """Who this token is, and which worlds it may name."""
        return self._request("GET", "/me", None)

    # ── the wire ──────────────────────────────────────────────────────────

    def _post(self, path: str, body: dict) -> dict:
        return self._request("POST", path, body)

    def _request(self, method: str, path: str, body: Optional[dict]) -> dict:
        request = urllib.request.Request(
            self.address + path,
            data=None if body is None else json.dumps(body).encode(),
            method=method,
            headers={
                "authorization": f"Bearer {self.token}",
                "content-type": "application/json",
                "accept": "application/json",
            },
        )

        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as answered:
                return self._answered(answered.status, answered.read())
        except urllib.error.HTTPError as refused:
            # A refusal is an ANSWER — 422 with the repair in the body — and
            # urllib reports it as an error. Read it anyway.
            return self._answered(refused.code, refused.read())
        except (urllib.error.URLError, OSError) as why:
            raise Unreachable(self.address, str(why)) from None

    def _answered(self, status: int, body: bytes) -> dict:
        try:
            decoded = json.loads(body)
        except ValueError:
            raise Refused(
                "not_a_cluster",
                f"{status} with a body that is not a blazie answer. Check the "
                "address points at a cluster.",
            ) from None

        error = decoded.get("error") if isinstance(decoded, dict) else None
        if error:
            raise Refused(
                error.get("problem", "refused"),
                error.get("repair", "No repair was given."),
            )

        if 200 <= status < 300:
            return decoded

        raise Refused("refused", f"{status} without saying how to comply.")
