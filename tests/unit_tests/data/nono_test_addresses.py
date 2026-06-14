#!/usr/bin/env python3
"""
Generate deterministic NONO base58 addresses for use as test fixtures.

Each address starts with 'N' because NONO mainnet prefixes (127 / 128 / 129
for standard / integrated / subaddress) all live in the {126,127,128,129,130}
band that maps to base58 first-char index 21 = 'N' under the Cryptonote
alphabet "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".

The spend and view pubkeys are NUMS points derived deterministically from
a public seed via try-and-decode:

    spend_pub(label) = first 32-byte SHA-256("NONO_TEST_FIXTURE:<label>:spend:<i>")
                      that decodes as a valid Ed25519 point
    view_pub(label)  = analogous with role "view"

Properties:
  * No private key exists for these addresses (the bytes come from a hash of
    a public string, not from k*G), so the test addresses are intentionally
    unspendable on any live NONO network.
  * Re-running this script produces the same addresses byte for byte; any
    reviewer can verify that a fixture address in tests/ matches what this
    generator would produce for the given label.
  * Self-contained (Python stdlib only — pure-Python Keccak-256 and
    Ed25519-point validation inline).

Usage:
    python3 tests/unit_tests/data/nono_test_addresses.py

Output lists each fixture's label, the derived spend/view pubkeys, and the
final base58 address. Test fixtures in tests/unit_tests/ that need a NONO
address use the corresponding label from this script.
"""

import hashlib

# ---------------------------------------------------------------------------
# Cryptonote base58 alphabet + block-size table
# ---------------------------------------------------------------------------
ALPHA = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
assert len(ALPHA) == 58
ENCODED_BLOCK_SIZES = [0, 2, 3, 5, 6, 7, 9, 10, 11]
FULL_BLOCK_SIZE = 8
FULL_ENCODED_BLOCK_SIZE = 11

def _encode_block(block: bytes, out_len: int) -> str:
    n = int.from_bytes(block, "big")
    out = ""
    for _ in range(out_len):
        n, rem = divmod(n, 58)
        out = ALPHA[rem] + out
    return out

def cn_base58_encode(data: bytes) -> str:
    out = []
    full = len(data) // FULL_BLOCK_SIZE
    rem = len(data) % FULL_BLOCK_SIZE
    for i in range(full):
        block = data[i*FULL_BLOCK_SIZE : (i+1)*FULL_BLOCK_SIZE]
        out.append(_encode_block(block, FULL_ENCODED_BLOCK_SIZE))
    if rem:
        block = data[full*FULL_BLOCK_SIZE:]
        out.append(_encode_block(block, ENCODED_BLOCK_SIZES[rem]))
    return "".join(out)

# ---------------------------------------------------------------------------
# Keccak-256 (original Keccak padding, NOT SHA-3 padding) — used for
# Cryptonote address checksums.
# ---------------------------------------------------------------------------
_R = [[0, 36, 3, 41, 18],
      [1, 44, 10, 45, 2],
      [62, 6, 43, 15, 61],
      [28, 55, 25, 21, 56],
      [27, 20, 39, 8, 14]]
_RC = [0x0000000000000001, 0x0000000000008082, 0x800000000000808a,
       0x8000000080008000, 0x000000000000808b, 0x0000000080000001,
       0x8000000080008081, 0x8000000000008009, 0x000000000000008a,
       0x0000000000000088, 0x0000000080008009, 0x000000008000000a,
       0x000000008000808b, 0x800000000000008b, 0x8000000000008089,
       0x8000000000008003, 0x8000000000008002, 0x8000000000000080,
       0x000000000000800a, 0x800000008000000a, 0x8000000080008081,
       0x8000000000008080, 0x0000000080000001, 0x8000000080008008]

def keccak256(data: bytes) -> bytes:
    rotl = lambda v, n: ((v << n) | (v >> (64 - n))) & 0xFFFFFFFFFFFFFFFF
    def f(A):
        for rnd in range(24):
            C = [A[x][0]^A[x][1]^A[x][2]^A[x][3]^A[x][4] for x in range(5)]
            D = [C[(x-1)%5] ^ rotl(C[(x+1)%5], 1) for x in range(5)]
            for x in range(5):
                for y in range(5):
                    A[x][y] ^= D[x]
            B = [[0]*5 for _ in range(5)]
            for x in range(5):
                for y in range(5):
                    B[y][(2*x+3*y) % 5] = rotl(A[x][y], _R[x][y])
            for x in range(5):
                for y in range(5):
                    A[x][y] = B[x][y] ^ ((~B[(x+1)%5][y]) & B[(x+2)%5][y])
            A[0][0] ^= _RC[rnd]
    rate = 136
    pad = b"\x01" + b"\x00" * ((-(len(data) + 2)) % rate) + b"\x80"
    msg = data + pad
    A = [[0]*5 for _ in range(5)]
    for off in range(0, len(msg), rate):
        block = msg[off:off+rate]
        for i in range(rate // 8):
            x, y = i % 5, i // 5
            A[x][y] ^= int.from_bytes(block[i*8:(i+1)*8], "little")
        f(A)
    out = b""
    for i in range(4):
        x, y = i % 5, i // 5
        out += A[x][y].to_bytes(8, "little")
    return out

# ---------------------------------------------------------------------------
# Ed25519 point validation (decode-from-bytes only — no scalar mult needed).
# ---------------------------------------------------------------------------
_P = 2**255 - 19
_D = (-121665 * pow(121666, _P - 2, _P)) % _P
_SQRT_M1 = pow(2, (_P - 1) // 4, _P)

def _recover_x(y, sign):
    if y >= _P:
        return None
    x2 = ((y*y - 1) * pow(_D * y * y + 1, _P - 2, _P)) % _P
    if x2 == 0:
        return 0 if sign == 0 else None
    x = pow(x2, (_P + 3) // 8, _P)
    if (x*x - x2) % _P != 0:
        x = (x * _SQRT_M1) % _P
    if (x*x - x2) % _P != 0:
        return None
    if (x & 1) != sign:
        x = _P - x
    return x

def is_valid_ed25519_point(b: bytes) -> bool:
    if len(b) != 32:
        return False
    sign = b[31] >> 7
    y_bytes = b[:31] + bytes([b[31] & 0x7F])
    y = int.from_bytes(y_bytes, "little")
    return _recover_x(y, sign) is not None

def derive_nums(domain: str, extra_predicate=None) -> bytes:
    """Find the first SHA-256(domain:i) that decodes as a valid Ed25519 point
    (and optionally also satisfies extra_predicate)."""
    i = 0
    while True:
        h = hashlib.sha256(f"{domain}:{i}".encode("ascii")).digest()
        if is_valid_ed25519_point(h) and (extra_predicate is None or extra_predicate(h)):
            return h
        i += 1

# ---------------------------------------------------------------------------
# Cryptonote varint (for prefix encoding) + address blob assembly
# ---------------------------------------------------------------------------
def varint(v: int) -> bytes:
    out = bytearray()
    while True:
        b = v & 0x7F
        v >>= 7
        if v == 0:
            out.append(b)
            return bytes(out)
        out.append(b | 0x80)

def make_address(prefix_tag: int, spend_pub: bytes, view_pub: bytes,
                 payment_id: bytes = b"") -> str:
    blob = varint(prefix_tag) + spend_pub + view_pub + payment_id
    checksum = keccak256(blob)[:4]
    return cn_base58_encode(blob + checksum)

# ---------------------------------------------------------------------------
# NONO mainnet prefixes (kept in sync with src/cryptonote_config.h)
# ---------------------------------------------------------------------------
TAG_STANDARD    = 127
TAG_INTEGRATED  = 128
TAG_SUBADDRESS  = 129

FIXTURES = [
    # (label, kind, payment_id_hex_or_None)
    ("address_from_url:txt-record",         "standard",   None),
    ("wallet_storage:primary",              "standard",   None),
    ("base58:roundtrip-standard",           "standard",   None),
    ("base58:roundtrip-integrated",         "integrated", "1122334455667788"),
    ("base58:roundtrip-subaddress",         "subaddress", None),
]

def derive(label: str, kind: str, payment_id_hex):
    # For the base58 roundtrip-standard fixture we additionally require that
    # zeroing the spend pubkey's first byte and replacing the view pubkey's
    # last byte with 0x01 each yield an *invalid* Ed25519 point — the
    # base58.cpp negative tests rely on those mutations producing parse
    # failures, and a NUMS point that happens to remain valid under those
    # specific mutations would invert the assertion.
    if label == "base58:roundtrip-standard":
        spend = derive_nums(
            f"NONO_TEST_FIXTURE:{label}:spend",
            extra_predicate=lambda h: not is_valid_ed25519_point(b"\x00" + h[1:]),
        )
        view = derive_nums(
            f"NONO_TEST_FIXTURE:{label}:view",
            extra_predicate=lambda h: not is_valid_ed25519_point(h[:-1] + b"\x01"),
        )
    else:
        spend = derive_nums(f"NONO_TEST_FIXTURE:{label}:spend")
        view  = derive_nums(f"NONO_TEST_FIXTURE:{label}:view")
    if kind == "standard":
        tag = TAG_STANDARD
        pid = b""
    elif kind == "subaddress":
        tag = TAG_SUBADDRESS
        pid = b""
    elif kind == "integrated":
        tag = TAG_INTEGRATED
        pid = bytes.fromhex(payment_id_hex)
    else:
        raise ValueError(kind)
    addr = make_address(tag, spend, view, pid)
    return spend, view, addr

def main():
    print(f"# Deterministic NONO test-fixture addresses")
    print(f"# Mainnet tags: standard={TAG_STANDARD} integrated={TAG_INTEGRATED} subaddress={TAG_SUBADDRESS}")
    print()
    for label, kind, pid in FIXTURES:
        spend, view, addr = derive(label, kind, pid)
        print(f"## {label}  ({kind})")
        print(f"spend_pubkey = {spend.hex()}")
        print(f"view_pubkey  = {view.hex()}")
        if pid:
            print(f"payment_id   = {pid}")
        print(f"address      = {addr}")
        print(f"len          = {len(addr)}  starts_with_N={addr.startswith('N')}")
        print()

if __name__ == "__main__":
    main()
