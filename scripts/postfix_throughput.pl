#!/usr/bin/perl

#####################################################################
# AUTHOR: Clemens Schwaighofer
# DATE: 2013/8/8
# DESC: parses through a log file and creates throughput for the data in this file
# - overall average throughput of sent/error
# - per day/hour/minute/second throughput as log data/graph output
#####################################################################

use strict;
use warnings;

BEGIN
{
	$Date::Manip::Backend = 'DM6';
	use Getopt::Long;
	use Date::Manip;
	use Number::Format qw(format_number);
}

$| ++;

my %opt = ();
our $verbose = 0;
my $print_per_minute = 0;
my $start;
my $end;
# add prompt bundeling (eg -qqq
Getopt::Long::Configure ("bundling");
# command line
my $result = GetOptions(\%opt,
	'verbose|v+' => \$verbose,
	'print-per-minute' => \$print_per_minute,
	'start=s' => \$start,
	'end=s' => \$end,
	'help|h|?',
) || exit 0;

if ($opt{'help'})
{
	print "This script parses data from the STDIN.\n\n";
	print "cat postfix.mail.log | ./postfix_throughput.pl\n\n";
	print "Options:\n";
	print "--verbose | -v [--verbose | -v] \tProgress output, if verbose is given twice then per entry data is print out\n";
	print "--start <start timestamp>\tFind data from this time date: YYYY-MM-DD HH:MM:SS\n";
	print "--end <end timestamp>\tFind data until this time date: YYYY-MM-DD HH:MM:SS\n";
	print "--print-per-minute\tPrint detail stats not oonly for per hour, but also per minute\n";
}

my $error = 0;
exit 0 if ($error);

print "Reading in data from STDIN\n";
# set this years year
my $year = UnixDate(ParseDateString("now"), "%Y");
my %delivered = ();
my %delivered_time = ();
my %rejects = ();
my $start_time = 0;
my $end_time = 0;
my $time_frame = 0;
my $calc_time_frame = 0;
my $date;
my $last_time;
my $dot_time = 60; # in seconds
my $show_time = 0;
my $date_regex = qr/^(\w{3})\s{1}\s?(\d?\d{1})\s{1}(\d{2}:\d{2}:\d{2}) /;
# read from stdin
while (<STDIN>)
{
	my $line = $_;
	chomp ($line);
	my $go = 0;

	# line start Aug  8 10:17:35 is needed for time grouping
	$line =~ $date_regex;
	# convert that date into a proper timestamp that we can use
	$date = UnixDate(ParseDate($2.'/'.$1.'/'.$year.' '.$3), "%Y-%m-%d %T");
	my ($per_day, $hour, $minute, $second) = split(/[ :]/, $date);
	my $per_hour = $per_day.' '.$hour;
	my $per_minute = $per_day.' '.$hour.':'.$minute;
	my $per_second = $per_day.' '.$hour.':'.$minute.':'.$second;
	$start_time = UnixDate(ParseDate($date), "%s") if (!$start_time);
	$go = 1 if (!$start && !$end);
	$go = 1 if ($start && Date_Cmp(ParseDate($start), ParseDate($date)) <= 0 && !$end);
	$go = 1 if ($end && Date_Cmp(ParseDate($end), ParseDate($date)) >= 0 && !$start);
	$go = 1 if ($end && $start && Date_Cmp(ParseDate($start), ParseDate($date)) <= 0 && Date_Cmp(ParseDate($end), ParseDate($date)) >= 0);
	# this is just for the visual output, we print something out every 60 seconds of processing time
	if (!$last_time || (time() - $last_time) >= $dot_time)
	{
		$last_time = time();
		$show_time = 1;
	}
	else
	{
		$show_time = 0;
	}
	# if no go and verbose, print out . only
	if (!$go)
	{
		print "." if ($verbose >= 1 && $show_time);
	}
	else
	{
		# find delivered & error mails
		if ($line =~ /([\w-]*)\/qmgr.*from=.*size=[0-9]*/ ||
			$line =~ /([\w-]*)\/smtp.* status=sent /)
		{
			print "+" if ($verbose >= 1 && $show_time);
			$delivered{$1} ++;
			print "HOST: $1: DELV: ".$delivered{$1}."\n" if ($verbose >= 2);
			# per day/hour/minute
			$delivered_time{'per_day'}{$per_day}{$1} ++;
			$delivered_time{'per_hour'}{$per_hour}{$1} ++;
			$delivered_time{'per_minute'}{$per_minute}{$1} ++;
#			$delivered_time{'per_second'}{$per_second}{$1} ++;
		}
		elsif ($line =~ /([\w-]*)\/smtpd.*reject: \S+ \S+ \S+ (\S+)/ ||
			   $line =~ /([\w-]*)\/cleanup.* reject: (\S+)/)
		{
			print "-" if ($verbose >= 1 && $show_time);
			$rejects{$1}{$2} ++;
			print "HOST: $1: ERR: $2: ".$rejects{$1}{$2}."\n" if ($verbose >= 2);
		}
		else
		{
			print ":" if ($verbose >= 1 && $show_time);
		}
	}
}
$end_time = UnixDate(ParseDate($date), "%s");
$time_frame = $end_time - $start_time;
print "\n" if ($verbose >= 1);
print "From: ".UnixDate(ParseDateString("epoch ".$start_time), "%Y-%m-%d %T")." to ".UnixDate(ParseDateString("epoch ".$end_time), "%Y-%m-%d %T")."\n";
print "Selected Time" if ($start || $end);
print " From: ".$start if ($start);
print " to: ".$end if ($end);
print "\n" if ($start || $end);
$calc_time_frame = $time_frame if (!$start && !$end);
$calc_time_frame = $end_time - UnixDate(ParseDate($start), "%s") if ($start && !$end);
$calc_time_frame = UnixDate(ParseDate($end), "%s") - $start_time if (!$start && $end);
$calc_time_frame = UnixDate(ParseDate($end), "%s") - UnixDate(ParseDate($start), "%s") if ($start && $end);

my $count_sum = 0;
print "Delivered:\n";
foreach my $host (sort keys %delivered)
{
	print " - $host: ".format_number($delivered{$host})." (".format_number(sprintf("%.3f", $delivered{$host} / ($calc_time_frame / 60)))." mails/m, ".sprintf("%.3f", $delivered{$host} / $calc_time_frame)." mails/s)\n";
	$count_sum += $delivered{$host};
}
print " + Sum: ".format_number($count_sum)." (".format_number(sprintf("%.3f", $count_sum / ($calc_time_frame / 60)))." mails/m, ".sprintf("%.3f", $count_sum / $calc_time_frame)." mails/s)\n";
$count_sum = 0;
my $error_out = '';
foreach my $host (sort keys %rejects)
{
	foreach my $err (sort keys %{$rejects{$host}})
	{
		$error_out .= " - $host, $err: ".format_number($rejects{$host}{$err})."\n";
		$count_sum += $rejects{$host}{$err};
	}
}
if ($count_sum)
{
	print "Error:\n";
	print $error_out;
	print " + Sum: ".format_number($count_sum)."\n";
}

# this is temporary output
print "Per hour output\n";
foreach my $time (sort keys %{$delivered_time{'per_hour'}})
{
	$count_sum = 0;
	print " * Time: $time:00:00\n";
	foreach my $host (sort keys %{$delivered_time{'per_hour'}{$time}})
	{
		print "   - ".$host.": ".format_number($delivered_time{'per_hour'}{$time}{$host})." (".format_number(sprintf("%.3f", $delivered_time{'per_hour'}{$time}{$host} / 60))." mails/m, ".sprintf("%.3f", $delivered_time{'per_hour'}{$time}{$host} / (60 * 60))." mails/s)\n";
		$count_sum += $delivered_time{'per_hour'}{$time}{$host};
	}
	print "   + Sum: ".format_number($count_sum)." (".format_number(sprintf("%.3f", $count_sum / 60))." mails/m, ".sprintf("%.3f", $count_sum / (60 * 60))." mails/s)\n";
}
# Only show if requested
if ($print_per_minute)
{
	print "Per minute output\n";
	foreach my $time (sort keys %{$delivered_time{'per_minute'}})
	{
		$count_sum = 0;
		print " * Time: $time:00\n";
		foreach my $host (sort keys %{$delivered_time{'per_minute'}{$time}})
		{
			print "   - ".$host.": ".format_number($delivered_time{'per_minute'}{$time}{$host})." (".format_number(sprintf("%.3f", $delivered_time{'per_minute'}{$time}{$host} / 60))." mails/s)\n";
			$count_sum += $delivered_time{'per_minute'}{$time}{$host};
		}
		print "   + Sum: ".format_number($count_sum)." (".format_number(sprintf("%.3f", $count_sum / 60))." mails/s)\n";
	}
}
__END__
