#!/usr/bin/perl -w
#
# Postgresql tuning script.
# Copy on to a server with postgresql on it and run it:
# ./postgresql_tuner.pl
#
# Requires access to postgresql as the postgres user (runs `psql -U postgres` commands)
# and generates a new config (does not touch the original config at all).
#
# $Id: postgresql_tuner.pl 5715 2011-02-01 22:36:15Z dschoen $

use strict;
use Data::Dumper;
use File::Compare;
use POSIX qw(ceil floor);

# set to non-zero to get status messages.
my $verbose = 0;

my $reconfigure = 0;
if (defined($ARGV[0])) {
	$reconfigure = 1;
}

# percentage amount to allow before throwing a warning
# (if you run with 'reconfigure') useful for running from cron
# if the setting calculating being checked is < the new calculated size
# this setting is ignored.
#
# fsm* settings in particular being low can cause issues for maintenance
# they need to be right for autovac/vacuum to work properly.
my $reconfigure_leeway = 5;

my $os;
if (-f '/etc/debian_version') {
	$os = 'debian';
}

if (-f '/etc/redhat-release') {
	$os = 'rhel';
}

die "Unknown o/s\n" unless $os;

my ($pg_major_version, $pg_minor_version, $pgdir, $pgconfig, $found, $psql);
if ($os =~ 'debian') {
	foreach (9,8) {
		my $major_version = $_;
		foreach (4,3,2,1,0) {
			$pgdir = "/usr/lib/postgresql/".$major_version.".". $_;
			$pgconfig = "/etc/postgresql/".$major_version."." . $_;
			if (-d $pgdir) {
				$pg_major_version = $major_version;
				$pg_minor_version = $_;
				$found = 1;
				last;
			}
		}
		if ($found) {
			last;
		}
	}
	if ($found) {
		$pgconfig = "/etc/postgresql/" . $pg_major_version . "." . $pg_minor_version . "/main/postgresql.conf";
		$psql = $pgdir . '/bin/psql';
	}
}

if ($os =~ 'rhel') {
	my $postmaster = '/usr/bin/postmaster';
	$psql = '/usr/bin/psql';
	die "Unable to find postmaster at $postmaster\n" unless (-f $postmaster);
	my $output = `$postmaster -V`;
	my ($n1, $n2, $full_version) = split(/\s+/, $output);
	($pg_major_version, $pg_minor_version) = split(/\./, $full_version);

	$pgconfig = "/var/lib/pgsql/data/postgresql.conf";
	die "Unable to find postgresql.conf at $pgconfig\n" unless (-f $pgconfig);

	$found = 1;
}
die "Unable to find postgres version\n" unless $found;

# print a message if verbose is enabled
sub print_verbose {
	if (!$verbose) {
		return;
	}
	my $msg = join("", @_);
	print $msg;
}

# Trim whitespace off the beginning of a string
# and from the end.
sub trim {
	my $string = shift;
	$string =~ s/^\s+//;
	$string =~ s/\s+$//;
	return $string;
}

# turns a string like '2.5mb' into bytes
sub fetch_size {
	my $size = shift;
	if ($size =~ /kb/i || $size =~ /k/i) {
		$size =~ s/kb//i;
		$size =~ s/k//i;
		return trim($size) * 1024;
	}

	if ($size =~ /mb/i || $size =~ /m/i) {
		$size =~ s/mb//i;
		$size =~ s/m//i;
		return trim($size) * 1024 * 1024;
	}

	if ($size =~ /gb/i || $size =~ /g/i) {
		$size =~ s/gb//i;
		$size =~ s/g//i;
		return trim($size) * 1024 * 1024 * 1024;
	}

	# Mustn't have units
	# Return the original size (just white-space trimmed)
	return trim($size);
}

# print the $size passed in in a nice way
# if you pass '1' as the 2nd param,
# it will round off the number to the nearest int
# (using sprintf)
# if you do not, you'll get 2 dec places.
#
# some postgres configs can use nice readable formats
# like '1.9GB' or '256kB' or '500MB'
sub print_size {
	my $size = shift;
	my $round = 1;
	if (defined($_[0])) {
		$round = 0;
	}

	if ($size < 1024) {
		return "$size b";
	}

	$size = $size / 1024;
	if ($size < (1024)) {
		$size = sprintf("%.2f", $size);
		if (!$round) {
			$size = sprintf("%.0f", $size);
		}
		return $size . "kB";
	}

	$size = $size / 1024;
	if ($size < 1024) {
		$size = sprintf("%.2f", $size);
		if (!$round) {
			$size = sprintf("%.0f", $size);
		}
		return $size. "MB";
	}

	$size = $size / 1024;
	$size = sprintf("%.2f", $size);
	if (!$round) {
		$size = sprintf("%.0f", $size);
	}
	return $size . "GB";
}

sub percentage_difference {
	my ($a,$b) = @_;
	abs(($a - $b) / $a ) *100;
}

# Some postgres options have minimum values
# eg max_stack_depth has to be '100kB'
my %MIN_SETTINGS = (
	'max_stack_depth' => '100kB',
	'shared_buffers' => '128kB',
	'temp_buffers' => '800kB',
	'work_mem' => '64kB',
	'maintenance_work_mem' => '1MB',
	'wal_buffers' => '32kB',
);

# Values we get from asking questions.
# These values are used over defaults when making calculations
my %NEW_SETTINGS = ();

# These are suggested settings kept separate from defaults
# since defaults are overwritten as the config is read through.
my %SUGGESTED_SETTINGS = (
    'log_line_prefix' => '\'%m %d [%p]: [%l-1] \'',
);

# What we want as minimum defaults (min work_mem, shared_buffers etc)
# these options will be overwritten as the config file is read through.
my %DEFAULTS = (
	'bgwriter_delay' => '200ms',
	'bgwriter_lru_maxpages' => 100,
	'bgwriter_lru_multiplier' => '2.0',

	'listen_addresses' => 'localhost',

	'maintenance_work_mem' => '16MB',
	'max_connections' => 80,
	'max_fsm_pages' => 1600,
	'max_fsm_relations' => 100,
	'max_prepared_transactions' => 10,
	'max_stack_depth' => '2MB',

	'port' => 5432,
	'ssl' => 'false',
	'superuser_reserved_connections' => 8,
	'temp_buffers' => '100kB',

	'work_mem' => '1MB',

	'vacuum_cost_delay' => 0,
	'vacuum_cost_page_hit' => 1,
	'vacuum_cost_page_miss' => 10,
	'vacuum_cost_page_dirty' => 20,
	'vacuum_cost_limit' => 200,

	'wal_sync_method' => 'fdatasync',
	'wal_buffers' => '256kB',
	'wal_writer_delay' => '1000ms',
	'commit_delay' => 5000,
	'commit_siblings' => 10,
	'checkpoint_segments' => 10,
	'checkpoint_timeout' => '10min',
	'checkpoint_completion_target' => '0.8',
	'checkpoint_warning' => '30s',

	'default_statistics_target' => 150,
	'max_locks_per_transaction' => 64,

	'effective_cache_size' => '16MB',

	'log_destination' => 'syslog',
	'syslog_facility' => 'local0',
	'syslog_ident' => 'postgres',

	'log_min_duration_statement' => 2000,

	# Set these to unwanted values
	# so if they are commented out in the config,
	# we get warnings about them being disabled.
	'autovacuum' => 'off',
	'stats_start_collector' => 'off',
	'stats_row_level' => 'off',
	'track_counts' => 'off',
	'wal_sync_method' => 'fsync',
	'fsync' => 'off',
	'log_autovacuum_min_duration' => -1,
);

# pg 9 added this option
# matrix requires it to be 'escape'
# so we'll set the unwanted version (ie default)
# to make sure we get a warning about changing it.
if ($pg_major_version > 8) {
	$DEFAULTS{'bytea_output'} = 'hex';
}

# include all 'suggested settings' as defaults
while ( my ($key, $value) = each(%SUGGESTED_SETTINGS) ) {
    $DEFAULTS{$key} = $value;
}

# These are used to calculate how much memory postgres needs
# before it can allocate shared_buffers or effective_cache_size
my %MEM_SETTINGS = (
	'shm_per_fsmpage' => 6,
	'shm_per_fsmrel' => 70,
	'shm_pertran' => 600,
	'shm_perconn' => 400,
	'shm_perlock' => 270,
);

# Taken from comments at
# http://devdaily.com/perl/edu/articles/pl010005/
sub promptUser {
  my($prompt, $default) = @_;
  my $defaultValue = $default ? "[$default]" : "";
  print "$prompt $defaultValue: ";
  chomp(my $input = <STDIN>);
  return $input ? $input : $default;
}

# keep the complete config so we can place our new variables in.
# this allows us to keep commented out values and descriptions.
my $complete_config;
open CONFIG, $pgconfig or die "Can't open $pgconfig: $!";
while (<CONFIG>) {
	$complete_config .= $_;

	my $line = trim($_);
	next if $line =~ /^#/; #ignore commented lines
	next unless $line; #ignore blank lines

	my ($option, $value) = split(/\s*=\s*/, $line);

	next unless $value;

	$option = trim($option);

	# clean up the value by removing comments
	# (eg 'value = x # comment here')
	# then trim it
	$value =~ s/#(.*)//;
	$value = trim($value);

	# if we find one of the default options
	# update that value
	# so when we prompt later on,
	# it will use the setting from the config.
	if ($DEFAULTS{$option}) {
		$DEFAULTS{$option} = $value;
	}
}
close CONFIG;

my $pg_db_list = `$psql -U postgres -p $DEFAULTS{'port'} -Alt`;
if (($? >> 8) > 0) {
	die "Unable to connect to postgres, script aborting.\n";
}
my @pg_db_lines = split(/\n/, $pg_db_list);


print_verbose "Checking locale settings .. ";
# for postgres < 8.4, lc_ctype is for the entire cluster.
my $locale_query = "SELECT setting FROM pg_settings WHERE name='lc_ctype'";
if ($pg_major_version == 8 && $pg_minor_version < 4) {
	my $locale = trim(`$psql -AqSt -U postgres -p $DEFAULTS{'port'} -c "$locale_query"`);
	if ($locale !~ /C/) {
		print "Locale settings are not set to 'C' (they are ", $locale, ").\n";
		print "Re-init the db cluster to the 'C' locale for some performance improvements.\n\n";
	}
} else {
	my $msg = "";
	# for postgres 8.4+, lc_ctype can be set per db.
	foreach (@pg_db_lines) {
		my $line = trim($_);
		next if $line !~ /\|/; # ignore extra 'acl' lines
		my ($_db, $_owner, $_encoding, $_collation, $_ctype) = split(/\|/, $line);
		next if $_db =~ /template0/;# we can't connect to template0 so skip it
		if ($_collation !~ /C/ or $_ctype !~ /C/) {
			$msg .= "Database $_db collation or ctype are not set to 'C'.\n";
			$msg .= "Recreate this database with both collation and ctype set to 'C' for some performance improvements.\n";
		}
	}
	if ($msg !~ /^$/) {
		print "\n", $msg, "\n";
	}
}
print_verbose "Done\n";

# Calculate fsm settings before anything else.
# If we're reconfiguring the server (ie this is run from cron)
# this is the only option that needs adjusting - so after doing
# those calculations, the script can exit.

my $fsm_pages = 0;
my $fsm_rels = 0;
# We only need to calculate fsm settings for postgres 8.3 and lower
# 8.4 removed fsm settings from the config (it's all just "handled")
# so they won't be factored in to calculations.
if ($pg_major_version == 8 && $pg_minor_version < 4) {
	print_verbose "Calculating fsm settings .. ";

	# do one query to get both
	# - relpages (number of pages we're currently using)
	# - relcount (number of relations we currently have)
	# saves two round trips to the db.
	my $fsm_query = "select * from (select sum(relpages) as relpages from pg_class) x, (SELECT (select count(relid) from pg_stat_all_indexes)+(select count(relid) from pg_stat_all_tables) AS relcount) y";

	foreach (@pg_db_lines) {
		my $line = trim($_);
		my ($_db, $_owner, $_encoding) = split(/\|/, $line);
		next if $_db =~ /template0/;# we can't connect to template0 so skip it
		my ($tmp_page_count, $tmp_rel_count) = split(/\|/, `$psql -AqSt -U postgres -p $DEFAULTS{'port'} -c "$fsm_query" $_db`);
		$fsm_pages = $fsm_pages + $tmp_page_count;
		$fsm_rels = $fsm_rels + $tmp_rel_count;
	}
	print_verbose "Done\n";
}

# times the real value by 1.5 to give us some
# headroom for further growth.
my $adjusted_fsm_pages = ceil($fsm_pages * 1.5);
my $adjusted_fsm_rels = ceil($fsm_rels * 1.5);

if ($reconfigure && ($pg_major_version == 8 && $pg_minor_version < 4)) {
	# If the current ('default') setting is less than the required,
	# show a warning msg.
	#
	# if fsm settings are too low, vacuum/autovacuum can't do it's work properly
	# they need to be higher than required.
	#
	# if we happen to have dropped by > $reconfigure_leeway
	# then it's probably worth adjusting.
	my $msg = "";

	my $fsm_diff = &percentage_difference($adjusted_fsm_pages, $DEFAULTS{'max_fsm_pages'});

	if (($DEFAULTS{'max_fsm_pages'} < $fsm_pages) || ($adjusted_fsm_pages > $DEFAULTS{'max_fsm_pages'} && $fsm_diff > $reconfigure_leeway)) {
		$msg = $msg . "- max_fsm_pages have changed from " . $DEFAULTS{'max_fsm_pages'} . " to " . $adjusted_fsm_pages . "\n";
	}

	$fsm_diff = &percentage_difference($adjusted_fsm_rels, $DEFAULTS{'max_fsm_relations'});

	if (($DEFAULTS{'max_fsm_relations'} < $fsm_rels) || ($adjusted_fsm_rels > $DEFAULTS{'max_fsm_relations'} && $fsm_diff > $reconfigure_leeway)) {
		$msg = $msg . "- max_fsm_relations have changed from " . $DEFAULTS{'max_fsm_relations'} . " to " . $adjusted_fsm_rels . "\n";
	}

	if ($msg) {
		print "On ", trim(`hostname`), ", fsm settings have changed significantly.\n";
		print $msg;
		print "Run $0 to reconfigure the server.\n";
	}
	exit;
}

# postgres requirement that fsm_pages be
# fsm_rels * 16
# (add 50 for a little room)
if ($adjusted_fsm_pages < ($adjusted_fsm_rels * 16)) {
	$adjusted_fsm_pages = ($adjusted_fsm_rels * 16) + 50;
}

# we've calculated fsm, set the new variables
$NEW_SETTINGS{'max_fsm_pages'} = $adjusted_fsm_pages;
$NEW_SETTINGS{'max_fsm_relations'} = $adjusted_fsm_rels;

# calculate how much mem we have
my $memory_info = `free -bo`;
my @lines = split(/\n/, $memory_info);
my ($name, $system_memory);
foreach (@lines) {
	next unless $_ =~ /Mem/;
	# we only want the first two fields
	# so stop the split at the 3rd
	($name, $system_memory) = split(/\s+/, $_, 3);
}
die "Unable to fetch memory info using 'free -bo'" unless $system_memory;


my $dedicated_server = &promptUser('Is this a dedicated database server?', 'n');
my $default_memory = $system_memory * 1/2;
if (lc $dedicated_server =~ /y/) {
	$default_memory = $system_memory * 3/4;
}

#######################
#    Question time    #
#######################

print "For some options (such as memory), the units don't need to be specified in bytes. You can use kb, mb, or gb instead.\n";

my $memory = fetch_size(&promptUser('How much memory (bytes) can be allocated to postgres?', print_size($default_memory)));
# Sanity check - just in case!
die "Can't allocate " . print_size($memory) . ", the server only has " . print_size($system_memory) . " available.\n" if ($memory > $system_memory);

$NEW_SETTINGS{'superuser_reserved_connections'} = &promptUser('Enter number of connections to reserve for superuser use', $DEFAULTS{'superuser_reserved_connections'});

$NEW_SETTINGS{'max_connections'} = &promptUser('Enter max number of connections', $DEFAULTS{'max_connections'});

# remove quotes around the addresses. we add them back in later.
$DEFAULTS{'listen_addresses'} =~ s/'//g;
$NEW_SETTINGS{'listen_addresses'} = &promptUser('What address(es) will postgres listen on (for more than one ip, comma separate them) ?', $DEFAULTS{'listen_addresses'});

if ($NEW_SETTINGS{'listen_addresses'} !~ /'/) {
	$NEW_SETTINGS{'listen_addresses'} = "'" . $NEW_SETTINGS{'listen_addresses'} . "'";
}

$NEW_SETTINGS{'port'} = &promptUser('What port will postgres listen on?', $DEFAULTS{'port'});
die "Port must be > 1024\n" if ($NEW_SETTINGS{'port'} < 1024);

$NEW_SETTINGS{'default_statistics_target'} = &promptUser('Enter a default stats target', $DEFAULTS{'default_statistics_target'});

print "\n";
my $memory_preallocated = ((($NEW_SETTINGS{'max_connections'} * $MEM_SETTINGS{'shm_perconn'}) + ($NEW_SETTINGS{'superuser_reserved_connections'} * $MEM_SETTINGS{'shm_perconn'}) + ($DEFAULTS{'max_prepared_transactions'} * $MEM_SETTINGS{'shm_pertran'}) * $DEFAULTS{'max_locks_per_transaction'}) * $MEM_SETTINGS{'shm_perlock'}) + ($adjusted_fsm_pages * $MEM_SETTINGS{'shm_per_fsmpage'} + ($adjusted_fsm_rels * $MEM_SETTINGS{'shm_per_fsmrel'}));

print_verbose "memory_preallocated: $memory_preallocated\n";

print_verbose "Total system memory: ", print_size($system_memory), "\n";
print_verbose "Total pg memory: ", print_size($memory), "\n";

my $db_available_memory = $memory - $memory_preallocated;

print_verbose "Total db available memory (after pre-allocation): ", print_size($db_available_memory), "\n";

$NEW_SETTINGS{'shared_buffers'} = ($db_available_memory * 0.4);
$NEW_SETTINGS{'effective_cache_size'} = ($db_available_memory * 0.6);

print_verbose "shared_buffers is now ", print_size($NEW_SETTINGS{'shared_buffers'}), "\n";
print_verbose "effective_cache_size is now ", print_size($NEW_SETTINGS{'effective_cache_size'}), "\n";

# 8.3+ use friendly units
# < 8.3 didn't for some options.
my $convert = 0;
if (($pg_major_version > 8) or ($pg_major_version == 8 and $pg_minor_version >= 3)) {
	$convert = 1;
}

print_verbose "Checking minimum settings .. \n";
while ( my ($key, $value) = each(%MIN_SETTINGS) ) {
	print_verbose "Checking setting $key .. ";
	# We're not changing this option? That's ok.
	if (!defined($NEW_SETTINGS{$key})) {
		print_verbose "Its set to default\n";
		next;
	}

	print_verbose "Changing the setting .. ";

	my $new = fetch_size($NEW_SETTINGS{$key});
	my $min = fetch_size($value);

	print_verbose "New: $new, min: $min\n";

	if ($new < $min) {
		print_verbose "\nSetting $key is too low, adjusting to min (", print_size($value), ") .. ";
		$NEW_SETTINGS{$key} = $value;
	}
}
print "Done\n";

# these options are specified in kb <= 8.2
# 8.3+ use any friendly units (kb/mb/gb)
my @_fix_opts = (
	'max_stack_depth',
	'maintenance_work_mem',
	'work_mem',
);

print_verbose "Convert is $convert\n";

if ($convert) {
	# in 8.3+ these are specified in friendly units (kb, meg, gig)
	my @_extra_opts = (
		'effective_cache_size',
		'shared_buffers',
	);
	push (@_fix_opts, @_extra_opts);
}

print_verbose "Fixing options to make them use easy settings rather than # of blocks .. ";
foreach (@_fix_opts) {
	my $_fix_opt = $_;

	# Check we've got an uncommented option
	# The new setting will not be defined if it's commented out
	# So pick the default value instead.

	print_verbose "Fixing $_fix_opt .. \n";
	if ($convert) {
		if (!defined $NEW_SETTINGS{$_fix_opt}) {
			$NEW_SETTINGS{$_fix_opt} = fetch_size($DEFAULTS{$_fix_opt});
			print_verbose "Getting default value ", $NEW_SETTINGS{$_fix_opt}, "\n";
		}

		$NEW_SETTINGS{$_fix_opt} = print_size($NEW_SETTINGS{$_fix_opt}, 0);
	} else {

        # When working out the new size, see if it's defined as a new setting
        # if it's not, use the default.
        my $new_size;
		if (!defined $NEW_SETTINGS{$_fix_opt}) {
            $new_size = $DEFAULTS{$_fix_opt};
        } else {
            $new_size = $NEW_SETTINGS{$_fix_opt};
        }

        # before converting to the new size, see if we need to.
        if ($new_size =~ /k/i || $new_size =~ /m/i || $new_size =~ /g/i) {
            $new_size = fetch_size($new_size) / 1024;
        }
        $NEW_SETTINGS{$_fix_opt} = $new_size;
	}
}

if (!$convert) {
	# in 8.2 and lower, these options are specified in 8kb blocks.
	@_fix_opts = (
		'effective_cache_size',
		'shared_buffers',
	);
	foreach (@_fix_opts) {
		my $_fix_opt = $_;
		if (!defined $NEW_SETTINGS{$_fix_opt}) {
			$NEW_SETTINGS{$_fix_opt} = fetch_size($DEFAULTS{$_fix_opt});
		}
		# from bytes:
		# / 1024 (to get kb)
		# / 8 (to get 8kb blocks)
		$NEW_SETTINGS{$_fix_opt} = sprintf("%.0f", (($NEW_SETTINGS{$_fix_opt}/1024) / 8));
	}
}
print_verbose "Done\n";

# see if these values are uncommented. If they are, leave them alone.
# Otherwise use the default value.
@_fix_opts = (
    'log_min_duration_statement',
    'log_line_prefix',
);
foreach (@_fix_opts) {
    my $_fix_opt = $_;
    $NEW_SETTINGS{$_fix_opt} = $DEFAULTS{$_fix_opt};
}

if (
    $NEW_SETTINGS{'log_line_prefix'} !~ /\%m/
    && $NEW_SETTINGS{'log_line_prefix'} !~ /\%t/
) {
    print "log_line_prefix has neither %m or %t\n";
    print "Changing the default log_line_prefix so %m is included\n";
    $NEW_SETTINGS{'log_line_prefix'} = $SUGGESTED_SETTINGS{'log_line_prefix'};
}

# Throw a message if the original does not enable autovacuum
if ($DEFAULTS{'autovacuum'} !~ /on/) {
	print "autovacuum is off, enabling it now\n";
	$NEW_SETTINGS{'autovacuum'} = 'on';
}

if (($pg_major_version == 8 && $pg_minor_version > 2) || $pg_major_version > 8) {
    if ($DEFAULTS{'log_autovacuum_min_duration'} < 0) {
        print "log_autovacuum_min_duration is off, enabling it now\n";
        $NEW_SETTINGS{'log_autovacuum_min_duration'} = 0;
    }
}

if ($pg_major_version > 8) {
	if ($DEFAULTS{'bytea_output'} !~ /escape/) {
		print "Matrix requires bytea_output set to escape\n";
		print "Changing it now\n";
		$NEW_SETTINGS{'bytea_output'} = 'escape';
	}
}

# autovacuum requirements are different depending on the version.
# 8.3+ uses 'track_counts'
# < 8.3 uses 'stats_start_collector' and 'stats_row_level'
if (($pg_major_version == 8 && $pg_minor_version >= 3) || $pg_major_version > 8) {
	if ($DEFAULTS{'track_counts'} !~ /on/) {
		print "autovacuum is enabled, but also requires track_counts to be set to on.\n";
		print "enabling that option now.\n";
		$NEW_SETTINGS{'track_counts'} = 'on';
		print "\n";
	}
} else {
	if ($DEFAULTS{'stats_row_level'} !~ /on/ || $DEFAULTS{'stats_start_collector'} !~ /on/) {
		print "autovacuum is enabled, but also requires both stats_row_level and stats_start_collector to be on.\n";
		print "enabling those options now.\n";
		print "\n";

		$NEW_SETTINGS{'stats_start_collector'} = 'on';
		$NEW_SETTINGS{'stats_row_level'} = 'on';
	}
}

if ($DEFAULTS{'fsync'} !~ /on/) {
	print "fsync is off, are you mad? enabling it now\n";
	$NEW_SETTINGS{'fsync'} = 'on';
}

if ($DEFAULTS{'wal_sync_method'} =~ /fsync/) {
	print "wal_sync_method is set to fsync, the recommended setting is fdatasync. setting that now\n";
	$NEW_SETTINGS{'wal_sync_method'} = 'fdatasync';
}

print_verbose "Fixing up the config with new options .. ";
# Now we've done all our calculations,
# lets replace the new settings in the config
while ( my ($key, $value) = each(%NEW_SETTINGS) ) {
	# If the option is already uncommented, that's good.
	if ($complete_config =~ /\n$key/) {
		$complete_config =~ s/\n$key\s*=\s*(.*?)(\s*#.*?)/\n$key = $value$2/;
		next;
	}
	# If it's commented out, we need to uncomment it.
	$complete_config =~ s/\n\#$key\s*=\s*(.*?)(\s*#.*?)/\n$key = $value$2/;
}

open (NEW_CONFIG, '>./postgresql_new.conf');
print NEW_CONFIG $complete_config;
close NEW_CONFIG;
print_verbose "Done\n";

if (compare($pgconfig, 'postgresql_new.conf') != 0) {
	print "./postgresql_new.conf has some modified settings. Please review.\n\n";
} else {
	print "Your configuration has been tuned already, there are no suggested changes.\n\n";
}

print "You should set shmmax and shmall in /etc/sysctl.conf to the following:\n";
print "kernel.shmmax=", ceil($memory + 1024), "\n"; # set it *slightly* higher rather than exactly.
print "kernel.shmall=", ceil($memory/8), "\n";
print "Note: shmmax and shmall do not need to be changed if they are already at the suggested values or higher.\n";

print "\n";
print "Don't forget to: restart postgres and run 'VACUUM ANALYSE VERBOSE;'\n";

