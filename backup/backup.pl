#!/usr/bin/perl

# = Subversion Data ===================================================
# $HeadURL: svn://svn:3691/somen.tokyo.tequila.jp/dirs/usr/local/scripts/backup/backup.pl $
# $LastChangedBy: root $
# $LastChangedDate: 2013-04-09 10:44:32 +0900 (Tue, 09 Apr 2013) $
# $LastChangedRevision: 1623 $
# = Subversion Data ===================================================

# AUTHOR: Clemens Schwaighofer
# DATE: in 2002/12/01
# LAST CHANGE: 2004/08/04
# DESCRIPTION:
# Makes backup from a folders in gzip or bzip2. full or incremental

# creates bk dir mit date yesterday and copys all from bk_array into this dir
# keeps directories as said in config, checks free disk on share, if < than last backup, 
# deletes the oldest (if exists), else writes mail to admin

# to do
# delete or some other action when disk is full (so it doesn't just drop out and doesn't make any backup at all) [2003/02/18 still no happy way found for this must-delete-secnario]

# last changes:
# 2004/08/04 (cs) flag for find, so I can switch descent into foreign FS on or off (xdev)
# 2004/07/08 (cs) added function for calculating down the size
# 2004/07/06 (cs) bug with -type f fixed: doesn't store symlinks, uses -xtype f now
#                 added "exclude" feature for tar per backup dir
# 2004/06/14: split main code and config vars and moved config vars into 
#			  external file
# 2003/02/19: small bug when delete files: I removed the set from the hash && 
#             in the if removed one additionl ($del_count), removed $del_count
# 2003/02/17: added output if no files will be deleted, just for info
# 2003/02/13: complete rewrite for better handle of file deletes
# 2002/12/27: typoooo!!! ."$var instead of ".$var ... my god, I am so fucked up
# 2002/12/26: forgot complete path, that's why he didn't delete any files
# 2002/12/20: updated delete old files so it also works for incr backups
# 2002/12/12: added delete old full bk files
# 2002/12/05: complete rewrite for incr & full bk

use strict;
use warnings;

BEGIN
{
	use Number::Format qw(:subs);
	use File::Basename;
	use Getopt::Long;
	use Time::HiRes qw(time);
	use POSIX qw(floor);
	unshift(@INC, File::Basename::dirname($0).'/');
}

my %opt = ();
my $backup_incr = 0;
my $backup_full = 0;
#my $verbose = 0;
my $debug = 0;
my $test = 0;
# add prompt bundeling (eg -qqq
Getopt::Long::Configure ("bundling");
# command line
my $result = GetOptions(\%opt,
	'incr' => \$backup_incr,
	'full' => \$backup_full,
#	'verbose|v+' => \$verbose,
	'debug' => \$debug, # show debug messages
	'test' => \$test, # no insert, just test
	'help' # just help
	) || exit 1;

if ((!$backup_incr && !$backup_full) || $opt{'help'})
{
	print "No argument given, or wrong argument. Please set either --full or --incr for backup type\n";
	print "Set --test for test run without doing any backup\n";
	exit 0;
}

# get the data for the DB login
use backup_config;

# name parts 
my $backup_name_full = 'full'; # pre part for naming files
#chop($free=`df | grep $config::backup_device | awk '{print \$4}'`);
my $backup_name_incr = 'incr';
# normal vars
my $bk_name; # file name for backuping
my $bk_sub_name; # var holder for pre part (full, incr)
my $bk; # each @backup directory
my @dirparts; # splitting up the backup directory for the last part for building bk file name
my %files; # hash that keeps all bk file names (grouped in date)
my $count_bk; # amount of bks files found on device
my $backup_file; # the final COMPLETE bk file name for the bk cmd
my $backup_file_acl; # the final COMPLETE bk file name for the ACL bk cmd
my $name; # a file name in the check full for delete loop
my $timestamp_day = 86400; # one day in seconds
my $keep_full = 0; # keep how many full backups ...
my $keep_incr = 6; # keep one week of incremental files ...
my $keep_bk; # summary var for keep_full & keep_incr
my $free; # free disk space on bk device
my $used; # used disk space on bk device
my $backup_timeframe = '-mtime -1'; # default bk type is full
my $size = 0; # diskfree size counter
my $date; # those 3 are for the split for files_detail
my $temp; # temp for all temp stuff 
my $tmp_file; # temporary file name for the -X flag
my $exclude; # one exclude
my $tar_flags; # flags for tar
my $tar_compress_flag; # compress flag for tar
my $find_flags; # flags for find

# override default keep count settings
$keep_full = $config::keep_full if ($config::keep_full =~ /\d+/ && $keep_full != $config::keep_full);
$keep_incr = $config::keep_incr if ($config::keep_incr =~ /\d+/ && $keep_incr != $config::keep_incr);
# check full/incremental and set vars
if ($backup_incr)
{
	$bk_sub_name = $backup_name_incr;
	$keep_bk = $keep_incr;
}
elsif ($backup_full)
{
	$backup_timeframe = ''; # unset the day time frame full backup
	$bk_sub_name = $backup_name_full;
	$keep_bk = $keep_full;
}

# check that the compress_type is set either to gzip or bzip2, if not set to gzip
$config::compress_type = 'gzip' if ($config::compress_type ne 'gzip' && $config::compress_type ne 'bzip2');
if ($config::compress_type eq 'gzip')
{
	$tar_compress_flag = '-z';
}
elsif ($config::compress_type eq 'bzip2')
{
	$tar_compress_flag = '-j';
}

# check that full and incr used default data is set correct
# this is only needed for the first run, other runs will use file size
# data is in kilobytes
$config::full_used = 2300000 if ($config::full_used !~ /\d+/);
$config::incr_used = 60000 if ($config::incr_used !~ /\d+/);

# creates a prober date (YYYY-MM-DD) out of perl time
sub create_date
{
	my($year,$month,$day) = @_;
	$year += 1900;
	$month++;
	$month = "0".$month if ($month < 10); 
	$day = "0".$day if ($day < 10); 
	return $year."-".$month."-".$day;
}

# gets the date from the shell
sub get_datetime
{
	my $temp;
	chop($temp = `date +'%Y-%m-%d %H:%M:%S'`);
	return $temp;
}

#perl round substitute
# returns free space device
sub df_free
{
	my ($device) = @_;
	my $free;
	chop($free = `df -P | grep $device | awk '{print \$4}'`);
	return $free;
}

# converts KB to MB, etc
sub convert_number
{
	my ($number) = @_;
	my @labels = ('KB', 'MB', 'GB', 'TB'); # the labels
	my $pos = 0; # the original position in the labels array
	my $number_string = ''; # the return string
	# so it is 0
	if (!$number)
	{
		$number = 0;
	}
	# if $convert is set, then check the length of the var
	# divied number until its division would be < 1024. count that and make the right MB, GB guess.
	if ($number >= 1024)
	{
		while (($number / 1024) >= 1)
		{
			$number = $number / 1024;
			# move up one level in the labels
			$pos ++;
		}
	}
	my $comma = $pos == 0 ? '%.0f' : '%.2f';
	# before we return it, we format it [rounded to 2 digitas]
	$number = format_number(sprintf($comma, $number));
	# we add the right label to it and return it
	return $number." ".$labels[$pos];
}

# make time from seconds string
sub convert_time
{
	my ($timestamp, $show_micro) = @_;
	my $ms = '';
	# cut of the ms, but first round them up to four
	$timestamp = sprintf("%.4f", $timestamp);
	#print "T: ".$timestamp."\n";
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

# start time
my $start_time = time();
print uc($bk_sub_name)." Backup started at ".get_datetime()." ...\n";

# check for full or incr backups and already one or more full or incr set exists remove it
# get groups, group is x (where x is all to one day fitting either incr or full)
undef($name);
opendir(DIR, $config::backup_target) || die ("Cannot open backup target: ".$config::backup_target."\n");
# sorting in other direction as we start from the end when we delete files ...
foreach my $name (sort {uc($b) cmp uc($a)} grep /$bk_sub_name/, readdir(DIR))
{
	my $date;
	# split up each file to get date)
	($temp, $date, $temp) = split(/_/,$name);
	print "DATE: $date => $name\n" if ($debug);
	# store in a hash type -> date -> number of files (file name)
	push(@{$files{$date}}, $name);
}
closedir(DIR);

# if there are more then we want to keep
if ((keys %files) > $keep_bk)
{
	print "Found ".(keys %files)." Filegroups, Keep Files is set to $keep_bk. Will delete ".((keys %files) - $keep_bk)." file group(s) ...\n";
	# for each date, delete files ...
	foreach $date (sort {$a cmp $b} keys %files)
	{
		# ... but only keep limit is reached
		if ((keys %files) > $keep_bk)
		{
			print "Found ".@{$files{$date}}." files for date $date ...\n";
			foreach $name (@{$files{$date}})
			{
				print "Deleting file ".$config::backup_target.$name."\n";
				unlink($config::backup_target.$name) || print "Failed to unlink '$name': $!\n" if (!$test);
			}
			# remove that file group from the file list
			delete ($files{$date});
		} # is limit reached
	} # for each date
}
else
{
	print "Found ".(keys %files)." Filegroups, Keep Files is set to $keep_bk. No files will be deleted ...\n";
}

# if something found (and summarized) calculate average, else check if minimum free (guess)
if (%files)
{
	# getting last backup size (full if full, else incr)
	# get all incr/full sizes available, and calucalte average from it
	foreach my $date (keys %files)
	{
		foreach my $name (@{$files{$date}})
		{
			if ((stat($config::backup_target.$name))[7])
			{
				$size += (stat($config::backup_target.$name))[7];
			}
		}
	}
	# size is in bytes, but free is in kbyes ...
	$used = (($size / (keys %files)) / 1024);
}
else
{
	# set an minimum used (in Kb)
	if ($bk_sub_name eq 'full')
	{
		$used = $config::full_used;
	}
	else
	{
		$used = $config::incr_used;
	}
}

# now check free space on that share ...
$free = df_free($config::backup_device);

# if not enough space left ... delete the oldest ...
if ($used && $free)
{
	if ($free > $used)
	{
		print "Enough free disk space.\n".convert_number($free)." free disk space, estimated use will be ".convert_number($used)."\n"; 
	}
	else
	{
		# check first the selected set (full on full day eg)
		# if old set(s) exists delete filegroups until free>used
		# if delete of file groups is finished and still not free>used
		# switch to opposite group (incr on full eg) and delete from 
		# old set until free>used
		# if still not enought free, die ...
		if (%files)
		{    
			die "ERROR: Died on ".get_datetime()."\nActually I would have delete some files from ".uc($bk_sub_name)." set.\nUsed: ".convert_number($used).", Free: ".convert_number($free)."\n";
		}
		else
		{
			# here should be the delete and not the die msg ...
			die "ERROR: Died on ".get_datetime()."\nNot enough disk free and no old backup files that could be deleted.\nUsed: ".convert_number($used).", Free: ".convert_number($free)."\n";
		}
	}
}

# create name for bk dir
chop($bk_name = $bk_sub_name."_".`date +%Y-%m-%d`);
#print $bk_name."\n";

foreach my $bk (@config::backup)
{
	# check if we have excludes for this dir, if yes make a temp file for tar
	if ($config::excludes{$bk} && @{$config::excludes{$bk}} > 0)
	{
		# create a tmp file name
		$tmp_file = '/tmp/'.rand(99999).'.tmp';
		# open temp file
		open(FH, ">", $tmp_file);
		foreach my $exclude (@{$config::excludes{$bk}})
		{
			print FH $exclude."\n";
		}
		# close temp file
		close (FH);
		# the tag for tar
		$tar_flags = $tar_compress_flag.' -X '.$tmp_file;
	}
	else
	{
		$tar_flags = $tar_compress_flag;
	}
	# avoid one calls
	if ($config::ext_fs{$bk})
	{
		$find_flags = '';
	}
	else
	{
		$find_flags = '-xdev';
	}
	#get the last part of the dir
	@dirparts = split(/\//, $bk);
	$backup_file = $config::backup_target.$bk_name."_".$dirparts[$#dirparts].".tar.gz";
	# had j before, but bzip2 is too slow
	print "Backuping $bk to ".$backup_file." ...\n";
	# check if acl dump is requested, if yes, predump ACL data into separate file
	if (grep {$_ eq $bk} @config::acl_dump)
	{
		$backup_file_acl = $config::backup_target.$bk_name."_".$dirparts[$#dirparts]."_acl.gz";
		`find $bk $find_flags $backup_timeframe -xtype f | getfacl - | gzip -c -f >$backup_file_acl` if (!$test);
		print "find $bk $find_flags $backup_timeframe -xtype f | getfacl - | gzip -c -f >$backup_file_acl\n" if ($test);
	}
	# fine only files, don't descent into xternal devices
	`find $bk $find_flags $backup_timeframe -xtype f | tar -cip $tar_flags -f $backup_file -T - ` if (!$test);
	print "find $bk $find_flags $backup_timeframe -xtype f | tar -cip $tar_flags -f $backup_file -T - \n" if ($test);
	# remove the tmp file if set
	if ($tmp_file)
	{
		unlink $tmp_file;
		$tmp_file = '';
	}
	# check if not exists create (touch) ?
	if (! -e $backup_file)
	{
		`touch $backup_file` if (!$test);
		`touch $backup_file_acl` if (!$test);
	}
}

print uc($bk_sub_name)." Backup finished at ".get_datetime()." and run for ".convert_time(time() - $start_time, 1).", free space now is ".convert_number(df_free($config::backup_device)).".\n";

__END__

# $Header: svn://svn:3691/somen.tokyo.tequila.jp/dirs/usr/local/scripts/backup/backup.pl 1805 2013-10-02 02:58:53Z root $
