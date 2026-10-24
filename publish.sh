#!/usr/bin/env bash
# publish.sh — the publish path for Organize's static sites.
#
# ONE script, THREE sites. It is embedded verbatim into each site's CodeBuild
# buildspec by render.py, so organdonationreform.org, opodata.org and
# costlyeffects.organdonationreform.org publish and roll back through exactly the
# same code. It lives in organize-org/infra — Organize's own repository — and
# reaches AWS only as the buildspec each CodeBuild project holds.
#
#   publish.sh release <sha>     upload releases/<sha>/, prove it, move the pointer
#   publish.sh stage <sha>       upload releases/<sha>/ and stop before the pointer
#   publish.sh preview <pr>      upload b/pr-<pr>/, comment the link on the request
#   publish.sh rollback [<sha>]  move the pointer back (default: the previous one)
#
# `stage` is how this pipeline is cut over onto a site that is already live: the
# release lands in the bucket and can be compared against what is being served
# before anything points at it. It is also the honest dry run of a publish.
#
# The shape, and why it is this shape:
#
#   A release is a directory in S3 named for the commit, written once and never
#   again. What is LIVE is a pointer — the distribution's OriginPath. Publishing
#   is a pointer move; rolling back is the same move in reverse. Neither needs a
#   build, a toolchain, a laptop, or the source, which is the whole point: the
#   recovery path must not depend on the thing that broke.
#
#   The pointer's history is kept beside the releases, at _pointer/current and
#   _pointer/previous, because CloudFront will tell you where the pointer IS but
#   not where it WAS. Rollback reads those, so it works for whoever is holding it
#   at the time, with no memory of what shipped.
#
# Expects, from the buildspec's env: SITE BUCKET DIST OUT_DIR MIN_PAGES
# PREVIEW_HOST REPO KEEP_RELEASES. GITHUB_TOKEN only for `preview`.

set -euo pipefail

say() { printf '==> %s\n' "$*"; }
die() { printf 'publish: %s\n' "$*" >&2; exit 1; }

: "${SITE:?}" "${BUCKET:?}" "${DIST:?}" "${OUT_DIR:?}" "${MIN_PAGES:?}"
: "${KEEP_RELEASES:=20}"

POINTER_CURRENT="s3://$BUCKET/_pointer/current"
POINTER_PREVIOUS="s3://$BUCKET/_pointer/previous"

# ---------------------------------------------------------------- build output

# A build that "succeeded" and produced nothing is the failure this guards. Jekyll
# and Gatsby both exit 0 on an empty or half-rendered site often enough to matter,
# and the pointer move that follows is what makes such a build the live site.
check_build() {
  [ -d "$OUT_DIR" ] || die "no $OUT_DIR/ — refusing to publish"
  [ -f "$OUT_DIR/index.html" ] || die "no $OUT_DIR/index.html — refusing to publish"
  [ -s "$OUT_DIR/index.html" ] || die "$OUT_DIR/index.html is empty — refusing to publish"

  local pages
  pages=$(find "$OUT_DIR" -name '*.html' -type f | wc -l | tr -d ' ')
  say "$pages HTML pages in $OUT_DIR (floor $MIN_PAGES)"
  [ "$pages" -ge "$MIN_PAGES" ] ||
    die "only $pages pages, expected at least $MIN_PAGES — refusing to publish a site this much smaller than the last one"
}

# ------------------------------------------------------------------- the pointer

read_pointer() {  # read_pointer current|previous → the sha, or empty
  aws s3 cp "s3://$BUCKET/_pointer/$1" - 2>/dev/null | tr -d '[:space:]' || true
}

# What CloudFront actually serves right now. The pointer objects are our record of
# it; this is the truth. They are compared before every move, because a pointer
# moved by hand in the console would otherwise make our "previous" a lie.
live_origin_path() {
  aws cloudfront get-distribution-config --id "$DIST" \
    --query 'DistributionConfig.Origins.Items[0].OriginPath' --output text
}

# Move OriginPath to /releases/<sha>, and ONLY OriginPath.
#
# CloudFront has no partial update: you read the whole DistributionConfig, change
# your field, and write the whole thing back. Every pointer move is therefore a
# rewrite of the certificate, the aliases, the cache behaviour and the error
# responses, and the hazard is a field our document did not carry — dropped by an
# SDK version, or added by AWS since — being reset to its default on the way
# through. A read of our own document cannot show that, because the omission is
# already in both copies. Only AWS's own answer afterwards can, so the check is
# made AFTER the write: re-read the distribution and insist that exactly one leaf
# moved. The pre-image is kept, and it is a complete, valid DistributionConfig,
# so a failure here is reported with the document that puts it back.
move_pointer() {
  local sha="$1" want="/releases/$1"
  local etag changed

  aws cloudfront get-distribution-config --id "$DIST" > /tmp/dist-before.json
  etag=$(python3 -c "import json;print(json.load(open('/tmp/dist-before.json'))['ETag'])")
  python3 - "$want" <<'PY'
import json, sys
doc = json.load(open('/tmp/dist-before.json'))['DistributionConfig']
doc['Origins']['Items'][0]['OriginPath'] = sys.argv[1]
json.dump(doc, open('/tmp/dist-after.json', 'w'))
PY

  say "pointer → $want"
  aws cloudfront update-distribution --id "$DIST" --if-match "$etag" \
    --distribution-config file:///tmp/dist-after.json >/dev/null

  aws cloudfront get-distribution-config --id "$DIST" > /tmp/dist-live.json
  changed=$(python3 - <<'PY'
import json

def leaves(node, path=''):
    """Every scalar in the document, by its path. Compared as a mapping and not
    pairwise, so a field APPEARING or VANISHING is named rather than silently
    shifting every later comparison by one."""
    if isinstance(node, dict):
        for k, v in node.items():
            yield from leaves(v, f'{path}/{k}')
    elif isinstance(node, list):
        for i, v in enumerate(node):
            yield from leaves(v, f'{path}/{i}')
    else:
        yield path, node

a = dict(leaves(json.load(open('/tmp/dist-before.json'))['DistributionConfig']))
b = dict(leaves(json.load(open('/tmp/dist-live.json'))['DistributionConfig']))
print(' '.join(sorted(
    k for k in a.keys() | b.keys() if a.get(k, '<absent>') != b.get(k, '<absent>'))))
PY
)

  if [ "$changed" != "/Origins/Items/0/OriginPath" ]; then
    die "the pointer moved, but so did something else: $changed
The distribution as it was before this write is saved at /tmp/dist-before.json and is
a complete DistributionConfig. To put it back:
  aws cloudfront get-distribution-config --id $DIST --query ETag --output text
  aws cloudfront update-distribution --id $DIST --if-match <that etag> \\
    --distribution-config file:///tmp/dist-before.json"
  fi

  printf '%s' "$sha" | aws s3 cp - "$POINTER_CURRENT" --content-type text/plain --only-show-errors
}

# An invalidation makes the move visible. Waiting on it is what lets this script
# say "published" and mean it, rather than "asked CloudFront to publish".
invalidate_and_wait() {
  local id
  id=$(aws cloudfront create-invalidation --distribution-id "$DIST" --paths '/*' \
         --query 'Invalidation.Id' --output text)
  say "invalidation $id"
  aws cloudfront wait invalidation-completed --distribution-id "$DIST" --id "$id" ||
    say "WARNING: the invalidation did not complete in time; the pointer HAS moved and the edge will catch up"
}

# ----------------------------------------------------------------------- release

# The sha the pointer is on, or empty if it has never been moved. `--output text`
# renders an unset OriginPath as an empty line and a null as "None", and a `[ ]`
# test chained with && would take the whole script down under `set -e` when it is
# false, so this is a case and not a string of one-liners.
current_release() {
  local p
  p=$(live_origin_path)
  case "$p" in
    /releases/*) printf '%s' "${p#/releases/}" ;;
    *)           printf '' ;;
  esac
}

# Upload the build as releases/<sha>/ and prove it arrived. Shared by release and
# stage, so what gets staged and what gets published are the same bytes by the
# same code — a staged release is not a rehearsal of the real one, it IS it.
upload_release() {
  local sha="$1"
  check_build
  say "uploading releases/$sha/"
  aws s3 sync "$OUT_DIR/" "s3://$BUCKET/releases/$sha/" --delete --only-show-errors

  # A sync that reported success but wrote nothing would otherwise take the site
  # down at the pointer move. Ask S3, not the exit code.
  aws s3 ls "s3://$BUCKET/releases/$sha/index.html" >/dev/null ||
    die "releases/$sha/index.html is not in the bucket after the upload — refusing to go on"
}

cmd_stage() {
  local sha="$1"
  upload_release "$sha"
  say "staged releases/$sha/ — nothing points at it; $SITE is unchanged"
  say "to publish it:  publish.sh release $sha"
}

cmd_release() {
  local sha="$1" prev
  prev=$(current_release)
  upload_release "$sha"

  if [ -n "$prev" ]; then
    printf '%s' "$prev" | aws s3 cp - "$POINTER_PREVIOUS" --content-type text/plain --only-show-errors
    say "previous is $prev"
  fi

  move_pointer "$sha"
  invalidate_and_wait
  prune_releases
  say "published $SITE from $sha"
  if [ -n "$prev" ]; then
    say "to undo: publish.sh rollback   (back to $prev)"
  fi
}

# Old releases are superseded build output, but the two or three behind the live
# one are the rollback targets, so this keeps a generous window and only ever
# deletes what is neither live nor the recorded previous.
prune_releases() {
  local keep cur prev
  cur=$(read_pointer current); prev=$(read_pointer previous)
  keep=$(aws s3 ls "s3://$BUCKET/releases/" | awk '{print $2}' | tr -d '/' |
           sort | head -n "-$KEEP_RELEASES" 2>/dev/null || true)
  for sha in $keep; do
    [ "$sha" = "$cur" ] && continue
    [ "$sha" = "$prev" ] && continue
    say "pruning releases/$sha/"
    aws s3 rm "s3://$BUCKET/releases/$sha/" --recursive --only-show-errors
  done
}

# ---------------------------------------------------------------------- rollback

cmd_rollback() {
  local to="${1:-}" cur
  cur=$(live_origin_path); cur="${cur#/releases/}"

  if [ -z "$to" ]; then
    to=$(read_pointer previous)
    [ -n "$to" ] || die "no recorded previous release to go back to; name one: publish.sh rollback <sha>"
  fi
  [ "$to" != "$cur" ] || die "$to is already live"

  aws s3 ls "s3://$BUCKET/releases/$to/index.html" >/dev/null ||
    die "releases/$to/ is not in the bucket — it may have been pruned; 'aws s3 ls s3://$BUCKET/releases/' lists what is kept"

  printf '%s' "$cur" | aws s3 cp - "$POINTER_PREVIOUS" --content-type text/plain --only-show-errors
  move_pointer "$to"
  invalidate_and_wait
  say "rolled $SITE back to $to; $cur is now the previous one, so this is reversible the same way"
}

# ----------------------------------------------------------------------- preview

# A preview is a candidate, never production: its own hostname, its own prefix,
# the same URL for the life of the pull request so a new push updates it in place.
cmd_preview() {
  local pr="$1" url
  check_build
  : "${PREVIEW_HOST:?}" "${REPO:?}"

  say "uploading b/pr-$pr/"
  aws s3 sync "$OUT_DIR/" "s3://$BUCKET/b/pr-$pr/" --delete --only-show-errors
  url="https://pr-$pr.$PREVIEW_HOST/"
  say "preview: $url"

  [ -n "${GITHUB_TOKEN:-}" ] || { say "no GITHUB_TOKEN; not commenting"; return 0; }
  python3 - "$pr" "$url" "$REPO" "$GITHUB_TOKEN" <<'PY'
import json, sys, urllib.request
pr, url, repo, token = sys.argv[1:5]
body = (f"Preview of this pull request: {url}\n\n"
        "The link stays the same for this pull request, so a new push updates it "
        "in place. Nothing is live until this is merged.")
req = urllib.request.Request(
    f"https://api.github.com/repos/{repo}/issues/{pr}/comments",
    data=json.dumps({"body": body}).encode(),
    headers={"Authorization": f"Bearer {token}",
             "Accept": "application/vnd.github+json",
             "Content-Type": "application/json"})
try:
    urllib.request.urlopen(req, timeout=20).read()
    print("==> posted the preview link on the pull request")
except Exception as e:
    # The preview is up; failing the build over a comment would hide that.
    print(f"==> could not post the comment ({e}); the preview is still at {url}")
PY
}

# --------------------------------------------------------------------------- main

case "${1:-}" in
  release)  cmd_release  "${2:?a release needs the commit}" ;;
  stage)    cmd_stage    "${2:?staging needs the commit}" ;;
  preview)  cmd_preview  "${2:?a preview needs the pull request number}" ;;
  rollback) cmd_rollback "${2:-}" ;;
  *) die "usage: publish.sh release <sha> | stage <sha> | preview <pr> | rollback [<sha>]" ;;
esac
