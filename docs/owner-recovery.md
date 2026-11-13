# Owner recovery

Recovery is opened from the Owner-only link beside Summary in Transfers. The site selector manages Transfers or Live Trailer Board. LTB requires its own Owner sign-in; that session is kept only in memory.

## Protection

- Full initial backup and automatic daily backups (09:15 UTC); automatic backups retain 14 days.
- Full before/after change records retain 90 days. Protection starts November 13, 2026; older complete deleted-record archives are imported where available.
- Manual backups and backups taken before a recovery remain until deliberately managed by the database administrator.
- Transfers coverage: jobs (including packing slips), status boxes, links, drivers, locations, schedules, downtime, invoice marks and chat.
- LTB coverage: docks, trailers, dock groups and chat.
- Activity/audit records, authentication/accounts, permissions and application source are not rolled back.

## Workflow

Filter change history by date/time, user or deleted records. Select changes, then Preview Undo. Alternatively choose a backup and Preview Restore. Review the differences and skipped conflicts, confirm the review checkbox, then apply. No restore occurs just by previewing.

Undo skips rows with unselected later/intervening edits. Applying a preview rechecks the current state under database locks; stale previews stop. Every apply saves a consistent full backup first. Restore, audit and backup are one transaction. Constraints remain enforced; failure rolls back all recovery changes. Linked references are restored after their targets. Unexpected cascading changes abort the operation.

Emergency locks prevent authenticated non-Owner writes to the covered operational and activity tables, globally or for one user. Owner access and trusted backend/system operations remain available. These locks do not suspend authentication or replace account/permission management.

Owner authorization is checked in the database for every RPC. Backups and recovery tables are private and have no direct authenticated/anonymous access. The recovery page and navigation are also gated on the actual Owner role.

The SQL file is the consolidated initial installation applied to the corresponding Supabase project. Existing installations should use incremental migrations rather than re-running it.
