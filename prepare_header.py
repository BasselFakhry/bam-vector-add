"""Prepare a private BaM header overlay; leave the installed source untouched."""
import pathlib
import re
import sys

source, destination = map(pathlib.Path, sys.argv[1:])
text = source.read_text()
# These variables are allocated with new[] in BaM 315fadfc. Accept an already
# corrected header, but refuse an unrelated API revision rather than guessing.
for name in ("tps", "temp", "temp1", "temp2", "temp3", "h_ranges",
             "h_ranges_page_starts", "h_ranges_dists", "ts"):
    if not re.search(r"\b" + name + r"\s*=\s*new\s+[^;]+\[", text):
        raise SystemExit(f"Unrecognized BaM allocation for {name}")
    text = re.sub(r"\bdelete\s+" + name + r"\s*;", f"delete[] {name};", text)

# Upstream flush dereferences page_translation even for unused cache slots.
# Small test arrays may not fill the 1 GiB cache. Skip those slots first.
anchor = "    if (page < pc->n_pages) {"
start = text.index("void __flush(page_cache_d_t* pc)")
pos = text.index(anchor, start) + len(anchor)
text = text[:pos] + "\n        if (pc->cache_pages[page].page_take_lock.load(simt::memory_order_relaxed) == FREE) return;" + text[pos:]
destination.parent.mkdir(parents=True, exist_ok=True)
destination.write_text(text)
print(f"Prepared private header: {destination}")
