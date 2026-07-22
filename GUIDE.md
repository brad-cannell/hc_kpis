# Using the Harris College Faculty Database

This guide is for keeping the current Harris College faculty roster accurate and using it to answer routine questions about appointments, graduate-faculty status, and Center for Neurodegenerative Disease (CND) affiliation.

## What the database does

The database stores a current faculty roster and preserves prior status records when a person’s appointment, tenure track, or graduate-faculty status changes. The most useful starting point is the `v_current_faculty` view, which combines the current information in one table.

It does not yet track faculty research interests, grants, publications, or other research KPIs. Those belong in later, separate database additions.

## Where the data lives

The editable source data is stored in Dropbox at `/Users/bradcannell/Library/CloudStorage/Dropbox/Datasets/hc_kpis`. In this repository, `data/` is a symlink to that location so the R loader scripts keep using the familiar `data/raw/` paths.

The most important file is `data/raw/faculty_roster_clean.csv`. The local DuckDB database created from that file is `db/faculty.duckdb`; it is a rebuildable working file and is not stored in Git.

On a new computer, wait for Dropbox to make that folder available, then create the local link from the project root:

```sh
ln -s "/Users/bradcannell/Library/CloudStorage/Dropbox/Datasets/hc_kpis" data
```

The symlink is intentionally local and is not versioned. Do not add the roster files or the `data/` symlink to Git.

## Update the roster

1. Edit `data/raw/faculty_roster_clean.csv` in the Dropbox folder.
2. Keep one row for each current faculty appointment. Someone with a joint appointment should have one row for each unit.
3. Use only the allowed tenure-track values: `Tenured`, `Tenure-Track`, or `Professional Practice`.
4. Use `TRUE` or `FALSE` for `is_graduate_faculty`.
5. Add `CND` in `center_code`, the full center name in `center_name`, and `TRUE` or `FALSE` in `is_primary` when a current CND affiliation applies.
6. Treat the CSV as the complete current roster, not a partial update. Removing a current appointment from it closes that appointment in the database on the next load.

## Rebuild or refresh the database

Open your usual R session in the project folder and run the scripts in order:

```r
source("R/data_01_duckdb_schema.R")
source("R/data_02_load_people.R")
source("R/data_03_load_tenure_status.R")
source("R/data_04_load_grad_faculty_status.R")
source("R/data_05_load_center_affiliations.R")
```

Close any database viewer or R session that has `db/faculty.duckdb` open before running the loaders. DuckDB allows only one writer at a time.

## Check the result

Use the following in R after the load finishes:

```r
library(DBI)
library(duckdb)

con <- dbConnect(duckdb("db/faculty.duckdb"), read_only = TRUE)
dbGetQuery(con, "SELECT COUNT(*) AS n_current_faculty FROM v_current_faculty;")
dbGetQuery(con, "SELECT * FROM v_current_faculty ORDER BY last_name, first_name;")
dbGetQuery(con, "SELECT * FROM v_current_faculty WHERE center_code = 'CND';")
dbDisconnect(con)
```

If a person has changed tenure track, graduate-faculty status, or unit, the database retains the earlier row as history and exposes only the new row through the `v_current_*` views.

## Run the regression check

Before releasing changes to the loader scripts, run:

```sh
RENV_CONFIG_AUTOLOADER_ENABLED=FALSE Rscript tests/regression_test_status_loaders.R
```

The check copies the needed files into a temporary folder, changes one disposable roster record, and confirms that both status views return exactly one current record without adding history on a later unchanged reload. It does not modify the Dropbox data or the working database.

## Troubleshooting

If the loader reports that the database is locked, close other DuckDB connections and retry. If a roster row cannot be matched to a person, check the `given_name` and `family_name` spelling against the same CSV. If you need a wholly fresh rebuild, first make a backup of the Dropbox source data, then remove only the local `db/faculty.duckdb` file and run the five loader scripts in order.
