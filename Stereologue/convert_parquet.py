#!/usr/bin/env python3
"""
Convert predictions_with_metadata.parquet to catalog.json for Stereologue.

Groups rows by uuid so each card appears once with nested detections.
This cuts JSON size roughly in half vs the flat row-per-detection format.
"""

import json
import pandas as pd
import numpy as np

INPUT = "predictions_with_metadata.parquet"
OUTPUT = "catalog.json"

def to_native(v):
    """Convert numpy types to Python natives for JSON serialization."""
    if isinstance(v, np.ndarray):
        return v.tolist()
    if isinstance(v, (np.integer,)):
        return int(v)
    if isinstance(v, (np.floating,)):
        if np.isnan(v):
            return None
        return float(v)
    if isinstance(v, float) and (v != v):  # NaN check
        return None
    if pd.isna(v):
        return None
    return v

def main():
    print(f"Reading {INPUT}...")
    df = pd.read_parquet(INPUT)
    print(f"  {len(df)} rows, {len(df.columns)} columns")

    print("Grouping by uuid and building cards...")
    cards = []
    grouped = df.groupby("uuid")

    for uuid, group in grouped:
        first = group.iloc[0]

        card = {
            "uuid": str(uuid),
            "title": to_native(first["title"]),
            "date_start": to_native(first.get("date_start")),
            "date_end": to_native(first.get("date_end")),
            "creator": to_native(first.get("creator")),
            "physical_form": to_native(first.get("physical_form")),
            "geographic_subjects": to_native(first.get("geographic_subjects")),
            "topic_subjects": to_native(first.get("topic_subjects")),
            "division": to_native(first.get("division")),
            "collection": to_native(first.get("collection")),
            "shelf_locator": to_native(first.get("shelf_locator")),
            "image_width": to_native(first.get("image_width")),
            "image_height": to_native(first.get("image_height")),
            "detections": [],
        }

        for _, row in group.iterrows():
            det_class = to_native(row.get("class"))
            if det_class is None:
                continue
            card["detections"].append({
                "class": det_class,
                "confidence": to_native(row.get("confidence")),
                "x": to_native(row.get("x")),
                "y": to_native(row.get("y")),
                "width": to_native(row.get("width")),
                "height": to_native(row.get("height")),
                "detection_id": to_native(row.get("detection_id")),
            })

        cards.append(card)

    print(f"  {len(cards)} unique cards")

    print(f"Writing {OUTPUT}...")
    with open(OUTPUT, "w") as f:
        json.dump(cards, f, separators=(",", ":"))

    import os
    size_mb = os.path.getsize(OUTPUT) / (1024 * 1024)
    print(f"  {size_mb:.1f} MB uncompressed")
    print("Done.")

if __name__ == "__main__":
    main()
