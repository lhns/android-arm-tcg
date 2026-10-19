#!/usr/bin/env python3
"""Apply one boot byte-patch (from patches/boot-patches.toml) to one file.

Usage:
    patch_bytes.py <boot-patches.toml> <patch-id> <file>

The patch is looked up by its `id`. Two methods are supported:

  method = "offset"   verify `before` bytes at `offset`, write `after`.
  method = "string"   find `find`, replace with `replace` (padded to the same
                      length per `pad`: "nul", "space", or "none").

Every patch is idempotent and self-validating:
  * already in the patched state            -> print "skip", exit 0
  * matches the expected pre-patch state     -> patch it,    exit 0
  * expected bytes/needle absent             -> exit 3 (NOTE; caller decides)
  * bytes present but wrong / ambiguous      -> exit 1 (ABORT; nothing written)

A tiny dependency-free TOML reader handles the subset this project uses
(arrays of tables, string/boolean scalars, `#` comments). No third-party
modules, so it runs on any python3.
"""
import sys


def read_patches(path):
    """Parse the [[patch]] array-of-tables subset we use. Returns list[dict]."""
    patches, cur = [], None
    with open(path, "r", encoding="utf-8") as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("#"):
                continue
            if line == "[[patch]]":
                cur = {}
                patches.append(cur)
                continue
            if cur is None or "=" not in line:
                continue
            key = line.partition("=")[0].strip()
            val = line.partition("=")[2].strip()
            if val.startswith('"'):
                # Quoted basic string: take up to the closing quote (ignore any
                # trailing inline comment). Unescape \n \t \\ \" and \xNN.
                end = val.find('"', 1)
                inner = val[1:end] if end > 0 else val[1:]
                val = bytes(inner, "utf-8").decode("unicode_escape")
            else:
                val = val.split("#", 1)[0].strip()
                if val in ("true", "false"):
                    val = (val == "true")
            cur[key] = val
    return patches


def hexbytes(s):
    return bytes.fromhex("".join(s.split()))


def apply_offset(data, p):
    off = int(str(p["offset"]), 0)
    before, after = hexbytes(p["before"]), hexbytes(p["after"])
    if len(before) != len(after):
        print(f"ABORT {p['id']}: before/after length differ", file=sys.stderr)
        return None, 1
    cur = data[off:off + len(before)]
    if cur == after:
        print(f"skip  {p['id']} @ {hex(off)}: already patched")
        return data, 0
    if cur == before:
        data[off:off + len(after)] = after
        print(f"patch {p['id']} @ {hex(off)}: {before.hex()} -> {after.hex()}")
        return data, 0
    print(f"ABORT {p['id']} @ {hex(off)}: have {cur.hex()} want {before.hex()}", file=sys.stderr)
    return None, 1


def apply_string(data, p):
    find = p["find"].encode("latin-1")
    repl = p.get("replace", "").encode("latin-1")
    pad = p.get("pad", "none")
    if len(repl) < len(find):
        fill = {"nul": b"\x00", "space": b" "}.get(pad)
        if fill is None:
            print(f"ABORT {p['id']}: replace shorter than find and pad=none", file=sys.stderr)
            return None, 1
        repl = repl + fill * (len(find) - len(repl))
    if len(repl) != len(find):
        print(f"ABORT {p['id']}: replace length {len(repl)} != find length {len(find)}", file=sys.stderr)
        return None, 1
    n = data.count(find)
    if n == 0:
        if data.find(repl) >= 0:
            print(f"skip  {p['id']}: already patched")
            return data, 0
        print(f"NOTE  {p['id']}: needle not present in this file")
        return None, 3
    pos = data.find(find)
    data[pos:pos + len(repl)] = repl
    extra = f" ({n} occurrences; patched first)" if n > 1 else ""
    print(f"patch {p['id']} @ {hex(pos)}: string{extra}")
    return data, 0


def main(argv):
    if len(argv) != 4:
        print(__doc__)
        return 2
    toml_path, patch_id, target = argv[1], argv[2], argv[3]
    patches = read_patches(toml_path)
    match = [p for p in patches if p.get("id") == patch_id]
    if not match:
        print(f"ABORT: no patch with id={patch_id} in {toml_path}", file=sys.stderr)
        return 1
    p = match[0]
    with open(target, "rb") as fh:
        data = bytearray(fh.read())
    method = p.get("method", "offset")
    out, rc = apply_offset(data, p) if method == "offset" else apply_string(data, p)
    if rc == 0 and out is not None:
        with open(target, "wb") as fh:
            fh.write(out)
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv))
