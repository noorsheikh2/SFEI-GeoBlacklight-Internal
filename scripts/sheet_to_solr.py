#!/usr/bin/env python3
"""
Sync the SFEI "Metadata Upload Doc" Google Sheet into GeoBlacklight's Solr core,
and automatically sync referenced thumbnail images from Google Drive into public/thumbnails/.

The sheet layout this script expects:
  Row 1  - human-readable column labels ("Title", "Bounding Box (West Longitude)", ...)
  Row 2  - GeoBlacklight/Solr field names ("dct_title_s", "dcat_bbox", ...)
  Row 3  - "Required (by whom)" notes (ignored)
  Row 4+ - one record per row
Column A ("Label") is ignored.

Image Sync Behavior:
  - Scans converted records for 'sfei_image_name_s'.
  - Checks if the file already exists in public/thumbnails/.
  - Existing files are SKIPPED (not re-downloaded).
  - New/missing files are downloaded from Google Drive using gdown (or an optional Service Account).

Usage:
  python3 sheet_to_solr_with_images.py --dry-run
  python3 sheet_to_solr_with_images.py
  python3 sheet_to_solr_with_images.py --skip-images
  python3 sheet_to_solr_with_images.py --images-dir /path/to/local/source
"""

import argparse
import csv
import io
import json
import os
import re
import shutil
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

# --------------------------------------------------------------------------
# Settings
# --------------------------------------------------------------------------
SHEET_ID = "1Kv6W_hUBSz8dmYAqxvS_J_Y5UWXCgTYoaZSkK5WgYSs"
SHEET_GID = "0"  # the tab to export; "0" is the first tab
SOLR_URL = "http://localhost:8983/solr/blacklight-core"
GDRIVE_FOLDER_ID = "17D5TLgcpPV83MimUhCafa9roncOSgHsa"
GDRIVE_FOLDER_URL = f"https://drive.google.com/drive/folders/{GDRIVE_FOLDER_ID}"

# Default output directory for thumbnail images
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_THUMBNAILS_DIR = os.path.join(SCRIPT_DIR, "SFEI-GeoBlacklight-Internal", "public", "thumbnails")
if not os.path.isdir(DEFAULT_THUMBNAILS_DIR):
    # If run from inside SFEI-GeoBlacklight-Internal directory
    alt_dir = os.path.join(SCRIPT_DIR, "public", "thumbnails")
    if os.path.isdir(alt_dir):
        DEFAULT_THUMBNAILS_DIR = alt_dir

ID_PREFIX = "sfei-"           # generated IDs look like sfei-baylands-habitat-map-2020-v1-3-bhm2020
INCLUDE_CUSTOM_FIELDS = True  # index SFEI columns that have no field name (Citation, Data Version, ...)

FIELD_ROW = 1        # zero-based: row 2 in the sheet
FIRST_DATA_ROW = 3   # zero-based: row 4 in the sheet

# If these field names are missing from row 2, the sheet layout has changed
# (or Google returned something other than the sheet), so we stop before touching Solr.
EXPECTED_FIELDS = {"dct_title_s", "dct_accessRights_s"}

# Multi-valued fields are split on ";". These are also split on ",".
COMMA_SPLIT_FIELDS = {"dct_subject_sm", "dcat_keyword_sm"}
# These are never split, even though they are multi-valued.
NEVER_SPLIT_FIELDS = {"dct_description_sm"}

# Values like "Polygon (MultiPolygon)" in the Geometry column are geometry *types*,
# which belong in Resource Type, not in locn_geometry.
GEOMETRY_TYPE_TO_RESOURCE_TYPE = {
    "polygon": "Polygon data",
    "line": "Line data",
    "point": "Point data",
    "raster": "Raster data",
}
# Real geometry looks like "ENVELOPE(-122.7,..." or "POLYGON((-122.7 ...": a keyword,
# then parentheses, then a number. "Polygon (MultiPolygon)" does not match.
WKT_PATTERN = re.compile(
    r"^\s*(ENVELOPE|POLYGON|MULTIPOLYGON|POINT|MULTIPOINT|LINESTRING|MULTILINESTRING)"
    r"\s*\(\s*\(*\s*-?\d", re.IGNORECASE)

INVISIBLE_CHARS = dict.fromkeys(map(ord, "\u200b\u200c\u200d\u2060\ufeff"), None)


# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------
def log(message):
    stamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{stamp}] {message}", flush=True)


def clean(value):
    """Strip whitespace and the invisible characters Google Sheets leaves in 'empty' cells."""
    if value is None:
        return ""
    return value.translate(INVISIBLE_CHARS).replace("\xa0", " ").strip()


def slugify(text, separator="-"):
    slug = re.sub(r"[^a-z0-9]+", separator, text.lower()).strip(separator)
    return slug[:80].rstrip(separator)


def split_values(raw, field):
    if field in NEVER_SPLIT_FIELDS:
        return [raw]
    pattern = r"[;,]" if field in COMMA_SPLIT_FIELDS else r";"
    values = []
    for part in re.split(pattern, raw):
        part = part.strip()
        if part and part not in values:
            values.append(part)
    return values


def parse_float(value):
    try:
        return float(clean(value))
    except (TypeError, ValueError):
        return None


def make_envelope(west, east, north, south):
    """Return a valid ENVELOPE string, or None if the numbers don't make sense."""
    if None in (west, east, north, south):
        return None
    if not (-180 <= west <= 180 and -180 <= east <= 180):
        return None
    if not (-90 <= south <= north <= 90):
        return None
    return f"ENVELOPE({west:.6f},{east:.6f},{north:.6f},{south:.6f})"


def parse_envelope(text):
    """Parse 'ENVELOPE(w,e,n,s)', tolerating the trailing comma the sheet currently has."""
    match = re.match(r"\s*ENVELOPE\s*\(([^)]*)\)", text or "", re.IGNORECASE)
    if not match:
        return None
    numbers = [parse_float(n) for n in match.group(1).split(",") if n.strip()]
    if len(numbers) != 4:
        return None
    return numbers


# --------------------------------------------------------------------------
# Download & Ingest
# --------------------------------------------------------------------------
def download_sheet_csv():
    url = (f"https://docs.google.com/spreadsheets/d/{SHEET_ID}/export"
           f"?format=csv&gid={SHEET_GID}")
    request = urllib.request.Request(url, headers={"User-Agent": "sfei-geoblacklight-sync"})
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            content_type = response.headers.get("Content-Type", "")
            text = response.read().decode("utf-8-sig")
    except urllib.error.URLError as error:
        raise SystemExit(f"ERROR: could not download the sheet: {error}")

    # If sharing settings change, Google returns an HTML sign-in page instead of the CSV.
    if "text/csv" not in content_type or text.lstrip().startswith("<"):
        raise SystemExit("ERROR: Google did not return a CSV (the sheet may no longer be "
                         "shared as 'anyone with the link can view'). Solr was not changed.")
    return text


def plan_columns(labels, fields):
    """Work out which Solr field each column goes into."""
    plan = {}
    bbox_columns = {}
    for index in range(1, max(len(labels), len(fields))):  # skip column A ("Label")
        label = clean(labels[index]) if index < len(labels) else ""
        field = clean(fields[index]) if index < len(fields) else ""
        label_lower = label.lower()

        if field:
            plan[index] = field
        elif "west longitude" in label_lower:
            bbox_columns["west"] = index
        elif "east longitude" in label_lower:
            bbox_columns["east"] = index
        elif "north latitude" in label_lower:
            bbox_columns["north"] = index
        elif "south latitude" in label_lower:
            bbox_columns["south"] = index
        elif label and INCLUDE_CUSTOM_FIELDS:
            plan[index] = f"sfei_{slugify(label, '_')}_s"
    return plan, bbox_columns


def convert_row(row, row_number, plan, bbox_columns, warnings):
    def warn(message):
        warnings.append(f"Row {row_number}: {message}")

    doc = {}
    for index, field in plan.items():
        raw = clean(row[index]) if index < len(row) else ""
        if not raw:
            continue
        if field.endswith("_sm") or field.endswith("_drsim"):
            doc[field] = split_values(raw, field)
        elif field.endswith("_im"):
            numbers = []
            for part in re.split(r"[;,]", raw):
                part = part.strip()
                if re.fullmatch(r"-?\d+", part):
                    numbers.append(int(part))
                elif part:
                    warn(f"'{part}' in {field} is not a whole number; skipped it")
            if numbers:
                doc[field] = numbers
        elif field.endswith("_b"):
            if raw.lower() in ("true", "yes", "y", "1"):
                doc[field] = True
            elif raw.lower() in ("false", "no", "n", "0"):
                doc[field] = False
            else:
                warn(f"'{raw}' in {field} is not true/false; skipped it")
        else:
            doc[field] = raw

    title = doc.get("dct_title_s")
    if not title:
        return None  # blank row

    if not doc.get("dct_accessRights_s"):
        warn(f"'{title}' has no Access Rights; skipped the whole record")
        return None

    # Geometry *type* (e.g. "Polygon (MultiPolygon)") -> Resource Type
    geometry = doc.get("locn_geometry")
    if geometry and not WKT_PATTERN.match(geometry):
        first_word = geometry.split()[0].lower()
        resource_type = GEOMETRY_TYPE_TO_RESOURCE_TYPE.get(first_word)
        if resource_type:
            types = doc.setdefault("gbl_resourceType_sm", [])
            if resource_type not in types:
                types.append(resource_type)
        del doc["locn_geometry"]

    # Bounding box: prefer the four W/E/N/S columns, fall back to the ENVELOPE column
    envelope = None
    if len(bbox_columns) == 4:
        parts = {side: parse_float(row[i]) if i < len(row) else None
                 for side, i in bbox_columns.items()}
        envelope = make_envelope(parts["west"], parts["east"], parts["north"], parts["south"])
    if not envelope and doc.get("dcat_bbox"):
        numbers = parse_envelope(doc["dcat_bbox"])
        if numbers:
            envelope = make_envelope(*numbers)

    if envelope:
        doc["dcat_bbox"] = envelope
        if not doc.get("locn_geometry"):
            doc["locn_geometry"] = envelope
        if not doc.get("dcat_centroid"):
            west, east, north, south = parse_envelope(envelope)
            doc["dcat_centroid"] = f"{(north + south) / 2:.6f},{(west + east) / 2:.6f}"
    else:
        doc.pop("dcat_bbox", None)
        warn(f"'{title}' has no valid bounding box; it won't appear on the map")

    # References: plain URL -> GeoBlacklight's JSON format (shows a Download button)
    references = doc.get("dct_references_s")
    if references:
        if references.startswith("{"):
            try:
                json.loads(references)
            except ValueError:
                warn(f"'{title}' has invalid JSON in References; skipped that field")
                del doc["dct_references_s"]
        else:
            urls = [u for u in re.split(r"[\s;,]+", references) if u.startswith("http")]
            if urls:
                doc["dct_references_s"] = json.dumps({"http://schema.org/downloadUrl": urls[0]})
            else:
                warn(f"'{title}' References is not a URL; skipped that field")
                del doc["dct_references_s"]

    # Defaults for required / housekeeping fields
    doc.setdefault("gbl_mdVersion_s", "Aardvark")
    doc.setdefault("gbl_suppressed_b", False)
    doc["gbl_mdModified_dt"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    if not doc.get("gbl_resourceClass_sm"):
        doc["gbl_resourceClass_sm"] = ["Other"]
        warn(f"'{title}' has no Resource Class; using 'Other'")

    if not doc.get("id"):
        doc["id"] = ID_PREFIX + slugify(title)
    return doc


def convert_sheet(text):
    rows = list(csv.reader(io.StringIO(text)))
    if len(rows) <= FIELD_ROW:
        raise SystemExit("ERROR: the sheet has fewer rows than expected. Solr was not changed.")

    labels, fields = rows[0], rows[FIELD_ROW]
    found_fields = {clean(f) for f in fields}
    missing = EXPECTED_FIELDS - found_fields
    if missing:
        raise SystemExit(f"ERROR: row 2 is missing expected field names {sorted(missing)}. "
                         "The sheet layout may have changed. Solr was not changed.")

    plan, bbox_columns = plan_columns(labels, fields)
    warnings, docs, seen_ids = [], [], {}

    for offset, row in enumerate(rows[FIRST_DATA_ROW:]):
        row_number = FIRST_DATA_ROW + offset + 1
        doc = convert_row(row, row_number, plan, bbox_columns, warnings)
        if doc is None:
            continue
        base_id = doc["id"]
        count = seen_ids.get(base_id, 0) + 1
        seen_ids[base_id] = count
        if count > 1:
            doc["id"] = f"{base_id}-{count}"
            warnings.append(f"Row {row_number}: duplicate title, so the ID became {doc['id']}")
        docs.append(doc)

    return docs, warnings


# --------------------------------------------------------------------------
# Image Sync
# --------------------------------------------------------------------------
def sync_thumbnails(docs, output_dir=DEFAULT_THUMBNAILS_DIR, source_dir=None, dry_run=False):
    """
    Ensures images referenced by sfei_image_name_s in docs are present in output_dir.
    Files that already exist are NEVER re-downloaded (immutability rule).
    """
    os.makedirs(output_dir, exist_ok=True)

    # Collect unique non-empty image filenames
    referenced_images = set()
    for doc in docs:
        img_name = doc.get("sfei_image_name_s")
        if img_name:
            # Handle if full path or just basename is given
            referenced_images.add(os.path.basename(img_name.strip()))

    if not referenced_images:
        log("No image filenames referenced in records.")
        return

    log(f"Referenced images in records: {len(referenced_images)}")
    missing = []
    already_present = []

    for img in sorted(referenced_images):
        dest_path = os.path.join(output_dir, img)
        if os.path.exists(dest_path):
            already_present.append(img)
        else:
            missing.append(img)

    log(f"Image status: {len(already_present)} already exist (skipping), {len(missing)} missing.")

    if not missing:
        log("All referenced images are already present on disk.")
        return

    if dry_run:
        log(f"Dry run: {len(missing)} images would need to be synced: {missing}")
        return

    # Strategy 1: Copy from a local directory (e.g. mounted drive or local backup)
    if source_dir and os.path.isdir(source_dir):
        log(f"Attempting to copy missing images from source directory: {source_dir}")
        for img in missing[:]:
            src_file = os.path.join(source_dir, img)
            if os.path.isfile(src_file):
                dest_file = os.path.join(output_dir, img)
                shutil.copy2(src_file, dest_file)
                log(f"  Copied {img} -> {dest_file}")
                missing.remove(img)

    # Strategy 2: Download missing images from Google Drive via gdown if available
    if missing:
        try:
            import gdown
            log(f"Attempting to sync missing images from Google Drive folder ({GDRIVE_FOLDER_ID})...")
            # gdown download_folder will check output directory and skip files that already exist
            gdown.download_folder(
                id=GDRIVE_FOLDER_ID,
                output=output_dir,
                quiet=True,
                remaining_ok=True
            )
            # Re-check which files are still missing
            still_missing = [img for img in missing if not os.path.exists(os.path.join(output_dir, img))]
            if still_missing:
                log(f"WARNING: {len(still_missing)} images were not found in Google Drive: {still_missing}")
            else:
                log("Successfully synced missing images from Google Drive!")
        except ImportError:
            log("NOTE: 'gdown' package is not installed. To enable automated Google Drive sync, run:")
            log("  pip install gdown")
            log(f"Currently missing images: {missing}")
        except Exception as e:
            log(f"WARNING: Could not complete Google Drive sync: {e}")


# --------------------------------------------------------------------------
# Solr
# --------------------------------------------------------------------------
def solr_request(path, payload=None):
    url = f"{SOLR_URL}/{path}"
    data = None
    headers = {}
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(url, data=data, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8", errors="replace")
        try:
            message = json.loads(body).get("error", {}).get("msg", body)
        except ValueError:
            message = body
        raise RuntimeError(f"Solr returned {error.code}: {message}")


def count_solr_docs():
    result = solr_request("select?q=*:*&rows=0&wt=json")
    return result["response"]["numFound"]


def update_solr(docs):
    try:
        before = count_solr_docs()
    except (urllib.error.URLError, RuntimeError) as error:
        raise SystemExit(f"ERROR: could not reach Solr at {SOLR_URL}: {error}")

    added, failed = 0, []
    for doc in docs:
        try:
            solr_request("update", [doc])
            added += 1
        except RuntimeError as error:
            failed.append((doc["id"], str(error)))

    if added == 0:
        log("ERROR: no records could be added, so nothing was deleted or committed.")
        for doc_id, message in failed:
            log(f"  FAILED {doc_id}: {message}")
        return 1

    keep = " OR ".join(f'"{doc["id"]}"' for doc in docs)
    solr_request("update", {"delete": {"query": f"*:* -id:({keep})"}})
    solr_request("update", {"commit": {}})

    after = count_solr_docs()
    log(f"Solr updated: {added} added/updated, {len(failed)} failed. "
        f"Records in Solr: {before} before, {after} after.")
    for doc_id, message in failed:
        log(f"  FAILED {doc_id}: {message}")
    return 1 if failed else 0


# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(description="Sync the SFEI Google Sheet and images into Solr.")
    parser.add_argument("--dry-run", action="store_true",
                        help="convert and print the records without changing Solr or images")
    parser.add_argument("--csv-file", help="read this local CSV instead of downloading the sheet")
    parser.add_argument("--skip-images", action="store_true", help="skip thumbnail image synchronization")
    parser.add_argument("--images-dir", help="local directory with images to copy from (e.g. mounted drive)")
    parser.add_argument("--thumbnails-dir", default=DEFAULT_THUMBNAILS_DIR,
                        help=f"destination directory for thumbnails (default: {DEFAULT_THUMBNAILS_DIR})")
    args = parser.parse_args()

    if args.csv_file:
        with open(args.csv_file, encoding="utf-8-sig") as handle:
            text = handle.read()
        log(f"Read {args.csv_file}")
    else:
        text = download_sheet_csv()
        log("Downloaded the Google Sheet")

    docs, warnings = convert_sheet(text)
    log(f"Converted {len(docs)} records")
    for warning in warnings:
        log(f"  WARNING {warning}")

    if not docs:
        log("ERROR: no records found in the sheet, so Solr was not changed.")
        return 1

    # Sync thumbnail images if not skipped
    if not args.skip_images:
        sync_thumbnails(
            docs=docs,
            output_dir=args.thumbnails_dir,
            source_dir=args.images_dir,
            dry_run=args.dry_run
        )

    if args.dry_run:
        print(json.dumps(docs, indent=2, ensure_ascii=False))
        log("Dry run: Solr was not changed.")
        return 0

    return update_solr(docs)


if __name__ == "__main__":
    sys.exit(main())
