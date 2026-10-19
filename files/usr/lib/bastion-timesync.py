"""Set the clock from the HTTPS Date headers of several independent web servers.

The idea is Kicksecure's sdwdate: no NTP, which is unauthenticated (or, with NTS, a protocol few
servers speak and a fingerprint of its own), just ordinary TLS connections to ordinary websites.
One server is picked at random from each pool, every answer is checked against the others, and
the clock only moves when enough of them agree.

What this does that sdwdate didn't:
  * Corrects for the request's round trip and the Date header's one-second truncation.
  * Needs a quorum that agrees within a tolerance, not a bare median of whatever answered.
  * Slews small offsets through adjtimex(2) instead of stepping the clock in a shell loop,
    and marks the kernel clock synchronised so the RTC follows it.
  * When the clock is so wrong that certificates look expired or not yet valid, it retries
    with the validity dates ignored (chain and hostname are still checked), and looks the
    servers up over DNS-over-HTTPS itself (to resolvers pinned by IP), since the system resolver has the same problem.
"""

from __future__ import annotations

import argparse
import base64
import ctypes
import email.utils
import http.client
import ipaddress
import json
import logging
import os
import random
import socket
import ssl
import statistics
import struct
import sys
import time
from dataclasses import dataclass

log = logging.getLogger("bastion-timesync")

# OpenSSL's X509_V_FLAG_NO_CHECK_TIME: verify the chain and name, skip the validity window.
NO_CHECK_TIME = 0x200000


@dataclass(frozen=True)
class Config:
    pools: list[list[str]]
    quorum: int
    tolerance: float
    step_threshold: float
    max_rtt: float
    timeout: float
    floor: int
    resolvers: list[str]

    @classmethod
    def load(cls, path: str) -> Config:
        with open(path, encoding="utf-8") as f:
            raw = json.load(f)
        cfg = cls(
            pools=[list(p) for p in raw["pools"]],
            quorum=int(raw["quorum"]),
            tolerance=float(raw["tolerance"]),
            step_threshold=float(raw["stepThreshold"]),
            max_rtt=float(raw["maxRtt"]),
            timeout=float(raw["timeout"]),
            floor=int(raw["floor"]),
            resolvers=list(raw.get("resolvers", [])),
        )
        if not 1 <= cfg.quorum <= len(cfg.pools):
            raise ValueError(f"quorum {cfg.quorum} needs between 1 and {len(cfg.pools)} pools")
        if any(not p for p in cfg.pools):
            raise ValueError("every pool needs at least one server")
        return cfg


@dataclass(frozen=True)
class Sample:
    server: str
    offset: float  # seconds to add to the local clock
    error: float  # half-width of the interval the true offset lies in


class CertTimeError(Exception):
    """The server's certificate was rejected only because of its validity dates."""


def split_host(server: str) -> tuple[str, int]:
    host, sep, port = server.rpartition(":")
    if sep and port.isdigit() and "]" not in port:
        return host.strip("[]"), int(port)
    return server, 443


# --- DNS-over-HTTPS fallback -------------------------------------------------------------------


def decode_stamp(stamp: str) -> tuple[str, int, str, str]:
    """(ip, port, tls hostname, path) from a DoH DNS stamp (sdns://, protocol 0x02)."""
    raw = base64.urlsafe_b64decode(stamp.removeprefix("sdns://") + "==")
    if raw[0] != 0x02:
        raise ValueError("not a DoH stamp")
    i = 9  # protocol byte + 8 bytes of properties

    def lp() -> bytes:
        nonlocal i
        n = raw[i]
        i += 1
        out = raw[i:i + n]
        i += n
        return out

    addr = lp().decode()
    while raw[i] & 0x80:  # certificate hashes: a VLP set, skipped
        i += 1 + (raw[i] & 0x7F)
    lp()
    host = lp().decode()
    path = lp().decode()
    ip, port = addr, 443
    if addr.startswith("["):
        ip, _, rest = addr[1:].partition("]")
        port = int(rest[1:]) if rest.startswith(":") else 443
    elif addr.count(":") == 1:
        ip, p = addr.split(":")
        port = int(p)
    return ip, port, host, path


# --- Just enough HTTP/2 for one DoH request -------------------------------------------------
# RFC 8484 section 5.2 lets a DoH server insist on HTTP/2, and Quad9 does: it answers every
# HTTP/1.1 request, GET or POST, with "505 HTTP Version Not Supported". http.client only speaks
# HTTP/1.1 and this file deliberately imports nothing outside the standard library, so the
# handful of frames a single request needs are written out here.
#
# This is not a general HTTP/2 client. One request goes out on one connection, on stream 1,
# and the connection is closed afterwards, which removes nearly all of the protocol: no
# multiplexing, no priorities, no server push, no flow-control accounting (a DNS query is tens
# of bytes and an answer a few hundred, against the 65535-byte window both ends start with).

H2_PREFACE = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
H2_DATA, H2_HEADERS, H2_RST_STREAM, H2_SETTINGS = 0, 1, 3, 4
H2_PING, H2_GOAWAY, H2_CONTINUATION = 6, 7, 9
H2_END_STREAM, H2_ACK, H2_END_HEADERS, H2_PADDED, H2_PRIORITY = 0x1, 0x1, 0x4, 0x8, 0x20

# HPACK (RFC 7541) static table entries this code names. 3 and 7 are whole header fields,
# the rest are names whose value is sent as a literal.
HPACK_POST, HPACK_HTTPS = 3, 7
HPACK_NAMES = {":authority": 1, ":path": 4, "content-length": 28, "accept": 19, "content-type": 31}
HPACK_STATUS = {8: 200, 9: 204, 10: 206, 11: 304, 12: 400, 13: 404, 14: 500}
# RFC 7541 appendix B, the ten digits only: a :status value is always three of them, and
# :status is the only field this decoder ever reads. Every digit's code starts with a 0 bit,
# so the all-ones padding at the end of a Huffman string can never look like one.
HPACK_HUFFMAN_DIGITS = {
    (5, 0x00): "0", (5, 0x01): "1", (5, 0x02): "2", (6, 0x19): "3", (6, 0x1A): "4",
    (6, 0x1B): "5", (6, 0x1C): "6", (6, 0x1D): "7", (6, 0x1E): "8", (6, 0x1F): "9",
}


def hpack_int(value: int, prefix: int, flags: int) -> bytes:
    """An HPACK integer in a prefix-bit field, under the given high-bit flags."""
    limit = (1 << prefix) - 1
    if value < limit:
        return bytes([flags | value])
    out = bytearray([flags | limit])
    value -= limit
    while value >= 0x80:
        out.append((value & 0x7F) | 0x80)
        value >>= 7
    out.append(value)
    return bytes(out)


def hpack_int_at(buf: bytes, i: int, prefix: int) -> tuple[int, int]:
    """Read an HPACK integer at buf[i]; returns it and the offset just past it."""
    limit = (1 << prefix) - 1
    value = buf[i] & limit
    i += 1
    if value < limit:
        return value, i
    shift = 0
    while True:
        if i >= len(buf):
            raise OSError("HTTP/2: header block ends inside an integer")
        byte = buf[i]
        i += 1
        value += (byte & 0x7F) << shift
        shift += 7
        if not byte & 0x80:
            return value, i


def hpack_str(buf: bytes, i: int, wanted: bool) -> tuple[str, int]:
    """Read an HPACK string at buf[i]. Unless wanted, step over it without interpreting it."""
    if i >= len(buf):
        raise OSError("HTTP/2: header block ends where a string should start")
    huffman = bool(buf[i] & 0x80)
    length, i = hpack_int_at(buf, i, 7)
    raw = buf[i:i + length]
    if len(raw) != length:
        raise OSError("HTTP/2: truncated header block")
    i += length
    if not wanted:
        return "", i
    if not huffman:
        return raw.decode("ascii", "replace"), i
    out, code, used = [], 0, 0
    for pos in range(length * 8 - 1, -1, -1):
        code = (code << 1) | ((raw[length - 1 - pos // 8] >> (pos % 8)) & 1)
        used += 1
        digit = HPACK_HUFFMAN_DIGITS.get((used, code))
        if digit is not None:
            out.append(digit)
            code, used = 0, 0
        elif used > 6:
            raise OSError("HTTP/2: :status is not a plain number")
    return "".join(out), i


def hpack_status(block: bytes) -> int:
    """The :status of a response header block.

    Only :status is decoded; every other field is stepped over without being interpreted, which
    is why no Huffman table beyond the digits is needed. The SETTINGS frame below pins the
    server's dynamic table to zero entries, so a reference outside the static table is a
    protocol error rather than something this has to keep state for. A server that spelled the
    name :status out as a literal instead of referring to the static table would read as
    "no :status" and fail; nothing does, because it is in the static table so nobody has to.
    """
    i, status = 0, None
    while i < len(block):
        byte = block[i]
        if byte & 0x80:  # wholly indexed field
            index, i = hpack_int_at(block, i, 7)
            if index == 0 or index > 61:
                raise OSError(f"HTTP/2: header index {index} is outside the static table")
            status = HPACK_STATUS.get(index, status)
            continue
        if byte & 0xE0 == 0x20:  # dynamic table size update
            _, i = hpack_int_at(block, i, 5)
            continue
        index, i = hpack_int_at(block, i, 6 if byte & 0xC0 == 0x40 else 4)
        if index > 61:
            raise OSError(f"HTTP/2: header name index {index} is outside the static table")
        if index == 0:
            _, i = hpack_str(block, i, False)
        # Static entries 8 to 14 are all named :status and differ only in the value they carry,
        # so a literal status may be written against any of them -- Cloudflare picks 14.
        is_status = index in HPACK_STATUS
        value, i = hpack_str(block, i, is_status)
        if is_status:
            status = int(value)
    if status is None:
        raise OSError("HTTP/2: response carried no :status")
    return status


def h2_frame(kind: int, flags: int, stream: int, payload: bytes = b"") -> bytes:
    return len(payload).to_bytes(3, "big") + bytes([kind, flags]) + stream.to_bytes(4, "big") + payload


def h2_body(kind: int, flags: int, payload: bytes) -> bytes:
    """A frame payload with its padding and priority fields removed."""
    i, pad = 0, 0
    if flags & H2_PADDED:
        pad, i = payload[0], 1
    if kind == H2_HEADERS and flags & H2_PRIORITY:
        i += 5
    if len(payload) - pad < i:
        raise OSError("HTTP/2: frame padding overruns the frame")
    return payload[i:len(payload) - pad]


def h2_post(ip: str, port: int, host: str, path: str, body: bytes,
            ctx: ssl.SSLContext, timeout: float) -> tuple[int, bytes]:
    """POST body to https://host:path, connecting to ip, over HTTP/2. Returns status and body."""
    sock = ctx.wrap_socket(socket.create_connection((ip, port), timeout=timeout), server_hostname=host)
    try:
        if sock.selected_alpn_protocol() != "h2":
            raise OSError(f"{host}: would not negotiate HTTP/2 over ALPN")
        head = bytearray(hpack_int(HPACK_POST, 7, 0x80) + hpack_int(HPACK_HTTPS, 7, 0x80))
        for name, text in ((":authority", host), (":path", path),
                           ("accept", "application/dns-message"),
                           ("content-type", "application/dns-message"),
                           ("content-length", str(len(body)))):
            # Literal, never added to the dynamic table, name from the static table, value in
            # plain ASCII: nothing here needs a Huffman encoder or any per-connection state.
            value = text.encode("ascii")
            head += hpack_int(HPACK_NAMES[name], 4, 0x00) + hpack_int(len(value), 7, 0x00) + value
        # HEADER_TABLE_SIZE 0 forbids the server the HPACK dynamic table, which is what lets
        # hpack_status get away with knowing only the static one; ENABLE_PUSH 0 refuses pushes.
        settings = struct.pack(">HIHI", 0x1, 0, 0x2, 0)
        opening = H2_PREFACE + h2_frame(H2_SETTINGS, 0, 0, settings)
        request = h2_frame(H2_HEADERS, H2_END_HEADERS, 1, bytes(head))
        request += h2_frame(H2_DATA, H2_END_STREAM, 1, body)
        sock.sendall(opening + request)
        stream = sock.makefile("rb")
        block, data, headers_done, done = b"", b"", False, False
        while not done:
            raw = stream.read(9)
            if len(raw) != 9:
                raise OSError(f"{host}: HTTP/2 connection closed mid-frame")
            size = int.from_bytes(raw[:3], "big")
            kind, flags, ident = raw[3], raw[4], int.from_bytes(raw[5:9], "big") & 0x7FFFFFFF
            payload = stream.read(size)
            if len(payload) != size:
                raise OSError(f"{host}: HTTP/2 frame shorter than its length")
            if kind == H2_SETTINGS and not flags & H2_ACK:
                sock.sendall(h2_frame(H2_SETTINGS, H2_ACK, 0))
            elif kind == H2_PING and not flags & H2_ACK:
                sock.sendall(h2_frame(H2_PING, H2_ACK, 0, payload))
            elif kind == H2_GOAWAY:
                code = int.from_bytes(payload[4:8], "big") if len(payload) >= 8 else 0
                raise OSError(f"{host}: HTTP/2 GOAWAY, error {code}")
            elif kind == H2_RST_STREAM and ident == 1:
                code = int.from_bytes(payload[:4], "big") if len(payload) >= 4 else 0
                raise OSError(f"{host}: HTTP/2 stream reset, error {code}")
            elif ident == 1 and kind in (H2_HEADERS, H2_CONTINUATION):
                # Trailers arrive as a second header block; the status is in the first.
                if not headers_done:
                    block += h2_body(kind, flags, payload)
                    headers_done = bool(flags & H2_END_HEADERS)
                done = bool(flags & H2_END_STREAM)
            elif ident == 1 and kind == H2_DATA:
                data += h2_body(kind, flags, payload)
                done = bool(flags & H2_END_STREAM)
        return hpack_status(block), data
    finally:
        sock.close()


def doh_query(stamp: str, name: str, ctx: ssl.SSLContext, timeout: float) -> list[str]:
    """A and AAAA records for name over DNS-over-HTTPS (RFC 8484), to the stamp's pinned IP.

    ctx decides how strictly certificates are checked, but the connection gets a context of its
    own: ALPN has to offer h2, and the caller reuses theirs for ordinary HTTP/1.1 requests.
    """
    ip, port, host, path = decode_stamp(stamp)
    h2ctx = tls_context(not ctx.verify_flags & NO_CHECK_TIME, alpn=["h2"])
    qname = b"".join(bytes([len(label)]) + label for label in name.rstrip(".").encode("idna").split(b"."))
    addrs: list[str] = []
    for qtype in (1, 28):
        msg = struct.pack(">HHHHHH", 0, 0x0100, 1, 0, 0, 0) + qname + b"\0" + struct.pack(">HH", qtype, 1)
        status, body = h2_post(ip, port, host, path or "/dns-query", msg, h2ctx, timeout)
        if status != 200:
            raise OSError(f"DoH {host}: HTTP {status}")
        addrs += parse_answers(body, 0, qtype)
    return addrs


def skip_name(msg: bytes, i: int) -> int:
    while True:
        n = msg[i]
        if n == 0:
            return i + 1
        if n & 0xC0 == 0xC0:
            return i + 2
        i += n + 1


def parse_answers(msg: bytes, qid: int, qtype: int) -> list[str]:
    rid, flags, qd, an, _, _ = struct.unpack(">HHHHHH", msg[:12])
    if rid != qid or flags & 0x8000 == 0 or flags & 0x000F:
        return []
    i = 12
    for _ in range(qd):
        i = skip_name(msg, i) + 4
    out = []
    for _ in range(an):
        i = skip_name(msg, i)
        rtype, _, _, rdlen = struct.unpack(">HHIH", msg[i:i + 10])
        i += 10
        if rtype == qtype and rdlen in (4, 16):
            out.append(str(ipaddress.ip_address(msg[i:i + rdlen])))
        i += rdlen
    return out


# --- HTTPS Date ----------------------------------------------------------------------------------


def tls_context(check_time: bool, alpn: list[str] | None = None) -> ssl.SSLContext:
    ctx = ssl.create_default_context()
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    if not check_time:
        ctx.verify_flags |= NO_CHECK_TIME
    if alpn:
        ctx.set_alpn_protocols(alpn)
    return ctx


def query(server: str, cfg: Config, check_time: bool) -> Sample:
    host, port = split_host(server)
    ctx = tls_context(check_time)
    addr = host
    if not check_time and cfg.resolvers:
        # The system resolver validates certificates against the same wrong clock.
        resolver = random.SystemRandom().choice(cfg.resolvers)
        found = doh_query(resolver, host, ctx, cfg.timeout)
        if not found:
            raise OSError(f"no address for {host} from {resolver}")
        addr = found[0]
    conn = http.client.HTTPSConnection(host, port, timeout=cfg.timeout, context=ctx)
    try:
        if addr != host:
            conn.sock = ctx.wrap_socket(
                socket.create_connection((addr, port), timeout=cfg.timeout), server_hostname=host
            )
        else:
            conn.connect()
    except ssl.SSLCertVerificationError as e:
        conn.close()
        if e.verify_code in (9, 10):  # X509_V_ERR_CERT_NOT_YET_VALID, X509_V_ERR_CERT_HAS_EXPIRED
            raise CertTimeError(f"{server}: {e.verify_message}") from e
        raise
    try:
        # Timed from just before the request to the end of the headers; the handshake is excluded.
        t0 = time.time()
        conn.request("HEAD", "/", headers={"User-Agent": "Mozilla/5.0", "Accept": "*/*"})
        resp = conn.getresponse()
        t1 = time.time()
        date = resp.getheader("Date")
    finally:
        conn.close()
    if not date:
        raise ValueError(f"{server}: no Date header")
    rtt = t1 - t0
    if rtt > cfg.max_rtt:
        raise ValueError(f"{server}: round trip {rtt:.2f}s is over {cfg.max_rtt}s")
    remote = email.utils.parsedate_to_datetime(date).timestamp()
    # Date is truncated to the second, so the server's clock read somewhere in [remote, remote+1).
    return Sample(server, remote + 0.5 - (t0 + t1) / 2, 0.5 + rtt / 2)


def sample_pool(pool: list[str], cfg: Config, check_time: bool) -> tuple[Sample | None, bool]:
    """Try the pool's servers in random order until one answers. Second value: saw a cert time error."""
    order = pool[:]
    random.SystemRandom().shuffle(order)
    time_error = False
    for server in order:
        try:
            s = query(server, cfg, check_time)
            log.info("%s: offset %+.3fs (±%.3fs)", server, s.offset, s.error)
            return s, time_error
        except CertTimeError as e:
            time_error = True
            log.warning("%s", e)
        except (OSError, ValueError, http.client.HTTPException, ssl.SSLError) as e:
            log.warning("%s: %s", server, e)
    return None, time_error


def agree(samples: list[Sample], quorum: int, tolerance: float) -> float | None:
    """Offset that at least quorum samples agree on, or None.

    A sample agrees with a candidate offset when their intervals, widened by tolerance, overlap.
    The answer is the median of the largest agreeing group, so one lying or broken server can
    neither move the clock nor block an update while the others agree.
    """
    best: list[Sample] = []
    for c in samples:
        group = [s for s in samples if abs(s.offset - c.offset) <= s.error + c.error + tolerance]
        if len(group) > len(best):
            best = group
    if len(best) < quorum:
        return None
    return statistics.median(s.offset for s in best)


def collect(cfg: Config) -> list[Sample]:
    pools = cfg.pools[:]
    random.SystemRandom().shuffle(pools)
    results = [sample_pool(p, cfg, check_time=True) for p in pools]
    samples = [s for s, _ in results if s]
    if len(samples) < cfg.quorum and any(t for _, t in results):
        log.warning("certificates look expired or not yet valid, so the clock is probably far off; "
                    "retrying with certificate dates ignored (chain and hostname still checked)")
        samples = [s for s in (sample_pool(p, cfg, check_time=False)[0] for p in pools) if s]
    return samples


# --- Setting the clock ---------------------------------------------------------------------------


class Timex(ctypes.Structure):
    """struct timex from <sys/timex.h> (Linux, 64-bit time)."""

    _fields_ = [
        ("modes", ctypes.c_uint),
        ("offset", ctypes.c_long),
        ("freq", ctypes.c_long),
        ("maxerror", ctypes.c_long),
        ("esterror", ctypes.c_long),
        ("status", ctypes.c_int),
        ("constant", ctypes.c_long),
        ("precision", ctypes.c_long),
        ("tolerance", ctypes.c_long),
        ("time_sec", ctypes.c_long),
        ("time_usec", ctypes.c_long),
        ("tick", ctypes.c_long),
        ("ppsfreq", ctypes.c_long),
        ("jitter", ctypes.c_long),
        ("shift", ctypes.c_int),
        ("stabil", ctypes.c_long),
        ("jitcnt", ctypes.c_long),
        ("calcnt", ctypes.c_long),
        ("errcnt", ctypes.c_long),
        ("stbcnt", ctypes.c_long),
        ("tai", ctypes.c_int),
        ("_pad", ctypes.c_int * 11),
    ]


ADJ_OFFSET_SINGLESHOT = 0x8001  # adjtime(3)-style slew of `offset` microseconds
ADJ_MAXERROR = 0x0004
ADJ_ESTERROR = 0x0008
ADJ_STATUS = 0x0010
STA_UNSYNC = 0x0040

_libc = ctypes.CDLL(None, use_errno=True)  # libc is already loaded into the interpreter


def adjtimex(tx: Timex) -> None:
    if _libc.adjtimex(ctypes.byref(tx)) < 0:
        err = ctypes.get_errno()
        raise OSError(err, f"adjtimex: {os.strerror(err)}")


def apply(offset: float, error: float, cfg: Config, dry_run: bool) -> None:
    target = time.time() + offset
    if target < cfg.floor:
        raise ValueError(f"refusing to set the clock to {time.ctime(target)}, before this build")
    remaining = 0.0  # what is still off once this returns
    if abs(offset) >= cfg.step_threshold:
        log.info("stepping the clock by %+.3fs", offset)
        if not dry_run:
            time.clock_settime(time.CLOCK_REALTIME, time.time() + offset)
    elif abs(offset) > error:
        # The kernel slews at 500 ppm: half a second takes about 17 minutes, with no jump.
        log.info("slewing the clock by %+.3fs", offset)
        remaining = abs(offset)
        if not dry_run:
            adjtimex(Timex(modes=ADJ_OFFSET_SINGLESHOT, offset=round(offset * 1e6)))
    else:
        log.info("clock is within %.3fs, leaving it alone", error)
    if not dry_run:
        # Tell the kernel the clock is synchronised: timedatectl shows it, and the kernel keeps
        # the RTC in step. The kernel grows maxerror by itself and drops the flag if we stop.
        us = round((error + remaining) * 1e6)
        adjtimex(Timex(modes=ADJ_STATUS | ADJ_MAXERROR | ADJ_ESTERROR, status=0, maxerror=us, esterror=us))


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--config", required=True)
    ap.add_argument("--dry-run", action="store_true", help="report the offset, change nothing")
    args = ap.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(message)s")

    cfg = Config.load(args.config)
    samples = collect(cfg)
    offset = agree(samples, cfg.quorum, cfg.tolerance)
    if offset is None:
        log.error("no agreement: %d of %d pools answered, %d needed within %.1fs of each other",
                  len(samples), len(cfg.pools), cfg.quorum, cfg.tolerance)
        return 1
    error = max(s.error for s in samples)
    log.info("agreed offset %+.3fs from %d servers", offset, len(samples))
    apply(offset, error, cfg, args.dry_run)
    return 0


if __name__ == "__main__":
    sys.exit(main())
