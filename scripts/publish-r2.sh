#!/usr/bin/env bash
set -euo pipefail

: "${R2_ACCOUNT_ID:?Set the Cloudflare account ID}"
: "${R2_BUCKET_NAME:?Set the production R2 bucket}"
: "${R2_PUBLIC_URL:?Set the public download domain}"
: "${AWS_ACCESS_KEY_ID:?Set the bucket-scoped R2 access key}"
: "${AWS_SECRET_ACCESS_KEY:?Set the bucket-scoped R2 secret key}"

repo="${GITHUB_REPOSITORY:-LiuLawrence45/stt-sparkle-update}"
endpoint="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
public_url="${R2_PUBLIC_URL%/}"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

# Always start from the current feed, even when an older workflow event was queued.
git fetch origin main
git checkout --detach origin/main
feed_blob="$(git rev-parse HEAD:appcast.xml)"
python3 - "$work_dir" <<'PY'
import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
item = ET.parse("appcast.xml").getroot().find("./channel/item")
version = item.findtext("sparkle:shortVersionString", namespaces=ns)
if not version or not re.fullmatch(r"[0-9][0-9A-Za-z.-]*", version):
    raise SystemExit("The feed must contain a valid release version")
asset = item.find("enclosure")
manifest = {
    "tag": "v" + version,
    "url": asset.attrib["url"],
    "length": int(asset.attrib["length"]),
    "signature": asset.attrib["{" + ns["sparkle"] + "}edSignature"],
}
Path(sys.argv[1], "manifest.json").write_text(json.dumps(manifest))
PY
tag="$(jq -r .tag "$work_dir/manifest.json")"
gh release view "$tag" --repo "$repo" --json isDraft,isPrerelease \
  | jq -e '.isDraft == false and .isPrerelease == false' >/dev/null
gh release download "$tag" --repo "$repo" --pattern Willow.Installer.dmg \
  --output "$work_dir/Willow.Installer.dmg"

# Verify against the public key embedded in existing Mac apps before serving any bytes.
node - "$work_dir" <<'JS'
const fs = require("node:fs");
const crypto = require("node:crypto");
const directory = process.argv[2];
const manifest = JSON.parse(fs.readFileSync(`${directory}/manifest.json`, "utf8"));
const installer = fs.readFileSync(`${directory}/Willow.Installer.dmg`);
const key = crypto.createPublicKey({
  key: Buffer.concat([
    Buffer.from("302a300506032b6570032100", "hex"),
    Buffer.from("BCYOgnP6FTikbrrbSe9cBAFC8sXND7KhWeFnd0Pu8eA=", "base64"),
  ]),
  format: "der",
  type: "spki",
});
if (installer.length !== manifest.length ||
    !crypto.verify(null, installer, key, Buffer.from(manifest.signature, "base64"))) {
  throw new Error("Installer size or Sparkle signature does not match the feed");
}
console.log(`Verified ${manifest.tag}: ${installer.length} bytes, valid Sparkle signature`);
JS

object_key="mac/$tag/Willow.Installer.dmg"
download_url="$public_url/$object_key"
# Cached release URLs must never change bytes when a workflow is rerun.
if aws s3api head-object --bucket "$R2_BUCKET_NAME" --key "$object_key" \
  --endpoint-url "$endpoint" --region auto > /dev/null 2> "$work_dir/head-error"; then
  aws s3 cp "s3://$R2_BUCKET_NAME/$object_key" "$work_dir/existing.dmg" \
    --endpoint-url "$endpoint" --region auto --only-show-errors
  if ! cmp -s "$work_dir/Willow.Installer.dmg" "$work_dir/existing.dmg"; then
    echo "Refusing to replace different bytes at $object_key" >&2
    exit 1
  fi
elif grep -Eq '\((404|NoSuchKey)\)' "$work_dir/head-error"; then
  aws s3 cp "$work_dir/Willow.Installer.dmg" "s3://$R2_BUCKET_NAME/$object_key" \
    --endpoint-url "$endpoint" --region auto --only-show-errors \
    --content-type application/x-apple-diskimage \
    --content-disposition 'attachment; filename="Willow.Installer.dmg"' \
    --cache-control 'public, max-age=31536000, immutable'
else
  cat "$work_dir/head-error" >&2
  exit 1
fi
curl --fail --silent --show-error --location --retry 3 --max-time 180 \
  "$download_url" --output "$work_dir/public.dmg"
cmp "$work_dir/Willow.Installer.dmg" "$work_dir/public.dmg"

# A release published during the transfer must keep its newer appcast and latest link.
git fetch origin main
if [[ "$feed_blob" != "$(git rev-parse origin/main:appcast.xml)" ]]; then
  echo "A newer appcast was published; leaving it and the latest installer unchanged."
  exit 0
fi
git checkout --detach origin/main
python3 - "$work_dir/manifest.json" "$download_url" <<'PY'
import html
import json
import sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text())
path = Path("appcast.xml")
source = path.read_text()
old = 'url="' + html.escape(manifest["url"], quote=True) + '"'
new = 'url="' + html.escape(sys.argv[2], quote=True) + '"'
if source.count(old) != 1:
    raise SystemExit("Expected exactly one matching appcast download URL")
path.write_text(source.replace(old, new, 1))
PY
if ! git diff --quiet -- appcast.xml; then
  git config user.name github-actions[bot]
  git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
  git add appcast.xml
  git commit -m "Serve $tag Mac updates from the download CDN"
  git push origin HEAD:main
fi

# Bot commits do not trigger the repository's legacy GitHub Pages build.
gh api --method POST "repos/$repo/pages/builds" --silent

aws s3 cp "$work_dir/Willow.Installer.dmg" \
  "s3://$R2_BUCKET_NAME/mac/latest/Willow.Installer.dmg" \
  --endpoint-url "$endpoint" --region auto --only-show-errors \
  --content-type application/x-apple-diskimage \
  --content-disposition 'attachment; filename="Willow.Installer.dmg"' \
  --cache-control 'public, max-age=60, must-revalidate'
echo "Published $download_url; website latest can remain cached for up to 60 seconds."
