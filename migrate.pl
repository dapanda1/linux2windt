#!/usr/bin/perl
# ============================================================================
# linux2windt - Config Migration
# ============================================================================
# Migrates linux2windt.conf between schema versions when the project is
# updated via git pull. Follows the same pattern as HA add-on migrate.py:
#   - Schema version tracked in .schema_version next to the config file
#   - Migrations defined as an ordered list of version-keyed changes
#   - Each migration can rename, add (with default + comment), or drop keys
#   - Config file is rewritten in place, preserving comments and structure
#
# Called automatically by linux2windt.pl before the main run.
# Can also be run standalone:
#   perl migrate.pl                        # uses ./linux2windt.conf
#   perl migrate.pl /path/to/config.conf   # explicit config path
#   perl migrate.pl --dry-run              # preview changes without writing
# ============================================================================

use strict;
use warnings;
use File::Basename;

# ============================================================================
# Current schema version — bump this when adding a new migration
# ============================================================================
my $CURRENT_SCHEMA_VERSION = 1;

# ============================================================================
# Migration definitions
# ============================================================================
# Each migration is a hashref with:
#   version  => the version this migration brings the config TO
#   desc     => human-readable description of what changed
#   rename   => { OLD_KEY => NEW_KEY, ... }
#   add      => [ { key => KEY, default => VALUE, after => EXISTING_KEY,
#                    comment => "# comment line(s) to insert above" }, ... ]
#   drop     => [ KEY, ... ]
#
# Migrations are applied in order. Only migrations with version > current
# schema version are applied.
# ============================================================================

my @MIGRATIONS = (

    # ----------------------------------------------------------------
    # Version 1: Initial schema. No changes needed — this just marks
    # configs that have been through the migration system.
    # ----------------------------------------------------------------
    {
        version => 1,
        desc    => 'Initial schema version (baseline)',
        rename  => {},
        add     => [],
        drop    => [],
    },

    # ----------------------------------------------------------------
    # TEMPLATE — copy this block to add a new migration:
    # ----------------------------------------------------------------
    # {
    #     version => 2,
    #     desc    => 'Added SOME_NEW_FEATURE setting',
    #     rename  => { OLD_NAME => 'NEW_NAME' },
    #     add     => [
    #         {
    #             key     => 'SOME_NEW_KEY',
    #             default => 'some_default_value',
    #             after   => 'EXISTING_KEY_TO_INSERT_AFTER',
    #             comment => "# Description of what this key does.\n# Can be multiple lines.",
    #         },
    #     ],
    #     drop => ['REMOVED_KEY'],
    # },

);

# ============================================================================
# Main
# ============================================================================

sub run_migrate {
    # ------------------------------------------------------------------
    # Entry point for the migration process. Determines the config file
    # path, reads the current schema version, and applies any pending
    # migrations in order.
    #
    # Args: $config_path - path to the .conf file (optional, defaults to
    #                      linux2windt.conf in the same dir as this script)
    #       $dry_run     - if true, prints what would change without writing
    #
    # Returns: 1 if migrations were applied, 0 if already up to date
    # ------------------------------------------------------------------
    my ($config_path, $dry_run) = @_;

    # Default config path: same directory as this script
    if (!$config_path) {
        my $script_dir = dirname(__FILE__);
        $config_path = "$script_dir/linux2windt.conf";
    }

    unless (-f $config_path) {
        warn "[migrate] Config file not found: $config_path — skipping migration.\n";
        return 0;
    }

    my $schema_file    = _schema_version_path($config_path);
    my $current_version = _read_schema_version($schema_file);

    if ($current_version >= $CURRENT_SCHEMA_VERSION) {
        print "[migrate] Config is up to date (schema v$current_version).\n";
        return 0;
    }

    print "[migrate] Config at schema v$current_version, target v$CURRENT_SCHEMA_VERSION.\n";

    # Read the full config file as lines (preserving comments/structure)
    my @lines = _read_file_lines($config_path);

    # Apply each pending migration in order
    my $applied = 0;
    for my $migration (@MIGRATIONS) {
        next if $migration->{version} <= $current_version;

        print "[migrate] Applying v$migration->{version}: $migration->{desc}\n";

        if ($dry_run) {
            _preview_migration($migration, \@lines);
        } else {
            @lines = _apply_migration($migration, \@lines);
        }
        $applied++;
    }

    unless ($dry_run) {
        _write_file_lines($config_path, \@lines);
        _write_schema_version($schema_file, $CURRENT_SCHEMA_VERSION);
        print "[migrate] Config migrated to schema v$CURRENT_SCHEMA_VERSION.\n";
    }

    return $applied;
}

# ============================================================================
# Migration engine
# ============================================================================

sub _apply_migration {
    # ------------------------------------------------------------------
    # Applies a single migration to the config file lines.
    # Processes renames first, then drops, then adds — this ordering
    # ensures that renamed keys exist before adds reference them via
    # "after", and dropped keys don't interfere with insertion.
    #
    # Args: $migration - migration hashref
    #       $lines_ref - arrayref of config file lines
    # Returns: new list of lines after migration
    # ------------------------------------------------------------------
    my ($migration, $lines_ref) = @_;
    my @lines = @$lines_ref;

    # 1. Renames
    if ($migration->{rename} && %{$migration->{rename}}) {
        for my $old_key (keys %{$migration->{rename}}) {
            my $new_key = $migration->{rename}{$old_key};
            @lines = _rename_key(\@lines, $old_key, $new_key);
        }
    }

    # 2. Drops
    if ($migration->{drop} && @{$migration->{drop}}) {
        for my $key (@{$migration->{drop}}) {
            @lines = _drop_key(\@lines, $key);
        }
    }

    # 3. Adds
    if ($migration->{add} && @{$migration->{add}}) {
        for my $addition (@{$migration->{add}}) {
            @lines = _add_key(\@lines, $addition);
        }
    }

    return @lines;
}

sub _rename_key {
    # ------------------------------------------------------------------
    # Renames a config key in-place, preserving its value and position.
    # Args: $lines_ref - arrayref of config lines
    #       $old_key   - key name to find
    #       $new_key   - key name to replace it with
    # Returns: new list of lines
    # ------------------------------------------------------------------
    my ($lines_ref, $old_key, $new_key) = @_;
    my @out;
    for my $line (@$lines_ref) {
        if ($line =~ /^\Q$old_key\E=(.*)$/) {
            print "[migrate]   Rename: $old_key -> $new_key\n";
            push @out, "$new_key=$1";
        } else {
            push @out, $line;
        }
    }
    return @out;
}

sub _drop_key {
    # ------------------------------------------------------------------
    # Removes a config key and its immediately preceding comment block
    # (contiguous lines starting with '#' directly above the key line).
    # Args: $lines_ref - arrayref of config lines
    #       $key       - key name to remove
    # Returns: new list of lines
    # ------------------------------------------------------------------
    my ($lines_ref, $key) = @_;
    my @out;
    my $found_at = -1;

    # First pass: find the key line index
    for my $i (0 .. $#$lines_ref) {
        if ($lines_ref->[$i] =~ /^\Q$key\E=/) {
            $found_at = $i;
            last;
        }
    }

    if ($found_at < 0) {
        return @$lines_ref;    # key not found, nothing to drop
    }

    # Walk backwards from the key to find contiguous comment lines
    my $comment_start = $found_at;
    while ($comment_start > 0 && $lines_ref->[$comment_start - 1] =~ /^#/) {
        $comment_start--;
    }

    print "[migrate]   Drop: $key (lines $comment_start-$found_at)\n";

    # Build output, skipping the comment block + key line
    for my $i (0 .. $#$lines_ref) {
        next if $i >= $comment_start && $i <= $found_at;
        push @out, $lines_ref->[$i];
    }

    return @out;
}

sub _add_key {
    # ------------------------------------------------------------------
    # Inserts a new config key (with optional comment) after a specified
    # existing key. If the key already exists in the config, it is
    # skipped (no duplicate). If the "after" key is not found, the new
    # key is appended to the end of the file.
    #
    # Args: $lines_ref - arrayref of config lines
    #       $addition  - hashref with: key, default, after, comment
    # Returns: new list of lines
    # ------------------------------------------------------------------
    my ($lines_ref, $addition) = @_;
    my $key     = $addition->{key};
    my $default = $addition->{default} // '';
    my $after   = $addition->{after}   // '';
    my $comment = $addition->{comment} // '';

    # Check if key already exists — skip if so
    for my $line (@$lines_ref) {
        if ($line =~ /^\Q$key\E=/) {
            print "[migrate]   Add: $key — already exists, skipping.\n";
            return @$lines_ref;
        }
    }

    # Build the new lines to insert
    my @new_lines;
    push @new_lines, '' ;    # blank separator line
    if ($comment) {
        push @new_lines, split(/\n/, $comment);
    }
    push @new_lines, "$key=$default";

    # Find insertion point (after the specified key)
    if ($after) {
        my @out;
        my $inserted = 0;
        for my $line (@$lines_ref) {
            push @out, $line;
            if (!$inserted && $line =~ /^\Q$after\E=/) {
                push @out, @new_lines;
                $inserted = 1;
                print "[migrate]   Add: $key=$default (after $after)\n";
            }
        }
        if (!$inserted) {
            push @out, @new_lines;
            print "[migrate]   Add: $key=$default (appended — '$after' not found)\n";
        }
        return @out;
    }

    # No "after" specified — append to end
    print "[migrate]   Add: $key=$default (appended)\n";
    return (@$lines_ref, @new_lines);
}

sub _preview_migration {
    # ------------------------------------------------------------------
    # Prints a dry-run preview of what a migration would do, without
    # modifying any files.
    # Args: $migration - migration hashref
    #       $lines_ref - arrayref of config lines (for key-exists checks)
    # ------------------------------------------------------------------
    my ($migration, $lines_ref) = @_;

    if ($migration->{rename} && %{$migration->{rename}}) {
        for my $old (keys %{$migration->{rename}}) {
            print "[dry-run]   Would rename: $old -> $migration->{rename}{$old}\n";
        }
    }
    if ($migration->{drop} && @{$migration->{drop}}) {
        for my $key (@{$migration->{drop}}) {
            print "[dry-run]   Would drop: $key\n";
        }
    }
    if ($migration->{add} && @{$migration->{add}}) {
        for my $a (@{$migration->{add}}) {
            print "[dry-run]   Would add: $a->{key}=$a->{default}\n";
        }
    }
}

# ============================================================================
# Schema version file
# ============================================================================

sub _schema_version_path {
    # ------------------------------------------------------------------
    # Returns the path to the .schema_version file, stored alongside
    # the config file.
    # Args: $config_path - path to the .conf file
    # Returns: path string
    # ------------------------------------------------------------------
    my ($config_path) = @_;
    my $dir = dirname($config_path);
    return "$dir/.schema_version";
}

sub _read_schema_version {
    # ------------------------------------------------------------------
    # Reads the current schema version from the .schema_version file.
    # Returns 0 if the file doesn't exist (first run / pre-migration).
    # Args: $path - path to .schema_version
    # Returns: integer version number
    # ------------------------------------------------------------------
    my ($path) = @_;
    return 0 unless -f $path;
    open my $fh, '<', $path or return 0;
    my $version = <$fh>;
    close $fh;
    chomp $version if defined $version;
    return int($version // 0);
}

sub _write_schema_version {
    # ------------------------------------------------------------------
    # Writes the schema version number to the .schema_version file.
    # Args: $path    - path to .schema_version
    #       $version - integer version to write
    # ------------------------------------------------------------------
    my ($path, $version) = @_;
    open my $fh, '>', $path or do {
        warn "[migrate] Cannot write schema version to $path: $!\n";
        return;
    };
    print $fh "$version\n";
    close $fh;
}

# ============================================================================
# File I/O helpers
# ============================================================================

sub _read_file_lines {
    # ------------------------------------------------------------------
    # Reads a file into an array of chomped lines.
    # Args: $path - file path
    # Returns: list of line strings
    # ------------------------------------------------------------------
    my ($path) = @_;
    open my $fh, '<', $path or die "Cannot read $path: $!\n";
    my @lines = <$fh>;
    close $fh;
    chomp @lines;
    return @lines;
}

sub _write_file_lines {
    # ------------------------------------------------------------------
    # Writes an array of lines back to a file, each terminated with a
    # newline. Creates a .bak backup before overwriting.
    # Args: $path  - file path
    #       $lines - arrayref of line strings
    # ------------------------------------------------------------------
    my ($path, $lines) = @_;

    # Backup before overwriting
    if (-f $path) {
        require File::Copy;
        File::Copy::copy($path, "${path}.bak")
            or warn "[migrate] Could not create backup ${path}.bak: $!\n";
    }

    open my $fh, '>', $path or die "Cannot write $path: $!\n";
    for my $line (@$lines) {
        print $fh "$line\n";
    }
    close $fh;
}

# ============================================================================
# Standalone execution
# ============================================================================
# When run directly (not loaded via require), parse args and run.
# ============================================================================

unless (caller) {
    my $dry_run = 0;
    my $config_path;

    for my $arg (@ARGV) {
        if ($arg eq '--dry-run') {
            $dry_run = 1;
        } else {
            $config_path = $arg;
        }
    }

    my $applied = run_migrate($config_path, $dry_run);
    exit($applied > 0 ? 0 : 0);
}

1;    # Return true when loaded via require
