"""The Python client, over a real wire.

Driven from blazie's own suite (test/client_python_test.exs), which starts a
real listener and hands this script the address and a token — so the SDK and
the surface cannot drift apart unnoticed. Prints the failures it finds;
prints nothing but 'ok' when there are none.
"""

import sys
import uuid

from blazie_client import Cache, Client, Refused, Unreachable


def main(address: str, token: str) -> int:
    client = Client(address, token)
    world = f"py-world-{uuid.uuid4().hex[:8]}"

    # Claim, write, read back — a chunk reads its snapshot, so the write and
    # its read-back are two runs.
    claimed = client.claim(world)
    assert claimed["world"] == world, claimed

    wrote = client.run("ada.height = 180", world=world)
    assert wrote["wrote"] > 0, wrote
    name = wrote["name"]

    read = client.run("return ada.height", world=world)
    assert read["value"] == 180, read

    assert world in client.me()["worlds"]

    # A pinned answer is cached; the same ask never touches the wire twice.
    cache = Cache()
    first = client.run("return ada.height", world=world, name=name, cache=cache)
    assert first["value"] == 180

    broken = Client("http://127.0.0.1:1", token, timeout=0.5)
    again = broken.run("return ada.height", world=world, name=name, cache=cache)
    assert again == first, "the cache did not answer for a dead wire"

    # Flushed, the wire is the only source again — and this wire is dead.
    cache.flush()
    try:
        broken.run("return ada.height", world=world, name=name, cache=cache)
        return fail("a flushed cache still answered")
    except Unreachable:
        pass

    # A refusal crosses with its repair intact.
    intruder = Client(address, f"intruder-{uuid.uuid4().hex}")
    try:
        intruder.run("return 1", world=world)
        return fail("an intruder was answered")
    except Refused as refused:
        assert len(refused.repair) > 30, refused

    print("ok")
    return 0


def fail(reason: str) -> int:
    print(f"FAILED: {reason}")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))
