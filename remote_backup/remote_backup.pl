#!/usr/bin/perl

# Author: Clemens Schwaighofer
# Date: 2004/06/23
# Description:
# Dumps the DB from the foreign host and makes a sync & bzip frmo the webroot
# History:
# 2013/11/14 (cs) update to strict + proper command line options
# 2005/10/17 (cs) mac & ccifj: moved login from root to the user, removed renault & careerjapan backups
# 2005/02/28 (cs) fixed another problem that could happen if the file was wrongly named, fixed that
# 2005/02/25 (cs) fixed a type :(
# 2005/02/24 (cs) added prefix for other downloads, removed all DB syncs for careerjapan, now down on the server and then rsync
# 2004/08/05 (cs) added more ...
# 2004/07/06 (cs) added delete for old files

use strict;
use warnings;

BEGIN
{
	use Date::Manip;
	use Time::Local;
	use Getopt::Long;
	use Time::HiRes qw(time);
	use POSIX qw(floor);
}

$| ++;

# test var
my $error = 0;
our $test = 0;
our $verbose = 0;
my %opt = ();
# add prompt bundeling (eg -qqq
Getopt::Long::Configure ("bundling");
# command line
my $result = GetOptions(\%opt,
	'verbose|v+' => \$verbose,
	'test' => \$test,
	'help|h|?'
) || exit 1;

# the structure with where/what/etc
#
my $mysqldump = '/usr/bin/mysqldump';
my $pgsqldump_all = '/usr/bin/pg_dumpall';
my $pgsqldump = '/usr/bin/pg_dump';
my $bzip2 = '/bin/bzip2';
my $rsync = '/usr/bin/rsync';
my $tar = '/bin/tar';

# log for rsync
my $rsync_log_file = '/var/log/rsync/remote_backup_rsync.log';
#my $rsync_log_file_format = '%o %i [%B:%4U:%4G] %f%L [--> %l => %b]';
my $rsync_log_file_format = "%o %i [%B:%4U:%4G] %f%L [--> %'l {%''l} => %'b {%''b}]";

my $day_seconds = 86400; # seconds of one day (24 * 60 * 60)

# what to backup
my @backups = (
	# PEM SYNC
	{
		"type" => 'rsync',
		"name" => "<some name>"
		"server" => "<host name>"
		"rsync" => "/remote/folder",
		"user" => "<login user>",
		"sshkey" => "<PEM file>", # the -i key to use
		"pass" => "",
		"path" => "/local/backup/target/",
		"remote_data" => "delete", # flag remote data for delete
		"remote_lock" => "/path/to/delete_trigger.lock"
	},
	## SSH KEY SYNC
	{
		"type" => 'rsync',
		"name" => "<other name>",
		"server" => "<host name",
		"rsync" => "/remote/folder",
		"user" => "<login user>",
		"pass" => "",
		"path" => "/local/backup/target/",
		"keep" => "4"
	}
);

sub now
{
	# not today, now, today is only date
	return UnixDate("now", "%Y-%m-%d %T");
}

sub convert_time
{
	my ($timestamp, $show_micro) = @_;
	my $ms = '';
	# cut of the ms, but first round them up to four
	$timestamp = sprintf("%.4f", $timestamp);
	($timestamp, $ms) = split(/\./, $timestamp);
	my @timegroups = ("86400", "3600", "60", "1");
	my @output = ();
	for (my $i = 0; $i < @timegroups; $i ++)
	{   
		push(@output, floor($timestamp / $timegroups[$i]));
		$timestamp = $timestamp % $timegroups[$i];
	}
	# output has days|hours|min|sec
	return (($output[0]) ? $output[0]."d " : "").(($output[1] || $output[0]) ? $output[1]."h " : "").(($output[2] ||$output[1] || $output[0]) ? $output[2]."m " : "").$output[3]."s".(($show_micro) ? " ".((!$ms) ? 0 : $ms)."ms" : "");
}

my $start_time = now();
my $start = time();

print "START remote backup run\n";
print "--------------------------------------------------------------------------->\n";

for my $backup (@backups)
{
	my $start_run = time();
	# start flow
	print "[".now()."] Flow START for ".$backup->{'name'}."\n";
	# lock for current flow, so no two run at the same time the same flows (lock is per server)
	my $lock_file = '/tmp/remote_backup.'.$backup->{'server'}.'.lock';
	if (-f $lock_file)
	{
		print "Lock file ($lock_file) already exists. Process is running or lock file is still existing\n";
	}
	else
	{
		# lock file
		`touch $lock_file`;
		my $date;
		chop($date = `date +%Y%m%d`);
		# download/dump remote database, compress and check for keep data
		if ($backup->{'type'} eq 'mysql' || $backup->{'type'} eq 'pgsql')
		{
			print "[".now()."] Working on ".$backup->{'name'}." from ".$backup->{'server'}." for database: ".(($backup->{'db'}) ? $backup->{'db'} : 'ALL')."\n";
			# check if we have old files in here that have to be cleaned
			# open the dir
			opendir(DIR, $backup->{'path'}) || die ("Can't open ".$backup->{'path'}."\n");
			my $fn_part = (($backup->{'db'}) ? $backup->{'db'} : 'all').$backup->{'type'};
			foreach my $filename (sort grep/$fn_part/, readdir(DIR))
			{
				if ( -f $backup->{'path'}.$filename )
				{
					# get the date from the filename, if its older than the keep date remove it
					# each file is name_date.endings
					my $filename =~ /\w_(\d{4})(\d{2})(\d{2})\./;
					# timestamp for that date
					my $filename_time = timelocal(0, 0, 0, $3, ($2 - 1), $1);
					if ((time() - $filename_time) > ($day_seconds * $backup->{'keep'}))
					{
						print "[".now()."] Delete file: ".$backup->{'path'}.$filename."\n";
						# remove the file, its older than the keep time
						unlink $backup->{'path'}.$filename if (!$test);
					}
				}
			}
			closedir(DIR);
			
			# the backup filename
			my $dumpname = (($backup->{'db'}) ? $backup->{'db'} : 'all').'_'.$backup->{'type'}.'_'.$date.'.bk.sql';
			my $dumpfile = $backup->{'path'}.$dumpname;
			# connect to the db and pipe the data to the log file
			my $user = $backup->{'user'};
			my $pass = $backup->{'pass'};
			my $name = $backup->{'db'};
			my $server = $backup->{'server'};
			my $error;
			if (! -f $dumpfile.".bz2")
			{
				# depending on the DB we have to call different dumps
				if ($backup->{'type'} eq 'mysql')
				{
					if ($backup->{'db'})
					{
						print "[".now()."] Command: $mysqldump -u $user -h $server -p$pass --create-options --add-drop-table $name >$dumpfile\n";
						$error = `$mysqldump -u $user -h $server -p$pass --create-options --add-drop-table $name >$dumpfile` if (!$test);
					}
					else
					{
						print "[".now()."] Command: $mysqldump -u $user -h $server -p$pass --create-options --add-drop-table --add-drop-database -A >$dumpfile\n";
						$error = `$mysqldump -u $user -h $server -p$pass --create-options --add-drop-table --add-drop-database -A >$dumpfile` if (!$test);
					}
					# check if the dump file is okay, or has this mysql error msg
					# mysqldump: Got error: 1129: Host 'obelix.tequila.jp' is blocked because of many connection errors.  Unblock with 'mysqladmin flush-hosts' when trying to connect
					# TODO
				}
				elsif ($backup->{'type'} eq 'pgsql')
				{
					if ($backup->{'db'})
					{
						print "[".now()."] Command: $pgsqldump -U $user -h $server -c -f $dumpfile $name\n";
						$error = `export PGPASSWORD='$pass'; $pgsqldump -U $user -h $server -c -f $dumpfile $name; export PGPASSWORD=;` if (!$test);
					}
					else
					{
						print "[".now()."] Command: $pgsqldump_all -U $user -h $server -c >$dumpfile\n";
						$error = `export PGPASSWORD='$pass'; $pgsqldump_all -U $user -h $server -c >$dumpfile; export PGPASSWORD=;` if (!$test);
					}
				}
				print "[".now()."] $bzip2 $dumpfile";
				`$bzip2 $dumpfile` if (!$test);
			}
			else
			{
				print "[".now()."] $dumpfile already exists. Skipping\n";
			}
		}
		# download remote data, compress/tar it, and check for old to delete
		elsif ($backup->{'webroot'})
		{
			print "[".now()."] Working on ".$backup->{'name'}." from ".$backup->{'server'}." to ".$backup->{'webroot'}."\n";
			# check if we have old files in here that have to be cleaned
			# open the dir
			opendir(DIR, $backup->{'path'}) || die ("Can't open ".$backup->{'path'}."\n");
			my $prefix = ($backup->{'prefix'}) ? $backup->{'prefix'}.'_' : 'wwwroot_';
			foreach my $filename (sort grep/^$prefix/, readdir(DIR))
			{
				if ( -f $backup->{'path'}.$filename )
				{
					# get the date from the filename, if its older than the keep date remove it
					# each file is name_date.endings
					$filename =~ /\w_(\d{4})(\d{2})(\d{2})\./;
					if ($1 && $2 && $3)
					{
						# timestamp for that date
						my $filename_time = timelocal(0, 0, 0, $3, ($2 - 1), $1);
						if ((time() - $filename_time) > ($day_seconds * $backup->{'keep'}))
						{
							print "[".now()."] Delete file: ".$backup->{'path'}.$filename."\n";
							# remove the file, its older than the keep time
							unlink $backup->{'path'}.$filename if (!$test);
						}
					}
					else
					{
						print "[".now()."] Couldn't get full date, no file deleted!\n";
					}
				}
			}
			closedir(DIR);
		
			# we create the backup dir for that set
			my $path = $backup->{'path'}.$prefix.$date.'/';
			my $webroot = $backup->{'webroot'};
			my $backupfile = $backup->{'path'}.$prefix.$date.'.tar.bz2';
			my $login = $backup->{'user'}.'@'.$backup->{'server'};
			if (! -f $backupfile)
			{
				print "[".now()."] mkdir $path\n";
				# set the ssh key file if it is needed
				my $sshkey = $backup->{'sshkey'} ? " -i /root/.ssh/".$backup->{'sshkey'} : '';
				`mkdir $path` if (!$test);
				# please see the rsync man page for description of flags
				print "[".now()."] Command: $rsync -Plzvruptog -hh --log-file=$rsync_log_file --log-file-format=\"$rsync_log_file_format\" --stats -e \"ssh$sshkey\" $login:$webroot* $path\n";
				`$rsync -Plzvruptog -hh --log-file=$rsync_log_file --log-file-format="$rsync_log_file_format" --stats -e \"ssh$sshkey\" $login:$webroot* $path` if (!$test);
				# make a bzip2 from the parth
				print "[".now()."] Command: $tar cvfj $backupfile $path\n";
				`$tar cvfj $backupfile $path` if (!$test);
				# cleanup dir
				print "[".now()."] Command: rm -rf $path";
				`rm -rf $path` if (!$test);
			}
			else
			{
				print "[".now()."] $backupfile already exists. Skipping\n";
			}
		}
		# rsync data only [recommended]
		elsif ($backup->{'rsync'})
		{
			print "[".now()."] Working on ".$backup->{'name'}." from ".$backup->{'server'}." to ".$backup->{'rsync'}."\n";
			# check if we have old files in here that have to be cleaned
			# open the dir
			opendir(DIR, $backup->{'path'}) || die ("Can't open ".$backup->{'path'}."\n");
			# we create the backup dir for that set
			my $path = $backup->{'path'}.'/';
			my $root = $backup->{'rsync'};
			my $login = $backup->{'user'}.'@'.$backup->{'server'};
			# set the ssh key file if it is needed
			my $sshkey = $backup->{'sshkey'} ? " -i /root/.ssh/".$backup->{'sshkey'} : '';
			# please see the rsync man page for description of flags
			print "[".now()."] Command: $rsync -Plzvruptog -hh --delete --log-file=$rsync_log_file --log-file-format=\"$rsync_log_file_format\" --stats -e \"ssh$sshkey\" $login:$root* $path\n";
			`$rsync -Plzvruptog -hh --delete --log-file=$rsync_log_file --log-file-format="$rsync_log_file_format" --stats -e \"ssh$sshkey\" $login:$root* $path` if (!$test);
			# if we have remote data delete, delete all data in the remote folders, but keep the folders itself
			if (defined($backup->{'remote_backup'}) && $backup->{'remote_data'} eq 'delete')
			{
				if (defined($backup->{'remote_lock'}))
				{
					my $remote_lock = $backup->{'remote_lock'};
					# all data in $login:$root
#					print "[".now()."] Command: ssh$sshkey $login \"find $path -type f -delete -print\"\n";
#					`ssh$sskey $login "find $path -type f -delete -print"` if (!$test);
					# user has perhaps no rights. touch a file on the remote side where then a script checks this file and cleans up the data
					print "[".now()."] Command: ssh$sshkey $login \"touch $remote_lock\"\n";
					`ssh$sshkey $login "touch $remote_lock"` if (!$test);
				}
				else
				{
					print "Missing remote lock file entry\n";
				}
			}
		}
		# remove lock file
		if (-f $lock_file)
		{
			unlink($lock_file);
		}
	} # locked or not locked
	my $end_run = time();
	print "[".now()."] Flow end for ".$backup->{'name'}.". Run time: ".convert_time($end_run - $start_run, 1)."\n";
	print "--------------------------------------------------------------------------->\n";
}

my $end = time();
print "Start: ".$start_time.", End: ".now().". Run Time: ".convert_time($end - $start, 1)."\n";

__END__
