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
    "touch_start": request("_touchStart", {"_height": 1000.0, "_tFl": 0, "_width": 1000.0}, 13),
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


# Pairing (pair-setup M5 and M6) ------------------------------------------------


def pairing_vectors():
    """Drive pyatv's own pair-setup steps 3 and 4 with fixed keys.

    Ed25519 signatures and the fixed ChaCha nonces make the output deterministic.
    """
    from types import SimpleNamespace

    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    from pyatv.auth.hap_srp import SRPAuthHandler, hkdf_expand
    from pyatv.support import chacha20

    raw = serialization.Encoding.Raw
    session_key = fixed_bytes(21, 64)
    client_seed = fixed_bytes(22, 32)
    pairing_id = b"6F1B3C2A-9D4E-4F5A-8B7C-0D1E2F3A4B5C"
    atv_seed = fixed_bytes(23, 32)
    atv_id = b"AA:BB:CC:DD:EE:FF"

    client_key = Ed25519PrivateKey.from_private_bytes(client_seed)
    handler = SRPAuthHandler()
    handler.initialize()
    handler._signing_key = client_key
    handler._auth_private = client_seed
    handler._auth_public = client_key.public_key().public_bytes(raw, serialization.PublicFormat.Raw)
    handler.pairing_id = pairing_id
    handler._session = SimpleNamespace(key=session_key.hex())
    m5 = handler.step3(name="Clickr")

    # Build the TV's M6 the way a HAP accessory does, then let pyatv read it.
    atv_key = Ed25519PrivateKey.from_private_bytes(atv_seed)
    atv_public = atv_key.public_key().public_bytes(raw, serialization.PublicFormat.Raw)
    accessory_x = hkdf_expand("Pair-Setup-Accessory-Sign-Salt", "Pair-Setup-Accessory-Sign-Info", session_key)
    signature = atv_key.sign(accessory_x + atv_id + atv_public)
    sub_tlv = write_tlv({TlvValue.Identifier: atv_id, TlvValue.PublicKey: atv_public, TlvValue.Signature: signature})
    encrypt_key = hkdf_expand("Pair-Setup-Encrypt-Salt", "Pair-Setup-Encrypt-Info", session_key)
    m6 = chacha20.Chacha20Cipher8byteNonce(encrypt_key, encrypt_key).encrypt(sub_tlv, nonce=b"PS-Msg06")
    credentials = handler.step4(m6)
    assert credentials.atv_id == atv_id and credentials.ltpk == atv_public

    return {
        "session_key": session_key.hex(),
        "client_seed": client_seed.hex(),
        "client_public": handler._auth_public.hex(),
        "pairing_id": pairing_id.decode(),
        "name": "Clickr",
        "encrypt_key": encrypt_key.hex(),
        "controller_x": hkdf_expand("Pair-Setup-Controller-Sign-Salt", "Pair-Setup-Controller-Sign-Info", session_key).hex(),
        "m5_encrypted": m5.hex(),
        "atv_seed": atv_seed.hex(),
        "atv_public": atv_public.hex(),
        "atv_id": atv_id.decode(),
        "m6_encrypted": m6.hex(),
    }


# Pair-verify and the encrypted transport ----------------------------------------


def verify_vectors():
    """pyatv's pair-verify (verify1/verify2) with fixed keys, plus frames encrypted the way
    its CompanionConnection does after pair-verify."""
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
    from pyatv.auth.hap_pairing import HapCredentials
    from pyatv.auth.hap_srp import SRPAuthHandler, hkdf_expand
    from pyatv.support import chacha20

    raw, public = serialization.Encoding.Raw, serialization.PublicFormat.Raw
    client_ltsk = fixed_bytes(31, 32)
    client_id = b"6F1B3C2A-9D4E-4F5A-8B7C-0D1E2F3A4B5C"
    atv_key = Ed25519PrivateKey.from_private_bytes(fixed_bytes(32, 32))
    atv_ltpk = atv_key.public_key().public_bytes(raw, public)
    atv_id = b"AA:BB:CC:DD:EE:FF"
    client_eph = X25519PrivateKey.from_private_bytes(fixed_bytes(33, 32))
    client_eph_public = client_eph.public_key().public_bytes(raw, public)
    atv_eph = X25519PrivateKey.from_private_bytes(fixed_bytes(34, 32))
    atv_eph_public = atv_eph.public_key().public_bytes(raw, public)

    handler = SRPAuthHandler()
    handler.initialize()
    handler._verify_private = client_eph
    handler._public_bytes = client_eph_public
    credentials = HapCredentials(atv_ltpk, client_ltsk, atv_id, client_id)

    # The TV's M2.
    shared = atv_eph.exchange(X25519PrivateKey.from_private_bytes(fixed_bytes(33, 32)).public_key())
    session_key = hkdf_expand("Pair-Verify-Encrypt-Salt", "Pair-Verify-Encrypt-Info", shared)
    signature = atv_key.sign(atv_eph_public + atv_id + client_eph_public)
    m2 = chacha20.Chacha20Cipher8byteNonce(session_key, session_key).encrypt(
        write_tlv({TlvValue.Identifier: atv_id, TlvValue.Signature: signature}), nonce=b"PV-Msg02")

    m3 = handler.verify1(credentials, atv_eph_public, m2)
    output_key, input_key = handler.verify2("", "ClientEncrypt-main", "ServerEncrypt-main")

    # Frames as CompanionConnection sends them, and as the TV would send them back.
    def frames(out_key, in_key):
        cipher = chacha20.Chacha20Cipher(out_key, in_key, nonce_length=12)
        result = []
        for frame_type, payload in [(8, opack.pack({"_i": "_hidC", "_t": 2, "_c": {"_hBtS": 1, "_hidC": 6}, "_x": 7})),
                                    (8, fixed_bytes(40, 300)), (1, b""), (8, b"\x01")]:
            length = len(payload) + (16 if payload else 0)
            header = bytes([frame_type]) + length.to_bytes(3, "big")
            body = cipher.encrypt(payload, aad=header) if payload else b""
            result.append({"type": frame_type, "payload": payload.hex(), "wire": (header + body).hex()})
        return result

    return {
        "client_ltsk": client_ltsk.hex(),
        "client_id": client_id.decode(),
        "atv_ltpk": atv_ltpk.hex(),
        "atv_id": atv_id.decode(),
        "client_eph_private": fixed_bytes(33, 32).hex(),
        "client_eph_public": client_eph_public.hex(),
        "atv_eph_public": atv_eph_public.hex(),
        "shared_secret": shared.hex(),
        "verify_key": session_key.hex(),
        "m2_encrypted": m2.hex(),
        "m3_encrypted": m3.hex(),
        "output_key": output_key.hex(),
        "input_key": input_key.hex(),
        "frames_to_tv": frames(output_key, input_key),
        "frames_from_tv": frames(input_key, output_key),
    }


# Text input (RTI keyed archives) --------------------------------------------------


def text_input_vectors():
    """pyatv's pre-encoded RTI payloads, plus a made-up `_tiStart` reply archive shaped
    like the paths pyatv reads from it (sessionUUID, documentState.docSt.contextBeforeInput).
    """
    import plistlib

    from pyatv.protocols.companion import keyed_archiver
    from pyatv.protocols.companion.plist_payloads.rti_text_operations import (
        get_rti_clear_text_payload,
        get_rti_input_text_payload,
    )

    session = uuid.UUID("0F8E7D6C-5B4A-4938-8271-605F4E3D2C1B").bytes
    reply = plistlib.dumps({
        "$version": 100000,
        "$archiver": "RTIKeyedArchiver",
        "$top": {"sessionUUID": plistlib.UID(1), "documentState": plistlib.UID(2)},
        "$objects": [
            "$null",
            session,
            {"docSt": plistlib.UID(3), "$class": plistlib.UID(6)},
            {"contextBeforeInput": plistlib.UID(4), "$class": plistlib.UID(5)},
            "Star W",
            {"$classname": "TIDocumentState", "$classes": ["TIDocumentState", "NSObject"]},
            {"$classname": "RTIDocumentState", "$classes": ["RTIDocumentState", "NSObject"]},
        ],
    }, fmt=plistlib.PlistFormat.FMT_BINARY, sort_keys=False)
    read_uuid, read_text = keyed_archiver.read_archive_properties(
        reply, ["sessionUUID"], ["documentState", "docSt", "contextBeforeInput"])
    assert read_uuid == session and read_text == "Star W"

    return {
        "session_uuid": session.hex(),
        "insert_text": "Café ’s",
        "insert_payload": get_rti_input_text_payload(session, "Café ’s").hex(),
        "clear_payload": get_rti_clear_text_payload(session).hex(),
        "start_reply": reply.hex(),
        "start_reply_text": "Star W",
    }


# MRP over AirPlay ---------------------------------------------------------------


def mrp_vectors():
    """MRP protobufs, HAP framing and data-stream frames, made with pyatv's own code.

    Random identifiers are replaced with fixed strings so the bytes are reproducible.
    """
    from pyatv.auth.hap_session import HAPSession
    from pyatv.protocols.airplay.channels import DataStreamChannel
    from pyatv.protocols.mrp import messages
    from pyatv.protocols.mrp import protobuf as pb
    from pyatv.settings import InfoSettings
    from pyatv.support.variant import write_variant

    def fixed(message, identifier=None):
        message.uniqueIdentifier = "5E1F2B6C-0A9D-4C3E-8F71-2D4B6A8C0E1F"
        if identifier is not None:
            message.identifier = identifier
        return message.SerializeToString().hex()

    info = InfoSettings()
    info.name = "Clickr"
    device_info = messages.device_information(info, "abcdef01-2345-6789-abcd-ef0123456789")
    handshake = {
        "device_info": fixed(device_info, "11111111-1111-1111-1111-111111111111"),
        "set_connection_state": fixed(messages.set_connection_state()),
        "client_updates_config": fixed(messages.client_updates_config(), "22222222-2222-2222-2222-222222222222"),
        "get_keyboard_session": fixed(messages.get_keyboard_session(), "33333333-3333-3333-3333-333333333333"),
        "playback_queue_request": fixed(messages.playback_queue_request(0, 512, -1), "44444444-4444-4444-4444-444444444444"),
    }

    # A SetState the way the TV sends it: player path, state and a queue with one item.
    state = messages.create(pb.SET_STATE_MESSAGE)
    inner = pb.extract_inner(state)
    inner.playbackState = 1
    inner.playerPath.origin.displayName = "Apple TV"
    inner.playerPath.client.bundleIdentifier = "com.example.video"
    inner.playerPath.client.displayName = "Video"
    inner.playerPath.player.identifier = "MediaRemote-DefaultPlayer"
    inner.playbackQueue.location = 0
    item = inner.playbackQueue.contentItems.add()
    item.identifier = "ITEM-1"
    meta = item.metadata
    meta.title = "Episode 3"
    meta.trackArtistName = "Some Show"
    meta.albumName = "Season 1"
    meta.duration = 2712.5
    meta.elapsedTime = 61.25
    meta.elapsedTimeTimestamp = 813508517.465923
    meta.playbackRate = 1.0
    meta.artworkAvailable = True
    meta.artworkMIMEType = "image/jpeg"
    meta.artworkIdentifier = "3e7d403ad36f7472"
    meta.mediaType = 2
    set_state = fixed(state)

    # The TV's reply to a PlaybackQueueRequest: a SetState whose item carries the artwork.
    artwork_reply = messages.create(pb.SET_STATE_MESSAGE)
    art_item = pb.extract_inner(artwork_reply).playbackQueue.contentItems.add()
    art_item.identifier = "ITEM-1"
    art_item.artworkData = fixed_bytes(50, 300)
    art_item.artworkDataWidth = 512
    art_item.artworkDataHeight = 288
    artwork = fixed(artwork_reply, "44444444-4444-4444-4444-444444444444")

    # Playback commands, built the way pyatv's remote control builds them.
    from pyatv.protocols.mrp.protobuf import CommandInfo_pb2 as commands
    command_messages = {
        "toggle_play_pause": fixed(messages.command(commands.TogglePlayPause), "55555555-5555-5555-5555-555555555555"),
        "skip_forward_15": fixed(messages.command(commands.SkipForward, skipInterval=15), "66666666-6666-6666-6666-666666666666"),
        "skip_backward_10": fixed(messages.command(commands.SkipBackward, skipInterval=10), "77777777-7777-7777-7777-777777777777"),
        "next_track": fixed(messages.command(commands.NextTrack), "88888888-8888-8888-8888-888888888888"),
        "seek_to_123_5": fixed(messages.seek_to_position(123.5), "99999999-9999-9999-9999-999999999999"),
    }
    result = messages.command_result("55555555-5555-5555-5555-555555555555")
    command_result = fixed(result)

    # A SetState that lists the player's supported commands, and a client's defaults.
    with_commands = messages.create(pb.SET_STATE_MESSAGE)
    commands_inner = pb.extract_inner(with_commands)
    commands_inner.playerPath.client.bundleIdentifier = "com.example.video"
    commands_inner.playerPath.player.identifier = "MediaRemote-DefaultPlayer"
    for command, enabled, intervals in [
        (commands.TogglePlayPause, True, []),
        (commands.SkipForward, True, [15.0, 30.0]),
        (commands.SkipBackward, False, [15.0]),
        (commands.SeekToPlaybackPosition, True, []),
        (commands.Stop, True, []),
    ]:
        info = commands_inner.supportedCommands.supportedCommands.add()
        info.command = command
        info.enabled = enabled
        info.preferredIntervals.extend(intervals)
    set_state_commands = fixed(with_commands)

    defaults = messages.create(pb.SET_DEFAULT_SUPPORTED_COMMANDS_MESSAGE)
    defaults_inner = pb.extract_inner(defaults)
    defaults_inner.playerPath.client.bundleIdentifier = "com.example.video"
    for command in (commands.NextTrack, commands.SkipBackward):
        info = defaults_inner.supportedCommands.supportedCommands.add()
        info.command = command
        info.enabled = True
    default_commands = fixed(defaults)

    # HAP framing: 1500 bytes splits into a 1024-byte and a 476-byte block.
    out_key, in_key = fixed_bytes(60, 32), fixed_bytes(61, 32)
    session = HAPSession()
    session.enable(out_key, in_key)
    plaintext = fixed_bytes(62, 1500)
    framed = session.encrypt(plaintext)
    reverse = HAPSession()
    reverse.enable(in_key, out_key)
    assert reverse.decrypt(framed) == plaintext

    # A data-stream frame the way pyatv's channel sends one MRP message.
    sent = []
    channel = DataStreamChannel.__new__(DataStreamChannel)
    channel.send = lambda data: sent.append(data)
    channel.send_seqno = 0x123456789
    data_frame_payload = bytes.fromhex(handshake["set_connection_state"])
    DataStreamChannel.send_protobuf(channel, pb.ProtocolMessage.FromString(data_frame_payload))

    return {
        "handshake": handshake,
        "set_state": set_state,
        "artwork_reply": artwork,
        "commands": command_messages,
        "command_result": command_result,
        "set_state_commands": set_state_commands,
        "default_commands": default_commands,
        "hap_out_key": out_key.hex(),
        "hap_in_key": in_key.hex(),
        "hap_plaintext": plaintext.hex(),
        "hap_framed": framed.hex(),
        "data_frame": sent[0].hex(),
        "data_frame_seqno": 0x123456789,
        "varint_300": write_variant(300).hex(),
    }


def write(path: Path, payload):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=1, ensure_ascii=False) + "\n")
    print(f"wrote {path.relative_to(ROOT)}")


if __name__ == "__main__":
    write(TESTS / "OPACKTests" / "Vectors" / "opack.json", opack_vectors())
    write(TESTS / "TLV8Tests" / "Vectors" / "tlv8.json", tlv_vectors())
    write(TESTS / "BigIntTests" / "Vectors" / "bigint.json", bigint_vectors())
    write(TESTS / "SRPTests" / "Vectors" / "srp.json", srp_vectors())
    write(TESTS / "PairingTests" / "Vectors" / "pairing.json", pairing_vectors())
    verify = verify_vectors()
    frames = {key: verify.pop(key) for key in ("frames_to_tv", "frames_from_tv")}
    frames.update(output_key=verify["output_key"], input_key=verify["input_key"])
    write(TESTS / "PairingTests" / "Vectors" / "verify.json", verify)
    write(TESTS / "TransportTests" / "Vectors" / "frames.json", frames)
    write(TESTS / "SessionTests" / "Vectors" / "text_input.json", text_input_vectors())
    mrp = mrp_vectors()
    write(TESTS / "MRPTests" / "Vectors" / "mrp.json", mrp)
    write(TESTS / "AirPlayTests" / "Vectors" / "mrp.json", mrp)
