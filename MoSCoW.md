# MoSCoW — amber-glycin

Prioritisation by **Must / Should / Could / Won't have** (the lower-case Os just make it
pronounceable). This is the **scope** document, and it holds only what is **still open**: an
item leaves this file the moment it ships. Nothing here records work done — `git log` is for
that.

An empty band means that band is finished, not that it was never populated.

## Must have

## Should have

## Could have

**The RAW loader.** `glycin-raw` is upstream's but not in the default set; check what it
pulls in and what it decodes before adding it to `LOADERS`.

## Won't have (this time)

**HEIF, AVIF and JPEG XL loaders.** `glycin-heif` needs libheif >= 1.20 and `glycin-jxl` needs
libjxl >= 0.11.1; Ubuntu noble ships 1.17 and 0.7. They are left out of `LOADERS` until Ubuntu
ships those versions; bundling the two libraries is not planned.
