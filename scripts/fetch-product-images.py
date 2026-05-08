import argparse
import csv
import json
import mimetypes
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


IMAGE_EXTENSIONS = {
    "image/jpeg": ".jpg",
    "image/jpg": ".jpg",
    "image/png": ".png",
    "image/webp": ".webp",
    "image/gif": ".gif",
    "image/avif": ".avif",
}


def slugify(value, fallback):
    value = (value or "").strip().lower()
    value = re.sub(r'[\\/:*?"<>|]', " ", value)
    value = re.sub(r"\s+", "-", value)
    value = re.sub(r"[^\w\-\u4e00-\u9fff]", "-", value)
    value = re.sub(r"-+", "-", value).strip("-_ ")
    return value or fallback


def compact_text(value):
    return re.sub(r"[\s\W_]+", "", value or "", flags=re.UNICODE).lower()


def query_for(row, category_column, product_column, query_suffix):
    category = (row.get(category_column) or "").strip()
    product = (row.get(product_column) or "").strip()
    parts = []
    if category:
        parts.append(f'"{category}"')
    if product:
        parts.append(f'"{product}"')
        without_volume = re.sub(r"[（(][^）)]*(?:ml|ML|公升|L|l)[^）)]*[）)]", "", product).strip()
        if without_volume and without_volume != product:
            parts.append(f'"{without_volume}"')
    if query_suffix:
        parts.append(query_suffix.strip())
    return " ".join(parts)


def score_result(result, row, category_column, product_column):
    category = compact_text(row.get(category_column, ""))
    product = compact_text(row.get(product_column, ""))
    product_without_volume = compact_text(re.sub(r"[（(][^）)]*[）)]", "", row.get(product_column, "")))
    haystack = compact_text(" ".join([
        str(result.get("title") or ""),
        str(result.get("description") or ""),
        str(result.get("page_url") or ""),
        str(result.get("source") or ""),
        str((result.get("properties") or {}).get("url") or ""),
    ]))

    score = 0
    if product and product in haystack:
        score += 100
    if product_without_volume and product_without_volume in haystack:
        score += 60
    if category and category in haystack:
        score += 30

    volume_match = re.search(r"(\d+)\s*(ml|ML|公升|L|l)", row.get(product_column, ""))
    if volume_match:
        volume = volume_match.group(1)
        if volume in haystack:
            score += 15

    return score


def brave_image_search(api_key, query, count, country, search_lang, safesearch):
    params = {
        "q": query,
        "count": str(max(1, min(count, 200))),
        "country": country,
        "search_lang": search_lang,
        "safesearch": safesearch,
        "spellcheck": "false",
    }
    url = "https://api.search.brave.com/res/v1/images/search?" + urllib.parse.urlencode(params)
    request = urllib.request.Request(
        url,
        headers={
            "Accept": "application/json",
            "X-Subscription-Token": api_key,
            "User-Agent": "tunghsun-product-image-fetcher/1.0",
        },
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        payload = json.loads(response.read().decode("utf-8"))
    return payload.get("results") or []


def image_url_from_result(result):
    properties = result.get("properties") or {}
    thumbnail = result.get("thumbnail") or {}
    return properties.get("url") or thumbnail.get("src") or result.get("url")


def source_url_from_result(result):
    return result.get("page_url") or result.get("url") or ""


def extension_for(url, content_type):
    if content_type:
        normalized = content_type.split(";")[0].strip().lower()
        if normalized in IMAGE_EXTENSIONS:
            return IMAGE_EXTENSIONS[normalized]
    path = urllib.parse.urlparse(url).path
    suffix = Path(path).suffix.lower()
    if suffix in {".jpg", ".jpeg", ".png", ".webp", ".gif", ".avif"}:
        return ".jpg" if suffix == ".jpeg" else suffix
    guessed = mimetypes.guess_extension(content_type or "")
    return guessed if guessed in IMAGE_EXTENSIONS.values() else ".jpg"


def download_image(url, destination_base, force):
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"},
    )
    with urllib.request.urlopen(request, timeout=45) as response:
        content_type = response.headers.get("Content-Type", "")
        extension = extension_for(url, content_type)
        destination = destination_base.with_suffix(extension)
        if destination.exists() and not force:
            return destination
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(response.read())
    return destination


def read_rows(path):
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle)
        return list(reader), reader.fieldnames or []


def write_rows(path, rows, fieldnames):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def main():
    parser = argparse.ArgumentParser(description="Fetch product images with Brave Image Search.")
    parser.add_argument("--source-file", required=True)
    parser.add_argument("--output-file")
    parser.add_argument("--image-root", default="product-images")
    parser.add_argument("--api-key", default=os.environ.get("BRAVE_SEARCH_API_KEY", ""))
    parser.add_argument("--category-column", default="category")
    parser.add_argument("--product-column", default="product")
    parser.add_argument("--images-column", default="images")
    parser.add_argument("--product-slug-column", default="product_slug")
    parser.add_argument("--max-products", type=int, default=0)
    parser.add_argument("--max-images-per-product", type=int, default=1)
    parser.add_argument("--max-results-to-try", type=int, default=20)
    parser.add_argument("--query-suffix", default="產品 瓶身 酒瓶")
    parser.add_argument("--country", default="TW")
    parser.add_argument("--search-lang", default="zh-hant")
    parser.add_argument("--safesearch", default="strict")
    parser.add_argument("--min-score", type=int, default=30)
    parser.add_argument("--delay-seconds", type=float, default=0.2)
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--candidates-only", action="store_true")
    args = parser.parse_args()

    api_key = args.api_key.strip().strip("\"'")
    if not api_key:
        raise SystemExit("Brave Search API key is required. Pass --api-key or set BRAVE_SEARCH_API_KEY.")

    source_file = Path(args.source_file).resolve()
    output_file = Path(args.output_file).resolve() if args.output_file else source_file.with_name(source_file.stem + "-with-images.csv")
    image_root = Path(args.image_root).resolve()
    report_file = output_file.with_name(output_file.stem + ".image-report.csv")

    rows, fieldnames = read_rows(source_file)
    if args.images_column not in fieldnames:
        raise SystemExit(f"Images column '{args.images_column}' does not exist.")

    report_rows = []
    processed = 0

    for index, row in enumerate(rows, start=2):
        product = (row.get(args.product_column) or "").strip()
        if not product:
            report_rows.append({"Row": index, "Product": product, "Status": "Skipped: missing product", "Score": "", "File": "", "Url": "", "Source": ""})
            continue

        if args.max_products > 0 and processed >= args.max_products:
            break
        processed += 1

        if (row.get(args.images_column) or "").strip() and not args.force:
            report_rows.append({"Row": index, "Product": product, "Status": "Skipped: images already set", "Score": "", "File": row.get(args.images_column, ""), "Url": "", "Source": ""})
            continue

        product_slug = slugify(row.get(args.product_slug_column), f"product-{index}")
        query = query_for(row, args.category_column, args.product_column, args.query_suffix)
        print(f"Searching: {query}")

        try:
            results = brave_image_search(api_key, query, args.max_results_to_try, args.country, args.search_lang, args.safesearch)
        except urllib.error.HTTPError as exc:
            if exc.code == 401:
                raise SystemExit("Brave rejected the API key. Copy it from https://api-dashboard.search.brave.com/.") from exc
            raise

        ranked = sorted(
            ((score_result(result, row, args.category_column, args.product_column), result) for result in results),
            key=lambda item: item[0],
            reverse=True,
        )

        downloaded = []
        candidates = 0
        for score, result in ranked:
            if len(downloaded) >= args.max_images_per_product or (args.candidates_only and candidates >= args.max_images_per_product):
                break
            image_url = image_url_from_result(result)
            if not image_url:
                continue
            if score < args.min_score:
                report_rows.append({"Row": index, "Product": product, "Status": "Rejected: low score", "Score": score, "File": "", "Url": image_url, "Source": source_url_from_result(result)})
                continue

            candidates += 1
            relative_base = Path(product_slug) / f"{product_slug}-{candidates}"
            destination_base = image_root / relative_base

            if args.candidates_only:
                report_rows.append({"Row": index, "Product": product, "Status": "Candidate", "Score": score, "File": "", "Url": image_url, "Source": source_url_from_result(result)})
                continue

            try:
                saved = download_image(image_url, destination_base, args.force)
                relative = saved.relative_to(image_root)
                downloaded.append(str(relative).replace("\\", "/"))
                report_rows.append({"Row": index, "Product": product, "Status": "Downloaded", "Score": score, "File": str(relative).replace("\\", "/"), "Url": image_url, "Source": source_url_from_result(result)})
            except Exception as exc:
                report_rows.append({"Row": index, "Product": product, "Status": f"Download failed: {exc}", "Score": score, "File": "", "Url": image_url, "Source": source_url_from_result(result)})

        if downloaded:
            row[args.images_column] = ";".join(downloaded)
        elif not any(item["Row"] == index and item["Status"] != "Rejected: low score" for item in report_rows):
            report_rows.append({"Row": index, "Product": product, "Status": "No acceptable results", "Score": "", "File": "", "Url": "", "Source": ""})

        if args.delay_seconds > 0:
            time.sleep(args.delay_seconds)

    write_rows(output_file, rows, fieldnames)
    write_rows(report_file, report_rows, ["Row", "Product", "Status", "Score", "File", "Url", "Source"])
    print(f"Image CSV written: {output_file}")
    print(f"Report written: {report_file}")


if __name__ == "__main__":
    main()
