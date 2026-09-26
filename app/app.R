# Harris College Faculty Finder -------------------------------------------------
#
# Version 0 is intentionally a local, read-only interface. The roster CSV and
# loader scripts remain the only approved route for changing faculty data.

#' Locate the repository root for the local Finder.
#'
#' @return A normalized project-directory path.
#' @details The lookup supports launching Shiny from either the repository root
#'   or the `app/` directory without exposing a machine-specific path in the UI.
find_project_root <- function() {
  candidate_paths <- unique(normalizePath(c(getwd(), file.path(getwd(), "..")), mustWork = FALSE))
  project_path <- candidate_paths[file.exists(file.path(candidate_paths, "renv.lock"))]

  if (length(project_path) > 0L) {
    return(project_path[[1L]])
  }

  candidate_paths[[1L]]
}

# Keep the expected schema in one place so the app can distinguish a database
# that is readable but out of date from an ordinary connection failure.
required_faculty_columns <- c(
  "person_id",
  "first_name",
  "last_name",
  "unit_code",
  "unit_name",
  "track",
  "is_graduate_faculty",
  "center_code",
  "center_name"
)

# Sentinel values for the non-center choices in the Center or institute
# dropdown. The leading dot keeps them from colliding with a real center code.
center_filter_all <- ".all"
center_filter_any <- ".any"
center_filter_none <- ".none"

#' Read current Finder data from DuckDB without writing.
#'
#' @param database_path Path to the local DuckDB database.
#' @return A list with a status and, on success, current-faculty data.
#' @details The connection exists only for the initial query, avoiding a
#'   conflict with the controlled roster-refresh workflow that needs exclusive
#'   write access.
read_current_faculty <- function(database_path) {
  if (!file.exists(database_path)) {
    return(list(status = "database_error", detail = "The local database file is missing."))
  }

  connection <- NULL

  tryCatch(
    {
      connection <- DBI::dbConnect(duckdb::duckdb(database_path), read_only = TRUE)

      current_faculty <- DBI::dbGetQuery(
        connection,
        "SELECT person_id, first_name, last_name, unit_code, unit_name, track, is_graduate_faculty, center_code, center_name FROM v_current_faculty"
      )

      if (!all(required_faculty_columns %in% names(current_faculty))) {
        return(list(status = "schema_error"))
      }

      list(status = "ready", data = current_faculty)
    },
    error = function(error) {
      error_detail <- conditionMessage(error)
      # A missing view raises a Catalog Error; a view missing an expected
      # column raises a Binder Error because the query names each column.
      # Both mean the database predates the Version 0 schema.
      schema_mismatch <- grepl("v_current_faculty|does not exist|catalog error|binder error", error_detail, ignore.case = TRUE)

      if (schema_mismatch) {
        return(list(status = "schema_error"))
      }

      list(status = "database_error", detail = error_detail)
    },
    finally = {
      if (!is.null(connection)) {
        try(DBI::dbDisconnect(connection, shutdown = TRUE), silent = TRUE)
      }
    }
  )
}

#' Format a visible unit label without exposing database identifiers.
#'
#' @param unit_name Current unit name.
#' @param unit_code Current unit code.
#' @return A readable unit label.
#' @details Unit codes distinguish similarly named units while person IDs stay
#'   hidden from the interface.
display_unit <- function(unit_name, unit_code) {
  has_name <- !is.na(unit_name) && nzchar(unit_name)
  has_code <- !is.na(unit_code) && nzchar(unit_code)

  if (has_name && has_code) {
    return(sprintf("%s (%s)", unit_name, unit_code))
  }

  if (has_name) {
    return(unit_name)
  }

  if (has_code) {
    return(unit_code)
  }

  "Not recorded"
}

#' Order center codes for display: CND first, then alphabetically.
#'
#' @param center_codes Center codes, possibly with duplicates or missing values.
#' @return Unique, non-missing center codes in display order.
#' @details UI_SPEC.md lists CND first because it is the affiliation Brad
#'   checks most often; every other center follows alphabetically so newly
#'   loaded centers have a predictable place.
order_center_codes <- function(center_codes) {
  center_codes <- unique(center_codes[!is.na(center_codes) & nzchar(center_codes)])
  c(intersect("CND", center_codes), sort(setdiff(center_codes, "CND")))
}

#' Build the Center or institute dropdown choices from current data.
#'
#' @param current_faculty Appointment-level current-faculty data.
#' @return A named character vector: labels are shown, values are filtered on.
#' @details Choices come from the current `center_code` values, so a center
#'   added through the loaders appears without an app change (UI_SPEC.md).
center_choices <- function(current_faculty) {
  center_codes <- order_center_codes(current_faculty$center_code)

  center_labels <- vapply(center_codes, function(code) {
    names_for_code <- current_faculty$center_name[!is.na(current_faculty$center_code) & current_faculty$center_code == code]
    names_for_code <- names_for_code[!is.na(names_for_code) & nzchar(names_for_code)]

    if (length(names_for_code) == 0L) {
      return(code)
    }

    sprintf("%s (%s)", names_for_code[[1L]], code)
  }, character(1))

  c(
    stats::setNames(
      c(center_filter_all, center_filter_any, center_filter_none),
      c("All", "Any center or institute", "No center or institute")
    ),
    stats::setNames(center_codes, center_labels)
  )
}

#' Aggregate current source rows to one Finder row per person.
#'
#' @param current_faculty Appointment-level current-faculty data.
#' @return A person-level data frame with display and filter fields.
#' @details Valid joint appointments and center affiliations can create several
#'   joined view rows, so aggregation prevents those data from looking like
#'   duplicate people.
summarize_people <- function(current_faculty) {
  person_ids <- unique(current_faculty$person_id)

  person_rows <- lapply(person_ids, function(person_id) {
    person_data <- current_faculty[current_faculty$person_id == person_id, , drop = FALSE]
    first_name <- person_data$first_name[[1L]]
    last_name <- person_data$last_name[[1L]]

    # Center affiliations multiply the joined view rows, so reduce to distinct
    # unit-and-track pairs before display. Unit and Track are shown in separate
    # columns, one pair per line, so both vectors keep the same order.
    appointments <- unique(data.frame(
      unit = vapply(
        seq_len(nrow(person_data)),
        function(index) display_unit(person_data$unit_name[[index]], person_data$unit_code[[index]]),
        character(1)
      ),
      track = ifelse(is.na(person_data$track) | !nzchar(person_data$track), "Not recorded", person_data$track),
      stringsAsFactors = FALSE
    ))
    appointments <- appointments[order(appointments$unit, appointments$track), , drop = FALSE]

    graduate_values <- as.logical(person_data$is_graduate_faculty)
    graduate_values <- graduate_values[!is.na(graduate_values)]
    graduate_status <- if (length(graduate_values) == 0L) {
      "Not recorded"
    } else if (any(graduate_values)) {
      "Yes"
    } else {
      "No"
    }

    center_codes <- order_center_codes(person_data$center_code)

    data.frame(
      person_id = person_id,
      last_name = last_name,
      first_name = first_name,
      search_name = tolower(sprintf("%s %s %s, %s", first_name, last_name, last_name, first_name)),
      # Newline-separated so the browser table can show one pair per line while
      # still escaping the text (see the multi-line CSS class in the UI).
      units = paste(appointments$unit, collapse = "\n"),
      tracks = paste(appointments$track, collapse = "\n"),
      graduate_status = graduate_status,
      centers = if (length(center_codes) == 0L) "None" else paste(center_codes, collapse = "; "),
      sort_last = tolower(last_name),
      sort_first = tolower(first_name),
      stringsAsFactors = FALSE
    )
  })

  # UI_SPEC.md requires last name, then first name. Sorting the combined
  # "Last, First" text would place "Rivera Campos" before "Rivera", so the
  # names are compared as separate keys.
  summary <- do.call(rbind, person_rows)
  summary[order(summary$sort_last, summary$sort_first), , drop = FALSE]
}

#' Filter current faculty using the Version 0 Finder contract.
#'
#' @param current_faculty Appointment-level current-faculty data.
#' @param name_query Optional case-insensitive partial name search.
#' @param selected_units Visible unit labels selected by the user.
#' @param selected_tracks Tenure tracks selected by the user.
#' @param graduate_filter Graduate-faculty control value.
#' @param center_filter Center or institute control value: a sentinel
#'   (`center_filter_all`, `center_filter_any`, `center_filter_none`) or a
#'   center code.
#' @return A filtered person-level data frame.
#' @details Unit and Tenure Track are matched on the same current appointment,
#'   then every current appointment is shown for each accepted person. Center
#'   affiliation is a person-level property, so it is checked against all of
#'   the person's current rows rather than the unit-and-track matches.
filter_people <- function(current_faculty, name_query, selected_units, selected_tracks, graduate_filter, center_filter) {
  person_summary <- summarize_people(current_faculty)
  matched_appointments <- current_faculty

  if (nzchar(trimws(name_query))) {
    name_pattern <- tolower(trimws(name_query))
    person_summary <- person_summary[grepl(name_pattern, person_summary$search_name, fixed = TRUE), , drop = FALSE]
    matched_appointments <- matched_appointments[matched_appointments$person_id %in% person_summary$person_id, , drop = FALSE]
  }

  appointment_units <- vapply(
    seq_len(nrow(matched_appointments)),
    function(index) display_unit(matched_appointments$unit_name[[index]], matched_appointments$unit_code[[index]]),
    character(1)
  )

  if (length(selected_units) > 0L) {
    matched_appointments <- matched_appointments[appointment_units %in% selected_units, , drop = FALSE]
  }

  if (length(selected_tracks) > 0L) {
    matched_appointments <- matched_appointments[matched_appointments$track %in% selected_tracks, , drop = FALSE]
  }

  accepted_people <- unique(matched_appointments$person_id)
  person_summary <- person_summary[person_summary$person_id %in% accepted_people, , drop = FALSE]

  if (identical(graduate_filter, "Yes") || identical(graduate_filter, "No") || identical(graduate_filter, "Not recorded")) {
    person_summary <- person_summary[person_summary$graduate_status == graduate_filter, , drop = FALSE]
  }

  if (!is.null(center_filter) && nzchar(center_filter) && !identical(center_filter, center_filter_all)) {
    has_center <- !is.na(current_faculty$center_code) & nzchar(current_faculty$center_code)
    affiliated_people <- unique(current_faculty$person_id[has_center])

    if (identical(center_filter, center_filter_any)) {
      person_summary <- person_summary[person_summary$person_id %in% affiliated_people, , drop = FALSE]
    } else if (identical(center_filter, center_filter_none)) {
      person_summary <- person_summary[!person_summary$person_id %in% affiliated_people, , drop = FALSE]
    } else {
      center_people <- unique(current_faculty$person_id[has_center & current_faculty$center_code == center_filter])
      person_summary <- person_summary[person_summary$person_id %in% center_people, , drop = FALSE]
    }
  }

  person_summary
}

project_root <- find_project_root()
database_path <- file.path(project_root, "db", "faculty.duckdb")

ui <- shiny::fluidPage(
  shiny::tags$head(
    shiny::tags$title("Harris College Faculty Finder"),
    # Unit and Track cells hold one appointment per line. Rendering the
    # newlines with CSS keeps DT's HTML escaping on for all cell text. "pre"
    # (not "pre-line") also stops long values such as "Professional Practice"
    # from wrapping, which would break the line-for-line Unit/Track pairing.
    shiny::tags$style(".multi-line { white-space: pre; }")
  ),
  shiny::titlePanel("Harris College Faculty Finder"),
  shiny::tags$h2("Current roster"),
  shiny::fluidRow(
    shiny::column(
      width = 4,
      shiny::textInput("name_query", "Find faculty", placeholder = "Search by first or last name"),
      shiny::selectizeInput("unit_filter", "Unit(s)", choices = character(), multiple = TRUE),
      shiny::selectizeInput("track_filter", "Tenure track", choices = character(), multiple = TRUE)
    ),
    shiny::column(
      width = 4,
      shiny::radioButtons("graduate_filter", "Graduate faculty", choices = c("All", "Yes", "No", "Not recorded"), selected = "All", inline = TRUE),
      # Center choices are filled in from the database once it loads.
      shiny::selectInput("center_filter", "Center or institute", choices = c("All" = center_filter_all), selected = center_filter_all),
      shiny::actionButton("clear_filters", "Clear filters", class = "btn-default")
    )
  ),
  shiny::hr(),
  shiny::textOutput("result_count"),
  shiny::uiOutput("results")
)

server <- function(input, output, session) {
  # Load once after the initial page is available so the user has a clear
  # loading message rather than a blank screen while DuckDB is queried.
  data_state <- shiny::reactiveVal(list(status = "loading"))

  session$onFlushed(function() {
    loaded_data <- read_current_faculty(database_path)

    if (!identical(loaded_data$status, "ready")) {
      failure_detail <- if (is.null(loaded_data$detail)) loaded_data$status else loaded_data$detail
      message("Faculty Finder database read failed: ", failure_detail)
    }

    data_state(loaded_data)
  }, once = TRUE)

  # Populate choices only from current records, keeping defaults equivalent to
  # no filter and avoiding stale values from prior roster versions.
  shiny::observe({
    state <- data_state()
    shiny::req(identical(state$status, "ready"))

    unit_choices <- sort(unique(vapply(
      seq_len(nrow(state$data)),
      function(index) display_unit(state$data$unit_name[[index]], state$data$unit_code[[index]]),
      character(1)
    )))
    track_choices <- sort(unique(state$data$track[!is.na(state$data$track) & nzchar(state$data$track)]))

    shiny::updateSelectizeInput(session, "unit_filter", choices = unit_choices, selected = character(0), server = TRUE)
    shiny::updateSelectizeInput(session, "track_filter", choices = track_choices, selected = character(0), server = TRUE)
    shiny::updateSelectInput(session, "center_filter", choices = center_choices(state$data), selected = center_filter_all)
  })

  #' Reset all controls to the approved Finder defaults.
  #'
  #' @return Invisibly updates the current Shiny session.
  #' @details The same reset is available beside the filters and after a
  #'   zero-result search so the two controls cannot drift apart.
  clear_all_filters <- function() {
    shiny::updateTextInput(session, "name_query", value = "")
    shiny::updateSelectizeInput(session, "unit_filter", selected = character(0))
    shiny::updateSelectizeInput(session, "track_filter", selected = character(0))
    shiny::updateRadioButtons(session, "graduate_filter", selected = "All")
    shiny::updateSelectInput(session, "center_filter", selected = center_filter_all)
  }

  shiny::observeEvent(input$clear_filters, clear_all_filters())
  shiny::observeEvent(input$clear_filters_empty, clear_all_filters())

  filtered_people <- shiny::reactive({
    state <- data_state()
    shiny::req(identical(state$status, "ready"))

    filter_people(
      current_faculty = state$data,
      name_query = input$name_query,
      selected_units = input$unit_filter,
      selected_tracks = input$track_filter,
      graduate_filter = input$graduate_filter,
      center_filter = input$center_filter
    )
  })

  output$result_count <- shiny::renderText({
    state <- data_state()

    if (!identical(state$status, "ready") || nrow(state$data) == 0L) {
      return("")
    }

    sprintf("Showing %d current faculty", nrow(filtered_people()))
  })

  # Render explicit empty and error states instead of an empty data table so a
  # user is not led to assume that the roster itself contains no information.
  output$results <- shiny::renderUI({
    state <- data_state()

    if (identical(state$status, "loading")) {
      return(shiny::div(class = "alert alert-info", "Loading current faculty…"))
    }

    if (identical(state$status, "schema_error")) {
      return(shiny::div(class = "alert alert-danger", "The local database is not at the expected Version 0 schema. Run the full loader sequence described in GUIDE.md, then relaunch the Faculty Finder."))
    }

    if (identical(state$status, "database_error")) {
      return(shiny::div(class = "alert alert-danger", "The local database could not be read. Close any other database viewer or loader session, then follow the rebuild steps in GUIDE.md before relaunching the Faculty Finder."))
    }

    if (nrow(state$data) == 0L) {
      return(shiny::div(class = "alert alert-warning", "The current roster returned no rows. Verify the Dropbox roster, rerun the loader sequence, and then relaunch the Faculty Finder."))
    }

    if (nrow(filtered_people()) == 0L) {
      return(shiny::tagList(
        shiny::div(class = "alert alert-info", "No current faculty match these filters."),
        shiny::actionButton("clear_filters_empty", "Clear filters", class = "btn-default")
      ))
    }

    DT::DTOutput("faculty_table")
  })

  output$faculty_table <- DT::renderDT({
    people <- filtered_people()
    shiny::req(nrow(people) > 0L)

    display_table <- data.frame(
      `Last name` = people$last_name,
      `First name` = people$first_name,
      Unit = people$units,
      Track = people$tracks,
      `Graduate faculty` = people$graduate_status,
      `Centers and institutes` = people$centers,
      # Hidden rank from the R-side last-then-first order. The browser table
      # sorts the Last name column by this rank so tied last names fall back to
      # first name, as UI_SPEC.md requires.
      sort_order = seq_len(nrow(people)),
      check.names = FALSE
    )

    DT::datatable(
      display_table,
      rownames = FALSE,
      selection = "none",
      escape = TRUE,
      options = list(
        # "lrtip" omits DT's own search box ("f"). Find faculty is the only
        # search control, so the Showing <n> count always matches the table.
        dom = "lrtip",
        pageLength = 25,
        lengthMenu = c(10, 25, 50),
        order = list(list(0, "asc")),
        columnDefs = list(
          list(targets = 0, orderData = 6),
          list(targets = c(2, 3), className = "multi-line"),
          list(targets = 6, visible = FALSE, searchable = FALSE)
        ),
        autoWidth = FALSE
      )
    )
  }, server = FALSE)
}

shiny::shinyApp(ui, server)
