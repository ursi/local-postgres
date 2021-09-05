{ pkgs ? import <nixpkgs> {}
, postgresql ? pkgs.postgresql
}:

let

script = ''
#!${pkgs.bash}/bin/bash

function _main {
  local cmd="$1"; shift;

  case "$cmd" in
    help    ) lpg-help "$@" ;;
    make    ) lpg-make "$@" ;;
    env     ) lpg-env "$@" ;;
    do      ) lpg-do "$@" ;;
    shell   ) lpg-shell "$@" ;;
    sandbox ) lpg-sandbox "$@" ;;
    *       ) lpg-help ;;
  esac
}

function lpg-help {
  cat <<EOF | less
lpg (Local PostGres): manage local PostgreSQL instances

Commands:

  lpg make LOC

      Create an lpg-managed PostgreSQL instance at the specified location.
      The instance will be initialized with a superuser named 'postgres'
      Ex: lpg-make ./pg

  lpg shell (LOC | --anon)

      Enter an interactive shell with a modified environment such that libpq
      commands, like psql and pg_ctl, will use the lpg instance at LOC.

      If '--anon' is given, use a temporary anonymous lpg instance instead

      Environment modifications are:
        - LPG_IN_SHELL is set to '1'
        - LPG_LOC is set to an absolute versin of LOC
          This can come in handy when using 'lpg sandbox'
        - LPG_CONNSTR is set to a PostgrSQL connection string for the
          given lpg instance
        - PGDATA, PGHOST, and PGPORT are set, and pg_ctl is monkeypatched

  lpg do LOC CMD...

      Run a command on an lpg instance without affecting the shell
      Ex: lpg-do ./pg psql -U postgres

  lpg env (LOC | --anon)

      Like 'lpg shell', but instead of entering an interactive shell, prints
      a sourceable bash script.
      Ex: source <(lpg env --anon) && pg_ctl start

  lpg sandbox

      Synonym for 'lpg shell --anon'

  lpg help

      Show this message

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

function _find-unused-tcp-port {
  ${pkgs.python3}/bin/python3 -c '
import socket
s = socket.socket()
s.bind(("", 0))
(_, port) = s.getsockname()
print(port)
s.close()
  '
}

function lpg-env {
  [[ $# = 1 ]] || { echo >&2 "Expected exactly 1 argument"; return 1; }

  if [ "$1" = --anon ]; then
    local dir=$(mktemp -du)
    lpg-make "$dir" >/dev/null || return 1
  else
    [[ -d "$1" ]] || { echo >&2 "$1 does not exist"; return 1; }
    local dir=$(realpath "$1")
  fi

  local running_port=$(ls -A "$dir"/socket | head -n1 | awk -F. '{ print $4 }')
  if [ -n "$running_port" ]; then
    local pgport="$running_port"
  else
    local pgport=$(_find-unused-tcp-port)
  fi
  # ^ Technically, the port should be calculated when 'pg_ctl start' is run;
  #   This is a race condition.

  cat <<EOF

export PGDATA=$dir/cluster
export PGHOST=$dir/socket
export PGPORT=$pgport

export LPG_IN_SHELL=1
export LPG_LOC=$dir
export LPG_CONNSTR=postgresql://postgres@localhost?host=$dir/socket

function pg_ctl {
  ${postgresql}/bin/pg_ctl \
    -l "\$LPG_LOC"/log \
    -o "--unix_socket_directories='\$LPG_LOC/socket'" \
    "\$@"
}
export -f pg_ctl

EOF
}

function lpg-shell {
  ( source <(lpg-env "$@") && bash )
}

function lpg-sandbox {
  lpg-shell --anon
}

function lpg-do {
  [[ $# -gt 1 ]] || { echo >&2 "Expected 2 or more arguments"; return 1; }
  [[ -d "$1" ]] || { echo >&2 "$1 does not exist or is not a directory."; return 1; }
  local dir=$1; shift;

  ( source <(lpg-env "$dir") && "$@" )
}

_main "$@"

'';

in

pkgs.writeScriptBin "lpg" script
