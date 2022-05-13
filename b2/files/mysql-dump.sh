#!/bin/bash

set -euo pipefail

#####
# Configuration
#
# Variables here are configuration values determined by Salt.

# Where to store backups
readonly mysql_backup_dir='{{ mysql_backup_dir }}'

# Which MySQL host to target
readonly mysql_host='{{ mysql_host }}'

# Which MySQL port to target
readonly mysql_port='{{ mysql_port }}'

# Who to notify on backup failures
readonly mail_to='{{ mail_to }}'

# The sender of the notification email
readonly mail_from='{{ mail_from }}'

#####
# Runtime Values
#
# These are values used only by the script; don't change these unless you know
# what you're doing.

# Arguments for connecting to MySQL
mysql_connect_args=(
  --defaults-file=/root/.my.cnf
  --host="$mysql_host"
  --port="$mysql_port"
)

# Name of the lockfile preventing overlapping runs of this script
readonly lockfile="/var/run/mysql-$mysql_host-backup.lock"

# Name of the log file we copy output to
logfile="$(mktemp --tmpdir mysql-backups.log.XXXXXXXXXX)"

# Open the log file as a file descriptor to pass into other commands
# NB. Lockfile FD is 10
exec 11>"$logfile"
readonly log_fd=11

# Dates and times for identifying generated files
date="$(date +%Y-%m-%d)"
timestamp="$date-$(date +%H-%M-%S)"

#####
# Functions
#
# Behavior used elsewhere in the script. Moved here to keep the main script
# logic fairly concise.

# Output an informational notice
log_info() {
  echo "[INFO]" "$@" >&$log_fd
  logger --tag mysql-backup --id $$ -- "$*"
}

# Output an error message
log_error() {
  echo "[ERROR]" "$@" >&$log_fd
  logger --tag mysql-backup --id $$ --priority user.err -- "$*"
}

# Is this a database we should avoid backing up? These are MySQL databases that
# are system-generated or otherwise system-managed. (Restoring these, especially
# with Aurora, isn't something we should do.)
is_ignored_database() {
  [[ "$1" =~ ^(information_schema|performance_schema|mysql|sys|tmp)$ ]]
}

# Notify backup failure via email
notify_backup_failure() {
  mailx -r "$mail_from" -s "MySQL backup failure: $(hostname) ($mysql_host:$mysql_port)" "$mail_to" <"$logfile"
}

# Cleanup function. Once the lockfile is registered, this should be registered
# as the EXIT trap in order to clean up resources regardless of when (and how)
# the script exits.
#
# NB. It is NOT safe to register this handler until we know that we have a lock
# on $lockfile.
on_script_exit() {
  # Save the script exit code so we don't clobber it with our commands.
  exit=$?

  # Explicitly let stuff fail here. This is the last function that runs, so we
  # want to clean up as much as we can.
  set +e
  set +o pipefail

  # If the script didn't exit cleanly, send a notification email (this should
  # happen first because we will eventually rm $logfile).
  if test $exit -ne 0; then
    notify_backup_failure
  fi

  # Clean up the files we generated
  rm -f "$lockfile"
  rm -f "$logfile"

  return $exit
}

#####
# Startup
#
# Preflight checks and initialization

startup_ok=1

# Ensure the MySQL backup directory is present
log_info "Ensuring $mysql_backup_dir exists"
if ! mkdir -p "$mysql_backup_dir" 2>&$log_fd; then
  log_error "Failed to create directory $mysql_backup_dir"

  startup_ok=
fi

# Ping the MySQL server as a preflight check: an empty query will establish a
# connection and ensure the credentials we're sending are valid.
log_info "Pinging MySQL at $mysql_host:$mysql_port"
if ! mysql "${mysql_connect_args[@]}" --batch --execute '' 2>&$log_fd; then
  log_error "Failed to connect to MySQL"

  startup_ok=
fi

if test -z "$startup_ok"; then
  log_error "Refusing to proceed due to failed startup"

  # Notify manually of startup failures
  notify_backup_failure
  exit 1
fi

# Open the lockfile and get an exclusive lock on it. If we can't, fail.
exec 10<>"$lockfile"
if ! flock --nonblock --exclusive 10; then
  lock_contents="$(cat <&10)"
  log_error "Could not obtain lock for $lockfile (lock contents: $lock_contents)"

  # Notify backup failure manually: the cleanup trap isn't safe to run
  notify_backup_failure
  exit 1
fi

# Annotate the lock now that we know we have it.
echo "Started by pid $$ at $timestamp" >&10

# Now that we're running exclusively, register the script exit handler
trap on_script_exit EXIT

log_info "Determining databases to back up"
databases=()
while read -r line; do
  if is_ignored_database "$line"; then
    log_info "Ignoring database $line"
  else
    databases+=("$line")
  fi
done < <(mysql "${mysql_connect_args[@]}" --batch --skip-column-names --execute 'SHOW DATABASES' 2>&$log_fd)

log_info "Databases to be backed up:" "${databases[@]}"

# Flag to determine if the backup operation was successful
backup_ok=1

# Dump each database in serial. Even if one dump fails, we try to dump the others.
for database in "${databases[@]}"; do
  log_info "Dumping database $database"

  outfile="$mysql_backup_dir/$database-$date.sql.gz"
  if ! mysqldump "${mysql_connect_args[@]}" --opt --single-transaction "$database" 2>&$log_fd | gzip 2>&$log_fd >"$outfile"; then
    log_error "Failed to dump $mysql_host:$mysql_port/$database to $outfile (exit code $?)"

    backup_ok=
    continue
  fi

  log_info "Backed up to $outfile"
done

if test -n "$backup_ok"; then
  # Rotate backups if everything succeeded
  log_info "Rotating backups in $mysql_backup_dir"
  if ! find "$mysql_backup_dir" -type f -ctime +7 -delete 2>&$log_fd; then
    # We don't consider backup rotation failure to be an email-worthy emergency: it will use slightly more disk space,
    # but it is not as critical as failing to generate backups in the first place.
    log_error "Failed to rotate backups (exit code $?)"
  fi
else
  log_error "One or more databases failed to back up. Please see the log contents above this message."
  log_error "NOTE: Backups have not been rotated."
  exit 1
fi
