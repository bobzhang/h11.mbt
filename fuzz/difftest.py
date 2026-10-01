#!/usr/bin/env python3
"""Differential fuzzing: MoonBit h11 vs Python h11.

Generates random byte streams (valid messages, mutated messages, and
HTTP-flavoured garbage), runs the same deterministic script against Python
h11 (from ../.repos/h11) and the MoonBit port (fuzz/difftest), and reports
any case where the traces differ.

Usage:
    python3 fuzz/difftest.py [--cases N] [--seed S] [--ignore-chunk-start]

Requires `moon` and a clone of python-hyper/h11 in .repos/h11.
"""

import argparse
import os
import random
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, ".repos", "h11"))

import h11  # noqa: E402

TCHARS = b"!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
VCHARS = bytes(range(0x21, 0x7F))


# ---------------------------------------------------------------- the script
# Keep this in sync with run_case in fuzz/difftest/main.mbt.


def fmt_headers(headers):
    return " ".join(f"{n.hex()}={v.hex()}" for n, v in headers.raw_items())


def fmt_event(e):
    t = type(e)
    if t is h11.Request:
        return f"REQ {e.method.hex()} {e.target.hex()} {e.http_version.hex()} {fmt_headers(e.headers)}"
    if t is h11.InformationalResponse:
        return f"INFO {e.status_code} {e.http_version.hex()} {e.reason.hex()} {fmt_headers(e.headers)}"
    if t is h11.Response:
        return f"RESP {e.status_code} {e.http_version.hex()} {e.reason.hex()} {fmt_headers(e.headers)}"
    if t is h11.Data:
        return f"DATA {bytes(e.data).hex()} {int(e.chunk_start)}{int(e.chunk_end)}"
    if t is h11.EndOfMessage:
        return f"EOM {fmt_headers(e.headers)}"
    if t is h11.ConnectionClosed:
        return "CLOSED"
    raise AssertionError(e)


_BYTEARRAY_RE = re.compile(r"""bytearray\((b'(?:[^'\\]|\\.)*'|b"(?:[^"\\]|\\.)*")\)""")


def _unwrap_bytearray(m):
    # repr(bytearray) also escapes ' inside a double-quoted literal, unlike
    # repr(bytes); undo that so the two reprs coincide.
    lit = m.group(1)
    if lit.startswith('b"'):
        lit = re.sub(r"(?<!\\)((?:\\\\)*)\\'", r"\1'", lit)
    return lit


def protocol_message(e):
    # Python quotes received data as bytearray(b'...'); MoonBit as b'...'.
    msg = _BYTEARRAY_RE.sub(_unwrap_bytearray, str(e))
    if isinstance(e, h11.LocalProtocolError):
        return f"Local {e.error_status_hint} {msg}"
    if isinstance(e, h11.RemoteProtocolError):
        return f"Remote {e.error_status_hint} {msg}"
    return f"Other {type(e).__name__}: {e}"


def run_case(role, chunks):
    out = []
    conn = h11.Connection(role)
    if role is h11.CLIENT:
        conn.send(h11.Request(method=b"GET", target=b"/", headers=[(b"Host", b"x")]))
        conn.send(h11.EndOfMessage())

    def respond():
        if role is not h11.SERVER:
            return False
        progressed = False
        if conn.our_state is h11.SEND_RESPONSE and conn.their_state in (
            h11.DONE,
            h11.MUST_CLOSE,
            h11.CLOSED,
            h11.MIGHT_SWITCH_PROTOCOL,
        ):
            try:
                resp = h11.Response(status_code=200, headers=[(b"Content-Length", b"0")])
                sent = conn.send(resp) + conn.send(h11.EndOfMessage())
            except Exception as e:  # noqa: BLE001
                out.append(f"SENDERR {protocol_message(e)}")
                return False
            out.append(f"SENT {sent.hex()}")
            progressed = True
        if conn.our_state is h11.DONE and conn.their_state is h11.DONE:
            conn.start_next_cycle()
            out.append("CYCLE")
            progressed = True
        return progressed

    i = 0
    eof = False
    for _ in range(200):
        try:
            ev = conn.next_event()
        except Exception as e:  # noqa: BLE001
            out.append(f"ERR {protocol_message(e)}")
            break
        if ev is h11.NEED_DATA:
            if i < len(chunks):
                conn.receive_data(chunks[i])
                i += 1
            elif not eof:
                conn.receive_data(b"")
                eof = True
            else:
                out.append("STUCK")
                break
            continue
        if ev is h11.PAUSED:
            out.append("PAUSED")
            if not respond():
                break
            continue
        out.append(fmt_event(ev))
        if type(ev) is h11.ConnectionClosed:
            break
        respond()
    states = conn.states
    out.append(f"STATES {states[h11.CLIENT]} {states[h11.SERVER]}")
    return out


# ---------------------------------------------------------------- generators


def rbytes(rng, alphabet, lo, hi):
    return bytes(rng.choice(alphabet) for _ in range(rng.randint(lo, hi)))


def header_value(rng):
    field_vchars = bytes(b for b in range(256) if b not in b"\x00 \t\n\r\x0b\x0c")
    words = [rbytes(rng, field_vchars, 1, 5) for _ in range(rng.randint(0, 3))]
    return rng.choice([b" ", b"\t", b" \t "]).join(words)


def random_header(rng):
    name = rng.choice(
        [
            rbytes(rng, TCHARS, 1, 8),
            b"Host",
            b"Content-Length",
            b"Transfer-Encoding",
            b"Connection",
            b"Upgrade",
            b"Expect",
        ]
    )
    lname = name.lower()
    if lname == b"content-length":
        value = rng.choice([b"0", b"5", b"10", str(rng.randint(0, 40)).encode(), b"3, 3", b"x", b"99999999999999999999"])
    elif lname == b"transfer-encoding":
        value = rng.choice([b"chunked", b"Chunked", b"gzip", b"chunked, gzip"])
    elif lname == b"connection":
        value = rng.choice([b"close", b"keep-alive", b"Upgrade", b"close, upgrade"])
    elif lname == b"upgrade":
        value = rng.choice([b"websocket", b"h2c"])
    elif lname == b"expect":
        value = rng.choice([b"100-continue", b"100-Continue", b"nothing"])
    else:
        value = header_value(rng)
    return name + rng.choice([b": ", b":", b":  ", b" : ", b":\t"]) + value


def chunked_body(rng):
    out = b""
    for _ in range(rng.randint(0, 3)):
        data = rbytes(rng, range(256), 1, 20)
        size = format(len(data), rng.choice(["x", "X"])).encode()
        ext = rng.choice([b"", b"", b";a=b", b"; x", b"  "])
        out += size + ext + b"\r\n" + data + b"\r\n"
    out += b"0" + rng.choice([b"", b";e"]) + b"\r\n"
    if rng.random() < 0.3:
        out += random_header(rng) + b"\r\n"
    return out + b"\r\n"


def valid_request(rng):
    method = rng.choice([b"GET", b"POST", b"HEAD", b"PUT", b"CONNECT", b"OPTIONS", rbytes(rng, TCHARS, 1, 6)])
    target = rng.choice([b"/", b"/" + rbytes(rng, VCHARS, 0, 12), b"example.com:443", b"*"])
    version = rng.choice([b"1.1", b"1.1", b"1.1", b"1.0"])
    lines = [method + b" " + target + b" HTTP/" + version]
    if version == b"1.1" or rng.random() < 0.5:
        lines.append(b"Host: example.com")
    body = b""
    mode = rng.choice(["none", "cl", "chunked"])
    if mode == "cl":
        body = rbytes(rng, range(256), 0, 30)
        lines.append(b"Content-Length: " + str(len(body)).encode())
    elif mode == "chunked":
        lines.append(b"Transfer-Encoding: chunked")
        body = chunked_body(rng)
    for _ in range(rng.randint(0, 3)):
        lines.append(random_header(rng))
    eol = rng.choice([b"\r\n", b"\r\n", b"\n"])
    return eol.join(lines) + eol + eol + body


def valid_response(rng):
    status = rng.choice([100, 101, 200, 204, 304, 404, 500, rng.randint(100, 999)])
    version = rng.choice([b"1.1", b"1.0"])
    line = b"HTTP/" + version + b" " + str(status).encode()
    if rng.random() < 0.8:
        line += b" " + rbytes(rng, VCHARS + b" \t", 0, 10)
    lines = [line]
    body = b""
    mode = rng.choice(["none", "cl", "chunked", "close"])
    if mode == "cl":
        body = rbytes(rng, range(256), 0, 30)
        lines.append(b"Content-Length: " + str(len(body)).encode())
    elif mode == "chunked":
        lines.append(b"Transfer-Encoding: chunked")
        body = chunked_body(rng)
    elif mode == "close":
        body = rbytes(rng, range(256), 0, 30)
    for _ in range(rng.randint(0, 3)):
        lines.append(random_header(rng))
    head = b"\r\n".join(lines) + b"\r\n\r\n"
    return head + body


def mutate(rng, data):
    data = bytearray(data)
    for _ in range(rng.randint(1, 4)):
        op = rng.choice(["flip", "insert", "delete", "dup"])
        pos = rng.randint(0, len(data)) if data else 0
        if op == "flip" and data:
            pos = min(pos, len(data) - 1)
            data[pos] = rng.choice([rng.randrange(256), 0x20, 0x0D, 0x0A, 0x3A, 0x00, 0x09])
        elif op == "insert":
            data[pos:pos] = rng.choice([b"\r\n", b" ", b":", b"\x00", bytes([rng.randrange(256)]), b"0\r\n"])
        elif op == "delete" and data:
            del data[pos : pos + rng.randint(1, 3)]
        elif op == "dup" and data:
            end = min(len(data), pos + rng.randint(1, 10))
            data[pos:pos] = data[pos:end]
    return bytes(data)


GARBAGE_TOKENS = [
    b"GET ", b"POST ", b"/", b" HTTP/1.1", b" HTTP/1.0", b"HTTP/1.1 ", b"200", b" OK",
    b"101", b"\r\n", b"\n", b"\r", b": ", b":", b" ", b"\t", b"Host", b"Content-Length",
    b"Transfer-Encoding", b"chunked", b"Connection", b"close", b"Upgrade", b"Expect",
    b"100-continue", b"0", b"5", b"a", b"ffffffff", b";ext", b"\x00", b"\x16\x03",
    b"\xff", b"12345", b"x",
]


def gen_case(rng):
    role = rng.choice(["S", "S", "C"])
    make = valid_request if role == "S" else valid_response
    kind = rng.random()
    if kind < 0.3:
        data = b"".join(make(rng) for _ in range(rng.randint(1, 3)))
    elif kind < 0.8:
        data = mutate(rng, b"".join(make(rng) for _ in range(rng.randint(1, 2))))
    else:
        data = b"".join(rng.choice(GARBAGE_TOKENS) for _ in range(rng.randint(0, 30)))
        if role == "C" and rng.random() < 0.7:
            data = b"HTTP/1.1 200 OK\r\n" + data
    # fragment
    cuts = sorted(set(rng.randint(1, max(1, len(data) - 1)) for _ in range(rng.randint(0, 6))))
    chunks, start = [], 0
    for c in cuts:
        if start < c < len(data):
            chunks.append(data[start:c])
            start = c
    if start < len(data):
        chunks.append(data[start:])
    return role, chunks


# ---------------------------------------------------------------- comparison


def build_moonbit():
    subprocess.run(["moon", "build", "--release"], cwd=HERE, check=True, capture_output=True)
    exe = os.path.join(HERE, "_build", "native", "release", "build", "difftest", "difftest.exe")
    assert os.path.exists(exe), exe
    return exe


def normalize(line, ignore_chunk_start):
    if ignore_chunk_start and line.startswith("DATA "):
        return line[:-2] + "?" + line[-1]
    return line


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cases", type=int, default=20000)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--ignore-chunk-start", action="store_true",
                    help="don't compare Data.chunk_start (MoonBit fixes an h11 bug there)")
    ap.add_argument("--show", type=int, default=5, help="divergences to print")
    args = ap.parse_args()

    rng = random.Random(args.seed)
    cases = [gen_case(rng) for _ in range(args.cases)]
    batch = os.path.join(HERE, "_build", "difftest_cases.txt")
    os.makedirs(os.path.dirname(batch), exist_ok=True)
    with open(batch, "w") as f:
        for role, chunks in cases:
            f.write(role + " " + ",".join(c.hex() for c in chunks) + "\n")

    exe = build_moonbit()
    proc = subprocess.run([exe, batch], capture_output=True, text=True)
    mbt_traces, cur = [], []
    for line in proc.stdout.splitlines():
        if line == "END":
            mbt_traces.append(cur)
            cur = []
        else:
            cur.append(line)
    if proc.returncode != 0:
        role, chunks = cases[len(mbt_traces)]
        print(f"MoonBit driver crashed on case {len(mbt_traces)}: role={role} chunks={chunks!r}")
        print(proc.stderr[-2000:])
        sys.exit(1)

    divergences = 0
    for idx, ((role, chunks), mbt) in enumerate(zip(cases, mbt_traces)):
        py = run_case(h11.CLIENT if role == "C" else h11.SERVER, chunks)
        a = [normalize(l, args.ignore_chunk_start) for l in py]
        b = [normalize(l, args.ignore_chunk_start) for l in mbt]
        if a != b:
            divergences += 1
            if divergences <= args.show:
                print(f"--- case {idx}: role={role} input={b''.join(chunks)!r} chunks={len(chunks)}")
                for x, y in zip(a + [""] * len(b), b + [""] * len(a)):
                    if not x and not y:
                        break
                    mark = "  " if x == y else "!!"
                    print(f"{mark} py : {x}")
                    if x != y:
                        print(f"{mark} mbt: {y}")
    print(f"{len(cases)} cases, {divergences} divergences")
    sys.exit(1 if divergences else 0)


if __name__ == "__main__":
    main()
