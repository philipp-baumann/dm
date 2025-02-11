
#' Single out a table of a `dm`
#'
#' Zooming to a table of a [`dm`] allows for the use of many `dplyr`-verbs directly on this table, while retaining the
#' context of the `dm` object.
#'
#' @inheritParams cdm_add_pk
#'
#' @details `cdm_zoom_to_tbl()`: zooms to the given table
#'
#' `cdm_update_zoomed_tbl()`: overwrites the originally zoomed table with the manipulated table.
#' The filter conditions for the zoomed table are added to the original filter conditions.
#'
#' `cdm_insert_zoomed_tbl()`: adds a new table to the `dm`.
#'
#' `cdm_zoom_out()`: discards the zoomed table, returning the `dm` from before zooming
#'
#' Whenever possible, the key relations of the original table are transferred to the resulting table
#' when using `cdm_insert_zoomed_tbl()` or `cdm_update_zoomed_tbl()`.
#'
#' Functions from `dplyr`, that are supported for a `zoomed_dm`: `group_by()`, `summarise()`, `mutate()`,
#' `transmute()`, `select()`, `rename()` and `ungroup()`. You can use these functions just like you would
#' with a normal table.
#'
#' `filter()` is also supported, but treated in a special way: the filter expression for the zoomed table is
#' stored in the `dm` and is treated depending on which function you use to return to a normal `dm`:
#'
#' 1. `cdm_zoom_out()`: all filter conditions for the zoomed table are discarded
#' 1. `cdm_update_zoomed_tbl()`: the filter conditions of the original table and those of the zoomed table are combined
#' 1. `cdm_insert_zoomed_tbl()`: the filter conditions of the original table stay there and those of the zoomed table are
#' transferred to the new table of the `dm`
#'
#' @rdname cdm_zoom_to_tbl
#' @export
cdm_zoom_to_tbl <- function(dm, table) {
  if (is_zoomed(dm)) abort_no_zoom_allowed()

  # for now only one table can be zoomed on
  zoom <- as_string(ensym(table))
  check_correct_input(dm, zoom)

  keys <- list(get_all_keys(dm, zoom))

  structure(
    new_dm3(
      cdm_get_def(dm) %>%
        mutate(
          zoom = if_else(table == !!zoom, data, list(NULL)),
          key_tracker_zoom = if_else(table == !!zoom, keys, list(NULL))
          )
      ),
    class = c("zoomed_dm", "dm")
    )
}

is_zoomed <- function(dm) {
  inherits(dm, "zoomed_dm")
}

get_zoomed_tbl <- function(dm) {
  cdm_get_zoomed_tbl(dm) %>%
    pull(zoom) %>%
    pluck(1)
}

#' @rdname cdm_zoom_to_tbl
#' @param new_tbl_name Name of the new table
#'
#' @export
cdm_insert_zoomed_tbl <- function(dm, new_tbl_name) {
  if (!is_zoomed(dm)) abort_no_table_zoomed()
  new_tbl_name_chr <- as_string(enexpr(new_tbl_name))
  if (new_tbl_name_chr == "") abort_table_needs_name()
  old_tbl_name <- orig_name_zoomed(dm)
  new_tbl <- list(get_zoomed_tbl(dm))
  # filters need to be split: old_filters belong to old table, new ones to the inserted one
  all_filters <- get_filter_for_table(dm, old_tbl_name)
  old_filters <- all_filters %>% filter(!zoomed)
  new_filters <- all_filters %>% filter(zoomed) %>% mutate(zoomed = FALSE)

  # PK: either same as in old table, renamed in new table, or no PK if none available
  upd_pk <- update_zoomed_pk(dm)

  # incoming FKs: in the new row, based on old table;
  # if PK available, FK relations can be copied from old table
  # if PK vanished, empty entry
  upd_inc_fks <- update_zoomed_incoming_fks(dm)

  dm_wo_outgoing_fks <-
    update_filter(dm, old_tbl_name, vctrs::list_of(old_filters)) %>%
    cdm_add_tbl_impl(new_tbl, new_tbl_name_chr, vctrs::list_of(new_filters)) %>%
    cdm_get_def() %>%
    mutate(pks = if_else(table == new_tbl_name_chr, upd_pk, pks),
           fks = if_else(table == new_tbl_name_chr, upd_inc_fks, fks)) %>%
    new_dm3(zoomed = TRUE)

  # outgoing FKs: potentially in several rows, based on old table;
  # renamed(?) FK columns, if they still exist
  dm_update_zoomed_outgoing_fks(dm_wo_outgoing_fks, new_tbl_name_chr, is_upd = FALSE) %>%
    cdm_zoom_out()
}

#' @rdname cdm_zoom_to_tbl
#' @export
cdm_update_zoomed_tbl <- function(dm) {
  if (!is_zoomed(dm)) return(dm)
  table_name <- orig_name_zoomed(dm)
  upd_filter <- vctrs::list_of(get_filter_for_table(dm, table_name) %>% mutate(zoomed = FALSE))
  new_def <- cdm_get_def(dm) %>%
    mutate(
      data = if_else(table == table_name, zoom, data),
      pks = if_else(table == table_name, update_zoomed_pk(dm), pks),
      fks = if_else(table == table_name, update_zoomed_incoming_fks(dm), fks),
      filters = if_else(table == table_name, upd_filter, filters)
      )
  new_dm3(new_def, zoomed = TRUE) %>%
    dm_update_zoomed_outgoing_fks(table_name, is_upd = TRUE) %>%
    cdm_zoom_out()
}

#' @rdname cdm_zoom_to_tbl
#' @export
cdm_zoom_out <- function(dm) {
  if (!is_zoomed(dm)) {
    return(dm)
  }
  old_tbl_name <- orig_name_zoomed(dm)
  upd_filter <- get_filter_for_table(dm, old_tbl_name) %>%
    filter(zoomed == FALSE)
  new_dm3(
    cdm_get_def(dm) %>%
      mutate(zoom = list(NULL),
             key_tracker_zoom = list(NULL),
             filters = if_else(table == old_tbl_name, vctrs::list_of(upd_filter), filters))
  )
}

update_zoomed_pk <- function(dm) {
  old_tbl_name <- orig_name_zoomed(dm)
  tracked_keys <- get_tracked_keys(dm)
  orig_pk <- cdm_get_pk(dm, !!old_tbl_name)
  upd_pk <- if (!is_empty(orig_pk) && orig_pk %in% tracked_keys) {
    new_pk(list(names(tracked_keys[tracked_keys == orig_pk])))
  } else new_pk()
  vctrs::list_of(upd_pk)
}

update_zoomed_incoming_fks <- function(dm) {
  old_tbl_name <- orig_name_zoomed(dm)
  tracked_keys <- get_tracked_keys(dm)
  orig_pk <- cdm_get_pk(dm, !!old_tbl_name)
  if (!is_empty(orig_pk) && orig_pk %in% tracked_keys) {
    filter(cdm_get_def(dm), table == old_tbl_name) %>% pull(fks)
  } else vctrs::list_of(new_fk())
}

# is_upd is logical: either update (TRUE) or insert (FALSE)
# if `is_upd`, new_tbl_name needs to be same as old_tbl_name
dm_update_zoomed_outgoing_fks <- function(dm, new_tbl_name, is_upd) {
  old_tbl_name <- orig_name_zoomed(dm)
  tracked_keys <- get_tracked_keys(dm)
  old_out_keys <- cdm_get_all_fks(dm) %>%
    filter(child_table == old_tbl_name) %>%
    select(table = parent_table, column = child_fk_col)

  old_and_new_out_keys <-
    if (nrow(old_out_keys) > 0 && any(old_out_keys$column %in% tracked_keys)) {
      filter(old_out_keys, column %in% tracked_keys) %>%
        mutate(new_column = names(tracked_keys[tracked_keys %in% column]))
      } else filter(old_out_keys, 0 == 1) %>% mutate(new_column = character(0))

  if (is_upd) {
    # need to remove the old keys
    dm <- reduce2(
      old_out_keys$column,
      old_out_keys$table,
      ~cdm_rm_fk(..1, !!old_tbl_name, !!..2, !!..3), .init = dm
      )
  }
  reduce2(old_and_new_out_keys$new_column, old_and_new_out_keys$table, ~cdm_add_fk(..1, !!new_tbl_name, !!..2, !!..3), .init = dm)
}

get_tracked_keys <- function(dm) {
  cdm_get_def(dm) %>%
    filter(table == orig_name_zoomed(dm)) %>%
    pull(key_tracker_zoom) %>%
    pluck(1)
}

orig_name_zoomed <- function(dm) {
  cdm_get_zoomed_tbl(dm) %>% pull(table)
}

replace_zoomed_tbl <- function(dm, new_zoomed_tbl, tracked_keys = NULL) {
  table <- orig_name_zoomed(dm)
  def <- cdm_get_def(dm)
  def$zoom[def$table == table] <- list(new_zoomed_tbl)
  if (!is_null(tracked_keys)) def$key_tracker_zoom[def$table == table] <- list(tracked_keys)
  new_dm3(def, zoomed = TRUE)
}

check_zoomed <- function(dm) {
  check_dm(dm)
  if (is_zoomed(dm)) return()

  fun_name <- as_string(sys.call(-1)[[1]])
  abort_only_possible_w_zoom(fun_name)
}

check_not_zoomed <- function(dm) {
  check_dm(dm)
  if (!is_zoomed(dm)) return()

  fun_name <- as_string(sys.call(-1)[[1]])
  abort_only_possible_wo_zoom(fun_name)
}
