{ pkgs ? import <nixpkgs> {}
, postgresql ? pkgs.postgresql
}:

let

script = ''
#!${pkgs.bash}/bin/bash

function lpg-help {
  cat <<EOF | less
lpg (Local PostGres): manage local PostgreSQL instances


Basic Commands:

  lpg make <loc>

      Create an lpg-managed PostgreSQL instance at the specified location.
      The instance will be initialized with a superuser named 'postgres'
      Ex: lpg make ./pg

  lpg shell (<loc> | --sandbox)

      Enter an interactive shell with a modified environment such that libpq
      commands, like psql and pg_ctl, will use the lpg instance at <loc>.

      If '--sandbox' is given, use a temporary anonymous lpg instance instead

      Environment modifications are:
        - LPG_IN_SHELL is set to '1'
        - LPG_LOC is set to an absolute version of <loc>
        - LPG_CONNSTR is set to a PostgreSQL connection string for the
          given lpg instance
        - PGDATA and PGHOST are set
        - pg_ctl is monkeypatched to:
            - log to <loc>/log
            - listen on the unix socket at <loc>/socket/.s.PGSQL.5432
            - not listen on any TPC ports
        - psql is monkeypatched to:
            - log in with user postgres by default instead of $USER
          Note that this behaviour can be overturned by passing your
          own CLI arguments, e.g. 'psql -U $USER'

  lpg env (<loc> | --sandbox)

      Like 'lpg shell', but instead of entering an interactive shell, prints
      a sourceable bash script.
      Ex: source <(lpg env --sandbox) && pg_ctl start

  lpg help

      Show this message


Derived Commands:

  Convenience commands built on top of the basic commands

  lpg cmd <loc> <cmd>...
      Run a command on an lpg instance without affecting the shell
      Ex: lpg cmd ./pg psql -U postgres -tc 'SELECT * FROM mytable;'

  lpg bash <loc> <str>
      Run a bash command on an lpg instance
      Ex: lpg bash ./pg 'pg_ctl stop && pg_ctl start'

  lpg pg-start <loc>
      Start an lpg instance. Same as: lpg cmd <loc> pg_ctl start

  lpg pg-stop <loc>
      Stop an lpg instance. Same as: lpg cmd <loc> pg_ctl stop

  lpg pg-restart <loc>
      Restart an lpg instance. Same as: lpg bash <loc> 'pg_ctl stop && pg_ctl start'

EOF
}

function lpg-make {
  [[ $# = 1 ]] || { echo >&2 "Expected exactly 1 argument"; return 1; }
  [[ -e "$1" ]] && { echo >&2 "$1 already exists"; return 1; }
  local dir=$(realpath "$1")

  mkdir -p "$dir"/{cluster,socket} || return 1
  touch "$dir"/log || return 1
  ${postgresql}/bin/initdb "$dir"/cluster -U postgres || return 1
}

function lpg-env {
  [[ $# = 1 ]] || { echo >&2 "Expected exactly 1 argument"; return 1; }

  do_sandbox=
  [ "$1" = --sandbox ] && do_sandbox=1 || do_sandbox=0

  if (( $do_sandbox )); then
    local dir=$(mktemp -du)
    lpg-make "$dir" >/dev/null || return 1
  else
    [[ -d "$1" ]] || { echo >&2 "$1 does not exist"; return 1; }
    local dir=$(realpath "$1")
  fi

  cat <<EOF

export PGDATA=$dir/cluster
export PGHOST=$dir/socket

export LPG_IN_SHELL=1
export LPG_LOC=$dir
export LPG_CONNSTR=postgresql://postgres@localhost?host=$dir/socket

function pg_ctl {
  ${postgresql}/bin/pg_ctl \\
    -l "$dir"/log \\
    -o "--unix_socket_directories='$dir/socket'" \\
    -o '--listen_addresses=""' \\
    "\$@"
}
export -f pg_ctl

function psql {
  ${postgresql}/bin/psql \\
    -U postgres \\
    "\$@"
}
export -f psql

EOF

  (( $do_sandbox )) && cat <<EOF

lpg-sandbox-cleanup() {
  pg_ctl status >/dev/null && pg_ctl stop

  rm -rf "$dir"
}
trap lpg-sandbox-cleanup EXIT INT TERM

EOF
}

function lpg-shell {
  ( source <(lpg-env "$@") && bash )
}

function lpg-cmd {
  [[ $# -ge 2 ]] || { echo >&2 "Expected 2 or more arguments"; return 1; }
  [[ -d "$1" ]] || { echo >&2 "$1 does not exist or is not a directory."; return 1; }
  local dir=$1; shift;

  ( source <(lpg-env "$dir") && "$@" )
}

function lpg-bash {
  [[ $# -eq 2 ]] || { echo >&2 "Expected exactly 2 arguments"; return 1; }
  [[ -d "$1" ]] || { echo >&2 "$1 does not exist or is not a directory."; return 1; }
  local dir=$1; shift;
  local str=$1; shift;

  ( source <(lpg-env "$dir") && bash -c "$str" )
}

function lpg-pg-start_stop_restart {
  local str=$1; shift;
  [[ $# -eq 1 ]] || { echo >&2 "Expected exactly 1 argument"; return 1; }
  [[ -d "$1" ]] || { echo >&2 "$1 does not exist or is not a directory."; return 1; }
  local dir=$1; shift;

  ( source <(lpg-env "$dir") && bash -c "$str" )
}

function lpg-pg-start   { lpg-pg-start_stop_restart 'pg_ctl start'   "$@"; }
function lpg-pg-stop    { lpg-pg-start_stop_restart 'pg_ctl stop'    "$@"; }
function lpg-pg-restart { lpg-pg-start_stop_restart 'pg_ctl restart' "$@"; }


function _main {
  local cmd_name="$1"; shift;

  case "$cmd_name" in
    # Basic commands
    make       ) lpg-make "$@" ;;
    env        ) lpg-env "$@" ;;
    shell      ) lpg-shell "$@" ;;

    # Derived commands
    cmd        ) lpg-cmd "$@" ;;
    bash       ) lpg-bash "$@" ;;
    pg-start   ) lpg-pg-start "$@" ;;
    pg-stop    ) lpg-pg-stop "$@" ;;
    pg-restart ) lpg-pg-restart "$@" ;;

    # Help
    help       ) lpg-help "$@" ;;
    *          ) lpg-help ;;
  esac
}

_main "$@"

'';

in

pkgs.writeScriptBin "lpg" script
