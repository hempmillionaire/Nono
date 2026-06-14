#!/usr/bin/env python3
"""
Derive NONO's genesis-tx NUMS ("nothing-up-my-sleeves") pubkeys.

The two pubkeys inside the genesis transaction (the coinbase output pubkey
and the tx_extra pubkey) are derived deterministically from the public seed

    NONO_GENESIS_STRANDED_2026

by the following recipe:

    candidate(i) = SHA-256("NONO_GENESIS_STRANDED_2026:<net>:<role>:" + str(i))
    pubkey       = first candidate i = 0, 1, 2, ...  whose 32 bytes decode as
                   a valid Ed25519 (Cryptonote) point.

Domain strings used:
    <net>  in  { "mainnet", "testnet", "stagenet" }
    <role> in  { "output", "tx_extra" }

Properties:
  * Anyone can re-run this script and check the bytes match the GENESIS_TX
    constants in src/cryptonote_config.h byte for byte.
  * No private key exists. The pubkeys come from a hash of a public string,
    not from k * G for any known scalar k. The genesis coinbase output is
    therefore intentionally unspendable on all three NONO networks. There
    is no premine, no dev tax, no founder allocation in NONO; the genesis
    output is a placeholder that no party can ever claim.
  * This script is the only artifact needed to verify NONO's genesis identity.
    No external libraries are required; Ed25519 point validation is
    implemented inline using only Python's stdlib.

Run:
    python3 utils/genesis/derive_nums_pubkeys.py
"""

import hashlib

# Ed25519 / Curve25519 constants.
P = 2**255 - 19
D = (-121665 * pow(121666, P - 2, P)) % P
SQRT_M1 = pow(2, (P - 1) // 4, P)


def _recover_x(y: int, sign: int):
    if y >= P:
        return None
    x2 = ((y * y - 1) * pow(D * y * y + 1, P - 2, P)) % P
    if x2 == 0:
        return 0 if sign == 0 else None
    x = pow(x2, (P + 3) // 8, P)
    if (x * x - x2) % P != 0:
        x = (x * SQRT_M1) % P
    if (x * x - x2) % P != 0:
        return None
    if (x & 1) != sign:
        x = P - x
    return x


def is_valid_ed25519_point(b: bytes) -> bool:
    if len(b) != 32:
        return False
    sign = b[31] >> 7
    y_bytes = b[:31] + bytes([b[31] & 0x7F])
    y = int.from_bytes(y_bytes, "little")
    return _recover_x(y, sign) is not None


def derive_nums(domain: str):
    """Return (pubkey, iteration_index) for the first valid candidate."""
    i = 0
    while True:
        h = hashlib.sha256(f"{domain}:{i}".encode("ascii")).digest()
        if is_valid_ed25519_point(h):
            return h, i
        i += 1


SEED = "NONO_GENESIS_STRANDED_2026"

# Common parts of the genesis tx serialization.
#   version           = 01
#   unlock_time       = 3c   (60 blocks)
#   vin count         = 01
#     txin_gen tag    = ff
#     height          = 00
#   vout count        = 01
#     amount (varint) = 89 a1 f7 fd aa 0c   (= MONEY_SUPPLY >> 21 = 423,855,247,497 atomic)
#     target tag      = 02   (txout_to_key)
#     <32-byte output pubkey>
#   extra size (varint) = 21   (= 33 bytes that follow)
#     TX_EXTRA_TAG_PUBKEY = 01
#     <32-byte tx_extra pubkey>
AMOUNT_VARINT = "89a1f7fdaa0c"
PREFIX_HEX = "013c01ff0001"
OUT_TARGET_TAG = "02"
EXTRA_SIZE = "21"
EXTRA_TAG_PUBKEY = "01"


def build_genesis_tx(net: str):
    out_pk, n_out = derive_nums(f"{SEED}:{net}:output")
    tx_pk, n_tx = derive_nums(f"{SEED}:{net}:tx_extra")
    blob = (
        PREFIX_HEX
        + AMOUNT_VARINT
        + OUT_TARGET_TAG
        + out_pk.hex()
        + EXTRA_SIZE
        + EXTRA_TAG_PUBKEY
        + tx_pk.hex()
    )
    return blob, out_pk, tx_pk, n_out, n_tx


def main() -> None:
    print(f"# NUMS seed: {SEED}\n")
    for net in ("mainnet", "testnet", "stagenet"):
        blob, out_pk, tx_pk, n_out, n_tx = build_genesis_tx(net)
        print(f"## {net}")
        print(f"output pubkey   = {out_pk.hex()}   (first valid candidate: i={n_out})")
        print(f"tx_extra pubkey = {tx_pk.hex()}   (first valid candidate: i={n_tx})")
        print(f"GENESIS_TX      = {blob}")
        print()


if __name__ == "__main__":
    main()
