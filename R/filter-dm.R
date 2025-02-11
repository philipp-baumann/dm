#' Filtering a [`dm`] object
#'
#' Filtering one table of a [`dm`] object may affect all tables connected to this table
#' via one or more steps of foreign key relations. Firstly, one or more filter conditions for
#' one or more tables can be defined using `cdm_filter()`, with a syntax similar to [`dplyr::filter()`].
#' Each condition will only be immediately executed for the table it is referring to.
#' Furthermore all conditions are stored in the [`dm`].
#' With `cdm_apply_filters()` all tables will be updated according to the filter conditions and the foreign key relations.
#'
#' @details The effect of the stored filter conditions on the tables related to the filtered ones is only evaluated
#' in one of the following scenarios:
#' 1. Calling `cdm_apply_filters()` or `compute()` (method for `dm` objects) on a `dm`: each filtered table potentially
#' reduces the rows of all other tables connected to it by foreign key relations (cascading effect), only leaving the rows
#' with the corresponding key values.
#' Tables that are not connected to any table with an active filter are left unchanged.
#' This results in a new `dm` class object without any filter conditions.
#' 1. Calling one of `tbl()`, `[[.dm()`, `$.dm()`: the remaining rows of the requested table are calculated by performing a sequence
#' of semi-joins ([`dplyr::semi_join()`]) starting from each table that has been filtered to the requested table
#' (similar to 1. but only for one table).
#'
#' Several functions of the {dm} package will throw an error if filter conditions exist when they are called.
#' @rdname cdm_filter
#'
#' @inheritParams cdm_add_pk
#' @param ... Logical predicates defined in terms of the variables in `.data`, passed on to [dplyr::filter()].
#' Multiple conditions are combined with `&` or `,`. Only rows where the condition evaluates
#' to TRUE are kept.
#'
#' The arguments in ... are automatically quoted and evaluated in the context of
#' the data frame. They support unquoting and splicing. See `vignette("programming", package = "dplyr")`
#' for an introduction to these concepts.
#'
#' @examples
#' library(dplyr)
#'
#' dm_nyc_filtered <-
#'   cdm_nycflights13() %>%
#'   cdm_filter(airports, name == "John F Kennedy Intl")
#'
#' tbl(dm_nyc_filtered, "flights")
#' dm_nyc_filtered[["planes"]]
#' dm_nyc_filtered$airlines
#'
#' cdm_nycflights13() %>%
#'   cdm_filter(airports, name == "John F Kennedy Intl") %>%
#'   cdm_apply_filters()
#'
#' # If you want to only keep those rows in the parent tables
#' # whose primary key values appear as foreign key values in
#' # `flights`, you can set a `TRUE` filter in `flights`:
#' cdm_nycflights13() %>%
#'   cdm_filter(flights, 1 == 1) %>%
#'   cdm_apply_filters() %>%
#'   cdm_nrow()
#' # note, that in this example the only affected table is
#' # `airports` (since the departure airports in `flights` are
#' # only the 3 NYC ones).
#'
#' @export
cdm_filter <- function(dm, table, ...) {
  table <- as_name(ensym(table))
  check_correct_input(dm, table)

  cdm_zoom_to_tbl(dm, !!table) %>%
    filter(...) %>%
    cdm_update_zoomed_tbl()
}

set_filter_for_table <- function(dm, table, filter_exprs, zoomed) {
  def <- cdm_get_def(dm)

  i <- which(def$table == table)
  def$filters[[i]] <- vctrs::vec_rbind(def$filters[[i]], new_filter(filter_exprs, zoomed))
  new_dm3(def, zoomed = zoomed)
}


#' @rdname cdm_filter
#'
#' @inheritParams cdm_add_pk
#'
#' @examples
#' cdm_nycflights13() %>%
#'   cdm_filter(flights, month == 3) %>%
#'   cdm_apply_filters()
#'
#' library(dplyr)
#' cdm_nycflights13() %>%
#'   cdm_filter(planes, engine %in% c("Reciprocating", "4 Cycle")) %>%
#'   compute()
#' @export
cdm_apply_filters <- function(dm) {
  check_not_zoomed(dm)
  def <- cdm_get_def(dm)

  def$data <- map(def$table, ~ tbl(dm, .))

  cdm_reset_all_filters(new_dm3(def))
}

# calculates the necessary semi-joins from all tables that were filtered to
# the requested table
cdm_get_filtered_table <- function(dm, from) {
  filters <- cdm_get_filter(dm)
  if (nrow(filters) == 0) {
    return(cdm_get_tables(dm)[[from]])
  }

  fc <- get_all_filtered_connected(dm, from)

  fc_children <-
    fc %>%
    filter(node != parent) %>%
    select(-distance) %>%
    nest(semi_join = -parent) %>%
    rename(table = parent)

  recipe <-
    fc %>%
    select(table = node) %>%
    left_join(fc_children, by = "table")

  list_of_tables <- cdm_get_tables(dm)

  for (i in seq_len(nrow(recipe))) {
    table_name <- recipe$table[i]
    table <- list_of_tables[[table_name]]

    semi_joins <- recipe$semi_join[[i]]
    if (!is_null(semi_joins)) {
      semi_joins <- pull(semi_joins)
      semi_joins_tbls <- list_of_tables[semi_joins]
      table <-
        reduce2(semi_joins_tbls,
          semi_joins,
          ~ semi_join(..1, ..2, by = get_by(dm, table_name, ..3)),
          .init = table
        )
    }
    list_of_tables[[table_name]] <- table
  }
  list_of_tables[[from]]
}

get_all_filtered_connected <- function(dm, table) {
  filtered_tables <- unique(cdm_get_filter(dm)$table)
  graph <- create_graph_from_dm(dm)

  # Computation of distances and shortest paths uses the same algorithm
  # internally, but s.p. doesn't return distances and distances don't return
  # the predecessor.
  distances <- igraph::distances(graph, table)[1, ]
  finite_distances <- distances[is.finite(distances)]

  # Using only nodes with finite distances (=in the same connected component)
  # as target. This avoids a warning.
  target_tables <- names(finite_distances)
  paths <- igraph::shortest_paths(graph, table, target_tables, predecessors = TRUE)

  # All edges with finite distance as tidy data frame
  all_edges <-
    tibble(
      node = names(V(graph)),
      parent = names(paths$predecessors),
      distance = distances
    ) %>%
    filter(is.finite(distance))

  # Edges of interest, will be grown until source node `table` is reachable
  # from all nodes
  edges <-
    all_edges %>%
    filter(node %in% !!c(filtered_tables, table))

  # Recursive join
  repeat {
    missing <- setdiff(edges$parent, edges$node)
    if (is_empty(missing)) break

    edges <- bind_rows(edges, filter(all_edges, node %in% !!missing))
  }

  # Keeping the sentinel row (node == parent) to simplify further processing
  # and testing
  edges %>%
    arrange(-distance)
}

check_no_filter <- function(dm) {
  def <-
    cdm_get_def(dm)

  if (detect_index(def$filters, ~ vctrs::vec_size(.) > 0) == 0) return()

  fun_name <- as_string(sys.call(-1)[[1]])
  abort_only_possible_wo_filters(fun_name)
}

get_filter_for_table <- function(dm, table_name) {
  cdm_get_def(dm) %>%
    filter(table == table_name) %>%
    pull(filters) %>%
    pluck(1)
}
