#!/usr/bin/perl -w

$|++;

use strict;
use vars qw(
	$DEBUG
	$VERBOSE
	$LOG
	$LOG_FILE
	$VERSION
	$REVISION
	$ERRORS
	$PWD
	$OPENNMS_HOME
	$SOEXT

	$PG_USER
	$PG_PASS
	$PG_LIBDIR
	$PG_VERSION

	$USER
	$PASS

	$CASCADE
	$DATABASE
	$SQL_FILE

	%CHANGED
	%MONTHS
	@TABLES
	%SEQMAPPING
	@SEQUENCES
	@CFUNCTIONS
	@FUNCTIONS
	@LANGS
	@INDEXES
	@DROPS
	%INSERTS
	$CREATE
	$FORCE
	$RPM
	$NOINSERT
	$NOSO
	$TOMCAT
	$NOLDSO
	$DODROPS

	$template
	$psql
	$database
);

use File::Find;
use DBI;

$OPENNMS_HOME	= '@root.install@';
$SOEXT		= '@compile.soext@';
$TOMCAT		= 1;
$VERBOSE	= 1;
$LOG		= 0;
$LOG_FILE	= '/tmp/opennms-install.log';
$VERSION	= '0.6';
$REVISION	= 1;
$ERRORS		= 0;
$FORCE		= 0;
$RPM		= 0;
$PG_USER	= 'postgres';
$PG_PASS	= '';
$PG_LIBDIR	= undef;
$USER		= 'opennms';
$PASS		= 'opennms';
$DATABASE	= 'opennms';
%MONTHS		= (
	'jan' => 1,
	'feb' => 2,
	'mar' => 3,
	'apr' => 4,
	'may' => 5,
	'jun' => 6,
	'jul' => 7,
	'aug' => 8,
	'sep' => 9,
	'oct' => 10,
	'nov' => 11,
	'dec' => 12,
);

chomp($PWD = `pwd`);

print <<END;
==============================================================================
OpenNMS Installer Version $VERSION (Revision $REVISION)
==============================================================================

Configures PostgreSQL tables, users, and other miscellaneous settings.

END

my @argv_temp = @ARGV;
@ARGV = ();

# dig through the command-line arguments; can't use getopt because of the
# way they're being handled.  ugh.
while (1) {
	my $arg = shift(@argv_temp) || last;

	if ($arg =~ /^\-+(.+)$/) {
		my @args = split(//, $1);

		for my $arg (@args) {
			print_help()	if ($arg eq "h");
			$VERBOSE	= 0 if ($arg eq "q");
			$FORCE		= 1 if ($arg eq "c");
			$NOLDSO	 = 1 if ($arg eq "e");
			$FORCE		= 1 if ($arg eq "f");
			$NOINSERT = 1 if ($arg eq "i");
			$RPM			= 1 if ($arg eq "r");
			$NOSO		 = 1 if ($arg eq "s");
			$TOMCAT	 = 0 if ($arg eq "t");
			$DEBUG		= 1 if ($arg eq "x");
			$DODROPS	= 1 if ($arg eq "z");

			if ($arg eq "u") {
				$USER = shift @argv_temp;
				if ($USER =~ /^\-+/) {
					print_help();
				}
			}

			if ($arg eq "p") {
				$PASS = shift @argv_temp;
				if ($PASS =~ /^\-+/) {
					print_help();
				}
			}

			if ($arg eq "U") {
				$PG_USER = shift @argv_temp;
				if ($PG_USER =~ /^\-+/) {
					print_help();
				}
			}

			if ($arg eq "L") {
				$LOG = 1;
				if ($argv_temp[0] !~ /^\-+/ and $argv_temp[0] !~ /\.sql\s*$/) {
					$LOG_FILE = shift(@argv_temp);
				}
			}

			if ($arg eq "P") {
				$PG_PASS = shift @argv_temp;
				if ($PG_PASS =~ /^\-+/) {
					print_help();
				}
			}

			if ($arg eq "d") {
				$DATABASE = shift @argv_temp;
				if ($DATABASE =~ /^\-+/) {
					print_help();
				}
			}

			if ($arg eq "l") {
				$PG_LIBDIR = shift @argv_temp;
				if ($DATABASE =~ /^\-+/) {
					print_help();
				}
			}

		}
	} else {
		push (@ARGV, $arg);
	}

}

print_help() if (@ARGV == 0);

if ($> != 0) {
	die "You must be root to run this installation script.\n\n";
}

if ($LOG) {
	if ( open(LOG, "| tee $LOG_FILE") ) {
		select LOG;
	} else {
		warn "log file $LOG_FILE was not created: $!";
	}
}

my $failed = 0;

chdir($PWD);

##############################################################################
# diagnostic-type stuff
##############################################################################
print "* using '$USER' as the PostgreSQL user for OpenNMS\n";
print "* using '$PASS' as the PostgreSQL password for OpenNMS\n";
print "* using '$DATABASE' as the PostgreSQL database name for OpenNMS\n";
print "* I am being called from an RPM install\n" if ($RPM);

##############################################################################
# parse SQL
##############################################################################

$ARGV[0] = "$PWD/$ARGV[0]" unless ($ARGV[0] =~ /^\.?\//);
$SQL_FILE = $ARGV[0];
print "- reading table definitions... ";
if (read_tables($SQL_FILE)) {
	print "OK\n";
} else {
	print "FAILED\n";
}

##############################################################################
# build if necessary
##############################################################################

my @jars;
my $match_dir;

# check for OPENNMS_HOME and make sure there are jar files in there

if (exists $ENV{OPENNMS_HOME}) {
	@jars = file_match($ENV{OPENNMS_HOME}, 'opennms_.+.jar$', 'f');
	$match_dir = $ENV{OPENNMS_HOME};
} else {
	if (-d $OPENNMS_HOME) {
		$ENV{OPENNMS_HOME} = $OPENNMS_HOME;
		@jars = file_match($ENV{OPENNMS_HOME}, 'opennms_.+.jar$', 'f');
		$match_dir = $OPENNMS_HOME;
	} else {
		@jars = file_match($PWD, '.jar$', 'f');
		$match_dir = $PWD;
	}
}

##############################################################################
# check for database and users, create if necessary
##############################################################################

{

	$ENV{PGUSER} = $PG_USER;
	$template = DBI->connect('dbi:Pg:dbname=template1', $PG_USER, $PG_PASS) or die(<<END);

*** Unable to connect to the database!! ***

Be sure PostgreSQL is started and running correctly
before running this install script!

$DBI::errstr

END

	my $verquery = $template->prepare('select version()') or die "couldn't prepare version from the database: " . $template->errstr;
	$verquery->execute() or die "couldn't execute version from database: " . $verquery->errstr;
	if ($verquery->rows) {
		my ($version) = $verquery->fetchrow_array();
		($PG_VERSION) = $version =~ /PostgreSQL (\d+\.\d+)/;
	}

	if ($PG_VERSION >= 7.3) {
		$CASCADE = " CASCADE";
	}

	# dbi will return an OK even if the user exists, so we
	# always do a create, and let it silently fail if they do

	print "- creating user \"$USER\"... ";
	eval {
		stderr_off();
		$template->do("CREATE USER $USER WITH PASSWORD '$PASS' CREATEDB CREATEUSER") or die($template->errstr);
		stderr_on();
	};

	if (scalar $@ and $@ !~ /already exists/) {
		print "FAILED\n";
		print <<END;

*** ERROR ***
I was unable to create a user in the template1
database.  Please confirm that PostgreSQL is
installed and configured on your system and run this
script again.

$@
END

		$ERRORS++;
	} else {
		print "OK\n";
	}

	if ($VERBOSE) {
		$DATABASE = ask_question("what should we name the OpenNMS database?", $DATABASE);
	}

	print "- creating database \"$DATABASE\"... ";

	eval {
		stderr_off();
		$template->do("CREATE DATABASE " . $DATABASE . " WITH ENCODING='UNICODE'") or die("Unable to create $DATABASE database: " . $template->errstr);
		stderr_on();
	};

	if ($@ and $@ !~ /database "$DATABASE" already exists/) {
		print "FAILED\n";
		print <<END;

*** ERROR ***
I was unable to create the '$DATABASE' database.
Please confirm that PostgreSQL is installed and
configured on your system and run this script
again.

$@
END

		$ERRORS++;
	} else {
		print "OK\n";
	}

}

##############################################################################
# connect to the database
##############################################################################

$ENV{PGUSER} = $PG_USER;
$database = DBI->connect("dbi:Pg:dbname=$DATABASE", $PG_USER, $PG_PASS, { AutoCommit => 1 }) or die(<<END);

*** Unable to connect to the database!! ***

Be sure PostgreSQL is started and running correctly
before running this install script!

$DBI::errstr

END

##############################################################################
# create sequences
##############################################################################

for my $sequence (@SEQUENCES) {

	if (not exists $SEQMAPPING{$sequence}) {
		print "WARNING: sequence mapping for $sequence not found.  You're probably\n";
		print "         missing a sequence entry in your .sql file!\n";
		next;
	}

	my $minvalue;
	print "- checking \"$sequence\" minimum value... ";
	my $sth = $database->prepare("SELECT MAX(" . $SEQMAPPING{$sequence}->[0] .  ") AS max FROM " . $SEQMAPPING{$sequence}->[1]);
	if ($sth->execute() and $sth->rows()) {
		($minvalue) = $sth->fetchrow_array;
		$minvalue++;
	} else {
		$minvalue = 1;
	}
	print $minvalue, "\n";

	print "- removing sequence \"$sequence\"... ";
	eval {
		$database->do("DROP SEQUENCE $sequence") or die(scalar $database->errstr);
	};
	if ($@) {
		if ($@ =~ /does not exist/) {
			print "CLEAN\n";
		} else {
			$@ =~ s/\r?\n//gs;
			if ($@ =~ /Relation .+ does not exist/) {
				print "CLEAN\n";
			} else {
				print "FAILED: $@\n";
				$ERRORS++;
			}
		}
	} else {
		print "REMOVED\n";
	}

	print "- creating sequence \"$sequence\"... ";
	eval {
		$database->do("CREATE SEQUENCE $sequence minvalue $minvalue") or die(scalar $database->errstr);
		$database->do("GRANT ALL ON $sequence TO $USER") or die(scalar $database->errstr);
	};

	if ($@) {
		if ($@ =~ /Relation .+ already (at|exists)/) {
			print "EXISTS\n";
		} else {
			print "FAILED ($@)\n";
			$ERRORS++;
		}
	} else {
		print "OK\n";
	}

}

##############################################################################
# check tables, create columns or tables as needed
##############################################################################

for my $table (@TABLES) {

	# $FORCE (if set) will force it to drop and create
	if ($FORCE or (grep(/^$table$/, @DROPS) and $DODROPS)) {
		print "- creating table \"$table\"... ";

		$table  = lc($table);
		my $new = get_table_from_sql($table,1);
		if (not defined $new) {
			print "FAILED (can't get table)\n";
			$ERRORS++;
		}

		eval {
			stderr_off();
			$database->do("DROP TABLE $table $CASCADE") and print "DROPPED ";
			stderr_on();
		};
		undef $@;
		eval {
			$database->do("CREATE TABLE $table ($new)") or die scalar $database->errstr;
		};
		if ($@) {
			$@ =~ s/[\r\n]+$//gs;
			print "FAILED ($@)\n";
			$ERRORS++;
		} else {
			print "CREATED\n";
		}

		print "- giving \"$USER\" permissions on \"$table\"... ";

		eval {
			$database->do("GRANT ALL ON $table TO $USER") or die scalar $database->errstr;
		};
		if ($@) {
			$@ =~ s/[\r\n]+$//gs;
			print "FAILED ($@)\n";
			$ERRORS++;
		} else {
			print "GRANTED\n";
		}

	} else {
		print "- checking table $table... ";

		$table = lc($table);

		my $new = get_table_from_sql($table);
		if (int(@{$new}) == 0) {
			print "FAILED\n";
			$ERRORS++;
		}

		print int(@{$new}), " tokens, ";

		my $current = get_table_from_db($table);
		if (int(@{$current}) == 0) {
			my $new = get_table_from_sql($table, 1);
			$database->do("CREATE TABLE $table ($new)") or die("error: " . $database->errstr);
			$database->do("GRANT ALL ON $table TO $USER") or die ("error: " . $database->errstr);
			print "CREATED\n";
			next;
		}

		my $has_constraints = 0;
		my $col_added       = 0;
		my $col_changed     = 0;
		$database->do("GRANT ALL ON $table TO $USER") or print $database->errstr;

		for my $column (@{$new}) {

			if (exists $column->{CONSTRAINTS} and @{$column->{CONSTRAINTS}} > 0) {
				$has_constraints++;
			}

			next if (not defined $column);
			next if (not exists $column->{NAME} or not defined $column->{NAME});
			next if ($column->{NAME} eq "");

			if (my $work = find_column($current, $column->{NAME})) {

				for my $key (keys %{$column}) {
					if (exists $work->{$key}) {
						$work   = normalize_column($work);
						$column = normalize_column($column);
						if (lc($column->{$key}) ne lc($work->{$key})) {
							print "$column->{NAME} $key: $column->{$key} != $work->{$key}\n" if ($DEBUG);
							$col_changed++;
						}
					}
				}

			} else {
				$col_added++;
			}

		}

		if ($has_constraints or $col_changed or $col_added) {
			change_table($database, $table) or print "unable to change table: " . $database->errstr;
		}

		my $changed = 'EXISTS';
		$changed  = "$col_changed columns CHANGED"                 if ( $col_changed and !$col_added);
		$changed  = "$col_added columns NEW"                       if (!$col_changed and  $col_added);
		$changed  = "$col_changed columns CHANGED, $col_added NEW" if ( $col_changed and  $col_added);
		$changed .= " (has constraints)"                           if ( $has_constraints            );
		print "$changed\n";

	}

	print "- optimizing table $table... ";
	if ($database->do("VACUUM ANALYZE $table")) {
		print "DONE\n";
	} else {
		print "FAILED\n";
	}

}

##############################################################################
# create indexes
##############################################################################

for my $index (@INDEXES) {

	print "- creating index \"$index\"... ";
	eval {
		stderr_off();
		$database->do(get_index_from_sql($index)) or die scalar $database->errstr;
		stderr_on();
	};

	if ($@) {
		if ($@ =~ /already exists/) {
			print "EXISTS\n";
		} else {
			print "FAILED ($@)\n";
			$ERRORS++;
		}
	} else {
		print "OK\n";
	}

}

##############################################################################
# create C functions
##############################################################################

create_functions($database, @CFUNCTIONS);

##############################################################################
# create languages
##############################################################################

for my $lang (@LANGS) {

	print "- creating language reference \"$lang\"... ";
	eval {
		$database->do("create trusted procedural language '$lang' " . get_language_from_sql($lang)) or die(scalar $database->errstr);
	};

	if ($@) {
		if ($@ =~ /Language .+ already exists/) {
			print "EXISTS\n";
		} else {
			print "FAILED ($@)\n";
			$ERRORS++;
		}
	} else {
		print "OK\n";
	}

}

##############################################################################
# create other functions
##############################################################################

create_functions($database, @FUNCTIONS);

##############################################################################
# fix some data that has changed from previous releases
##############################################################################

stderr_off();
$database->do("UPDATE ipinterface SET issnmpprimary='N' WHERE issnmpprimary IS NULL");
$database->do("UPDATE service SET servicename='SSH' WHERE servicename='OpenSSH'");
$database->do("UPDATE snmpinterface SET snmpipadentnetmask=NULL");
stderr_on();

##############################################################################
# inserts
##############################################################################

unless ($NOINSERT) {

	for my $key (sort keys %INSERTS) {
		print "- inserting initial table data for \"$key\"... ";

		$database->{AutoCommit} = 0;
		$database->commit;
		eval {
			for my $row (@{$INSERTS{$key}}) {
				my $sth = $database->prepare($row) or die "cannot prepare \"$row\": " . $database->errstr;
				$sth->execute() or die "cannot execute \"$row\": " . $database->errstr;
			}
		};
		$database->commit;
		if ($@) {
			$@ =~ s/[\r\n]+//gs;
			if ($@ =~ /duplicate key/) {
				print "EXISTS\n";
			} else {
				print "FAILED: $@\n";
				$ERRORS++;
			}
		} else {
			print "OK\n";
		}
		$database->{AutoCommit} = 1;
	}

}

##############################################################################
# update tomcat server.xml
##############################################################################

if ($TOMCAT) {

	for my $dir ('/etc/tomcat4/conf', '/etc/tomcat4') {
		my $tomcatconf = $dir . '/tomcat4.conf';

		if (-f $tomcatconf) {
			my $conf_in;
			if (open(FILEIN, $tomcatconf)) {
				print "- setting tomcat4 user to 'root'... ";
				while (<FILEIN>) {
					if (/TOMCAT_USER/) {
						$conf_in .= "TOMCAT_USER=\"root\"\n";
					} else {
						$conf_in .= $_;
					}
				}
				close (FILEIN);
				print "done\n";

			} else {
				warn "unable to open $tomcatconf: $!\n";
			}
		}

	}

	for my $dir ('/var/tomcat4/conf', '/sw/var/tomcat4/conf', '/usr/local/tomcat4/conf', '/etc/tomcat4', '/usr/local/tomcat/conf') {

		my $serverxml  = $dir . '/server.xml';

		if (-f $serverxml) {
			my $server_in;
	
			print "- checking Tomcat 4 for OpenNMS web UI... ";
			if (open(FILEIN, $serverxml)) {
				$server_in .= $_ while (<FILEIN>);
				close (FILEIN);
	
				if (grep(/opennms/gsi, $server_in)) {
					if (not grep(/homeDir/gs, $server_in)) {
						print "UPDATING:\n";
						if (open(FILEOUT, ">$serverxml")) {
							$server_in =~ s#userFile\s*=\s*\".*?\"\s*#homeDir="${OPENNMS_HOME}" #gs;
							$server_in =~ s#<Logger className="org.apache.catalina.logger.FileLogger" prefix="localhost_opennms_log." suffix=".txt" timestamp="true"/>#<Logger className="org.opennms.web.log.Log4JLogger" homeDir="${OPENNMS_HOME}" />#gs;
							
							print FILEOUT $server_in;
							if (close(FILEOUT)) {
								print "DONE\n";
							}
						} else {
							$ERRORS++;
							print "FAILED\n";
						}
					} else {
						print "FOUND\n";
					}
				} else {
					print "UPDATING:\n";
	
					print "- adding OpenNMS web UI context to server.xml... ";
	
					if (open(FILEOUT, ">$serverxml")) {
						for my $line (split(/\r?\n/, $server_in)) {
							if ($line =~ m#</host>#gsi) {
								print FILEOUT <<END;

        <Context path="/opennms" docBase="opennms" debug="0" reloadable="true">
         <Logger className="org.opennms.web.log.Log4JLogger" homeDir="${OPENNMS_HOME}"/>
         <Realm className="org.opennms.web.authenticate.OpenNMSTomcatRealm" homeDir="${OPENNMS_HOME}"/>
        </Context>

END
							}
	
							print FILEOUT $line, "\n";
						}
						if (close(FILEOUT)) {
							print "DONE\n";
						} else {
							$ERRORS++;
							print "FAILED\n";
						}
					} else {
						$ERRORS++;
						print "FAILED\n";
					}
				}
	
			} else {
				$ERRORS++;
				print "FAILED\n";
			}
		}
	}

}

##############################################################################
# Check for unicode encoding.  If it doesn't exist, we move everything over.
##############################################################################

{

	print "- checking if database \"$DATABASE\" is unicode... ";
	eval {
		stderr_off();
		my $unicode = $template->prepare('SELECT encoding FROM pg_database WHERE datname=?') or die("Unable to prepare the database encoding query: " . $template->errstr);
		$unicode->execute($DATABASE) or die("Unable to get the database encoding: " . $template->errstr);
		(my $encoding) = $unicode->fetchrow_array;
		stderr_on();
		if ($encoding != 5 and $encoding != 6) {
			print "FAILED: rebuilding as unicode\n";
			$database->disconnect if (defined $database);
			$template->disconnect if (defined $template);
			system("$OPENNMS_HOME/bin/convert_db_to_unicode.sh", $PG_USER, $USER, $DATABASE, $SQL_FILE);
		} else {
			print "DONE\n";
		}
	}
}

##############################################################################
# locate postgres .so files and install
##############################################################################

$ENV{PGUSER} = $PG_USER;
$psql = DBI->connect("dbi:Pg:dbname=$DATABASE", $PG_USER, $PG_PASS) or die(<<END);

*** Unable to connect to the database!! ***

Be sure PostgreSQL is started and running correctly
before running this install script!

$DBI::errstr

END

unless ($NOSO) {

	print "- searching for PostgreSQL module directory... ";

	if (not $RPM) {

		for my $dir ($ENV{OPENNMS_HOME} . "/lib", '/usr/lib/opennms', '/usr/lib/pgsql/opennms', '/usr/lib/postgresql/lib/opennms') {
			if (-d $dir and -f "$dir/iplike.$SOEXT") {
				print "$dir\n";
				$PG_LIBDIR = $dir;
			} elsif (my ($pgdir) = file_match($PWD, 'iplike.$SOEXT$', 'f')) {
				if (not defined $PG_LIBDIR) {
					($PG_LIBDIR) = $pgdir =~ /^(.+)\/iplike\.$SOEXT$/;
					print "$PG_LIBDIR\n";
				} else {
					last;
				}
			}
		}

	} else {

		print "$PG_LIBDIR\n" if (defined $PG_LIBDIR);

	}

	if (not defined $PG_LIBDIR) {
		print "FAILED\n";
		$ERRORS++;
	} else {

		print "- checking for stale iplike.so references... ";
		eval {
			stderr_off();
			$psql->do("DROP FUNCTION iplike(text,text)") or die scalar $psql->errstr;
			stderr_on();
		};
		if ($@ eq "") {
			print "REMOVED\n";
		} elsif ($@ =~ /does not exist/) {
			print "CLEAN\n";
		} else {
			$@ =~ s/\r?\n//gs;
			print "FAILED: $@\n";
			$ERRORS++;
		}

		print "- checking for stale eventtime.so references... ";
		eval {
			stderr_off();
			$psql->do("DROP FUNCTION eventtime(text)") or die scalar $psql->errstr;
			stderr_on();
		};
		if ($@ eq "") {
			print "REMOVED\n";
		} elsif ($@ =~ /does not exist/) {
			print "CLEAN\n";
		} else {
			$@ =~ s/\r?\n//gs;
			print "FAILED: $@\n";
			$ERRORS++;
		}

		print "- adding iplike.so database function... ";
		eval {
			stderr_off();
			$psql->do("CREATE FUNCTION iplike(text,text) RETURNS bool AS '$PG_LIBDIR/iplike.$SOEXT' LANGUAGE 'c' WITH(isstrict)") or die scalar $psql->errstr;
			stderr_on();
		};
		if (not $@) {
			print "OK\n";
		} else {
			if ($@ =~ /procedure iplike already exists/i) {
				print "FAILED (non-fatal: already exists)\n";
			} else {
				print "FAILED ($@)\n";
				$ERRORS++;
			}
		}

	}

	my $plpgsql_failed = 0;
	my $plpgsql_sofile;
	print "- adding PL/pgSQL call handler... ";
	for my $dir ('/usr/lib', '/usr/local/lib', '/sw/lib/postgresql', '/usr/local/pgsql/lib', '/usr/lib/postgresql/lib', '/usr/lib/postgresql') {
		for ($SOEXT, 'so') {
			if (-d "$dir") {
				if (-f "$dir/pgsql/plpgsql.$_") {
					$plpgsql_sofile = "$dir/pgsql/plpgsql.$_";
					last;
				} elsif (-f "$dir/plpgsql.$_") {
					$plpgsql_sofile = "$dir/plpgsql.$_";
					last;
				}
			}
		}
	}
	if (defined $plpgsql_sofile) {
		eval {
			$psql->do("CREATE FUNCTION plpgsql_call_handler () RETURNS OPAQUE AS '$plpgsql_sofile' LANGUAGE 'C'") or die scalar $psql->errstr;
		};
    if ($@ =~ /already exists with same argument/) {
			print "EXISTS\n";
		} elsif ($@) {
			print "FAILED ($@)\n";
			$plpgsql_failed++;
			$ERRORS++;
		} else {
			print "OK\n";
		}
		print "- adding PL/pgSQL language module... ";
		eval {
			stderr_off();
			$psql->do("CREATE TRUSTED PROCEDURAL LANGUAGE 'plpgsql' HANDLER plpgsql_call_handler LANCOMPILER 'PL/pgSQL'") or die scalar $psql->errstr;
			stderr_on();
		};
		if ($@ =~ /already exists/) {
			print "EXISTS\n";
		} elsif ($@) {
			print "FAILED ($@)\n";
			$plpgsql_failed++;
			$ERRORS++;
		} else {
			print "OK\n";
		}
	} else {
		print "FAILED (unable to locate plpgsql.$SOEXT)\n";
		$plpgsql_failed++;
		$ERRORS++;
	}
	print "- adding stored procedures... ";
	if ($plpgsql_failed == 0 and opendir(DIR, $OPENNMS_HOME . "/etc")) {
		my @procedures = grep(/^get.+\.sql/, readdir(DIR));
		closedir(DIR);
		for my $procedure (@procedures) {
			print "\n  - $procedure... ";
			if (open(FILE, $OPENNMS_HOME . "/etc/" . $procedure)) {
				my ($contents, @drop);
				while (<FILE>) {
					if (/DROP FUNCTION/i) {
            					push(@drop, $_);
					} else {
						$contents .= $_;
					}
				}
				close(FILE);
				stderr_off();
				eval {
					for my $drop (@drop) {
						my $newdrop;
						if ($drop =~ /drop function\s+([^\(\s]+)\s*\((.+)\)/i) {
							my $function = $1;
							my @args = split(/\s*,\s*/, $2);
							for my $arg (@args) {
								$arg = parse_column($arg);
							}
							@args = clean_column(@args);
							my $collist = join(',', get_columntype(@args));
							$collist =~ s#\(\d+\)##g;
							$drop = "DROP FUNCTION ${function}(${collist})";
						}
						$psql->do($newdrop);
					}
					$psql->do($contents) or die scalar $psql->errstr;
				};
				stderr_on();
				if ($@ =~ /already exists/) {
					print "EXISTS";
				} elsif ($@) {
					print "FAILED ($@)";
					$ERRORS++;
				} else {
					print "OK";
				}
			} else {
				print "FAILED ($!)";
			}
		}
		print "\n";
	} else {
		if ($plpgsql_failed > 0) {
			print "FAILED (unable to add PL/PgSQL module)\n";
		} else {
			print "FAILED (unable to open $OPENNMS_HOME/etc)\n";
		}
		$ERRORS++;
	}
}

##############################################################################
# cleanup time
##############################################################################

if (-d '/var/run/opennms') {
	print "- removing /var/run/opennms... done";
	`rm -rf /var/run/opennms`
}

print "\n";

if ($ERRORS) {
	print <<END;
*** $ERRORS errors occurred! ***

END

	exit $ERRORS;
}

print <<END;
<<< Configuration Complete >>>

END

close(LOG);
$database->disconnect() if (defined $database);
$psql->disconnect()     if (defined $psql);
$template->disconnect() if (defined $template);

##############################################################################
# subroutines
##############################################################################

# subroutine: create_functions
# function: create a list of functions in the database
# input: the database handle and a list of functions
# output: n/a

sub create_functions {
	my $database  = shift;
	my @functions = @_;

	for my $function (@functions) {
		if ($FORCE) {
			my $function_sql = get_function_from_sql($function);
			$function_sql =~ m/^\s*(\(.+?\))/;
			print "- removing function \"$function\" if it exists... ";
			eval {
				$database->do("DROP FUNCTION \"$function\" $1;") or die scalar $database->errstr;
			};
			if ($@) {
				if ($@ =~ /does not exist/) {
					print "CLEAN\n";
				} else {
					$@ =~ s/\r?\n//gs;
					print "FAILED: $@\n";
					$ERRORS++;
				}
			} else {
				print "REMOVED\n";
			}
		}

		print "- creating function \"$function\"... ";
		eval {
			$database->do("CREATE FUNCTION \"$function\" " . get_function_from_sql($function)) or die scalar $database->errstr;
		};

		if ($@) {
			if ($@ =~ /procedure .+ already (at|exists)/) {
				print "EXISTS\n";
			} else {
				print "FAILED ($@)\n";
				$ERRORS++;
			}
		} else {
			print "OK\n";
		}

	}
}

# update_arch is deprecated, this should be unnecessary as the user can now
# put non-standard paths and compile flags into the ~/.bb-global.properties
# property file

sub update_arch {
	my $basename = shift;

	chomp(my $arch = `uname`);
	if (open (FILEIN, "$basename/arch/${arch}.properties") and open (FILEOUT, ">$basename/arch/${arch}.properties.new")) {

		if (not defined $ENV{POSTGRES_INCLUDE}) {
			$ENV{POSTGRES_INCLUDE} = ask_question('where are your PostgreSQL headers, eg postgres.h?', '/usr/include/pgsql');
		}
		if (not defined $ENV{POSTGRES_LIB}) {
			$ENV{POSTGRES_LIB}     = ask_question("where are your PostgreSQL libs, eg libpq.$SOEXT.2?", '/usr/lib');
		}

		print "- filtering arch/${arch}.properties... ";

		while (<FILEIN>) {
			if (/^\s*compile\.include/) {
				$_ = "compile.include=-I" . $ENV{POSTGRES_INCLUDE} . " -I/usr/include\n";
			} elsif (/^\s*compile\.lib/) {
				$_ = "compile.lib=" . $ENV{POSTGRES_LIB} . "\n";
			}

			print FILEOUT $_;
		}

		close (FILEOUT);
		close (FILEIN);

		unlink("$basename/arch/${arch}.properties");
		link("$basename/arch/${arch}.properties.new", "$basename/arch/${arch}.properties");
		unlink("$basename/arch/${arch}.properties.new");

		print "OK\n";

	} else {
		print "NOTICE: unable to update \"$basename/arch/${arch}.properties\"\n" unless ($RPM);
		return;
	}

	return 1;
}

{

	my @matches;
	my $spec;
	my $type;

	sub file_match {
		my $dir      = shift;
			 $spec     = shift;
			 $type     = shift;

		@matches = ();
		find(\&file_match_wanted, $dir);

		return @matches;
	}

	sub file_match_wanted {
		if (/$spec/) {
			if (defined $type) {
				eval "push(\@matches, \$File::Find::name) if (-$type \$File::Find::name);";
			} else {
				push(@matches, $File::Find::name);
			}
		}
	}

}

# subroutine: read_tables
# function: sanitize a block of sql code
# input: the filename to read (should be a full path to create.sql)
# output: sql code; no extra spaces or carriage returns, comments removed, etc.

sub read_tables {
	my $filename = shift;

	$CREATE = undef;

	if (-f "{$filename}.rpmnew") {
		print "WARNING: ${filename}.rpmnew exists.  Using that instead.\n";
		system("mv ${filename}.rpmnew ${filename}");
	}
	open (SQL, $filename) or return;
	while (my $line = <SQL>) {
		next if $line =~ /^\s*$/;
		next if $line =~ /^\s*\\/;

		if ($line =~ /^\s*--\#\s+install\:\s*(\S+)\s+(\S+)\s+(\S+)\s*$/) {
			$SEQMAPPING{$1} = [ $2, $3 ];
		}
		next if $line =~ /^\s*--/;
		if ($line =~ /^\s*create\b/i) {
			if (my ($type, $name) = $line =~ /^\s*create\s+((?:unique )?\w+)\s+["']?(\w+)["']?/i) {
				$name =~ s/^['"]//;
				$name =~ s/['"]$//;
				if ($type =~ /table/i) {
					push(@TABLES, $name);
				} elsif ($type =~ /sequence/i) {
					push(@SEQUENCES, $name);
				} elsif ($type =~ /function/i) {
					if ($line =~ /language 'c'/i) {
						push(@CFUNCTIONS, $name);
					} else {
						push(@FUNCTIONS, $name);
					}
				} elsif ($type =~ /trusted/i) {
					my ($type, $name) = $line =~ /^\s*create\s+(trusted procedural language)\s+["']?(\w+)["']?/i;
					push (@LANGS, $name);
				} elsif ($type =~ /\bindex\b/i) {
					my ($type, $name) = $line =~ /^\s*create\s+((?:unique )?index)\s+["']?([\w_]+)["']?/i;
					push (@INDEXES, $name);
				} else {
					warn "Unknown CREATE encountered: CREATE $type $name\n";
				}
			}
		} elsif ($line =~ /^INSERT INTO ["']?([\w_]+)["']?/i) {
			my $table = $1;
			chomp($line);
			push(@{$INSERTS{$table}}, $line);
			$line = undef;
		} elsif ($line =~ /^select setval .+$/i) {
			chomp($line);
			push(@{$INSERTS{'select_setval'}}, $line);
		} elsif ($line =~ /^DROP TABLE ["']?([\w_]+)["']?/i) {
			my $table = $1;
			push(@DROPS, $table);
		}

		$CREATE .= $line if (defined $line);
	}
	close (SQL);

#  $CREATE =~ s/\r?\n/ /gs;
#  $CREATE =~ s/\s+/ /gs;
#  $CREATE =~ s/\;/\;\n/gs;

	return 1;
}

# subroutine: get_table_from_db
# function: interrogate the database for the current columns in a table
# input: the table name to query
# output: an array reference containing a list of attributes for the columns

sub get_table_from_db {
	my $table_name = shift;
	my $attributes = [];

	eval {
		my $tables = $database->prepare("SELECT DISTINCT tablename FROM pg_tables") or return;
		$tables->execute or die($database->errstr);

		my $table_exists = 0;

		while (my ($table) = $tables->fetchrow_array) {
			next if $table =~ /^pg_/;
			$table_exists++ if (lc($table) eq lc($table_name));
		}

		return [] if not ($table_exists);

		$attributes = $database->func(lc($table_name), 'table_attributes') or return;

	};

	if ($@ ne "") {
		print "

*** ERROR ***
An error occurred reading table info for '$table_name'
from the database.  Please check to make sure your
PostgreSQL configuration is correct and then re-run
this script.

$@

";

		return [];
	}

	#my @return = map { $_->[0] } sort { $_->[1] cmp $_->[1] } map { $_ = [ $_, lc($_->{NAME}) ] } @{$attributes};
	#return \@return;

	my $index = 0;
	for my $attr (@{$attributes}) {
		($attributes->[$index]) = clean_column($attributes->[$index]);
		$index++;
	}
	return($attributes);
}

sub clean_text {
	my $text = join('', @_);

	$text =~ s/\r?\n/ /g;
	$text =~ s/\s+/ /g;
	$text =~ s/\;/\;\n/g;

	return $text;
}

# subroutine: get_sequence_from_sql
# function: parse an sql statement for sequence creation commands
# input: the sequence name to search for (in a global, $CREATE)
# output: the sql info about the sequence (minus create sequence _name_)

sub get_sequence_from_sql {
	my $sequence_name = shift;
	my $raw           = 1;  # always "raw-mode"

	my $CREATE = clean_text($CREATE);
	unless ($CREATE =~ /\bcreate sequence\s+$sequence_name\s+(.+?)\;/i) {
		return;
	}

	if ($raw) {
		return $1;
	}

	return;
}

# subroutine: get_table_from_sql
# function: parse an sql statement for a table definition
# input: the table name to search for (in a global, $CREATE)
#   and an optional "raw" flag to spit out the raw sql code
#   for that table
# output: in raw mode, the sql code for the table;
#   otherwise, an array reference of columns, containing a
#   hash reference of attributes for that column
#   -- see parse_column()

sub get_table_from_sql {
	my $table_name = shift;
	my $modifier   = shift;

	my $CREATE = clean_text($CREATE);
	unless ($CREATE =~ /\bcreate table\s+['"]?$table_name['"]?\s+\((.+?)\)\;/i) {
		return [];
	}

	if (defined $modifier and $modifier == 1) {
		return $1;
	}

	# lex through the sql statement
	my $create = $1;
	my $parens = 0;
	my @return;
	my $accumulator;

	while ($create =~ /\G(.)/gc) {

		if ($1 eq '(') { $parens++; $accumulator .= $1; next; }
		if ($1 eq ')') { $parens--; $accumulator .= $1; next; }

		if ($1 eq ',' and not $parens) {
			$accumulator =~ s/^\s*//;
			$accumulator =~ s/\s*$//;

			if ($accumulator =~ /^constraint /i) {
				my $lastcol = $return[$#return];
				if ($accumulator =~ /constraint .*primary key \($lastcol->{'NAME'}\)/i) {
					$lastcol->{'PRIMARY_KEY'} = 1;
				} else {
					push(@{$lastcol->{'CONSTRAINTS'}}, $accumulator);
				}
			} else {
				my $column = parse_column($accumulator);
				push(@return, $column);
			}
			$accumulator = undef;
		} else {
			$accumulator .= $1;
		}

	}

	$accumulator =~ s/^\s*//;
	$accumulator =~ s/\s*$//;

	if ($accumulator =~ /^constraint /i) {
		my $lastcol = $return[$#return];
		if ($accumulator =~ /constraint .*primary key \($lastcol->{'NAME'}\)/) {
			$lastcol->{'PRIMARY_KEY'} = 1;
		} else {
			push(@{$lastcol->{'CONSTRAINTS'}}, $accumulator);
		}
	} else {
		my $column = parse_column($accumulator);
		push(@return, $column);
	}

	@return = (@return);
	return \@return;
}

# subroutine: get_function_from_sql
# function: parse an sql statement for a function definition
# input: the function name to search for (in a global, $CREATE)
# output: (always in "raw" mode) the sql code for the function

sub get_function_from_sql {
	my $function_name = shift;

	if ($CREATE =~ /\bcreate function\s+['"]?$function_name['"]?\s+(.+? language ['"]?\w+["']?)\;/si) {
		return $1;
	}

	return;
}

# subroutine: get_language_from_sql
# function: parse an sql statement for a language definition
# input: the language name to search for (in a global, $CREATE)
# output: (always in "raw" mode) the sql code for the language

sub get_language_from_sql {
	my $language_name = shift;

	my $CREATE = clean_text($CREATE);
	if ($CREATE =~ /\bcreate trusted procedural language\s+["']?$language_name["']?\s+(.+?)\;/si) {
		return $1;
	}

	return;
}

# subroutine: get_index_from_sql
# function: parse an sql statement for an index definition
# input: the index name to search for
# output: (always in "raw" mode) the index creation

sub get_index_from_sql {
	my $index_name = shift;

	my $CREATE = clean_text($CREATE);
	if ($CREATE =~ /\b(create (unique )?index\s+["']?$index_name["']?\s+.+?)\;/si) {
		return $1;
	}

	return;
}

# subroutine: find_column
# function: search a column tree (see get_table_from_sql) for a column
# input: a scalar containing a tree definition, and the column name
#   to search for
# output: the contents of the column if found, an undefined value if not

sub find_column {
	my $column_list = shift;
	my $column      = shift;

	my @columns = @{$column_list};
	for my $col (@columns) {
		if (lc($col->{NAME}) eq lc($column)) {
			return $col;
		}
	}

	return;
}

# subroutine: parse_column
# function: parse a column's sql into a hash reference containing the
#   attributes of that column
# input: the raw column definition sql
# output: the attributes for that column as a hash reference

sub parse_column {
	my $column = shift;

	my $return = {
		CONSTRAINT  => undef,
		NAME        => undef,
		NOTNULL     => 0,
		PRIMARY_KEY => 0,
		SIZE        => 0,
		TYPE        => undef,
	};

	$column =~ s/\b(constraint \S+ )?primary key\b//i and $return->{PRIMARY_KEY} = 1;
	$column =~ s/\bnot null\b//i                      and $return->{NOTNULL}     = 1;
	$column =~ s/^\s*//;
	$column =~ s/\s*$//;
	$column =~ s/\s+/ /;
	#$column =~ s/\bdefault (.+)$//i and $return->{DEFAULT}     = $1;
	$column =~ s/\s*\bdefault (.+)$//i;

	my ($col_name, $col_type);
	if (($col_name, $col_type) = $column =~ /^(\S+)\s+(.+)$/) {
		$col_name =~ s/^['"]//;
		$col_name =~ s/['"]$//;
		$col_type =~ s/^['"]//;
		$col_type =~ s/['"]$//;
	} else {
		$col_type = $column;
	}

	$return->{NAME} = $col_name;

	if ($col_type =~ /^int(eger|4)$/) {
		$return->{TYPE} = 'integer';
		$return->{SIZE} = 4;
	} elsif ($col_type =~ /^(float8?|double precision)$/) {
		$return->{TYPE} = 'double precision';
		$return->{SIZE} = -1;
	} elsif ($col_type =~ /^(float4|real)$/) {
		$return->{TYPE} = 'real';
		$return->{SIZE} = -1;
	} elsif ($col_type =~ /^(bigint|int8)$/) {
		$return->{TYPE} = 'bigint';
		$return->{SIZE} = 8;
	} elsif ($col_type =~ /^(int2|smallint)$/) {
		$return->{TYPE} = 'smallint';
		$return->{SIZE} = 2;
	} elsif ($col_type =~ /^bool(ean)?$/) {
		$return->{TYPE} = 'boolean';
		$return->{SIZE} = 1;
	} elsif ($col_type =~ /^\s*character\s*$/) {
		$return->{TYPE} = 'character';
		$return->{SIZE} = 1;
	} elsif ($col_type =~ /(varchar|character varying)\((\d+)\)/i) {
		$return->{TYPE} = 'character varying';
		$return->{SIZE} = $2;
	} elsif ($col_type =~ /^\s*varchar\s*$/) {
		$return->{TYPE} = 'character varying';
		$return->{SIZE} = -1;
	} elsif ($col_type =~ /(char|character)\((\d+)\)/i) {
		$return->{TYPE} = 'bpchar';
		$return->{SIZE} = $2;
	} elsif ($col_type =~ /numeric\((\d+)\,\d+\)/i) {
		$return->{TYPE} = 'numeric';
		$return->{SIZE} = $1;
	} elsif ($col_type =~ /^numeric.*$/) {
		$return->{TYPE} = 'numeric';
		$return->{SIZE} = -1;
	} elsif ($col_type =~ /^text$/i) {
		$return->{TYPE} = $col_type;
		$return->{SIZE} = -1;
	} elsif ($col_type =~ /^timestamp/i) {
		$return->{TYPE} = 'timestamptz';
		$return->{SIZE} = 8 unless (exists $return->{SIZE} and int($return->{SIZE}) > 0);
	} else {
		$return->{TYPE} = $col_type;
	}

	return $return;
}

sub clean_column {
	my @return = @_;

	for my $index (0..$#return) {
		if ($return[$index]->{TYPE} =~ /^int(eger|4)$/) {
			$return[$index]->{TYPE} = 'integer';
		} elsif ($return[$index]->{TYPE} =~ /^(float8?|double precision)$/) {
			$return[$index]->{TYPE} = 'double precision';
		} elsif ($return[$index]->{TYPE} =~ /^(float4|real)$/) {
			$return[$index]->{TYPE} = 'real';
		} elsif ($return[$index]->{TYPE} =~ /^(bigint|int8)$/) {
			$return[$index]->{TYPE} = 'bigint';
		} elsif ($return[$index]->{TYPE} =~ /^(int2|smallint)$/) {
			$return[$index]->{TYPE} = 'smallint';
		} elsif ($return[$index]->{TYPE} =~ /^bool(ean)?$/) {
			$return[$index]->{TYPE} = 'boolean';
		} elsif ($return[$index]->{TYPE} =~ /^\s*character\s*$/) {
			$return[$index]->{TYPE} = 'character';
		} elsif ($return[$index]->{TYPE} =~ /(varchar|character varying)\((\d+)\)/i) {
			$return[$index]->{TYPE} = 'character varying';
		} elsif ($return[$index]->{TYPE} =~ /^\s*varchar\s*$/) {
			$return[$index]->{TYPE} = 'character varying';
		} elsif ($return[$index]->{TYPE} =~ /(char|character)\((\d+)\)/i) {
			$return[$index]->{TYPE} = 'bpchar';
		} elsif ($return[$index]->{TYPE} =~ /numeric\((\d+)\,\d+\)/i) {
			$return[$index]->{TYPE} = 'numeric';
		} elsif ($return[$index]->{TYPE} =~ /^numeric.*$/) {
			$return[$index]->{TYPE} = 'numeric';
		} elsif ($return[$index]->{TYPE} =~ /^text$/i) {
			$return[$index]->{TYPE} = $return[$index]->{TYPE};
		} elsif ($return[$index]->{TYPE} =~ /^timestamp/i) {
			$return[$index]->{TYPE} = 'timestamptz';
			$return[$index]->{SIZE} = 8 unless (exists $return[$index]->{SIZE} and int($return[$index]->{SIZE}) > 0);
		}
	}

	if (@return == 1) {
		return $return[0];
	} else {
		return @return;
	}
}

sub print_help {
	print <<END;
usage: $0 [-h] [-c] [-q] [-u user] [-p pass] /path/to/create.sql

   -h    this help

   -q    no questions (non-interactive, take defaults)
   -c    clear tables if they exist

   -d    name of the OpenNMS database to create/check
   -u    username for the OpenNMS database
   -p    password for the OpenNMS database
   -U    username of the PostgreSQL administrator
   -P    password of the PostgreSQL administrator
   -l    location of the OpenNMS postgresql libraries

END
	exit;
}

sub ask_question {
	my $question_text = "? " . shift;
	my $default       = shift;
	my $return;
 
	if ($default =~ /^(y|n)$/i) {
		# Yes/No Question
 
		my $prompt;
		$prompt = "Y/n" if ($default eq "y");
		$prompt = "y/N" if ($default eq "n");
 
		print $question_text, "  [$prompt] ";
		if ($VERBOSE) {
			chomp($return = <STDIN>);
		} else {
			print "\n";
		}
 
		$return = $default if ($return eq "");
 
		if ($return =~ /^y/i) {
			$return = 1;
		} else {
			$return = 0;
		}
 
	} else {
 
		$return = $default;
		$return = "none" if ($default eq "");
 
		print $question_text, "  [$return] ";
		if ($VERBOSE) {
			chomp($return = <STDIN>);
		} else {
			print "\n";
			$return = "";
		}

		$return = $default if ($return eq "");

	}

	return $return;
}

# subroutine: change_table
# function: update an entire table to a new schema
# input: a database handle to talk to, and the table name to change
# output: a true value on success, undef otherwise

sub change_table {
	my $database = shift;
	my $table    = shift;
	my $text;
	my @new_names;
	my @old_names;
	my $eventsource_index = -1;

	return 1 if (exists $CHANGED{$table});
	$CHANGED{$table} = 1;

	print "SCHEMA DOES NOT MATCH\n";

	my $db_cols   = get_table_from_db($table);
	my $sql_cols  = get_table_from_sql($table);
	my @db_cols   = @{$db_cols};
	my @sql_cols  = @{$sql_cols};
	my @db_names  = sort map { $_->{NAME} } @db_cols;
	my $columns;

	my $revert_table = sub {
		my $errormessage = shift;
		stderr_on();
		$database->do("DROP TABLE $table $CASCADE");
		$database->do("CREATE TABLE $table AS SELECT " . join(', ', @db_names) . " FROM temp");
		die "FAILED: $errormessage";
	};

	for my $column (@sql_cols) {
		$column->{NAME} = lc($column->{NAME});
		$columns->{$column->{NAME}} = $column;
		if ($column->{NOTNULL}) {
			if ($column->{NAME} eq "eventsource") {
				$columns->{$column->{NAME}}->{'null_replace'} = 'OpenNMS.Eventd';
			} elsif ($column->{NAME} eq 'svcregainedeventid' and $table eq 'outages') {
				$columns->{$column->{NAME}}->{'null_replace'} = 0;
			} elsif ($column->{NAME} eq 'eventid' and $table eq 'notifications') {
				$columns->{$column->{NAME}}->{'null_replace'} = 0;
			} else {
				$columns->{$column->{NAME}}->{'null_replace'} = '';
			}
		}
	}

	for my $column (@db_cols) {
		$column->{NAME} = lc($column->{NAME});
		my $name = $column->{NAME};
		if (exists $columns->{$name}) {
			if ($columns->{$name}->{TYPE} =~ /timestamp/ and $column->{TYPE} !~ /timestamp/) {
				$columns->{$name}->{'upgrade_timestamp'} = 1;
			}
		}
	}

	# This line throws a harmless error if the table doesn't exist (normally it shouldn't between upgrades)
	$database->do("DROP TABLE temp $CASCADE");

	print "  - creating temporary table... ";
	$text = "CREATE TABLE temp AS SELECT " . join(', ', @db_names) . " FROM $table";
	$database->do($text) or die "FAILED: unable to create temporary table $table (as 'temp'): " . $database->errstr;
	print "done\n";

	$database->do("DROP TABLE $table $CASCADE");

	print "  - creating new '$table' table... ";
	$text = "CREATE TABLE $table (" . get_table_from_sql($table, 1) . ")";
	unless ($database->do($text)) {
		&$revert_table("unable to create new table $table: " . $database->errstr);
	}
	print "done\n";

	# now we need to pull everything from the database and filter
	# it to update timestamps and other such things

	print "  - transforming data into the new table...\n";
	my ($sth, $insert);
	my $order = "";
	if ($table eq 'events') {
		$database->do("INSERT INTO events (eventid, eventuei, eventtime, eventsource, eventdpname,
		eventcreatetime, eventseverity, eventlog, eventdisplay) values (0,
		'http://uei.opennms.org/dummyevent', now(), 'OpenNMS.Eventd', 'localhost',
		now(), 1, 'Y', 'Y')");
	}
	$order = "ORDER BY iflostservice" if ($table eq "outages");
	my $dbcmd = "SELECT " . join(', ', @db_names) . " FROM temp $order";
	print "  - performing select: ", $dbcmd, "\n" if ($DEBUG);
	unless ($sth = $database->prepare($dbcmd)) {
		&$revert_table("unable to prepare select from temp: " . $database->errstr);
	}
	$dbcmd = "INSERT INTO $table (" . join(', ', sort keys %{$columns}) . ') values (' .  join(', ', map { '?' } keys %{$columns}) . ')';
	print "  - performing insert: ", $dbcmd, "\n" if ($DEBUG);
	unless ($insert = $database->prepare($dbcmd)) {
		&$revert_table("unable to prepare insert into $table: " . $database->errstr);
	}
	$sth->execute();
	$database->{AutoCommit} = 0;
	my $num_rows = $sth->rows;
	my $current_row = 0;
	if ($num_rows > 0) {
		while (my $row = $sth->fetchrow_hashref) {
			for my $key (keys %{$row}) {
				if ($key ne lc($key)) {
					$row->{lc($key)} = $row->{$key};
					delete $row->{$key};
				}
			}
			for my $key (keys %{$columns}) {
				if ($table eq 'outages' and $key eq 'outageid') {
					$row->{$key} = $current_row + 1;
				}
				if (exists $columns->{$key}->{'null_replace'}) {
					if (not defined $row->{$key}) {
						print "$key was NULL but is a NOT NULL column -- replacing with '", $columns->{$key}->{'null_replace'}, "'\n" if ($DEBUG);
						$row->{$key} = $columns->{$key}->{'null_replace'};
					}
				}
				if (defined $row->{$key}) {
					if ($columns->{$key}->{'upgrade_timestamp'}) {
						print "$key is an old-style timestamp\n" if ($DEBUG);
						my ($day, $month, $year, $hours, $minutes, $seconds) = $row->{$key} =~ /^(\d+)-(...)-(\d\d\d\d) (\d\d):(\d\d):(\d\d)$/;
					$month = lc($month);
					$month = $MONTHS{$month};
					my $newentry = sprintf('%04d-%02d-%02d %02d:%02d:%02d', $year, $month, $day, $hours, $minutes, $seconds);
						print $row->{$key}, " -> ", $newentry, "\n" if ($DEBUG);
						$row->{$key} = $newentry;
					}
					print $key, " = ", $row->{$key}, "\n" if ($DEBUG);
				} else {
					$row->{$key} = undef;
					print $key, " = undefined\n" if ($DEBUG);
				}
			}
			if (not $insert->execute(map { $row->{$_} } sort keys %{$columns})) {
				unless (
					$sth->errstr =~ /key referenced from $table not found in/ or
					$sth->errstr =~ /Cannot insert a duplicate key into unique index/
				) {
					&$revert_table("can't insert into $table: " . $sth->errstr);
				}
			}
			if (($current_row++ % 20) == 0) {
				print "  - transforming data into the new table... ", sprintf('%3d%%', ($current_row / $num_rows * 100)), "\n";
			}
		}
	}

	# Commit the changes and turn autocommit back on
	$database->commit;
	$database->{AutoCommit} = 1;

	print "  - transforming data into the new table... done     \n";

	print "  - dropping temporary table... ";
	$text = "DROP TABLE temp $CASCADE";
	$database->do($text) or die "FAILED: " . $database->errstr;
	print "done\n";

	print "  - completed updating table... ";
	return 1;
}

# subroutine: change_column
# function: change an existing column in the database
# input: a database handle to talk to, the table name to change
#   the column in, and a column hash structure (see parse_column)
# output: a true value on success, undef otherwise

sub change_column {
	my $database = shift;
	my $table    = shift;
	my $column   = shift;

	# move the old column out of the way
	my $text = "ALTER TABLE $table RENAME COLUMN $column->{NAME} TO $column->{NAME}_old";
	$database->do($text) or die "unable to rename column $column->{NAME} in table $table: " . $database->errstr;

	$text = "ALTER TABLE $table ADD COLUMN $column->{NAME} ";

	if ($column->{SIZE} >= 1) {
		if ($column->{TYPE} eq "numeric") {
			$text .= $column->{TYPE} . '(' . $column->{SIZE} . ',2)';
		} else {
			$text .= $column->{TYPE} . '(' . $column->{SIZE} . ')';
		}
	} else {
		$text .= $column->{TYPE};
	}

	$text .= " PRIMARY KEY" if ($column->{PRIMARY_KEY});
	$text .= " NOT NULL"    if ($column->{NOTNULL});

	if (not $database->do($text)) {
		my $error = $database->errstr;
		# put the column back  =)
		$database->do("ALTER TABLE $table RENAME COLUMN $column->{NAME}_old TO $column->{NAME}") or
	die "unable to add new column $column->{NAME} in table $table: " . $error;
	}

	# fill the new column with data
	$database->do("UPDATE $table SET $column->{NAME} = $column->{NAME}_old") or
	die "unable to populate new column with old values: " . $database->errstr;

	# delete the old column
	my $tabledata = get_table_from_db($table);
	my $columns;
	for my $col (map { $_->{NAME} } @{$tabledata}) {
		if (lc($col) ne lc("$column->{NAME}_old")) {
			$columns .= ", " if (defined $columns);
			$columns .= $col;
		}
	}

	$database->do("CREATE TABLE temp AS SELECT $columns FROM $table") or die "unable to create temporary table: " . $database->errstr;
	$database->do("DROP TABLE $table $CASCADE") or die "unable to drop old table: " . $database->errstr;
	my $new     = get_table_from_sql($table);
	my $newtext;
	for my $col (@{$tabledata}) {
		next if (lc($col->{NAME}) eq lc("$column->{NAME}_old"));
		$newtext .= ', ' if ($newtext ne '');
		$newtext .= $col->{NAME} . ' ' . get_columntype($col);
	}
	$database->do("CREATE TABLE $table ($newtext)") or die "unable to create new table: " . $database->errstr;
	$database->do("GRANT ALL ON $table TO $USER") or die(scalar $database->errstr);
	$database->do("INSERT INTO $table ($columns) SELECT $columns FROM temp") or die "unable to fill new table: " . $database->errstr;
	$database->do("DROP TABLE temp $CASCADE") or die "unable to drop temporary table: " . $database->errstr;

	return 1;
}

# subroutine: get_columntype
# function: return the normalized version of a column type
# input: a column object
# output: a string of the new column type

sub get_columntype {
	my @return;

	for my $column (@_) {
		my $text;
		($column) = clean_column($column);

		if ($column->{SIZE} >= 1) {
			if ($column->{TYPE} eq "numeric") {
				$text = $column->{TYPE} . '(' . $column->{SIZE} . ',2)';
			} else {
				$text = $column->{TYPE} . '(' . $column->{SIZE} . ')';
			}
		} else {
			$text = $column->{TYPE};
		}
		push(@return, $text);
	}

	if (@return == 1) {
		return $return[0];
	} else {
		return @return;
	}
}

# subroutine: get_column
# function: return the desired column from a list of column objects
# input: a column name, and an array of column objects
# output: the matching column object and the index it was found at

sub get_column {
	my $column_name = shift;
	my $index = 0;
	for my $column (@_) {
		if (lc($column->{NAME}) eq lc($column_name)) {
			return ($column, $index);
		}
		$index++;
	}
	return;
}

sub normalize_column {
	my $column = shift;

	return clean_column($column);
}

# subroutine: add_column
# function: add a new column to an existing table in the database
# input: a database handle to talk to, the table name to add
#   the column to, and a column hash structure (see parse_column)
# output: a true value on success, undef otherwise

sub add_column {
	my $database = shift;
	my $table    = shift;
	my $column   = shift;

	my $text   = "ALTER TABLE $table ADD COLUMN $column->{NAME} ";
		 $text  .= get_columntype($column);
		 $text  .= " PRIMARY KEY" if ($column->{PRIMARY_KEY});
		 $text  .= " NOT NULL"    if ($column->{NOTNULL});

	my $return = $database->do($text);
	if (not $return) {
		print STDERR "error adding column: " . $database->errstr . "\n";
	}
	return $return;
}

sub stderr_off {
	if (not $DEBUG) {
		open (OLDERR, ">&STDERR");
		open (STDERR, ">/dev/null");
	}
}

sub stderr_on {
	if (not $DEBUG) {
		close (STDERR);
		open (STDERR, ">&OLDERR");
		close (OLDERR);
	}
}
