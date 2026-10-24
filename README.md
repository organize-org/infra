# Organize's websites: how they are built, published and rolled back

This repository is Organize's own deploy code. It is here, in `organize-org`,
rather than in a contractor's repository, so that whoever holds this GitHub
organisation can read, change and run the pipeline for all three sites without
access to anything of Coa Solutions'. The sites do not depend on an engine
belonging to someone else.

| | source | AWS |
|---|---|---|
| organdonationreform.org | `organize-org/organdonationreform` | CodeBuild `odr-site` → `organdonationreform-org` → `E2R05YEKT1LB26` |
| opodata.org | `organize-org/opo-data` | CodeBuild `opodata-site` → `opodata-site` → `E1ZA50WGLCNLW2` |
| costlyeffects.organdonationreform.org | `organize-org/costly-effects` | CodeBuild `ord-site` → `costlyeffects-organdonationreform-org` → `ESJRQ7EDXGQIH` |

All in AWS account **245395155677**, us-east-1.

## The shape

A release is a directory in S3 named for the commit — `releases/<sha>/` — written
once and never again. What is **live** is a pointer: the CloudFront
distribution's `OriginPath`, which names one release.

- Publishing is a pointer move.
- Rolling back is the same move in reverse.

Neither needs a build, a toolchain, a laptop, or the source. That is the whole
reason for the shape: the recovery path must not depend on the thing that broke.

`_pointer/current` and `_pointer/previous` sit beside the releases, because
CloudFront will tell you where the pointer *is* but not where it *was*.

## Rolling back

About 25 seconds. Needs AWS credentials for the account and nothing else.

```sh
export AWS_PROFILE=<an admin profile for 245395155677>
export SITE=costlyeffects.organdonationreform.org \
       BUCKET=costlyeffects-organdonationreform-org \
       DIST=ESJRQ7EDXGQIH OUT_DIR=/tmp/unused MIN_PAGES=12
./publish.sh rollback              # back to the recorded previous release
./publish.sh rollback 4772557      # or to a named one
aws s3 ls s3://$BUCKET/releases/   # what is kept to go back to
```

Each site's variables are in `sites.toml`. A rollback records the release it
moved *off* as the new previous, so it is reversible the same way.

## Publishing

Automatic. A merge to `main` triggers the build by webhook, which builds, writes
the release and moves the pointer. A pull request publishes a preview and
comments the link on the request; the link stays the same for the life of the
request. Nothing is live until the request is merged.

## Changing the build

`sites.toml` and `publish.sh` are the source. The buildspec is generated:

```sh
python3.12 render.py costlyeffects            # print it
python3.12 render.py costlyeffects --check    # does the live project still match?
python3.12 render.py costlyeffects --push     # make the live project match
```

The buildspec lives in the CodeBuild project rather than in each site's own
repository, so a site repo stays nothing but the site. Generating it means the
definition is still in version control, `--check` catches a console edit, and
`publish.sh` goes into all three buildspecs byte for byte — so the sites cannot
drift apart in how they publish, only in the handful of lines `sites.toml`
allows.

`render.py` needs Python 3.11+ for `tomllib`.

## What refuses to publish

These are the point of the script, not decoration. Each has been exercised
against a live distribution, and each leaves the site exactly as it was.

- no output directory, no `index.html`, or an empty one
- fewer HTML pages than `min_pages` — the floor that catches a build which
  rendered a fraction of the site, which is the failure an exit code of 0 hides
- `index.html` not in the bucket after the upload, whatever the sync reported
- the distribution came back from the pointer move with **more than the pointer
  changed**. CloudFront has no partial update, so every publish rewrites the
  whole config; a field AWS reset would otherwise pass unnoticed. The check runs
  *after* the write, against AWS's own answer, and the refusal prints the command
  that puts the previous config back.
- a rollback to a release that is not in the bucket, or to the one already live

## What a build deliberately cannot do

Each build role may write `releases/`, `b/` and `_pointer/` in its own bucket and
is **denied the bucket root**. costlyeffects used to be published by
`aws s3 sync --delete` at the root from a laptop, which overwrote the only copy
of the site every time. No build can do that again — by permission, not by
convention.

Each preview distribution may read only `b/*` and `_error/*`, so a preview can
never serve a release even if its rewrite function is wrong.

## If you are taking this over

You need three things: this repository, the three site repositories, and
administrator access to AWS account **245395155677**. The account holds nothing
but these three websites. AWS has a documented process for moving an account to
a new owner's billing; everything in it survives intact. The domain
registrations are at Route 53 in the same account.

Nothing in this repository names a person, a profile or a system belonging to
the contractor. `render.py` uses whatever AWS credentials your shell already has
and checks it is pointed at the right account before it does anything.

**Two things in the AWS account are the contractor's and should be replaced when
the relationship ends. Neither stops the sites working.**

1. **`/organize/github-token`** (SSM, SecureString) is the token the builds post
   preview links with. It is currently the contractor's GitHub token and carries
   far more access than this needs. Replace it with a fine-grained token owned by
   Organize, scoped to the three site repositories with **pull requests: write**
   and nothing else. Until you do, a revoked token means pull-request previews
   stop being *commented* — they are still built and still published, because
   `publish.sh` treats a failed comment as a warning and carries on. Publishing
   to the live sites does not use this token at all.

2. **The three build roles** live under the IAM path `/fleet/managed/` and carry
   a permissions boundary named `fleet/guardrail/FleetManagedBoundary`. "fleet"
   is the contractor's word. The boundary policy lives **inside this account**,
   so it travels with the account and nothing breaks on handover — but if the
   naming bothers you, the roles can be recreated under any path with any
   boundary. The pipeline does not care what they are called.

Nothing else reaches outside the account.
