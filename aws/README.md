# AWS offsite backup — S3 + Glacier Instant Retrieval

The offsite half of the backup story. The local half is a RAID 1 mirror at
`/srv/backup` (see `scripts/setup-raid.sh`), which survives a dead disk but not
a fire, a theft, or a delete.

- **Bucket:** `homeserver-restic-offsite-p5ke0zp2me`
- **Region:** `us-west-2` (Oregon)
- **Repo:** `s3:s3.us-west-2.amazonaws.com/homeserver-restic-offsite-p5ke0zp2me/restic`
- **IAM user:** `homeserver-restic` (no console access, scoped to this one bucket)

Credentials live in the git-ignored `.env` as `AWS_ACCESS_KEY_ID` /
`AWS_SECRET_ACCESS_KEY` / `AWS_DEFAULT_REGION` / `RESTIC_OFFSITE_REPOSITORY`.
They are never committed.

## Why Glacier Instant Retrieval, not Deep Archive

restic must be able to `GET` any pack file on demand to check, prune, or
restore. Glacier IR serves reads immediately. Deep Archive puts every read
behind a 12-hour thaw job, which breaks every restic operation. Deep Archive
saves about $8/year and costs you a backup that works.

## Why a lifecycle rule and not `-o s3.storage-class`

restic's own `s3.storage-class` option applies the class to **everything**,
including the small, frequently-rewritten `index/` and `snapshots/` objects.
restic only exempts metadata for `GLACIER` and `DEEP_ARCHIVE`, not for
`GLACIER_IR`. Putting metadata in Glacier IR would hit both the 128 KB minimum
billable size and the 90-day minimum storage duration on files that change
weekly.

So: a lifecycle rule filtered to `restic/data/` moves the bulk data cold, and
everything restic reads constantly stays in STANDARD.

## Files

| File | What it is |
|---|---|
| `bucket-lifecycle.json` | applied with `aws s3api put-bucket-lifecycle-configuration` |
| `iam-policy.json` | the IAM policy, with `__BUCKET__` as a placeholder |

## Manual console steps (not automatable with this IAM user, by design)

The `homeserver-restic` user deliberately cannot create buckets, create IAM
users, or read billing. Those were done once by hand:

1. S3 -> Create bucket, **General purpose** (global namespace), versioning
   **Enabled**, Block Public Access **all four on**, SSE-S3 encryption.
2. IAM -> Policies -> Create policy -> paste `iam-policy.json` with
   `__BUCKET__` replaced by the real bucket name.
3. IAM -> Users -> Create user `homeserver-restic`, **no console access**,
   attach that policy, create one access key.
4. Billing -> Budgets -> a $5/month cost budget with an email alert.

## Cost, at ~231 GiB

| Item | Monthly |
|---|---|
| Glacier IR storage | $0.92 |
| STANDARD metadata (~1 GB) | $0.03 |
| Requests, steady state | ~$0.02 |
| **Total** | **~$1.00** |

A full disaster restore is a one-time ~$28 (retrieval $0.03/GB + egress
$0.09/GB). That is the price of the insurance paying out, and it is cheap.
