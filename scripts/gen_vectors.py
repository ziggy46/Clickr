#!/usr/bin/env python3
"""Generate test vectors for CompanionKit using pyatv as the reference.

Dev only. Set up once:
    python3 -m venv .venv && .venv/bin/pip install pyatv
Then from the repo root:
    .venv/bin/python scripts/gen_vectors.py

Vectors are written as JSON next to the tests that use them. Values are stored
as typed nodes so the Swift side can rebuild them exactly: ints as decimal
strings (UInt64 doesn't fit in a JSON double), bytes as hex, and dicts as
ordered [key, value] pairs.
"""

import hashlib
import json
import random
import struct
import uuid
from pathlib import Path

from pyatv.auth.hap_tlv8 import TlvValue, read_tlv, write_tlv
from pyatv.support import opack
from srptools import SRPClientSession, SRPContext, SRPServerSession, constants

ROOT = Path(__file__).resolve().parent.parent
TESTS = ROOT / "Packages" / "CompanionKit" / "Tests"


def node(value):
    if value is None:
        return {"t": "null"}
    if isinstance(value, bool):
        return {"t": "bool", "v": value}
    if isinstance(value, int):
        return {"t": "int", "v": str(value)}
    if isinstance(value, float):
        return {"t": "double", "v": struct.pack("<d", value).hex()}
    if isinstance(value, str):
        return {"t": "string", "v": value}
    if isinstance(value, bytes):
        return {"t": "data", "v": value.hex()}
    if isinstance(value, uuid.UUID):
        return {"t": "uuid", "v": str(value).upper()}
    if isinstance(value, list):
        return {"t": "array", "v": [node(v) for v in value]}
    if isinstance(value, dict):
        return {"t": "dict", "v": [[node(k), node(v)] for k, v in value.items()]}
    raise TypeError(type(value))


def fixed_bytes(seed: int, count: int) -> bytes:
    """Deterministic filler bytes so regenerating gives the same file."""
    return bytes((seed * 31 + i * 7) & 0xFF for i in range(count))


def request(identifier, content, xid):
    return {"_i": identifier, "_t": 2, "_c": content, "_x": xid}


# Shapes taken from what pyatv sends and receives over Companion. All IDs and
# names are made up.
APPS = [
    ("com.apple.TVWatchList", "TV"),
    ("com.apple.TVMusic", "Music"),
    ("com.apple.TVPhotos", "Photos"),
    ("com.apple.TVAppStore", "App Store"),
    ("com.apple.TVSettings", "Settings"),
    ("com.apple.TVSearch", "Search"),
    ("com.apple.podcasts", "Podcasts"),
    ("com.apple.Arcade", "Arcade"),
    ("com.apple.Fitness", "Fitness"),
    ("com.example.streamer", "Streamer"),
    ("com.example.movies", "Movies"),
    ("com.example.news", "News Now"),
    ("com.example.sports", "Sports"),
    ("com.example.kids", "Kids"),
    ("com.example.weather", "Weather"),
    ("com.example.radio", "Radio"),
]

OPACK_MESSAGES = {
    "ps_start": {
        "_pd": write_tlv({TlvValue.Method: b"\x00", TlvValue.SeqNo: b"\x01"}),
        "_pwTy": 1,
        "_x": 0,
    },
    "ps_next_m3": {
        "_pd": write_tlv({
            TlvValue.SeqNo: b"\x03",
            TlvValue.PublicKey: fixed_bytes(1, 384),
            TlvValue.Proof: fixed_bytes(2, 64),
        }),
        "_pwTy": 1,
        "_x": 1,
    },
    "pv_start": {
        "_pd": write_tlv({TlvValue.SeqNo: b"\x01", TlvValue.PublicKey: fixed_bytes(3, 32)}),
        "_auTy": 4,
        "_x": 2,
    },
    "system_info": request("_systemInfo", {
        "_bf": 0,
        "_cf": 512,
        "_clFl": 128,
        "_i": "a1b2c3d4e5f6",
        "_idsID": "6F1B3C2A-9D4E-4F5A-8B7C-0D1E2F3A4B5C",
        "_pubID": "AA:BB:CC:DD:EE:FF",
        "_sf": 256,
        "_sv": "170.18",
        "model": "Mac16,8",
        "name": "Clickr",
    }, 3),
    "session_start": request("_sessionStart", {
        "_srvT": "com.apple.tvremoteservices",
        "_sid": 0xDEADBEEF,
    }, 4),
    "session_start_reply": {"_c": {"_sid": 0x1234ABCD}, "_t": 3, "_x": 4},
    "session_stop": request("_sessionStop", {
        "_srvT": "com.apple.tvremoteservices",
        "_sid": (0x1234ABCD << 32) | 0xDEADBEEF,
    }, 5),
    "hid_down": request("_hidC", {"_hBtS": 1, "_hidC": 6}, 6),
    "hid_up": request("_hidC", {"_hBtS": 2, "_hidC": 6}, 7),
    "hid_touch_event": {
        "_i": "_hidT",
        "_t": 1,
        "_c": {"_ns": 1_234_567_890_123, "_tFg": 1, "_cx": 1000, "_tPh": 4, "_cy": 1000},
        "_x": 8,
    },
    "launch_app": request("_launchApp", {"_bundleID": "com.apple.TVWatchList"}, 9),
    "app_list_reply": {"_c": {bundle: name for bundle, name in APPS}, "_t": 3, "_x": 10},
    "app_list_as_array": {"_t": 3, "_c": {"apps": [{"name": n, "id": b} for b, n in APPS[:4]]}},
    "media_control_volume": request("_mcc", {"_mcc": 6, "_vol": 0.5}, 11),
    "text_input_start": request("_tiStart", {}, 12),
    "error_reply": {"_em": "Unsupported command", "_ec": 1, "_t": 3, "_x": 13},
    "repeated_values": ["foo", "bar", "foo", "bar", b"\x01\x02", b"\x01\x02", 1000, 1000, 2.5, 2.5],
    "endless_array": [f"item{i % 5}" for i in range(20)],
    "uuid_and_null": {"id": uuid.UUID("0F8E7D6C-5B4A-4938-8271-605F4E3D2C1B"), "none": None, "yes": True, "no": False},
    "nested": {"a": {"b": {"c": [1, [2, [3, {"d": "deep"}]]]}}},
}

SCALARS = {
    "int_39": 39,
    "int_40": 40,
    "int_255": 255,
    "int_256": 256,
    "int_65535": 65535,
    "int_65536": 65536,
    "int_2^32-1": 2**32 - 1,
    "int_2^32": 2**32,
    "int_max": 2**64 - 1,
    "string_empty": "",
    "string_32": "x" * 32,
    "string_33": "x" * 33,
    # Multibyte characters right at the 32/33 byte boundary.
    "string_32_bytes_multibyte": "Café ’s Room · Den" + "y" * 10,
    "string_33_bytes_multibyte": "Café ’s Room · Den" + "y" * 11,
    "string_255": "s" * 255,
    "string_256": "s" * 256,
    "string_65536": "L" * 65536,
    "data_empty": b"",
    "data_32": fixed_bytes(4, 32),
    "data_33": fixed_bytes(5, 33),
    "data_300": fixed_bytes(6, 300),
    "data_65536": fixed_bytes(7, 65536),
    "double": 3.141592653589793,
    "true": True,
    "false": False,
    "null": None,
    "empty_array": [],
    "empty_dict": {},
    "array_14": list(range(14)),
    "array_15": list(range(15)),
    "dict_14": {f"k{i}": i for i in range(14)},
    "dict_15": {f"k{i}": i for i in range(15)},
}

TLV_VECTORS = {
    "ps_m1": {TlvValue.Method: b"\x00", TlvValue.SeqNo: b"\x01"},
    "ps_m3": {TlvValue.SeqNo: b"\x03", TlvValue.PublicKey: fixed_bytes(1, 384), TlvValue.Proof: fixed_bytes(2, 64)},
    "value_255": {TlvValue.EncryptedData: fixed_bytes(8, 255)},
    "value_256": {TlvValue.EncryptedData: fixed_bytes(9, 256)},
    "value_510": {TlvValue.EncryptedData: fixed_bytes(10, 510)},
    "value_511": {TlvValue.EncryptedData: fixed_bytes(11, 511)},
    "error": {TlvValue.SeqNo: b"\x02", TlvValue.Error: b"\x02"},
    "unknown_tag": {TlvValue.SeqNo: b"\x02", 0x1B: b"\x01"},
}


def opack_vectors():
    vectors = []
    for name, value in {**OPACK_MESSAGES, **SCALARS}.items():
        packed = opack.pack(value)
        unpacked, rest = opack.unpack(packed)
        # pyatv's packer and unpacker disagree on back-references after nested
        # containers or empty strings (see BUILD_PLAN.md 3.3). Only keep vectors
        # pyatv can round-trip itself.
        if unpacked != value or rest:
            raise SystemExit(f"pyatv can't round-trip {name!r}; change the vector")
        vectors.append({"name": name, "value": node(value), "hex": packed.hex()})
    return vectors


def tlv_vectors():
    vectors = []
    for name, items in TLV_VECTORS.items():
        encoded = write_tlv(items)
        if read_tlv(encoded) != {int(k): v for k, v in items.items()}:
            raise SystemExit(f"pyatv can't round-trip TLV {name!r}")
        vectors.append({
            "name": name,
            "items": [[int(tag), value.hex()] for tag, value in items.items()],
            "hex": encoded.hex(),
        })
    return vectors


# BigInt ---------------------------------------------------------------------

MASK64 = (1 << 64) - 1
INTERESTING_LIMBS = [0, 1, 2, (1 << 63) - 1, 1 << 63, MASK64 - 1, MASK64]


def h(n: int) -> str:
    return format(n, "x")


def limbs_of(n):
    out = []
    while n:
        out.append(n & MASK64)
        n >>= 64
    return out


def knuth_branches(u: int, v: int):
    """Run Knuth's algorithm D on 64-bit limbs and report which rare branches fired.

    Only used to pick division vectors that exercise the qhat = 2^64 - 1 and add-back
    paths, which random inputs almost never reach.
    """
    vl, ul = limbs_of(v), limbs_of(u)
    n, m = len(vl), len(ul) - len(vl)
    if n < 2 or m < 0:
        return set()
    shift = 64 - vl[-1].bit_length()
    vn = limbs_of(v << shift)
    un = limbs_of(u << shift)
    un += [0] * (m + n + 1 - len(un))
    fired = set()
    for j in range(m, -1, -1):
        top = (un[j + n] << 64) | un[j + n - 1]
        if un[j + n] >= vn[n - 1]:
            fired.add("qhat_max")
        qhat = min(top // vn[n - 1], MASK64)
        rhat = top - qhat * vn[n - 1]
        while rhat <= MASK64 and qhat * vn[n - 2] > ((rhat << 64) | un[j + n - 2]):
            qhat -= 1
            rhat += vn[n - 1]
            fired.add("qhat_correction")
        window = sum(un[j + i] << (64 * i) for i in range(n + 1))
        diff = window - qhat * (v << shift)
        if diff < 0:
            fired.add("add_back")
            qhat -= 1
            diff += v << shift
        for i in range(n + 1):
            un[j + i] = (diff >> (64 * i)) & MASK64
    return fired


def bigint_vectors():
    rng = random.Random(0xC11C4)

    def rand_bits(bits):
        return rng.getrandbits(bits) | (1 << (bits - 1)) if bits else 0

    def structured(limb_count):
        return sum(rng.choice(INTERESTING_LIMBS + [rng.getrandbits(64)]) << (64 * i) for i in range(limb_count))

    sizes = [1, 2, 63, 64, 65, 127, 128, 129, 256, 511, 1024, 2048, 3072, 4096]
    add, sub, mul, divmod_, bytes_ = [], [], [], [], []
    for bits_a in sizes:
        for bits_b in (1, 64, 65, bits_a, max(1, bits_a // 2)):
            a, b = rand_bits(bits_a), rand_bits(bits_b)
            add.append([h(a), h(b), h(a + b)])
            hi, lo = max(a, b), min(a, b)
            sub.append([h(hi), h(lo), h(hi - lo)])
            mul.append([h(a), h(b), h(a * b)])
            if b:
                divmod_.append([h(a), h(b), h(a // b), h(a % b), "random"])
    # Carries and borrows that ripple through every limb.
    for limbs in (1, 2, 5, 48):
        ones = (1 << (64 * limbs)) - 1
        add.append([h(ones), "1", h(ones + 1)])
        sub.append([h(ones + 1), "1", h(ones)])
        mul.append([h(ones), h(ones), h(ones * ones)])
    for a in (0, 1, MASK64, 1 << 64):
        add.append([h(a), "0", h(a)])
        sub.append([h(a), h(a), "0"])
        mul.append([h(a), "0", "0"])

    # Division cases for the rare branches of algorithm D.
    wanted = {"qhat_max": 0, "qhat_correction": 0, "add_back": 0}
    # The classic Hacker's Delight add-back case, scaled to 64-bit limbs.
    classic = [
        ((MASK64 >> 1) << 192) | (1 << 191), (1 << 191) | 1,
    ]
    candidates = [tuple(classic)]
    for _ in range(200_000):
        if all(c >= 6 for c in wanted.values()):
            break
        n = rng.randint(2, 5)
        v = structured(n)
        if v.bit_length() <= 64 * (n - 1):
            continue
        q = structured(rng.randint(1, 4))
        r = rng.choice([0, v - 1, rng.randrange(v)])
        candidates.append((v * q + r, v))
    for u, v in candidates:
        fired = knuth_branches(u, v)
        # Keep a case only if it hits a branch we still want more of.
        if all(wanted[f] >= 6 for f in fired):
            continue
        for f in fired:
            wanted[f] += 1
        divmod_.append([h(u), h(v), h(u // v), h(u % v), "+".join(sorted(fired))])
    if any(c == 0 for c in wanted.values()):
        raise SystemExit(f"didn't find division vectors for every branch: {wanted}")
    divmod_.append(["0", "5", "0", "0", "zero dividend"])
    divmod_.append([h(MASK64), h(1 << 64), "0", h(MASK64), "dividend smaller"])

    modpow = []
    for bits in (64, 128, 1024, 3072):
        for odd in (True, False):
            mod = rand_bits(bits) | 1 if odd else rand_bits(bits) & ~1
            for exp_bits in (0, 1, 17, bits):
                base, exp = rng.getrandbits(bits + 8), rand_bits(exp_bits)
                modpow.append([h(base), h(exp), h(mod), h(pow(base, exp, mod))])
    srp_n = int(constants.PRIME_3072, 16)
    modpow.append(["5", h(rand_bits(3072)), h(srp_n), None])
    modpow[-1][3] = h(pow(5, int(modpow[-1][1], 16), srp_n))
    modpow.append([h(srp_n - 1), "2", h(srp_n), "1"])
    modpow.append(["7", "5", "1", "0"])

    for count in (0, 1, 7, 8, 9, 383, 384):
        raw = bytes([0, 0]) + fixed_bytes(count, count) if count else bytes([0, 0])
        bytes_.append([raw.hex(), h(int.from_bytes(raw, "big"))])

    return {"add": add, "sub": sub, "mul": mul, "divmod": divmod_, "modpow": modpow, "bytes": bytes_}


# SRP ------------------------------------------------------------------------

SRP_N = int(constants.PRIME_3072, 16)
SRP_G = 5
SRP_N_BYTES = 384


def minimal(n: int) -> bytes:
    return n.to_bytes(max(1, (n.bit_length() + 7) // 8), "big")


def sha512(*parts: bytes) -> bytes:
    return hashlib.sha512(b"".join(parts)).digest()


def srp_client(pin: str, salt: bytes, a: int, B: int):
    """The client math as Clickr does it. Same as srptools except the salt is hashed as
    the raw bytes received instead of being turned into an integer first (which drops
    leading zero bytes). See BUILD_PLAN.md 3.5.
    """
    pad = lambda n: n.to_bytes(SRP_N_BYTES, "big")
    A = pow(SRP_G, a, SRP_N)
    k = int.from_bytes(sha512(minimal(SRP_N), pad(SRP_G)), "big")
    x = int.from_bytes(sha512(salt, sha512(f"Pair-Setup:{pin}".encode())), "big")
    u = int.from_bytes(sha512(pad(A), pad(B)), "big")
    v = pow(SRP_G, x, SRP_N)
    S = pow((B - k * v) % SRP_N, a + u * x, SRP_N)
    K = sha512(minimal(S))
    group = bytes(p ^ q for p, q in zip(sha512(minimal(SRP_N)), sha512(minimal(SRP_G))))
    M1 = sha512(group, sha512(b"Pair-Setup"), salt, minimal(A), minimal(B), K)
    M2 = sha512(minimal(A), M1, K)
    return {"A": A, "k": k, "x": x, "u": u, "S": S, "K": K, "M1": M1, "M2": M2}


def srp_server_public(pin: str, salt: bytes, b: int) -> int:
    x = int.from_bytes(sha512(salt, sha512(f"Pair-Setup:{pin}".encode())), "big")
    k = int.from_bytes(sha512(minimal(SRP_N), SRP_G.to_bytes(SRP_N_BYTES, "big")), "big")
    return (k * pow(SRP_G, x, SRP_N) + pow(SRP_G, b, SRP_N)) % SRP_N


def check_against_srptools(pin: str, salt: bytes, a: int, b: int, ours):
    context = SRPContext("Pair-Setup", pin, prime=constants.PRIME_3072,
                         generator=constants.PRIME_3072_GEN, hash_func=hashlib.sha512)
    salt_hex = salt.hex()
    verifier = context.get_common_password_verifier(context.get_common_password_hash(int(salt_hex, 16)))
    server = SRPServerSession(context, format(verifier, "x"), private=format(b, "x"))
    client = SRPClientSession(context, format(a, "x"))
    client.process(server.public, salt_hex)
    server.process(client.public, salt_hex)
    assert server.verify_proof(client.key_proof), "srptools server rejected srptools client"
    # srptools hands back hex as str or bytes depending on the field.
    as_bytes = lambda hex_value: bytes.fromhex(hex_value.decode() if isinstance(hex_value, bytes) else hex_value)
    B = int(server.public, 16)
    theirs = {
        "A": int(client.public, 16),
        "k": context._mult,
        "x": client._password_hash,
        "u": client._common_secret,
        "S": context.get_client_premaster_secret(client._password_hash, B, a, client._common_secret),
        "K": as_bytes(client.key),
        "M1": as_bytes(client.key_proof),
        "M2": as_bytes(client.key_proof_hash),
    }
    for name, value in theirs.items():
        if ours[name] != value:
            raise SystemExit(f"our SRP math disagrees with srptools on {name}")


def srp_vectors():
    rng = random.Random(0x5EED)

    def secret():
        return int.from_bytes(bytes(rng.getrandbits(8) for _ in range(32)), "big")

    def vector(name, pin, salt, a, b, compare=True):
        B = srp_server_public(pin, salt, b)
        ours = srp_client(pin, salt, a, B)
        if compare:
            check_against_srptools(pin, salt, a, b, ours)
        return {
            "name": name, "pin": pin, "salt": salt.hex(), "a": h(a), "B": minimal(B).hex(),
            "A": minimal(ours["A"]).hex(), "k": h(ours["k"]), "x": h(ours["x"]), "u": h(ours["u"]),
            "S": minimal(ours["S"]).hex(), "K": ours["K"].hex(), "M1": ours["M1"].hex(), "M2": ours["M2"].hex(),
            "matches_srptools": compare,
        }

    def nonzero_salt():
        while True:
            salt = bytes(rng.getrandbits(8) for _ in range(16))
            if salt[0]:
                return salt

    vectors = [vector(f"random_{i}", pin, nonzero_salt(), secret(), secret())
               for i, pin in enumerate(["1234", "0000", "9999", "5821", "0042"])]

    # Edge cases where a value starts with a zero byte. Each is a 1-in-256 event.
    salt = b"\x00" + bytes(rng.getrandbits(8) for _ in range(15))
    vectors.append(vector("salt_leading_zero", "1234", salt, secret(), secret(), compare=False))
    while True:
        a = secret()
        if pow(SRP_G, a, SRP_N).bit_length() <= 8 * (SRP_N_BYTES - 1):
            vectors.append(vector("A_leading_zero", "1234", nonzero_salt(), a, secret()))
            break
    while True:
        salt, b = nonzero_salt(), secret()
        if srp_server_public("1234", salt, b).bit_length() <= 8 * (SRP_N_BYTES - 1):
            vectors.append(vector("B_leading_zero", "1234", salt, secret(), b))
            break
    while True:
        salt, a, b = nonzero_salt(), secret(), secret()
        B = srp_server_public("1234", salt, b)
        if srp_client("1234", salt, a, B)["S"].bit_length() <= 8 * (SRP_N_BYTES - 1):
            vectors.append(vector("S_leading_zero", "1234", salt, a, b))
            break
    return vectors


def write(path: Path, payload):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=1, ensure_ascii=False) + "\n")
    print(f"wrote {path.relative_to(ROOT)}")


if __name__ == "__main__":
    write(TESTS / "OPACKTests" / "Vectors" / "opack.json", opack_vectors())
    write(TESTS / "TLV8Tests" / "Vectors" / "tlv8.json", tlv_vectors())
    write(TESTS / "BigIntTests" / "Vectors" / "bigint.json", bigint_vectors())
    write(TESTS / "SRPTests" / "Vectors" / "srp.json", srp_vectors())
