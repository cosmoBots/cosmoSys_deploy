# Maintenance candidate for review — 2026-11-05

## Purpose

Prepare a small PR for Iván's review, not a redesign of deployment or experimental
plugins. This fork is the publication and test target; applying it to our 3004
does not imply approval or merge into the canonical cosmoBots repository.

## Scope

- Declare cosmoSys and Requirements production components. All optional sets in
  this distribution are experimental integrations, opt-in with known limitations;
  this does not reclassify independent upstream projects.
- Pin the current documentation-only release commits plus Architecture 0.1.4
  and CAD integration 0.1.5. No plugin dependency minimum is raised.
- Restrict CAD integration to exactly the validated upstream fork version
  `1.0.1-cosmobots.1` (`39fec08`). Main upstream `ca96eaf` declares 1.2.0 with
  overlapping macro and view storage; adopting it is not part of this delivery.
  Newer/unvalidated builds fail early with a clear dependency error. This is
  an intentional upper/exact compatibility constraint, not an increased minimum.
- Architecture confines its minimal viewer layout to its own requests, rather
  than overriding Redmine's global attachment layout.
- CAD integration registers attachment-view cleanup after plugins load and
  removes that attachment's saved views/locks without deleting another's.
- The integration ignores web-configurable DWG commands, using only the
  server-installed `/usr/local/bin/dwg2dxf` with code-built arguments. Availability
  has a 5-second bound; conversion timeout is capped at 120 seconds. The upstream
  CAD fork is unchanged. This policy is **not process isolation**.
- Include the Architecture catalog test in `check-config.sh`, complete the set
  table and remove an unused validator variable. Add maintenance assertions to
  production-image checks for CAD and Architecture.

## Explicitly excluded

No new schema migrations, optional sets or default activation. No conversion of
broken old ODS files. The unreleased local Requirements template remains outside
these pins. No changes to bridge read authorization: both endpoint items must
remain visible, with separate write permissions.

No performance programme, new queue infrastructure, sandbox, CAD filtering UI,
experimental ODS templates, saved-camera/binding snapshot extensions or upstream
CAD update. These are later work, not prerequisites disguised as fixes here.
CAD remains experimental and untrusted DWG parsing is not certified isolated.

## Validation evidence

Directed tests passed in an isolated Redmine laboratory: converter-policy unit
tests, attachment text/code/image HTTP layout, committed cleanup of default and
named views/locks, settings rendering, CAD item/wiki and ODT/DOCX/PDF reports,
Architecture preflight/viewer/permissions, PORIS–CAD dispatch and rejection of
unadapted upstream versions. The laboratory
lacks LibreDWG, so real DWG conversion must also pass in the pinned image.

Release gates still to record before approval:

- Both deployment variants and all optional-set configurations.
- Real DWG conversion with the shipped binary and the maintenance assertions.
- Canonical updater validation and backup/verification on our 3004 test instance.

Do not treat this document's planned gates as completed evidence. No public
production instance other than the explicitly authorized 3004 is updated here.
