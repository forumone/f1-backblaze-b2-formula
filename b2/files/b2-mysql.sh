#!/bin/bash
# shellcheck enable=avoid-nullary-conditions
# shellcheck enable=check-set-e-suppressed

set -euo pipefail

#####
# Configuration
#
# Variables here are configuration values determined by Salt.

# Number of days to persist old revisions
readonly b2_keep_days='{{ b2_keep_days }}'

# Number of threads to use when syncing. Contributes to system load; choose wisely.
readonly b2_threads='{{ b2_threads }}'

# Where MySQL backups are stored
readonly mysql_backup_dir='{{ mysql_backup_dir }}'

# SSM parameter (of type SecureString) containing the JSON-formatted payload
readonly b2_ssm_prefix='{{ b2_ssm_prefix }}'

# Who to notify on backup failures
readonly mail_to='{{ mail_to }}'

# The sender of the notification email
readonly mail_from='{{ mail_from }}'

#####
# Runtime Values
#
# These are values used only by the script; don't change these unless you know
# what you're doing.

# Name of the lockfile preventing overlapping runs of this script
readonly lockfile="/var/run/b2-mysql-backup.lock"

# Name of the log file we copy output to
logfile="$(mktemp --tmpdir b2-mysql-backups.log.XXXXXXXXXX)"

# Open the log file as a file descriptor to pass into other commands
# NB. Lockfile FD is 10
exec 11>"$logfile"
readonly log_fd=11

# Dates and times for identifying generated files
date="$(date +%Y-%m-%d)"
timestamp="$date-$(date +%H-%M-%S)"

# Arguments to pass to 'b2 sync' commands.
# cf. https://b2-command-line-tool.readthedocs.io/en/master/subcommands/sync.html
b2_sync_args=(
  # Skip progress bar output
  --noProgress

  # Use a thread pool of this size.
  --threads "$b2_threads"

  # Ignore symbolic links
  --excludeAllSymlinks

  # If a file in the B2 bucket is somehow newer than what we see on disk, replace it
  --replaceNewer

  # Hide files that aren't present in the source directory, and retain only
  # those revisions newer than the keepDays parameter.
  --keepDays "$b2_keep_days"
)

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

# Notify backup failure via email
notify_backup_failure() {
  mailx -r "$mail_from" -s "B2 MySQL backup sync failure: $(hostname)" "$mail_to" <"$logfile"
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
# Check that all tools are available and that we have the necessary B2 API credentials.

# This flag, when set, determines if the startup checks are all successful.
startup_ok=1

# Sanity checks: make sure the commands we need are available
if ! type -P aws >&/dev/null; then
  log_error "Preflight check failed: 'aws' is not available in \$PATH=$PATH"
  startup_ok=
fi

if ! type -P b2 >&/dev/null; then
  log_error "Preflight check failed: 'b2' is not available in \$PATH=$PATH"
  startup_ok=
fi

# Acquire B2 application credentials. Note that if this fails, we still proceed
# with loading the B2_* environment variables
if ! b2_credentials="$(aws ssm get-parameter --with-decryption --name "$b2_ssm_prefix/application-key" 2>&$log_fd | jq -r '.Parameter.Value')"; then
  log_error "Could not read B2 API credentials from $b2_ssm_prefix/application-key"
  log_info "This will cause the next two lines to be spurious errors; ignore them."
  startup_ok=
fi

B2_APPLICATION_KEY_ID="$(jq -r .B2_APPLICATION_KEY_ID <<<"$b2_credentials")"
if test -z "$B2_APPLICATION_KEY_ID"; then
  log_error "Received empty B2_APPLICATION_KEY_ID from SSM parameter $b2_ssm_prefix/application-key"
  startup_ok=
fi

B2_APPLICATION_KEY="$(jq -r .B2_APPLICATION_KEY <<<"$b2_credentials")"
if test -z "$B2_APPLICATION_KEY"; then
  log_error "Received empty B2_APPLICATION_KEY from SSM parameter $b2_ssm_prefix/application-key"
  startup_ok=
fi

export B2_APPLICATION_KEY B2_APPLICATION_KEY_ID
unset b2_credentials

if ! b2_bucket="$(aws ssm get-parameter --name "$b2_ssm_prefix/bucket-name" 2>&$log_fd | jq -r .Parameter.Value)"; then
  log_error "Could not read B2 bucket name from SSM parameter $b2_ssm_prefix/bucket-name"
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

log_info "Dumping MySQL databases via script /usr/local/sbin/mysql-dump.sh"
log_info "NOTE: Its status will be reported separately."
/usr/local/sbin/mysql-dump.sh

# Authorize against Backblaze now
log_info "Logging in to B2"
b2 authorize-account 2>&$log_fd

#####
# Backups
#
# Begin sync of database directory into Backblaze
sync_ok=1

log_info "Running sync of $mysql_backup_dir"
if b2 sync "${b2_sync_args[@]}" "$mysql_backup_dir" "b2://$b2_bucket/mysql" 2>&$log_fd; then
  log_info "Backup sync successful"
else
  log_error "Backup sync failed (exit code $?)"
  sync_ok=
fi

if test -n "$sync_ok"; then
  log_info "Backup successful"
else
  log_error "One or more sync operations failed. Please see the log contents above this message."
  exit 1
fi
