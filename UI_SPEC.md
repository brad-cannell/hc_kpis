# Harris College Faculty Finder: Version 0 UI Specification

Status: Approved 2026-07-21. The Version 0 prototype may now be implemented.

## Purpose and boundary

Version 0 is a local, read-only faculty finder for Brad Cannell in his role as Harris College Associate Dean for Research. It replaces routine DuckDB queries with a small filterable interface for the current faculty roster.

The app does not edit the roster CSV, write to DuckDB, expose status history, export data, host a web service, or provide access to another user. The Dropbox-backed `data/raw/faculty_roster_clean.csv` remains the only editable roster source, and the existing loader scripts remain the only way to update the database.

## Data contract

The app reads `db/faculty.duckdb` through a DuckDB connection opened with `read_only = TRUE`. Its current-roster source is `v_current_faculty`, which supplies `person_id`, names, unit, tenure track, graduate-faculty status, and center-affiliation fields.

The source view is appointment-level: a person with joint appointments or multiple center affiliations can correctly appear in more than one raw row. The app must deduplicate the view's joined rows and aggregate results by `person_id` for display. It must preserve the person’s current appointment combinations rather than treating valid source rows as duplicate people.

## Screen and interaction layout

```text
Harris College Faculty Finder                         Current roster

Find faculty [________________]  [Clear filters]

Unit(s)       [All current units                 v]
Tenure track  [All current tracks                v]
Graduate      (All) (Yes) (No) (Not recorded)
CND           (All) (Affiliated) (Not affiliated)

Showing <n> current faculty

| Faculty | Current appointment(s) | Graduate faculty | CND affiliation |
|---------|------------------------|------------------|-----------------|
```

The page uses ordinary text labels and controls; color is never the only way it communicates a result or state. Keyboard navigation and readable control labels are required.

## Filters

All filters apply to current data only. Multiple selections within Unit or Tenure track use OR logic. Different filter categories use AND logic.

| Control | Default | Behavior |
| --- | --- | --- |
| Find faculty | Empty | Case-insensitive partial match against first name, last name, or the displayed `Last, First` name. |
| Unit(s) | All | Multi-select list built from the current `unit_name` and `unit_code` values. A person matches when at least one current appointment belongs to a selected unit. |
| Tenure track | All | Multi-select list built from the current `track` values: `Tenured`, `Tenure-Track`, and `Professional Practice`. When both Unit and Tenure track are selected, the match must occur in the same current appointment. |
| Graduate faculty | All | Single-select: All, Yes, No, or Not recorded. Yes and No correspond to the current `is_graduate_faculty` value. |
| CND affiliation | All | Single-select: All, Affiliated, or Not affiliated. Affiliated means the person has at least one current `center_code = 'CND'` record. |
| Clear filters | Not applicable | Returns every control to its default and restores the unfiltered roster. |

The app filters the current appointment data before assembling the displayed person rows. Each accepted person then displays all of their current appointment combinations, so the table remains informative without multiplying the person into several rows.

## Results table

The default sort is last name, then first name. Users may sort the visible table by its displayed columns. The app shows a computed count such as `Showing 24 current faculty`; it does not hard-code a roster total.

| Column | Display rule |
| --- | --- |
| Faculty | `Last, First`; do not display `person_id`. |
| Current appointment(s) | One semicolon-separated entry per distinct current unit-and-track combination, for example `Nursing (NURS) — Tenured`. |
| Graduate faculty | `Yes`, `No`, or `Not recorded`. |
| CND affiliation | `CND` when currently affiliated and `Not affiliated` otherwise. |

No table column exposes status-history dates, loader-source metadata, notes, or database identifiers in Version 0.

## Empty and error states

| Situation | Required behavior |
| --- | --- |
| Initial load | Show a concise loading message while the current roster is read. |
| No filter matches | Replace the table with `No current faculty match these filters.` Keep the active controls visible and offer `Clear filters`. |
| Empty current view | State that the current roster returned no rows and direct the user to verify the Dropbox roster and rerun the loader sequence. Do not offer an in-app edit. |
| Database missing, unreadable, or locked | State that the local database cannot be read, advise closing any other database viewer or loader session, and direct the user to the guide's rebuild steps. Do not show a misleading empty roster. |
| Expected view or columns missing | State that the database is not at the expected Version 0 schema and direct the user to run the full loader sequence. |

Technical error details may be written to the local R console for diagnosis, but the visible message must be plain language and must not expose a file-system path or stack trace unnecessarily.

## Roster refresh workflow

There is no in-app data-refresh button in Version 0. A refresh is a controlled data-maintenance workflow:

1. Close the Faculty Finder and any other DuckDB viewer or writer.
2. Update `/Users/bradcannell/Library/CloudStorage/Dropbox/Datasets/hc_kpis/raw/faculty_roster_clean.csv` using the roster rules in `GUIDE.md`.
3. From the project folder, run the existing five scripts in order: `data_01_duckdb_schema.R`, `data_02_load_people.R`, `data_03_load_tenure_status.R`, `data_04_load_grad_faculty_status.R`, and `data_05_load_center_affiliations.R`.
4. Run the guide's read-only checks against `v_current_faculty`; when loader code has changed, also run `tests/regression_test_status_loaders.R`.
5. Relaunch the Faculty Finder. It opens a new read-only connection and shows the rebuilt current roster.

Closing the app before the loaders run is mandatory because DuckDB permits only one writer at a time. The app must never modify the CSV or database as part of this process.

## Guide as a required companion artifact

The practical, easy-to-read user guide is part of the Version 0 definition of done. Extend `GUIDE.md` as the app is built so it covers how to launch the Finder, what each filter means, how to interpret an aggregated person row, the controlled roster-refresh steps, validation checks, and Version 0 limitations.

Update the guide in the same change whenever a user-visible filter, table column, launch command, refresh requirement, validation check, error message, or known limitation changes. The specification may evolve during review; the guide documents the behavior actually implemented.

## Implementation preconditions and review checks

- Add and lock direct `shiny` and `DT` dependencies in `renv.lock` before committing app code; their current machine-wide availability is not a reproducible project dependency.
- Keep Version 0 implementation in `app/app.R` only after this specification is approved.
- Verify the unfiltered screen, each individual filter, combined Unit-and-Tenure-Track filtering, CND filtering, the zero-result state, and filter reset against the current roster.
- Verify that the app opens DuckDB read-only and that the standard roster refresh succeeds after the app is closed.

## Deferred decisions

- Any access for other Harris College or TCU users.
- Authentication, hosting, and deployment.
- Download/export controls.
- In-app roster editing or approval workflows.
- Status-history displays and research-interest, grant, publication, or KPI additions.
