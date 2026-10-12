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

import json
import struct
import uuid
from pathlib import Path

from pyatv.auth.hap_tlv8 import TlvValue, read_tlv, write_tlv
from pyatv.support import opack

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


def write(path: Path, payload):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=1, ensure_ascii=False) + "\n")
    print(f"wrote {path.relative_to(ROOT)}")


if __name__ == "__main__":
    write(TESTS / "OPACKTests" / "Vectors" / "opack.json", opack_vectors())
    write(TESTS / "TLV8Tests" / "Vectors" / "tlv8.json", tlv_vectors())
