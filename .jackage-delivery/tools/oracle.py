"""Independent fixture oracle for the delivery pack. Not Jackage product code."""
from __future__ import annotations
import hashlib
import json
from typing import Any

MAX_SAFE = 9007199254740991


def _check(value: Any) -> None:
    if value is None or isinstance(value, bool):
        return
    if isinstance(value, int):
        if abs(value) > MAX_SAFE:
            raise ValueError("unsafe integer")
        return
    if isinstance(value, str):
        value.encode("utf-8", errors="strict")
        return
    if isinstance(value, list):
        for item in value:
            _check(item)
        return
    if isinstance(value, dict):
        for key, item in value.items():
            if not isinstance(key, str):
                raise ValueError("non-string key")
            _check(key)
            _check(item)
        return
    raise ValueError("unsupported canonical value")


def canonical_bytes(value: Any) -> bytes:
    _check(value)
    # Valid Unicode scalar order equals UTF-8 byte order.
    return json.dumps(value, sort_keys=True, ensure_ascii=False,
                      separators=(",", ":"), allow_nan=False).encode("utf-8")


def parse_canonical_input(text: str) -> Any:
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError("duplicate key")
            result[key] = value
        return result

    def integer(raw):
        if raw == "-0":
            raise ValueError("negative zero")
        value = int(raw)
        if abs(value) > MAX_SAFE:
            raise ValueError("unsafe integer")
        return value

    def reject(raw):
        raise ValueError("unsupported number: " + raw)

    value = json.loads(text, object_pairs_hook=pairs, parse_int=integer,
                       parse_float=reject, parse_constant=reject)
    _check(value)
    return value


def digest(domain: str, value: Any) -> str:
    if domain not in ("tree", "action", "plan"):
        raise ValueError("unknown digest domain")
    payload = ("jckg:" + domain + ":v1\0").encode("ascii") + canonical_bytes(value)
    return "sha256:" + hashlib.sha256(payload).hexdigest()


def portable_path(path: str) -> bool:
    """Conservative portable fixture policy, not an extraction implementation."""
    if not isinstance(path, str) or not path or "\\" in path:
        return False
    try:
        path.encode("utf-8", errors="strict")
    except UnicodeError:
        return False
    if any(ord(c) < 32 for c in path) or any(c in '<>:"|?*' for c in path):
        return False
    reserved = {"CON", "PRN", "AUX", "NUL"}
    reserved.update("COM" + str(n) for n in range(1, 10))
    reserved.update("LPT" + str(n) for n in range(1, 10))
    # Windows also reserves these superscript device-number forms.
    reserved.update(p + n for p in ("COM", "LPT") for n in ("¹", "²", "³"))
    for part in path.split("/"):
        if part in ("", ".", "..") or part.endswith((".", " ")):
            return False
        if part.split(".", 1)[0].upper() in reserved:
            return False
    return True
