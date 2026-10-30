#!/usr/bin/env python3
"""Validate a Rill v1 JSONL export without sending any Redis commands."""
import base64
import hashlib
import json
import sys


def validate_export(stream):
    digest = hashlib.sha256()
    header = footer = None
    entries = payload = string_offset = file_bytes = 0

    def binary(value):
        if not isinstance(value, str):
            raise ValueError("binary field must be a base64 string")
        data = base64.b64decode(value, validate=True)
        if base64.b64encode(data).decode() != value:
            raise ValueError("noncanonical base64")
        return data

    while line := stream.readline(1024 * 1024 + 1):
        file_bytes += len(line)
        if len(line) > 1024 * 1024 or file_bytes > 256 * 1024 * 1024 or not line.endswith(b"\n"):
            raise ValueError("truncated line or size limit exceeded")
        if footer is not None:
            raise ValueError("data after footer")
        item = json.loads(line)
        if not isinstance(item, dict):
            raise ValueError("record must be a JSON object")
        record = item.get("record")
        if record == "header":
            if header is not None or entries:
                raise ValueError("duplicate or misplaced header")
            header = item["header"]
            if header["version"] != 1 or header["kind"] not in {"string", "hash", "list", "set", "zset", "stream"}:
                raise ValueError("unsupported version or type")
            binary(header["keyBase64"])
            if type(header["count"]) is not int or header["count"] < 0:
                raise ValueError("invalid original count")
        elif record == "entry":
            if header is None:
                raise ValueError("missing header")
            entry, kind = item["entry"], header["kind"]
            if kind == "string":
                value = binary(entry["value"])
                if entry["offset"] != string_offset:
                    raise ValueError("noncontiguous string chunk")
                string_offset += len(value)
            elif kind == "hash":
                binary(entry["field"]); binary(entry["value"])
            elif kind == "list":
                if entry["index"] != entries:
                    raise ValueError("noncontiguous list index")
                binary(entry["value"])
            elif kind == "set":
                binary(entry["value"])
            elif kind == "zset":
                binary(entry["field"])
                if not isinstance(entry["score"], str):
                    raise ValueError("score must preserve its original string")
            else:
                binary(entry["field"])
                fields = entry["streamFields"]
                if not isinstance(fields, list) or len(fields) % 2:
                    raise ValueError("invalid stream field pairs")
                for field in fields:
                    binary(field)
            payload += sum(len(binary(entry[key])) for key in ("field", "value") if key in entry)
            payload += sum(len(binary(field)) for field in entry.get("streamFields", []))
            entries += 1
        elif record == "footer":
            footer = item["footer"]
            if header is None or footer["sha256"] != digest.hexdigest():
                raise ValueError("missing header or SHA-256 mismatch")
            if footer["complete"] is not True:
                raise ValueError("incomplete export: " + str(footer.get("failure", "unknown cause")))
            if footer["entries"] != entries or footer["payloadBytes"] != payload:
                raise ValueError("footer counts do not match")
            if (header["kind"] == "string" and string_offset != header["count"]) or (header["kind"] != "string" and entries != header["count"]):
                raise ValueError("payload does not match header count")
        else:
            raise ValueError("unknown record")
        if record != "footer":
            digest.update(line)
    if footer is None:
        raise ValueError("missing footer; export is incomplete")
    return header, footer


if __name__ == "__main__":
    try:
        if len(sys.argv) != 2:
            raise ValueError("usage: python3 scripts/verify-export.py /path/to/key.jsonl")
        with open(sys.argv[1], "rb") as source:
            header, footer = validate_export(source)
        print(f"PASS: v1 {header['kind']}, {footer['entries']} records, SHA-256 verified; expiry={header['expiryMode']}. Live read, not a snapshot.")
    except (ValueError, KeyError, TypeError, OSError) as error:
        print(f"INVALID: {error}", file=sys.stderr)
        sys.exit(2)
