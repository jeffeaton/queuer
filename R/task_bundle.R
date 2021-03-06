##' Create a task bundle.  Generally these are not created manually,
##' but this page serves to document what task bundles are and the
##' methods that they have.
##'
##' A task bundle exists to group together tasks that are related.  It
##' is possible for a task to belong to multiple bundles.
##'
##' @title Create a task bundle
##'
##' @param obj An observer or queue object; something that can be
##'   passed through to \code{\link{context_db}}.
##'
##' @param task_ids A vector of task ids
##'
##' @param name Group name
##'
##' @param X Metadata to associate with the tasks.  This is used by
##'   the bulk interface (\code{\link{qlapply}} and
##'   \code{\link{enqueue_bulk}} to associate the first argument with
##'   the bundle).
##'
##' @param overwrite Logical indicating if an existing bundle with the
##'   same name should be overwritten.  If \code{FALSE} and a bundle
##'   with this name already exists, an error will be thrown.
##'
##' @export
##' @rdname task_bundle
task_bundle_create <- function(obj, task_ids, name=NULL, X=NULL,
                               overwrite=FALSE) {
  if (length(task_ids) < 1L) {
    stop("task_ids must be nonempty")
  }
  db <- context::context_db(obj)
  name <- create_bundle_name(name, overwrite, db)
  db$set(name, task_ids, "task_bundles")
  db$set(name, X, "task_bundles_X")
  task_bundle_get(obj, name)
}

##' @export
##' @rdname task_bundle
task_bundle_get <- function(obj, name) {
  .R6_task_bundle$new(obj, name)
}

##' Combine two or more task bundles
##'
##' For now task bundles must have the same function to be combined.
##' @title Combine task bundles
##' @param ... Any number of task bundles
##'
##' @param bundles A list of bundles (used in place of \code{...} and
##'   probably more useful for programming).
##'
##' @inheritParams task_bundle_create
##' @export
task_bundle_combine <- function(..., bundles=list(...),
                                name=NULL, overwrite=FALSE) {
  if (length(bundles) == 0L) {
    stop("Provide at least one task bundle")
  }
  names(bundles) <- NULL

  ok <- vlapply(bundles, inherits, "task_bundle")
  if (any(!ok)) {
    stop("All elements of ... or bundles must be task_bundle objects")
  }

  ## Check that the functions of each bundle job are the same.
  fns <- vcapply(bundles, function(x) x$function_name())
  if (length(unique(fns)) != 1L) {
    stop("task bundles must have same function to combine")
  }

  task_ids <- unlist(lapply(bundles, function(x) x$ids), FALSE, FALSE)

  named <- vlapply(bundles, function(x) !is.null(x$names))
  if (all(named)) {
    names(task_ids) <- unlist(lapply(bundles, function(x) x$names), FALSE, FALSE)
  } else if (any(named)) {
    tmp <- lapply(bundles, function(x) x$names)
    tmp[!named] <- lapply(bundles[!named], function(x) rep("", length(x$ids)))
    names(task_ids) <- unlist(tmp, FALSE, FALSE)
  }

  X <- lapply(bundles, function(x) x$X)
  is_df <- vlapply(X, is.data.frame)
  if (all(is_df)) {
    X <- do.call("rbind", X)
  } else {
    if (any(is_df)) {
      X[is_df] <- lapply(X[is_df], df_to_list)
    }
    X <- unlist(X, FALSE)
  }

  task_bundle_create(bundles[[1]], task_ids, name, X, overwrite)
}

.R6_task_bundle <- R6::R6Class(
  "task_bundle",

  public=list(
    db=NULL,
    tasks=NULL,
    name=NULL,
    names=NULL,
    ids=NULL,
    done=NULL,
    X=NULL,
    root=NULL,

    initialize=function(obj, name) {
      self$db <- context::context_db(obj)
      self$root <- context::context_root(obj)
      task_ids <- self$db$get(name, "task_bundles")
      self$name <- name
      self$tasks <- setNames(lapply(task_ids, task, obj=obj), task_ids)

      self$ids <- unname(task_ids)
      self$names <- names(task_ids)
      self$X <- self$db$get(name, "task_bundles_X")
      self$check()
    },

    times=function(unit_elapsed="secs") {
      context::tasks_times(self$to_handle(), unit_elapsed)
    },

    results=function(partial=FALSE) {
      if (partial) {
        task_bundle_partial(self)
      } else {
        self$wait(0, 0, FALSE)
      }
    },

    wait=function(timeout=60, time_poll=1, progress_bar=TRUE) {
      task_bundle_wait(self, timeout, time_poll, progress_bar)
    },

    check=function() {
      self$status()
      self$done
    },

    status=function(named=TRUE) {
      ## TODO: Only need to check the undone ones here?
      ret <- context::task_status(self$to_handle(), named=named)
      self$done <- setNames(!(ret %in% c("PENDING", "RUNNING", "ORPHAN")),
                            self$ids)
      ret
    },

    expr=function() {
      lapply(self$ids, function(id)
        context::task_expr(context::task_handle(self, id, FALSE)))
    },
    log=function() {
      setNames(lapply(self$ids, context::task_log, root=self$root),
               self$names)
    },
    function_name=function() {
      context::task_function_name(context::task_handle(self, self$ids[[1]]))
    },

    delete=function() {
      context::task_delete(self$to_handle())
    },

    to_handle=function() {
      context::task_handle(self, self$ids, FALSE)
    }

    ## TODO: overview()
  ))

task_bundles_list <- function(obj) {
  context::context_db(obj)$list("task_bundles")
}

task_bundles_info <- function(obj) {
  bundles <- task_bundles_list(obj)
  db <- context::context_db(obj)

  task_function <- function(id) {
    context::task_function_name(context::task_handle(obj, id, FALSE))
  }

  task_ids <- lapply(bundles, db$get, "task_bundles")
  ## TODO: don't do it this way; make a handle of the _first_ element
  ## of each.
  task_time_sub <-
    unlist_times(lapply(task_ids, function(x) db$get(x[[1L]], "task_time_sub")))
  task_function <-
    vapply(task_ids, function(x) task_function(x[[1L]]), character(1))

  i <- order(task_time_sub)
  data.frame(name=bundles[i],
             "function"=task_function[i],
             length=lengths(task_ids[i]),
             created=unlist_times(task_time_sub[i]),
             stringsAsFactors=FALSE,
             check.names=FALSE)
}

task_bundle_wait <- function(bundle, timeout, time_poll, progress_bar) {
  ## NOTE: For Redis we'd probably implement this differently due to
  ## the availability of BLPOP.  Note that would require *nonzero
  ## integer* time_poll though, and that 0.1 would become 0 which
  ## would block forever.
  task_ids <- bundle$ids
  done <- bundle$check()

  ## Immediately collect all completed results:
  results <- setNames(vector("list", length(task_ids)), task_ids)
  if (any(done)) {
    results[done] <- lapply(bundle$tasks[done], function(t) t$result())
  }

  cleanup <- function(results) {
    setNames(results, bundle$names)
  }
  if (all(done)) {
    return(cleanup(results))
  } else if (timeout == 0) {
    stop("Tasks not yet completed; can't be immediately returned")
  }

  p <- progress(total=length(bundle$tasks), show=progress_bar)
  p(sum(done))
  i <- 1L
  times_up <- time_checker(timeout)
  db <- context::context_db(bundle)
  while (!all(done)) {
    if (times_up()) {
      bundle$done <- done
      if (progress_bar) {
        message()
      }
      stop(sprintf("Exceeded maximum time (%d / %d tasks pending)",
                   sum(!done), length(done)))
    }
    res <- task_bundle_fetch1(db, task_ids[!done], time_poll)
    if (is.null(res$id)) {
      p(0)
    } else {
      p(1)
      task_id <- res[[1]]
      result <- res[[2]]
      done[[task_id]] <- TRUE
      ## NOTE: This conditional is needed to avoid deleting the
      ## element in results if we get a NULL result.
      if (!is.null(result)) {
        results[[task_id]] <- result
      }
    }
  }
  cleanup(results)
}

task_bundle_partial <- function(bundle) {
  task_ids <- bundle$ids
  done <- bundle$check()
  results <- setNames(vector("list", length(task_ids)), task_ids)
  if (any(done)) {
    results[done] <- lapply(bundle$tasks[done], function(t) t$result())
  }
  setNames(results, bundle$names)
}

## This is going to be something that a queue should provide and be
## willing to replace; something like a true blocking wait (Redis)
## will always be a lot nicer than filesystem polling.  Polling too
## quickly will cause filesystem overuse here.  Could do this with a
## growing timeout, perhaps.
task_bundle_fetch1 <- function(db, task_ids, timeout) {
  ## TODO: ideally exists() would be vectorisable.  That would require
  ## the underlying driver to express some traits about what it can
  ## do.
  ##
  ## In the absence of being able to do them in bulk, it might be
  ## worth explicitly looping over the set with a break?
  done <- vapply(task_ids, db$exists, logical(1), "task_results",
                 USE.NAMES=FALSE)
  if (any(done)) {
    id <- task_ids[[which(done)[[1]]]]
    list(id=id, value=db$get(id, "task_results"))
  } else {
    Sys.sleep(timeout)
    NULL
  }
}

create_bundle_name <- function(name, overwrite, db) {
  if (is.null(name)) {
    repeat {
      name <- ids::adjective_animal()
      if (!db$exists(name, "task_bundles")) {
        break
      }
    }
    message(sprintf("Creating bundle: '%s'", name))
  } else if (!overwrite && db$exists(name, "task_bundles")) {
    stop("Task bundle already exists: ", name)
  }
  name
}
