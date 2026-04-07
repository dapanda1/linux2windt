#!/usr/bin/perl
# ============================================================================
# linux2windt
# ============================================================================
# Scans a local folder for new files, wakes a Windows server via WoL,
# transfers files over SMB using smbclient, verifies file sizes, logs
# everything, and optionally sends a completion report to Home Assistant.
#
# Usage:
#   perl linux2windt.pl                    # normal run (uses ./linux2windt.conf)
#   perl linux2windt.pl /path/to/conf      # use a specific config file
#   perl linux2windt.pl --dry-run          # preview what would transfer (no changes)
#   perl linux2windt.pl --seed             # mark all existing files as already processed
#   perl linux2windt.pl --version          # print version and exit
# ============================================================================

use strict;
use warnings;
use File::Basename;
use File::Find;
use File::Path qw(make_path);
use File::Copy;
use File::Temp qw(tempfile);
use POSIX qw(strftime);
use Getopt::Long;
use JSON::PP;

# ============================================================================
# Version
# ============================================================================
my $VERSION = '2.1.2';

# ============================================================================
# Global state
# ============================================================================
my %CFG;                    # Holds all config key/value pairs
my @transfer_results;       # Collects per-file results for the final report
my $start_time;             # Epoch time when the run started
my $dry_run = 0;            # Preview mode flag

# ============================================================================
# Main entry point
# ============================================================================
sub main {
    # ------------------------------------------------------------------
    # Parses command-line arguments, loads configuration, then runs the
    # full transfer pipeline: scan -> wake -> transfer -> verify -> report.
    # ------------------------------------------------------------------
    my $config_file = '';
    my $show_version = 0;
    my $seed_mode = 0;
    GetOptions(
        'config=s' => \$config_file,
        'dry-run'  => \$dry_run,
        'version'  => \$show_version,
        'seed'     => \$seed_mode,
    );

    if ($show_version) {
        print "linux2windt v$VERSION\n";
        return 0;
    }

    # Default config: same directory as the script
    if (!$config_file) {
        my $script_dir = dirname(__FILE__);
        $config_file = "$script_dir/linux2windt.conf";
    }
    # Allow bare positional arg as config path
    if (!$config_file && @ARGV) {
        $config_file = $ARGV[0];
    }

    # Run config migrations before loading (handles renames/adds/drops
    # between versions so a git pull never breaks the live config).
    run_config_migration($config_file);

    load_config($config_file);
    ensure_log_dirs();
    $start_time = time();

    # --seed: Mark all existing files as already processed, then exit.
    if ($seed_mode) {
        return seed_processed_log();
    }

    # Acquire lock file to prevent overlapping runs
    my $lock_acquired = acquire_lock();
    if (!$lock_acquired) {
        log_warn("Another instance is already running. Exiting.");
        return 0;
    }

    log_info("=== linux2windt v$VERSION started ===");
    log_info("Dry-run mode: ON") if $dry_run;

    # Step 1: Clean stale entries from processed log and failure tracker
    cleanup_processed_log();
    cleanup_failures();

    # Step 2: Find new files (excluding permanently failed ones)
    my @new_files = scan_for_new_files();
    my $failures  = load_failures();
    my @skipped_given_up;
    my @to_transfer;

    for my $file (@new_files) {
        my $rel = get_relative_path($file, $CFG{SOURCE_DIR});
        if (is_given_up($rel, $failures)) {
            push @skipped_given_up, $rel;
        } else {
            push @to_transfer, $file;
        }
    }

    if (@skipped_given_up) {
        log_warn(sprintf("Skipping %d permanently failed file(s):", scalar @skipped_given_up));
        for my $rel (@skipped_given_up) {
            log_warn("  GIVEN UP: $rel ($failures->{$rel}{attempts} failed run(s), last: $failures->{$rel}{last_error})");
        }
    }

    if (!@to_transfer) {
        log_info("No new files found. Nothing to do.");
        log_info("=== Run complete (no work) ===");
        release_lock();
        return 0;
    }
    log_info(sprintf("Found %d new file(s) to transfer.", scalar @to_transfer));

    # Step 3: Wake the server
    if (!$dry_run) {
        my $server_ready = wake_and_wait();
        if (!$server_ready) {
            my $msg = "Server did not come online after WoL. Aborting.";
            log_error($msg);
            send_ha_report(scalar @to_transfer, 0, scalar @to_transfer, 0,
                [ { file => "ALL", status => "FAILED", reason => $msg } ]);
            release_lock();
            return 1;
        }
    }

    # Step 4: Transfer each file
    my ($ok_count, $fail_count) = (0, 0);
    my $max_errors = cfg('MAX_ERRORS_BEFORE_ABORT', 2);
    my $total_files = scalar @to_transfer;

    for my $i (0 .. $#to_transfer) {
        my $file = $to_transfer[$i];
        my $file_num = $i + 1;

        if ($dry_run) {
            log_info("[DRY-RUN] [$file_num/$total_files] Would transfer: $file");
            push @transfer_results, { file => $file, status => 'DRY-RUN', reason => '' };
            $ok_count++;
            next;
        }

        my $result = transfer_file($file, $file_num, $total_files);
        if ($result->{success}) {
            mark_processed($file);
            $ok_count++;
        } else {
            my $rel = get_relative_path($file, $CFG{SOURCE_DIR});
            my $abandoned = record_failure($rel, $result->{reason});
            if ($abandoned) {
                $result->{status} = 'GIVEN UP';
            }
            $fail_count++;
        }
        push @transfer_results, $result;

        # Abort if too many errors in this run
        if ($max_errors > 0 && $fail_count >= $max_errors) {
            my $remaining = scalar(@to_transfer) - $ok_count - $fail_count;
            log_error(sprintf("Aborting: hit %d errors (max %d). %d file(s) skipped.",
                $fail_count, $max_errors, $remaining));
            send_ha_abort($fail_count, $max_errors, $ok_count, $remaining, \@transfer_results);
            release_lock();
            return 1;
        }
    }

    # Step 5: Report
    my $total_bytes = 0;
    for my $r (@transfer_results) {
        $total_bytes += $r->{size} if $r->{success} && defined $r->{size};
    }
    my $run_elapsed = time() - $start_time;
    my $speed_str = ($run_elapsed > 0 && $total_bytes > 0)
        ? format_size($total_bytes / $run_elapsed) . "/s"
        : "N/A";

    send_ha_report(scalar @to_transfer, $ok_count, $fail_count, $total_bytes, \@transfer_results);
    log_info(sprintf("=== Run complete: %d OK, %d FAILED out of %d ===",
        $ok_count, $fail_count, scalar @to_transfer));
    log_info(sprintf("=== Total transferred: %s in %s (%s) ===",
        format_size($total_bytes), format_duration($run_elapsed), $speed_str));

    release_lock();
    return ($fail_count > 0) ? 1 : 0;
}

# ============================================================================
# Configuration
# ============================================================================

sub run_config_migration {
    # ------------------------------------------------------------------
    # Loads migrate.pl and runs the migration engine against the live
    # config file. This ensures that after a git pull, any new/renamed/
    # dropped config keys are applied automatically before the config
    # is parsed. Safe to call every run — exits early if already current.
    # Args: $config_path - path to the .conf file
    # ------------------------------------------------------------------
    my ($config_path) = @_;
    my $migrate_script = dirname(__FILE__) . "/migrate.pl";

    unless (-f $migrate_script) {
        warn "migrate.pl not found at $migrate_script — skipping migration.\n";
        return;
    }

    require $migrate_script;
    run_migrate($config_path, 0);
}

sub load_config {
    # ------------------------------------------------------------------
    # Reads the configuration file into the global %CFG hash.
    # Strips comments and blank lines. Dies if the file is missing.
    # Args: $path - path to the .conf file
    # ------------------------------------------------------------------
    my ($path) = @_;
    die "Config file not found: $path\n" unless -f $path;

    open my $fh, '<', $path or die "Cannot open config $path: $!\n";
    while (my $line = <$fh>) {
        chomp $line;
        $line =~ s/^\s+//;           # trim leading whitespace
        $line =~ s/\s+$//;           # trim trailing whitespace
        next if $line =~ /^#/ || $line eq '';
        if ($line =~ /^([A-Z_]+)=(.*)$/) {
            $CFG{$1} = $2;
        }
    }
    close $fh;

    # Validate required keys
    my @required = qw(
        SOURCE_DIR SMB_SERVER_IP SMB_SHARE SMB_USER SMB_PASS
        WOL_MAC LOG_DIR TRANSFER_LOG ERROR_LOG PROCESSED_LOG
    );
    for my $key (@required) {
        die "Missing required config key: $key\n" unless defined $CFG{$key};
    }
}

sub cfg {
    # ------------------------------------------------------------------
    # Retrieves a config value with an optional default.
    # Args: $key     - config key name
    #       $default - value to return if the key is not set
    # Returns: the config value or the default
    # ------------------------------------------------------------------
    my ($key, $default) = @_;
    return defined $CFG{$key} ? $CFG{$key} : $default;
}

# ============================================================================
# Logging
# ============================================================================

# ============================================================================
# Lock File
# ============================================================================

sub _lock_path {
    # ------------------------------------------------------------------
    # Returns the path to the lock file. Uses /tmp so it survives across
    # the script directory but not across reboots (which is correct —
    # a stale lock from a crashed run clears itself on restart).
    # Returns: path string
    # ------------------------------------------------------------------
    return "/tmp/linux2windt.lock";
}

sub acquire_lock {
    # ------------------------------------------------------------------
    # Creates a lock file containing the current PID. If a lock file
    # already exists, checks whether the PID in it is still running.
    # If the old process is dead, takes over the lock (stale lock).
    # Returns: 1 if lock acquired, 0 if another instance is running
    # ------------------------------------------------------------------
    my $path = _lock_path();

    if (-f $path) {
        open my $fh, '<', $path or return 0;
        my $old_pid = <$fh>;
        close $fh;
        chomp $old_pid if defined $old_pid;

        # Check if the old PID is still running
        if (defined $old_pid && $old_pid =~ /^\d+$/ && kill(0, $old_pid)) {
            return 0;    # another instance is genuinely running
        }

        # Stale lock — old process is gone
        log_warn("Removing stale lock file (PID $old_pid no longer running).");
    }

    # Write our PID
    open my $fh, '>', $path or do {
        log_error("Cannot create lock file $path: $!");
        return 0;
    };
    print $fh "$$\n";
    close $fh;
    return 1;
}

sub release_lock {
    # ------------------------------------------------------------------
    # Removes the lock file. Only removes it if the PID inside matches
    # our own (safety check against race conditions).
    # ------------------------------------------------------------------
    my $path = _lock_path();
    return unless -f $path;

    open my $fh, '<', $path or return;
    my $pid = <$fh>;
    close $fh;
    chomp $pid if defined $pid;

    if (defined $pid && $pid eq $$) {
        unlink $path;
    }
}

# ============================================================================
# Logging
# ============================================================================

sub ensure_log_dirs {
    # ------------------------------------------------------------------
    # Creates the log directory (and parents) if it doesn't already exist.
    # Dies if directory creation fails.
    # ------------------------------------------------------------------
    my $dir = $CFG{LOG_DIR};
    unless (-d $dir) {
        make_path($dir) or die "Cannot create log dir $dir: $!\n";
    }
}

sub _write_log {
    # ------------------------------------------------------------------
    # Low-level log writer. Appends a timestamped line to a log file.
    # Handles log rotation when the file exceeds LOG_MAX_SIZE.
    # Args: $filename    - log file name (not full path)
    #       $level       - severity string (INFO, ERROR, WARN)
    #       $message     - the log message text
    #       $print_stdout - if true, also print to STDOUT (default: 1)
    # ------------------------------------------------------------------
    my ($filename, $level, $message, $print_stdout) = @_;
    $print_stdout = 1 unless defined $print_stdout;
    my $path = "$CFG{LOG_DIR}/$filename";

    rotate_log($path) if -f $path && -s $path > cfg('LOG_MAX_SIZE', 5242880);

    my $timestamp = strftime("%Y-%m-%d %H:%M:%S", localtime);
    open my $fh, '>>', $path or warn "Cannot write to $path: $!\n" and return;
    print $fh "[$timestamp] [$level] $message\n";
    close $fh;

    # Also print to STDOUT for interactive/manual runs
    print "[$timestamp] [$level] $message\n" if $print_stdout;
}

sub rotate_log {
    # ------------------------------------------------------------------
    # Rotates a log file by renaming it with a numeric suffix.
    # Keeps up to LOG_KEEP_COUNT rotated copies, deleting the oldest.
    # Args: $path - full path to the log file to rotate
    # ------------------------------------------------------------------
    my ($path) = @_;
    my $keep = cfg('LOG_KEEP_COUNT', 3);

    # Remove the oldest if it exists
    unlink "${path}.${keep}" if -f "${path}.${keep}";

    # Shift existing rotated files up by one
    for (my $i = $keep - 1; $i >= 1; $i--) {
        my $src = "${path}.${i}";
        my $dst = "${path}." . ($i + 1);
        rename $src, $dst if -f $src;
    }

    # Rotate current file to .1
    rename $path, "${path}.1" if -f $path;
}

sub log_info {
    # ------------------------------------------------------------------
    # Logs an informational message to the main transfer log.
    # Args: $msg - message text
    # ------------------------------------------------------------------
    my ($msg) = @_;
    _write_log($CFG{TRANSFER_LOG}, 'INFO', $msg);
}

sub log_error {
    # ------------------------------------------------------------------
    # Logs an error message to BOTH the main transfer log and the
    # dedicated error log, so errors are easy to find in one place.
    # Prints to STDOUT only once (via the transfer log write).
    # Args: $msg - error message text
    # ------------------------------------------------------------------
    my ($msg) = @_;
    _write_log($CFG{TRANSFER_LOG}, 'ERROR', $msg, 1);
    _write_log($CFG{ERROR_LOG},    'ERROR', $msg, 0);
}

sub log_warn {
    # ------------------------------------------------------------------
    # Logs a warning message to the main transfer log.
    # Args: $msg - warning message text
    # ------------------------------------------------------------------
    my ($msg) = @_;
    _write_log($CFG{TRANSFER_LOG}, 'WARN', $msg);
}

# ============================================================================
# File Scanning
# ============================================================================

sub load_processed_list {
    # ------------------------------------------------------------------
    # Reads the processed-files log into a hash for fast lookups.
    # Each line in the file is a relative path that was previously
    # transferred successfully.
    # Returns: hashref where keys are relative file paths
    # ------------------------------------------------------------------
    my $path = "$CFG{LOG_DIR}/$CFG{PROCESSED_LOG}";
    my %seen;
    if (-f $path) {
        open my $fh, '<', $path or do {
            log_error("Cannot read processed log: $!");
            return \%seen;
        };
        while (<$fh>) {
            chomp;
            $seen{$_} = 1;
        }
        close $fh;
    }
    return \%seen;
}

sub seed_processed_log {
    # ------------------------------------------------------------------
    # Marks all files currently in SOURCE_DIR as already processed.
    # Used for first-time setup so existing files are not transferred.
    # Only adds files not already in processed.log (safe to run twice).
    # Called via: perl linux2windt.pl --seed
    # Returns: 0 on success
    # ------------------------------------------------------------------
    my $source = $CFG{SOURCE_DIR};
    my $path   = "$CFG{LOG_DIR}/$CFG{PROCESSED_LOG}";
    my $seen   = load_processed_list();

    $source =~ s/\/+$//;

    unless (-d $source) {
        print "ERROR: SOURCE_DIR not found: $source\n";
        return 1;
    }

    my @all_files;
    my $log_dir = $CFG{LOG_DIR};

    find({
        wanted => sub {
            return unless -f $_;
            my $abs = $File::Find::name;
            return if index($abs, $log_dir) == 0;
            my $rel = get_relative_path($abs, $source);
            push @all_files, $rel unless $seen->{$rel};
        },
        no_chdir => 1,
    }, $source);

    if (!@all_files) {
        print "Nothing to seed — all files already in processed.log.\n";
        return 0;
    }

    open my $fh, '>>', $path or do {
        print "ERROR: Cannot write to $path: $!\n";
        return 1;
    };
    print $fh "$_\n" for @all_files;
    close $fh;

    printf "Seeded %d file(s) into processed.log. These will be skipped on future runs.\n",
        scalar @all_files;

    return 0;
}

sub cleanup_processed_log {
    # ------------------------------------------------------------------
    # Removes entries from processed.log where the source file no longer
    # exists. This prevents the log from growing indefinitely as files
    # are added to and later removed from the source directory.
    # Runs at the start of each transfer cycle before scanning.
    # ------------------------------------------------------------------
    my $path   = "$CFG{LOG_DIR}/$CFG{PROCESSED_LOG}";
    my $source = $CFG{SOURCE_DIR};
    $source =~ s/\/+$//;    # strip trailing slashes

    return unless -f $path;

    my @kept;
    my $removed = 0;

    open my $fh, '<', $path or do {
        log_error("Cannot read processed log for cleanup: $!");
        return;
    };
    while (my $rel = <$fh>) {
        chomp $rel;
        next if $rel eq '';
        if (-e "$source/$rel") {
            push @kept, $rel;
        } else {
            $removed++;
        }
    }
    close $fh;

    if ($removed > 0) {
        open my $wfh, '>', $path or do {
            log_error("Cannot rewrite processed log: $!");
            return;
        };
        print $wfh "$_\n" for @kept;
        close $wfh;
        log_info("Cleaned processed.log: removed $removed stale entry(s), ${\scalar @kept} remaining.");
    }
}

sub scan_for_new_files {
    # ------------------------------------------------------------------
    # Walks the SOURCE_DIR looking for regular files that are not yet
    # in the processed log. Respects the RECURSE_SUBDIRS setting.
    # Returns: list of absolute file paths that are new
    # ------------------------------------------------------------------
    my $source  = $CFG{SOURCE_DIR};
    my $recurse = cfg('RECURSE_SUBDIRS', 1);
    my $seen    = load_processed_list();
    my @new;

    # Skip our own log directory to avoid transferring logs
    my $log_dir = $CFG{LOG_DIR};

    if ($recurse) {
        find({
            wanted => sub {
                return unless -f $_;
                my $abs = $File::Find::name;
                # Skip files inside the log directory
                return if index($abs, $log_dir) == 0;
                my $rel = get_relative_path($abs, $source);
                push @new, $abs unless $seen->{$rel};
            },
            no_chdir => 1,
        }, $source);
    } else {
        opendir my $dh, $source or do {
            log_error("Cannot open source dir $source: $!");
            return ();
        };
        while (my $entry = readdir $dh) {
            next if $entry =~ /^\./;
            my $abs = "$source/$entry";
            next unless -f $abs;
            next if index($abs, $log_dir) == 0;
            my $rel = get_relative_path($abs, $source);
            push @new, $abs unless $seen->{$rel};
        }
        closedir $dh;
    }

    return sort @new;
}

sub get_relative_path {
    # ------------------------------------------------------------------
    # Computes the relative path of a file with respect to a base dir.
    # Args: $abs  - absolute path to the file
    #       $base - base directory path
    # Returns: relative path string (e.g. "subdir/file.mkv")
    # ------------------------------------------------------------------
    my ($abs, $base) = @_;
    $base =~ s/\/+$//;    # strip trailing slashes
    my $rel = $abs;
    $rel =~ s/^\Q$base\E\/?//;
    return $rel;
}

sub mark_processed {
    # ------------------------------------------------------------------
    # Appends a file's relative path to the processed log so it won't
    # be transferred again on future runs.
    # Args: $abs_path - absolute path of the successfully transferred file
    # ------------------------------------------------------------------
    my ($abs_path) = @_;
    my $rel  = get_relative_path($abs_path, $CFG{SOURCE_DIR});
    my $path = "$CFG{LOG_DIR}/$CFG{PROCESSED_LOG}";
    open my $fh, '>>', $path or do {
        log_error("Cannot write to processed log: $!");
        return;
    };
    print $fh "$rel\n";
    close $fh;

    # Clear from failure tracker on success
    clear_failure($rel);
}

# ============================================================================
# Failure Tracker
# ============================================================================

sub _failures_path {
    # ------------------------------------------------------------------
    # Returns the path to the failures.json file in the log directory.
    # Returns: path string
    # ------------------------------------------------------------------
    return "$CFG{LOG_DIR}/failures.json";
}

sub load_failures {
    # ------------------------------------------------------------------
    # Reads the failure tracker from failures.json. Each key is a
    # relative file path; the value is a hashref with:
    #   attempts  => number of runs that have tried and failed
    #   last_error => most recent error message
    #   last_run   => timestamp of the last failed attempt
    #   given_up   => 1 if MAX_RUN_ATTEMPTS was exceeded
    # Returns: hashref of tracked failures
    # ------------------------------------------------------------------
    my $path = _failures_path();
    return {} unless -f $path;

    open my $fh, '<', $path or do {
        log_warn("Cannot read failures tracker: $!");
        return {};
    };
    local $/;
    my $json_text = <$fh>;
    close $fh;

    my $data = eval { decode_json($json_text) };
    if ($@) {
        log_warn("Corrupt failures.json, starting fresh: $@");
        return {};
    }
    return $data;
}

sub save_failures {
    # ------------------------------------------------------------------
    # Writes the failure tracker hashref to failures.json.
    # Args: $data - hashref of failure entries
    # ------------------------------------------------------------------
    my ($data) = @_;
    my $path = _failures_path();

    open my $fh, '>', $path or do {
        log_error("Cannot write failures tracker: $!");
        return;
    };
    print $fh JSON::PP->new->pretty->canonical->encode($data);
    close $fh;
}

sub record_failure {
    # ------------------------------------------------------------------
    # Records a failed transfer attempt for a file. Increments the
    # attempt counter and updates the last error and timestamp.
    # If MAX_RUN_ATTEMPTS is exceeded, marks the file as given up.
    # Args: $rel_path   - relative file path
    #       $error_msg  - reason for the failure
    # Returns: 1 if the file has been permanently abandoned, 0 otherwise
    # ------------------------------------------------------------------
    my ($rel_path, $error_msg) = @_;
    my $failures = load_failures();
    my $max      = cfg('MAX_RUN_ATTEMPTS', 3);

    $failures->{$rel_path} //= { attempts => 0, given_up => 0 };
    $failures->{$rel_path}{attempts}++;
    $failures->{$rel_path}{last_error} = $error_msg;
    $failures->{$rel_path}{last_run}   = strftime("%Y-%m-%d %H:%M:%S", localtime);

    my $abandoned = 0;
    if ($max > 0 && $failures->{$rel_path}{attempts} >= $max) {
        $failures->{$rel_path}{given_up} = 1;
        $abandoned = 1;
        log_error("Giving up on $rel_path after $max failed run(s).");
    }

    save_failures($failures);
    return $abandoned;
}

sub clear_failure {
    # ------------------------------------------------------------------
    # Removes a file from the failure tracker (called on successful
    # transfer so a previously-failing file gets cleaned up).
    # Args: $rel_path - relative file path
    # ------------------------------------------------------------------
    my ($rel_path) = @_;
    my $failures = load_failures();
    if (exists $failures->{$rel_path}) {
        delete $failures->{$rel_path};
        save_failures($failures);
    }
}

sub is_given_up {
    # ------------------------------------------------------------------
    # Checks if a file has been permanently abandoned after exceeding
    # MAX_RUN_ATTEMPTS.
    # Args: $rel_path - relative file path
    #       $failures - hashref from load_failures()
    # Returns: 1 if abandoned, 0 otherwise
    # ------------------------------------------------------------------
    my ($rel_path, $failures) = @_;
    return 0 unless exists $failures->{$rel_path};
    return $failures->{$rel_path}{given_up} ? 1 : 0;
}

sub cleanup_failures {
    # ------------------------------------------------------------------
    # Removes entries from failures.json where the source file no longer
    # exists, keeping the tracker in sync with the source directory.
    # ------------------------------------------------------------------
    my $failures = load_failures();
    my $source   = $CFG{SOURCE_DIR};
    $source =~ s/\/+$//;

    my $removed = 0;
    for my $rel (keys %$failures) {
        unless (-e "$source/$rel") {
            delete $failures->{$rel};
            $removed++;
        }
    }

    if ($removed > 0) {
        save_failures($failures);
        log_info("Cleaned failures.json: removed $removed stale entry(s).");
    }
}

# ============================================================================
# Wake-on-LAN
# ============================================================================

sub send_wol_packet {
    # ------------------------------------------------------------------
    # Sends a single Wake-on-LAN magic packet to the configured MAC
    # address via UDP broadcast on port 9.
    # Uses raw socket via Perl's socket functions.
    # ------------------------------------------------------------------
    my $mac_str   = $CFG{WOL_MAC};
    my $broadcast = cfg('WOL_BROADCAST', '255.255.255.255');

    # Parse MAC into 6 bytes
    my @mac_bytes = map { hex($_) } split(/[:\-]/, $mac_str);
    if (@mac_bytes != 6) {
        log_error("Invalid MAC address format: $mac_str");
        return 0;
    }

    # Build magic packet: 6x 0xFF followed by 16x the MAC address
    my $mac_packed = pack('C6', @mac_bytes);
    my $magic = ("\xff" x 6) . ($mac_packed x 16);

    # Send via UDP broadcast
    require IO::Socket::INET;
    my $sock = IO::Socket::INET->new(
        Proto     => 'udp',
        Broadcast => 1,
        PeerAddr  => $broadcast,
        PeerPort  => 9,
    );
    unless ($sock) {
        log_error("Failed to create WoL socket: $!");
        return 0;
    }
    $sock->send($magic);
    $sock->close();
    return 1;
}

sub wake_and_wait {
    # ------------------------------------------------------------------
    # Sends a burst of WoL packets then waits (via ping) for the server
    # to become reachable. Returns 1 if the server is online, 0 if the
    # wait timed out.
    # ------------------------------------------------------------------
    my $burst_count = cfg('WOL_BURST_COUNT', 3);
    my $burst_delay = cfg('WOL_BURST_DELAY', 1);
    my $timeout     = cfg('WOL_WAIT_TIMEOUT', 120);
    my $interval    = cfg('WOL_PING_INTERVAL', 5);
    my $server_ip   = $CFG{SMB_SERVER_IP};

    # Check if already online
    if (is_host_reachable($server_ip)) {
        log_info("Server $server_ip is already online.");
        return 1;
    }

    log_info("Sending $burst_count WoL packets to $CFG{WOL_MAC}...");
    for (1 .. $burst_count) {
        send_wol_packet();
        sleep $burst_delay if $_ < $burst_count;
    }

    log_info("Waiting up to ${timeout}s for server to come online...");
    my $elapsed = 0;
    while ($elapsed < $timeout) {
        sleep $interval;
        $elapsed += $interval;
        if (is_host_reachable($server_ip)) {
            log_info("Server is online after ${elapsed}s. Waiting 10s for SMB to start...");
            sleep 10;    # extra grace period for SMB service startup
            return 1;
        }
    }

    return 0;    # timed out
}

sub is_host_reachable {
    # ------------------------------------------------------------------
    # Pings a host once with a 2-second timeout to check if it's online.
    # Args: $host - IP address or hostname
    # Returns: 1 if reachable, 0 if not
    # ------------------------------------------------------------------
    my ($host) = @_;
    my $ret = system("ping -c 1 -W 2 $host > /dev/null 2>&1");
    return ($ret == 0) ? 1 : 0;
}

# ============================================================================
# SMB Transfer
# ============================================================================

sub run_smbclient {
    # ------------------------------------------------------------------
    # Runs smbclient commands by writing them to a temp file and piping
    # via stdin. This avoids all shell quoting issues with filenames
    # that contain spaces, quotes, or other special characters.
    #
    # Args: $service  - smbclient service string (//host/share)
    #       @commands - list of smbclient commands to execute
    # Returns: hashref with keys:
    #   output => combined stdout/stderr from smbclient
    #   exit   => exit code (0 = success)
    # ------------------------------------------------------------------
    my ($service, @commands) = @_;

    # Write commands to a temp file
    my ($tfh, $tfile) = tempfile(UNLINK => 1, SUFFIX => '.smb');
    for my $cmd (@commands) {
        print $tfh "$cmd\n";
    }
    print $tfh "exit\n";
    close $tfh;

    # Run smbclient reading commands from the temp file
    my $auth_file = _write_smb_auth_file();
    my $output = `smbclient "$service" -A "$auth_file" < "$tfile" 2>&1`;
    my $exit = $? >> 8;
    unlink $auth_file;

    return { output => $output, exit => $exit };
}

sub _write_smb_auth_file {
    # ------------------------------------------------------------------
    # Writes SMB credentials to a temporary auth file for smbclient -A.
    # This avoids putting the password on the command line where it
    # would be visible in process listings.
    # Returns: path to the temp auth file (caller must unlink)
    # ------------------------------------------------------------------
    my ($tfh, $tfile) = tempfile(UNLINK => 0, SUFFIX => '.auth');
    print $tfh "username = $CFG{SMB_USER}\n";
    print $tfh "password = $CFG{SMB_PASS}\n";
    close $tfh;
    chmod 0600, $tfile;
    return $tfile;
}

sub transfer_file {
    # ------------------------------------------------------------------
    # Transfers a single file to the SMB share using smbclient.
    # Retries up to TRANSFER_RETRIES times on failure.
    # If VERIFY_FILE_SIZE is enabled, checks the remote file size after
    # transfer and treats a mismatch as a failure.
    #
    # Args: $local_path - absolute path to the local file
    #       $file_num   - current file number (e.g. 3)
    #       $total      - total files to transfer (e.g. 9)
    # Returns: hashref with keys:
    #   file    => relative path
    #   status  => 'OK' or 'FAILED'
    #   reason  => error description (empty on success)
    #   size    => local file size in bytes
    #   remote_size => remote file size (if verified)
    # ------------------------------------------------------------------
    my ($local_path, $file_num, $total) = @_;
    my $rel_path    = get_relative_path($local_path, $CFG{SOURCE_DIR});
    my $local_size  = -s $local_path;
    my $retries     = cfg('TRANSFER_RETRIES', 3);
    my $retry_delay = cfg('RETRY_DELAY', 10);
    my $counter     = "[$file_num/$total]";

    log_info("$counter Transferring: $rel_path (${\format_size($local_size)})");

    # Determine remote subdirectory (preserve folder structure)
    my $remote_dir  = dirname($rel_path);
    my $remote_file = basename($rel_path);

    # Build the smbclient service string
    my $smb_service = "//$CFG{SMB_SERVER_IP}/$CFG{SMB_SHARE}";

    for my $attempt (1 .. $retries) {
        log_info("$counter   Attempt $attempt of $retries...");

        # Create remote subdirectories if needed
        if ($remote_dir ne '.' && $remote_dir ne '') {
            create_remote_dirs($smb_service, $remote_dir);
        }

        # Build remote target directory path (backslash-delimited for smbclient)
        my $target_dir = ($remote_dir eq '.' || $remote_dir eq '')
            ? '\\'
            : '\\' . join('\\', split(/\//, $remote_dir));

        my $xfer_start = time();

        my $result = run_smbclient($smb_service,
            qq{cd "$target_dir"},
            qq{put "$local_path" "$remote_file"},
        );

        my $xfer_elapsed = time() - $xfer_start;

        if ($result->{exit} != 0) {
            log_error("$counter   smbclient failed (exit $result->{exit}): $result->{output}");
            sleep $retry_delay if $attempt < $retries;
            next;
        }

        # Calculate transfer speed
        my $speed_str = ($xfer_elapsed > 0)
            ? format_size($local_size / $xfer_elapsed) . "/s"
            : "instant";

        log_info("$counter   Upload completed in ${\format_duration($xfer_elapsed)} ($speed_str)");

        # Check for long transfer and send HA alert
        my $alert_minutes = cfg('LONG_TRANSFER_ALERT_MINUTES', 60);
        if ($alert_minutes > 0 && $xfer_elapsed > ($alert_minutes * 60)) {
            log_warn(sprintf("$counter   Transfer took %s (threshold: %dm)",
                format_duration($xfer_elapsed), $alert_minutes));
            send_ha_long_transfer_alert($rel_path, $local_size, $xfer_elapsed, $speed_str);
        }

        # Size verification
        if (cfg('VERIFY_FILE_SIZE', 1)) {
            my $remote_size = get_remote_file_size($smb_service, $target_dir, $remote_file);
            if (!defined $remote_size) {
                log_error("$counter   Size verification failed: could not read remote size.");
                sleep $retry_delay if $attempt < $retries;
                next;
            }

            my $tolerance = cfg('SIZE_TOLERANCE', 0);
            if (abs($remote_size - $local_size) > $tolerance) {
                log_error(sprintf("$counter   Size mismatch! Local: %d, Remote: %d",
                    $local_size, $remote_size));
                sleep $retry_delay if $attempt < $retries;
                next;
            }

            log_info(sprintf("$counter   Size verified: %s (local) == %s (remote)",
                format_size($local_size), format_size($remote_size)));
            return {
                file => $rel_path, status => 'OK', reason => '',
                size => $local_size, remote_size => $remote_size, success => 1,
            };
        }

        # No verification requested; assume success
        return {
            file => $rel_path, status => 'OK', reason => '',
            size => $local_size, remote_size => 'N/A', success => 1,
        };
    }

    # All retries exhausted
    my $msg = "Failed after $retries attempts";
    log_error("$counter   $rel_path: $msg");
    return {
        file => $rel_path, status => 'FAILED', reason => $msg,
        size => $local_size, remote_size => 'N/A', success => 0,
    };
}

sub create_remote_dirs {
    # ------------------------------------------------------------------
    # Recursively creates directories on the SMB share so that the
    # folder structure from SOURCE_DIR is preserved on the destination.
    # Uses smbclient 'mkdir' for each path component.
    # Args: $service    - smbclient service string (//host/share)
    #       $remote_dir - relative directory path to create
    # ------------------------------------------------------------------
    my ($service, $remote_dir) = @_;
    my @parts = split(/\//, $remote_dir);
    my $cumulative = '';

    for my $part (@parts) {
        $cumulative .= "\\$part";
        run_smbclient($service, qq{mkdir "$cumulative"});
    }
}

sub get_remote_file_size {
    # ------------------------------------------------------------------
    # Queries the remote SMB share for the size of a specific file
    # using smbclient's 'ls' command and parsing the output.
    # Args: $service     - smbclient service string
    #       $remote_dir  - remote directory (backslash-delimited)
    #       $remote_file - filename to check
    # Returns: file size in bytes, or undef on failure
    # ------------------------------------------------------------------
    my ($service, $remote_dir, $remote_file) = @_;

    my $result = run_smbclient($service,
        qq{cd "$remote_dir"},
        qq{ls "$remote_file"},
    );

    # smbclient ls output format:
    #   filename           A     123456  Thu Jan  1 00:00:00 2025
    # We look for a line containing the filename and extract the size.
    for my $line (split /\n/, $result->{output}) {
        # Match lines with a size (sequence of digits) after attributes
        if ($line =~ /\s+[A-Z]*\s+(\d+)\s+\w{3}\s+\w{3}/) {
            return int($1);
        }
    }

    log_warn("Could not parse remote file size from smbclient output.");
    return undef;
}

# ============================================================================
# Home Assistant Notification
# ============================================================================

sub send_ha_long_transfer_alert {
    # ------------------------------------------------------------------
    # Sends an alert to Home Assistant when a single file transfer
    # exceeds LONG_TRANSFER_ALERT_MINUTES. Fires immediately so you
    # know something is slow without waiting for the full run to finish.
    #
    # Args: $file      - relative file path
    #       $size      - file size in bytes
    #       $elapsed   - transfer time in seconds
    #       $speed_str - formatted speed string
    # ------------------------------------------------------------------
    my ($file, $size, $elapsed, $speed_str) = @_;

    return unless cfg('HA_NOTIFY_ENABLED', 0);

    my $ha_url = $CFG{HA_URL} // return;
    my $token  = $CFG{HA_TOKEN} // return;
    my $name   = basename($file);

    my $msg = sprintf(
        "linux2windt v%s SLOW TRANSFER\n" .
        "File: %s (%s)\n" .
        "Duration: %s (%s)\n" .
        "Threshold: %d minutes\n",
        $VERSION, $name, format_size($size),
        format_duration($elapsed), $speed_str,
        cfg('LONG_TRANSFER_ALERT_MINUTES', 60)
    );

    my $service = cfg('HA_NOTIFY_SERVICE', 'notify.notify');
    (my $service_path = $service) =~ s/\./\//;
    ha_api_call("$ha_url/api/services/$service_path", $token, {
        title   => "linux2windt: SLOW TRANSFER - $name",
        message => $msg,
    });

    log_info("Home Assistant slow transfer alert sent.");
}

sub send_ha_abort {
    # ------------------------------------------------------------------
    # Sends an abort notification to Home Assistant when the error
    # threshold (MAX_ERRORS_BEFORE_ABORT) is reached during a run.
    # This is a distinct notification from the normal completion report
    # so it's immediately clear something went wrong.
    #
    # Args: $errors    - number of errors that triggered the abort
    #       $max       - the configured error threshold
    #       $ok        - files successfully transferred before abort
    #       $remaining - files not attempted due to abort
    #       $results   - arrayref of per-file result hashrefs
    # ------------------------------------------------------------------
    my ($errors, $max, $ok, $remaining, $results) = @_;

    return unless cfg('HA_NOTIFY_ENABLED', 0);

    my $ha_url = $CFG{HA_URL} // return;
    my $token  = $CFG{HA_TOKEN} // return;

    my $elapsed = time() - $start_time;

    my $msg = sprintf(
        "linux2windt v%s ABORTED\n" .
        "Hit %d errors (threshold: %d). Run stopped.\n" .
        "Transferred: %d OK, %d FAILED, %d SKIPPED\n" .
        "Duration: %s\n\n",
        $VERSION, $errors, $max, $ok, $errors, $remaining,
        format_duration($elapsed)
    );

    # Add per-file details
    my $max_detail = 20;
    my $shown = 0;
    for my $r (@$results) {
        last if $shown >= $max_detail;
        my $name = basename($r->{file});
        my $size_str = defined $r->{size} ? format_size($r->{size}) : '?';
        if ($r->{status} eq 'OK') {
            $msg .= sprintf("  OK: %s (%s)\n", $name, $size_str);
        } elsif ($r->{status} eq 'GIVEN UP') {
            $msg .= sprintf("  GIVEN UP: %s - %s\n", $name, $r->{reason});
        } elsif ($r->{status} eq 'FAILED') {
            $msg .= sprintf("  FAIL: %s - %s\n", $name, $r->{reason});
        }
        $shown++;
    }
    if (@$results > $max_detail) {
        $msg .= sprintf("  ... and %d more\n", scalar(@$results) - $max_detail);
    }

    # Send mobile push notification
    my $service = cfg('HA_NOTIFY_SERVICE', 'notify.notify');
    (my $service_path = $service) =~ s/\./\//;
    ha_api_call("$ha_url/api/services/$service_path", $token, {
        title   => "linux2windt: ABORTED",
        message => $msg,
    });

    # Send persistent notification
    if (cfg('HA_PERSISTENT_NOTIFY', 1)) {
        my $notif_id = "linux2windt_abort_" . strftime("%Y%m%d_%H%M%S", localtime($start_time));
        ha_api_call("$ha_url/api/services/persistent_notification/create", $token, {
            title          => "linux2windt: ABORTED",
            message        => $msg,
            notification_id => $notif_id,
        });
    }

    log_info("Home Assistant abort notification sent.");
}

sub send_ha_report {
    # ------------------------------------------------------------------
    # Sends a completion report to Home Assistant via the REST API.
    # Creates both a mobile push notification and a persistent
    # notification (if enabled in config).
    #
    # Args: $total       - total files found
    #       $ok          - successfully transferred count
    #       $failed      - failed transfer count
    #       $total_bytes - total bytes successfully transferred
    #       $results     - arrayref of per-file result hashrefs
    # ------------------------------------------------------------------
    my ($total, $ok, $failed, $total_bytes, $results) = @_;

    return unless cfg('HA_NOTIFY_ENABLED', 0);

    my $ha_url = $CFG{HA_URL} // return;
    my $token  = $CFG{HA_TOKEN} // return;

    my $elapsed = time() - $start_time;
    my $status  = ($failed > 0) ? "COMPLETED WITH ERRORS" : "SUCCESS";
    my $speed_str = ($elapsed > 0 && $total_bytes > 0)
        ? format_size($total_bytes / $elapsed) . "/s"
        : "N/A";

    # Build the message body
    my $msg = sprintf(
        "linux2windt v%s %s\n" .
        "Files: %d found, %d transferred, %d failed\n" .
        "Total transferred: %s in %s (%s)\n",
        $VERSION, $status, $total, $ok, $failed,
        format_size($total_bytes), format_duration($elapsed), $speed_str
    );

    # Add per-file details (truncated if too many)
    my $max_detail = 20;
    my $shown = 0;
    for my $r (@$results) {
        last if $shown >= $max_detail;
        my $name = basename($r->{file});
        my $size_str = defined $r->{size} ? format_size($r->{size}) : '?';
        if ($r->{status} eq 'OK') {
            $msg .= sprintf("  OK: %s (%s)\n", $name, $size_str);
        } elsif ($r->{status} eq 'GIVEN UP') {
            $msg .= sprintf("  GIVEN UP: %s - %s (max retries exceeded)\n", $name, $r->{reason});
        } elsif ($r->{status} eq 'FAILED') {
            $msg .= sprintf("  FAIL: %s - %s\n", $name, $r->{reason});
        } else {
            $msg .= sprintf("  %s: %s\n", $r->{status}, $name);
        }
        $shown++;
    }
    if (@$results > $max_detail) {
        $msg .= sprintf("  ... and %d more files\n", scalar(@$results) - $max_detail);
    }

    # Build notification title with file info
    my $title;
    my @ok_files = grep { $_->{status} eq 'OK' } @$results;
    if (@ok_files == 1) {
        $title = "linux2windt: $status - " . basename($ok_files[0]{file});
    } elsif (@ok_files > 1) {
        $title = sprintf("linux2windt: $status - %d files", scalar @ok_files);
    } else {
        $title = "linux2windt: $status";
    }

    # Send mobile push notification
    my $service = cfg('HA_NOTIFY_SERVICE', 'notify.notify');
    # HA REST API uses slashes (notify/mobile_app_xxx), config uses dots
    (my $service_path = $service) =~ s/\./\//;
    ha_api_call("$ha_url/api/services/$service_path", $token, {
        title   => $title,
        message => $msg,
    });

    # Send persistent notification
    if (cfg('HA_PERSISTENT_NOTIFY', 1)) {
        my $notif_id = "linux2windt_" . strftime("%Y%m%d_%H%M%S", localtime($start_time));
        ha_api_call("$ha_url/api/services/persistent_notification/create", $token, {
            title      => $title,
            message    => $msg,
            notification_id => $notif_id,
        });
    }

    log_info("Home Assistant notification sent.");
}

sub ha_api_call {
    # ------------------------------------------------------------------
    # Makes an HTTP POST request to the Home Assistant REST API using curl.
    # Args: $url     - full API endpoint URL
    #       $token   - long-lived access token
    #       $payload - hashref to be JSON-encoded as the request body
    # ------------------------------------------------------------------
    my ($url, $token, $payload) = @_;

    my $json = encode_json($payload);
    # Escape single quotes in JSON for shell safety
    $json =~ s/'/'\\''/g;

    my $cmd = sprintf(
        "curl -s -o /dev/null -w '%%{http_code}' -X POST " .
        "-H 'Authorization: Bearer %s' " .
        "-H 'Content-Type: application/json' " .
        "-d '%s' '%s' 2>&1",
        $token, $json, $url
    );

    my $http_code = `$cmd`;
    chomp $http_code;

    if ($http_code !~ /^2\d\d$/) {
        log_warn("HA API call to $url returned HTTP $http_code");
    }
}

# ============================================================================
# Utility Functions
# ============================================================================

sub format_size {
    # ------------------------------------------------------------------
    # Converts a byte count into a human-readable string with an
    # appropriate unit (B, KB, MB, GB).
    # Args: $bytes - number of bytes
    # Returns: formatted string (e.g. "1.23 GB")
    # ------------------------------------------------------------------
    my ($bytes) = @_;
    return '0 B' unless defined $bytes && $bytes >= 0;

    if ($bytes >= 1073741824) {
        return sprintf("%.2f GB", $bytes / 1073741824);
    } elsif ($bytes >= 1048576) {
        return sprintf("%.2f MB", $bytes / 1048576);
    } elsif ($bytes >= 1024) {
        return sprintf("%.2f KB", $bytes / 1024);
    } else {
        return "$bytes B";
    }
}

sub format_duration {
    # ------------------------------------------------------------------
    # Converts a number of seconds into a human-readable "Xm Ys" string.
    # Args: $secs - total seconds
    # Returns: formatted string (e.g. "3m 42s")
    # ------------------------------------------------------------------
    my ($secs) = @_;
    if ($secs >= 3600) {
        return sprintf("%dh %dm %ds", int($secs / 3600), int(($secs % 3600) / 60), $secs % 60);
    } elsif ($secs >= 60) {
        return sprintf("%dm %ds", int($secs / 60), $secs % 60);
    } else {
        return "${secs}s";
    }
}

# ============================================================================
# Run
# ============================================================================
exit main();
