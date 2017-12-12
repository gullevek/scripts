#!/usr/bin/perl

# AUTHOR: Clemens Schwaighofer
# DATE: 2009/6/10
# DSCRIPTION
# simple script to check if the CSV file is valid, eg has valid seperators
# line breaks, etc

use strict;
use warnings;
use utf8;

BEGIN
{
	use POSIX qw(floor);
	use Text::CSV_XS;
	use Getopt::Long;
	use Unicode::Japanese;
	use Time::HiRes qw(time);
	use File::Basename;
	use IO::File;
	use Number::Format qw(format_number);
	unshift(@INC, File::Basename::dirname($0).'/');
}

# converts bytes to human readable format
sub byte_format
{
	my ($number) = @_;
	my $pos; # the original position in the labels array
	# divied number until its division would be < 1024. count that position for label usage
	for ($pos = 0; $number > 1024; $pos ++)
	{
		$number = $number / 1024;
	}
	# before we return it, we format it [rounded to 2 digits, if has decimals, else just int]
	# we add the right label to it and return
	return sprintf(!$pos ? '%d' : '%.2f', $number)." ".qw(B KB MB GB TB PB EB)[$pos];
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

# get a timestamp and create a proper formated date/time field
sub create_time
{
	my ($timestamp, $show_micro) = @_;
	my $ms = '';
	$timestamp = 0 if (!$timestamp);
	# round ms to 4 numbers
	$timestamp = sprintf("%.4f", $timestamp);
	($timestamp, $ms) = split(/\./, $timestamp);
	# array for time
	my ($sec, $min, $hour, $day, $month, $year, $wday, $yday, $isdst) = localtime($timestamp);
	# year, month fix
	$year += 1900;
	$month += 1;
	# string for return
	return $year."-".($month < 10 ? '0'.$month : $month)."-".($day < 10 ? '0'.$day : $day)." ".($hour < 10 ? '0'.$hour : $hour).":".($min < 10 ? '0'.$min : $min).":".($sec < 10 ? '0'.$sec : $sec).(($ms && $show_micro) ? ".".$ms : "");
}

$| ++;

binmode STDOUT, ":encoding(utf8)";
binmode STDIN, ":encoding(utf8)";
binmode STDERR, ":encoding(utf8)";

my %opt = ();
my $write = 0;
our $verbose = 0;
# add prompt bundeling (eg -qqq
Getopt::Long::Configure ("bundling");
# command line
my $result = GetOptions(\%opt,
	'with-line-count', # count csv file lines
	'write' => \$write, # write errors to file
	'verbose|v+' => \$verbose,
	'help' # just help
) || exit 1;

if ($opt{'help'})
{
	print "Goes through a CSV file or files and checks if they are valid\n";
	print "On error prints the line and the line number, additional writes data to error file if requested\n";
	print "--with-line-count\t alternative count style instead of file size\n";
	print "--write\t write errors to file\n";
	print "--verbose|-v[-v[..]]\t\n";
	print "\n";
	exit 0;
}

if (!$ARGV[0])
{
	print "Please give a filename to check\n";
	exit 1;
}

# set start time
my $start = time();
my $end;
my $filesize;
my $linecount;
my $count = 1;
my $error_count = 0;
my $error_str;
my $encoding = 'utf8';
my $max_cols = 0;
my $base_path = File::Basename::dirname($0).'/';
# open log file if we want to write too
open(LOG, ">:encoding($encoding)", $base_path."CHECK_CSV_".time().".log") || die ("Cannot open log file for writing\n") if ($write);

# open the data file
print "Opening CSV File ...\n" if ($verbose > 2);
my $DATA = new IO::File;
open($DATA, "<:encoding($encoding)", $ARGV[0]) || die ("Can't open file '".$ARGV[0]."'\n");
# read filesize
print "Get filesize ... " if ($verbose > 2);
$DATA->seek(0, 2);
$filesize = $DATA->tell;
$DATA->seek(0, 0);
print byte_format($filesize)."\n" if ($verbose > 2);
# get line count
if ($opt{'with-line-count'})
{
	print "Get line count ... " if ($verbose > 2);
	$linecount = 0;
	$linecount ++ while(defined($DATA->getline));
	$DATA->seek(0, 0);
	print "$linecount\n" if ($verbose > 2);
}
# init csv
my $csv = Text::CSV_XS->new ({
	'binary' => 1,
	'eol' => "\n"
});

while (<$DATA>)
{
	my $error_str = '';
	$_ = Unicode::Japanese->new($_, $encoding)->get if ($encoding ne 'utf8');
#	$_ = Encode::encode_utf8($_) if ($encoding eq 'utf8');
	if ($csv->parse($_))
	{
		my @cols = $csv->fields();
		# first okay sets max elements per row, if different print error
		if (!$max_cols)
		{
			$max_cols = @cols;
		}
		if ($max_cols != @cols)
		{
			$error_str = "****> FILE: ".$ARGV[0].", ELEMENT COUNT IN LINE [".$count."] IS WRONG <****\n";
			$error_str .= "First line: $max_cols\n";
			$error_str .= "This line: ".@cols."\n";
			$error_count ++;
		}
	}
	else
	{
		# CSV line has an grave unrecoverable error
		$error_str = "====> FILE: ".$ARGV[0].", CSV SPLIT ERROR [".$csv->status()."] IN LINE [".$count."] <====\n";
		$error_str .= "CSV ERROR DESCRIPTION: ".$csv->error_diag()."\n";
		$error_str .= "CSV ERROR INPUT: ".$csv->error_input();
		$error_str .= "LINE DATA: ".$_."\n";
			$error_count ++;
	}
	if ($error_str)
	{
		print $error_str;
		print LOG $error_str if ($write);
	}
	$count ++;
}
close($DATA);
$end = time();
print "Errors: ".format_number($error_count)." / Lines: ".format_number($count)." | Start: ".create_time($start).", End: ".create_time($end).", Running Time: ".convert_time($end - $start)."\n";
close(LOG) if ($write);

__END__
