"""Downloads only the scratch-detection checkpoint out of the 2 GB
global_checkpoints.zip release asset, using HTTP range requests against the
zip's central directory. Writes checkpoints/FT_Epoch_latest.pt.

Usage: uv run fetch_checkpoint.py
"""
import os, struct, zlib, urllib.request

URL = "https://github.com/microsoft/Bringing-Old-Photos-Back-to-Life/releases/download/v1.0/global_checkpoints.zip"
ENTRY = "checkpoints/detection/FT_Epoch_latest.pt"
OUT = "checkpoints/FT_Epoch_latest.pt"


def fetch(start, end):
    req = urllib.request.Request(URL, headers={"Range": f"bytes={start}-{end}"})
    with urllib.request.urlopen(req) as r:
        return r.read(), r.headers.get("Content-Range")


def central_directory():
    _, content_range = fetch(0, 0)
    total = int(content_range.split("/")[1])
    tail, _ = fetch(max(0, total - 65536), total - 1)
    i = tail.rfind(b"PK\x05\x06")
    if i < 0:
        raise RuntimeError("end of central directory not found")
    cd_size, cd_off = struct.unpack("<II", tail[i + 12:i + 20])
    if 0xFFFFFFFF in (cd_size, cd_off):  # zip64
        j = tail.rfind(b"PK\x06\x06")
        cd_size, cd_off = struct.unpack("<QQ", tail[j + 40:j + 56])
    cd, _ = fetch(cd_off, cd_off + cd_size - 1)
    p = 0
    while p < len(cd) and cd[p:p + 4] == b"PK\x01\x02":
        method = struct.unpack("<H", cd[p + 10:p + 12])[0]
        csize, usize = struct.unpack("<II", cd[p + 20:p + 28])
        nlen, elen, clen = struct.unpack("<HHH", cd[p + 28:p + 34])
        loff = struct.unpack("<I", cd[p + 42:p + 46])[0]
        name = cd[p + 46:p + 46 + nlen].decode()
        extra = cd[p + 46 + nlen:p + 46 + nlen + elen]
        if 0xFFFFFFFF in (csize, usize, loff):
            q = 0
            while q < len(extra):
                hid, hlen = struct.unpack("<HH", extra[q:q + 4]); q += 4
                if hid == 1:
                    vals = list(struct.unpack("<" + "Q" * (hlen // 8), extra[q:q + hlen]))
                    if usize == 0xFFFFFFFF: usize = vals.pop(0)
                    if csize == 0xFFFFFFFF: csize = vals.pop(0)
                    if loff == 0xFFFFFFFF: loff = vals.pop(0)
                q += hlen
        yield name, method, csize, usize, loff
        p += 46 + nlen + elen + clen


def main():
    entry = next((e for e in central_directory() if e[0] == ENTRY), None)
    if entry is None:
        raise RuntimeError(f"{ENTRY} not in archive")
    _, method, csize, usize, loff = entry
    header, _ = fetch(loff, loff + 29)
    if header[:4] != b"PK\x03\x04":
        raise RuntimeError("bad local file header")
    nlen, elen = struct.unpack("<HH", header[26:30])
    start = loff + 30 + nlen + elen
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    print(f"downloading {csize / 1e6:.0f} MB compressed → {OUT} ({usize / 1e6:.0f} MB)", flush=True)
    req = urllib.request.Request(URL, headers={"Range": f"bytes={start}-{start + csize - 1}"})
    inflate = zlib.decompressobj(-15) if method == 8 else None
    with urllib.request.urlopen(req) as r, open(OUT, "wb") as f:
        while chunk := r.read(1 << 20):
            f.write(inflate.decompress(chunk) if inflate else chunk)
        if inflate:
            f.write(inflate.flush())
    print("done", os.path.getsize(OUT), "bytes")


if __name__ == "__main__":
    main()
