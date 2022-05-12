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
readonly lockfile="/var/run/b2-files-backup.lock"

# Name of the log file we copy output to
logfile="$(mktemp --tmpdir b2-backups.log.XXXXXXXXXX)"

# Open the log file as a file descriptor to pass into other commands
# NB. Lockfile FD is 10
exec 11>"$logfile"
readonly log_fd=11

# Name of the temporary directory used to mount the OFS snapshot (see the cleanup function)
snapshot_mount="$(mktemp -d --tmpdir b2-backups.mount.XXXXXXXXXX)"

# The backup date. Used to identify both the OFS snapshot as well as archive tarballs.
date="$(date +%Y-%m-%d)"

# Timestamp used to identify archive tarballs
timestamp="$date-$(date +%H-%M-%S)"

# Arguments shared between 'b2' command operations
b2_global_args=(
  # Skip progress bar output
  --noProgress

  # Use a thread pool of this size.
  --threads "$b2_threads"
)

# Arguments to pass to 'b2 sync' commands.
# cf. https://b2-command-line-tool.readthedocs.io/en/master/subcommands/sync.html
b2_sync_args=(
  "${b2_global_args[@]}"

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
  logger --tag b2 --id $$ -- "$*"
}

# Output an error message
log_error() {
  echo "[ERROR]" "$@" >&$log_fd
  logger --tag b2 --id $$ --priority user.err -- "$*"
}

# Notify backup failure via email
notify_backup_failure() {
  mailx -r "$mail_from" -s "B2 backup failure: $(hostname)" "$mail_to" <"$logfile"
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

  # Clean up the mount
  if test -f "$snapshot_mount/README"; then umount "$snapshot_mount"; fi
  rmdir "$snapshot_mount"

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

# Authorize against Backblaze now
log_info "Logging in to B2"
b2 authorize-account 2>&$log_fd

#####
# OFS
#
# Find and mount the latest OFS snapshot

# Use awk to find the S3 bucket mounted on /var/www
ofs_bucket="$(awk '$2 == "/var/www" { print $1 }' /etc/fstab)"
if test -z "$ofs_bucket"; then
  log_error "Failed to find OFS bucket mounted on /var/www"
  exit 1
fi

if [[ "$ofs_bucket" != s3://* ]]; then
  log_error "/var/www is mounted to $ofs_bucket which is not an S3 bucket"
  exit 1
fi

log_info "OFS bucket: $ofs_bucket"

# Find the latest snapshot (-sz: list snapshots (-s) in UTC (-z)). The /^s3/
# condition in awk avoids capturing the first line of output (the column names).
ofs_snapshot="$(/sbin/mount.objectivefs list -sz "$ofs_bucket@$date" | awk '/^s3/ { latest = $1 } END { print latest }')"
if test -z "$ofs_snapshot"; then
  log_error "Could not find OFS snapshot in $ofs_bucket matching date $date"
  exit 1
fi

# Mount the snapshot and validate it
log_info "Mounting OFS snapshot $ofs_snapshot"
/sbin/mount.objectivefs "$ofs_snapshot" "$snapshot_mount"

if ! test -f "$snapshot_mount/README"; then
  log_error "Failed to validate mount of OFS snapshot $ofs_snapshot: no README present"
  exit 1
fi

#####
# Sync and Backups

# This flag determines if backups were successful or not. We try to back up as
# much as possible, continuing even if errors occur during one phase and
# reporting errors in aggregate.
sync_ok=1

log_info "Running daily sync of $ofs_snapshot/vhosts"
if b2 sync "${b2_sync_args[@]}" "$snapshot_mount/vhosts" "b2://$b2_bucket/vhosts/" 2>&$log_fd; then
  log_info "Daily sync successful"
else
  log_error "Daily sync failed (exit code $?); additional logs may be available above this message"
  sync_ok=
fi

if test -n "$sync_ok"; then
  log_info "Backup successful"
else
  log_error "One or more sync operations failed. Please see the log contents above this message."
  exit 1
fi
