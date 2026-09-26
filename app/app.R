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
  "center_code"
)

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
        "SELECT person_id, first_name, last_name, unit_code, unit_name, track, is_graduate_faculty, center_code FROM v_current_faculty"
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

#' Aggregate current source rows to one Finder row per person.
#'
#' @param current_faculty Appointment-level current-faculty data.
#' @return A person-level data frame with display and filter fields.
#' @details Valid joint appointments and centre affiliations can create several
#'   joined view rows, so aggregation prevents those data from looking like
#'   duplicate people.
summarize_people <- function(current_faculty) {
  person_ids <- unique(current_faculty$person_id)

  person_rows <- lapply(person_ids, function(person_id) {
    person_data <- current_faculty[current_faculty$person_id == person_id, , drop = FALSE]
    first_name <- person_data$first_name[[1L]]
    last_name <- person_data$last_name[[1L]]

    appointments <- unique(vapply(
      seq_len(nrow(person_data)),
      function(index) {
        unit <- display_unit(person_data$unit_name[[index]], person_data$unit_code[[index]])
        track <- person_data$track[[index]]

        if (is.na(track) || !nzchar(track)) {
          return(unit)
        }

        sprintf("%s — %s", unit, track)
      },
      character(1)
    ))

    graduate_values <- as.logical(person_data$is_graduate_faculty)
    graduate_values <- graduate_values[!is.na(graduate_values)]
    graduate_status <- if (length(graduate_values) == 0L) {
      "Not recorded"
    } else if (any(graduate_values)) {
      "Yes"
    } else {
      "No"
    }

    cnd_affiliated <- any(!is.na(person_data$center_code) & person_data$center_code == "CND")

    data.frame(
      person_id = person_id,
      faculty = sprintf("%s, %s", last_name, first_name),
      search_name = tolower(sprintf("%s %s %s, %s", first_name, last_name, last_name, first_name)),
      appointments = paste(sort(appointments), collapse = "; "),
      graduate_status = graduate_status,
      cnd_affiliated = cnd_affiliated,
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
#' @param cnd_filter CND-affiliation control value.
#' @return A filtered person-level data frame.
#' @details Unit and Tenure Track are matched on the same current appointment,
#'   then every current appointment is shown for each accepted person.
filter_people <- function(current_faculty, name_query, selected_units, selected_tracks, graduate_filter, cnd_filter) {
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

  if (identical(cnd_filter, "Affiliated")) {
    person_summary <- person_summary[person_summary$cnd_affiliated, , drop = FALSE]
  }

  if (identical(cnd_filter, "Not affiliated")) {
    person_summary <- person_summary[!person_summary$cnd_affiliated, , drop = FALSE]
  }

  person_summary
}

project_root <- find_project_root()
database_path <- file.path(project_root, "db", "faculty.duckdb")

ui <- shiny::fluidPage(
  shiny::tags$head(shiny::tags$title("Harris College Faculty Finder")),
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
      shiny::radioButtons("cnd_filter", "CND affiliation", choices = c("All", "Affiliated", "Not affiliated"), selected = "All", inline = TRUE),
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
    shiny::updateRadioButtons(session, "cnd_filter", selected = "All")
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
      cnd_filter = input$cnd_filter
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
      Faculty = people$faculty,
      `Current appointment(s)` = people$appointments,
      `Graduate faculty` = people$graduate_status,
      `CND affiliation` = ifelse(people$cnd_affiliated, "CND", "Not affiliated"),
      # Hidden rank from the R-side last-then-first order. The browser table
      # sorts the Faculty column by this rank so its own string sort cannot
      # reintroduce the combined-text ordering.
      sort_order = seq_len(nrow(people)),
      check.names = FALSE
    )

    DT::datatable(
      display_table,
      rownames = FALSE,
      selection = "none",
      escape = TRUE,
      options = list(
        pageLength = 25,
        lengthMenu = c(10, 25, 50),
        order = list(list(0, "asc")),
        columnDefs = list(
          list(targets = 0, orderData = 4),
          list(targets = 4, visible = FALSE, searchable = FALSE)
        ),
        autoWidth = FALSE
      )
    )
  }, server = FALSE)
}

shiny::shinyApp(ui, server)
