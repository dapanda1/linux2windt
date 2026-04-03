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
#   perl linux2windt.pl --dry-run          # preview without transferring
#   perl linux2windt.pl --version          # print version and exit
# ============================================================================

use strict;
use warnings;
use File::Basename;
use File::Find;
use File::Path qw(make_path);
use File::Copy;
use POSIX qw(strftime);
use Getopt::Long;
use JSON::PP;

# ============================================================================
# Version
# ============================================================================
my $VERSION = '1.2.1';

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
    GetOptions(
        'config=s' => \$config_file,
        'dry-run'  => \$dry_run,
        'version'  => \$show_version,
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

    log_info("=== linux2windt v$VERSION started ===");
    log_info("Dry-run mode: ON") if $dry_run;

    # Step 1: Find new files
    my @new_files = scan_for_new_files();
    if (!@new_files) {
        log_info("No new files found. Nothing to do.");
        send_ha_report(0, 0, 0, []);
        log_info("=== Run complete (no work) ===");
        return 0;
    }
    log_info(sprintf("Found %d new file(s) to transfer.", scalar @new_files));

    # Step 2: Wake the server
    if (!$dry_run) {
        my $server_ready = wake_and_wait();
        if (!$server_ready) {
            my $msg = "Server did not come online after WoL. Aborting.";
            log_error($msg);
            send_ha_report(scalar @new_files, 0, scalar @new_files,
                [ { file => "ALL", status => "FAILED", reason => $msg } ]);
            return 1;
        }
    }

    # Step 3: Transfer each file
    my ($ok_count, $fail_count) = (0, 0);
    for my $file (@new_files) {
        if ($dry_run) {
            log_info("[DRY-RUN] Would transfer: $file");
            push @transfer_results, { file => $file, status => 'DRY-RUN', reason => '' };
            $ok_count++;
            next;
        }

        my $result = transfer_file($file);
        if ($result->{success}) {
            mark_processed($file);
            $ok_count++;
        } else {
            $fail_count++;
        }
        push @transfer_results, $result;
    }

    # Step 4: Report
    send_ha_report(scalar @new_files, $ok_count, $fail_count, \@transfer_results);
    log_info(sprintf("=== Run complete: %d OK, %d FAILED out of %d ===",
        $ok_count, $fail_count, scalar @new_files));

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
    # Args: $filename - log file name (not full path)
    #       $level    - severity string (INFO, ERROR, WARN)
    #       $message  - the log message text
    # ------------------------------------------------------------------
    my ($filename, $level, $message) = @_;
    my $path = "$CFG{LOG_DIR}/$filename";

    rotate_log($path) if -f $path && -s $path > cfg('LOG_MAX_SIZE', 5242880);

    my $timestamp = strftime("%Y-%m-%d %H:%M:%S", localtime);
    open my $fh, '>>', $path or warn "Cannot write to $path: $!\n" and return;
    print $fh "[$timestamp] [$level] $message\n";
    close $fh;

    # Also print to STDOUT for interactive/manual runs
    print "[$timestamp] [$level] $message\n";
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
    # Args: $msg - error message text
    # ------------------------------------------------------------------
    my ($msg) = @_;
    _write_log($CFG{TRANSFER_LOG}, 'ERROR', $msg);
    _write_log($CFG{ERROR_LOG},    'ERROR', $msg);
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

sub transfer_file {
    # ------------------------------------------------------------------
    # Transfers a single file to the SMB share using smbclient.
    # Retries up to TRANSFER_RETRIES times on failure.
    # If VERIFY_FILE_SIZE is enabled, checks the remote file size after
    # transfer and treats a mismatch as a failure.
    #
    # Args: $local_path - absolute path to the local file
    # Returns: hashref with keys:
    #   file    => relative path
    #   status  => 'OK' or 'FAILED'
    #   reason  => error description (empty on success)
    #   size    => local file size in bytes
    #   remote_size => remote file size (if verified)
    # ------------------------------------------------------------------
    my ($local_path) = @_;
    my $rel_path    = get_relative_path($local_path, $CFG{SOURCE_DIR});
    my $local_size  = -s $local_path;
    my $retries     = cfg('TRANSFER_RETRIES', 3);
    my $retry_delay = cfg('RETRY_DELAY', 10);

    log_info("Transferring: $rel_path (${\format_size($local_size)})");

    # Determine remote subdirectory (preserve folder structure)
    my $remote_dir  = dirname($rel_path);
    my $remote_file = basename($rel_path);

    # Build the smbclient service string
    my $smb_service = "//$CFG{SMB_SERVER_IP}/$CFG{SMB_SHARE}";

    for my $attempt (1 .. $retries) {
        log_info("  Attempt $attempt of $retries...");

        # Create remote subdirectories if needed
        if ($remote_dir ne '.' && $remote_dir ne '') {
            create_remote_dirs($smb_service, $remote_dir);
        }

        # Build smbclient put command
        my $target_dir = ($remote_dir eq '.' || $remote_dir eq '') ? '\\' : '\\' . join('\\', split(/\//, $remote_dir)) . '\\';
        my $smb_cmd = sprintf(
            'smbclient "%s" -U "%s%%%s" -c "cd %s; put \\"%s\\"" 2>&1',
            $smb_service, $CFG{SMB_USER}, $CFG{SMB_PASS},
            $target_dir, $local_path
        );

        my $output = `$smb_cmd`;
        my $exit   = $? >> 8;

        if ($exit != 0) {
            log_error("  smbclient failed (exit $exit): $output");
            sleep $retry_delay if $attempt < $retries;
            next;
        }

        log_info("  Upload completed.");

        # Size verification
        if (cfg('VERIFY_FILE_SIZE', 1)) {
            my $remote_size = get_remote_file_size($smb_service, $target_dir, $remote_file);
            if (!defined $remote_size) {
                log_error("  Size verification failed: could not read remote size.");
                sleep $retry_delay if $attempt < $retries;
                next;
            }

            my $tolerance = cfg('SIZE_TOLERANCE', 0);
            if (abs($remote_size - $local_size) > $tolerance) {
                log_error(sprintf("  Size mismatch! Local: %d, Remote: %d",
                    $local_size, $remote_size));
                sleep $retry_delay if $attempt < $retries;
                next;
            }

            log_info(sprintf("  Size verified: %s (local) == %s (remote)",
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
    log_error("  $rel_path: $msg");
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
        my $cmd = sprintf(
            'smbclient "%s" -U "%s%%%s" -c "mkdir %s" 2>&1',
            $service, $CFG{SMB_USER}, $CFG{SMB_PASS}, $cumulative
        );
        `$cmd`;    # ignore errors (dir may already exist)
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

    my $cmd = sprintf(
        'smbclient "%s" -U "%s%%%s" -c "cd %s; ls \\"%s\\"" 2>&1',
        $service, $CFG{SMB_USER}, $CFG{SMB_PASS},
        $remote_dir, $remote_file
    );

    my $output = `$cmd`;

    # smbclient ls output format:
    #   filename           A     123456  Thu Jan  1 00:00:00 2025
    # We look for a line containing the filename and extract the size.
    for my $line (split /\n/, $output) {
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

sub send_ha_report {
    # ------------------------------------------------------------------
    # Sends a completion report to Home Assistant via the REST API.
    # Creates both a mobile push notification and a persistent
    # notification (if enabled in config).
    #
    # Args: $total   - total files found
    #       $ok      - successfully transferred count
    #       $failed  - failed transfer count
    #       $results - arrayref of per-file result hashrefs
    # ------------------------------------------------------------------
    my ($total, $ok, $failed, $results) = @_;

    return unless cfg('HA_NOTIFY_ENABLED', 0);

    my $ha_url = $CFG{HA_URL} // return;
    my $token  = $CFG{HA_TOKEN} // return;

    my $elapsed = time() - $start_time;
    my $status  = ($failed > 0) ? "COMPLETED WITH ERRORS" : "SUCCESS";

    # Build the message body
    my $msg = sprintf(
        "linux2windt v%s %s\n" .
        "Files: %d found, %d transferred, %d failed\n" .
        "Duration: %s\n",
        $VERSION, $status, $total, $ok, $failed, format_duration($elapsed)
    );

    # Add per-file details (truncated if too many)
    my $max_detail = 20;
    my $shown = 0;
    for my $r (@$results) {
        last if $shown >= $max_detail;
        my $size_str = defined $r->{size} ? format_size($r->{size}) : '?';
        if ($r->{status} eq 'OK') {
            $msg .= sprintf("  OK: %s (%s)\n", $r->{file}, $size_str);
        } elsif ($r->{status} eq 'FAILED') {
            $msg .= sprintf("  FAIL: %s - %s\n", $r->{file}, $r->{reason});
        } else {
            $msg .= sprintf("  %s: %s\n", $r->{status}, $r->{file});
        }
        $shown++;
    }
    if (@$results > $max_detail) {
        $msg .= sprintf("  ... and %d more files\n", scalar(@$results) - $max_detail);
    }

    # Send mobile push notification
    my $service = cfg('HA_NOTIFY_SERVICE', 'notify.notify');
    ha_api_call("$ha_url/api/services/$service", $token, {
        title   => "linux2windt: $status",
        message => $msg,
    });

    # Send persistent notification
    if (cfg('HA_PERSISTENT_NOTIFY', 1)) {
        my $notif_id = "linux2windt_" . strftime("%Y%m%d_%H%M%S", localtime($start_time));
        ha_api_call("$ha_url/api/services/persistent_notification/create", $token, {
            title      => "linux2windt: $status",
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
