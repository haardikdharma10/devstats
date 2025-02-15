#!/bin/bash
# UDROP=1 attempt to drop users
# LDROP=1 attempt to drop devstats database
# NOCREATE=1 skip creating anything - can be used with UDROP and LDROP to drop database and users and do not create anything
# SETPASS=1 (should be set on a real first run to set main postgres password interactively, CANNOT be used without user interaction)
# WAITBOOT=N (use devel/wait_for_postgres.sh script before proceeding to bootstrap)
set -o pipefail
if ( [ -z "$PG_PASS" ] || [ -z "$PG_PASS_RO" ] || [ -z "$PG_PASS_TEAM" ] )
then
  echo "$0: You need to set PG_PASS, PG_PASS_RO, PG_PASS_TEAM when using INIT"
  exit 1
fi
function finish {
    sync_unlock.sh
}
if [ -z "$TRAP" ]
then
  sync_lock.sh || exit -1
  trap finish EXIT
  export TRAP=1
fi

echo "$0 start"

if [ ! -z "$WAITBOOT" ]
then
  echo "$0: $PROJ wait for postgres ready"
  ./devel/wait_for_postgres.sh $WAITBOOT || exit 13
  echo "$0: $PROJ wait for postgres ready completed"
fi

if [ ! -z "${SETPASS}" ]
then
  ./devel/set_psql_password.sh
fi

if [ ! -z "$UDROP" ]
then
  echo "dropping users"
  ONLY=devstats DROP=1 NOCREATE=1 devel/create_psql_user.sh gha_admin
  ONLY=devstats DROP=1 NOCREATE=1 devel/create_psql_user.sh ro_user
  ONLY=devstats DROP=1 NOCREATE=1 devel/create_psql_user.sh devstats_team
  echo "dropping done"
fi

exists=`./devel/db.sh psql postgres -tAc "select 1 from pg_database WHERE datname = 'devstats'"` || exit 1
if ( [ ! -z "$LDROP" ] && [ "$exists" = "1" ] )
then
  echo "dropping postgres database devstats (logs)"
  ./devel/db.sh psql postgres -c "select pg_terminate_backend(pid) from pg_stat_activity where datname = 'devstats'" || exit 2
  ./devel/db.sh psql postgres -c "drop database devstats" || exit 3
fi

if [ ! -z "$NOCREATE" ]
then
  echo "skipping create"
  exit 0
fi

user=gha_admin
if [ ! -z "${PG_USER}" ]
then
  user="${PG_USER}"
fi

exists=`./devel/db.sh psql postgres -tAc "select 1 from pg_database WHERE datname = 'devstats'"` || exit 4
if [ ! "$exists" = "1" ]
then
  echo "creating postgres database devstats (logs)"
  ./devel/db.sh psql postgres -c "create database devstats" || exit 5
  ./devel/db.sh psql postgres -c "create user gha_admin with password '$PG_PASS'" || exit 6
  ./devel/db.sh psql postgres -c "create user ro_user with password '$PG_PASS_RO'" || exit 7
  ./devel/db.sh psql postgres -c "create user devstats_team with password '$PG_PASS_TEAM'" || exit 8
  ./devel/db.sh psql postgres -c "grant all privileges on database \"devstats\" to gha_admin" || exit 9
  ./devel/db.sh psql postgres -c "alter user gha_admin createdb" || exit 10
  ./devel/db.sh psql devstats < ./util_sql/devstats_log_table.sql
  ./devel/db.sh psql devstats < ./util_sql/devstats_flags_table.sql.sql
  PG_USER="${user}" ./devel/db.sh psql devstats < ./util_sql/devstats_log_table_as_owner.sql
  PG_USER="${user}" ./devel/ro_user_grants.sh devstats || exit 11
  PG_USER="${user}" ./devel/psql_user_grants.sh devstats_team devstats || exit 12
else
  echo "postgres database devstats (logs) already exists"
fi

echo "$0 OK"
