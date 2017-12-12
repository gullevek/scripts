#!/usr/bin/perl

# AUTHOR: Clemens Schwaighofer
# DATE: 2009/8/19
# DESCRIPTION:
# uses the standard csv flow (with normal read not getline) and finds
# linebreaks in CSV lines and other non conform constructions and tries to
# clean them. before any run tries to replace ウ" to ヴ because this is a
# most common error
# if LB is found, clean all end of line and connect with next line

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

$| ++; # immediate flush

binmode STDOUT, ":encoding(utf8)";
binmode STDIN, ":encoding(utf8)";
binmode STDERR, ":encoding(utf8)";

my %opt = ();
our $verbose = 0;
my $double_quote_pre_clean = 0;
# add prompt bundeling (eg -qqq
Getopt::Long::Configure ("bundling");
# command line
my $result = GetOptions(\%opt,
	'doublequote-pre-clean' => \$double_quote_pre_clean, # do a pre clean of double quote (\") errors and not in the main loop
	'verbose|v+' => \$verbose,
	'help' # just help
) || exit 1;

if ($opt{'help'})
{
	print "Goes through a CSV file and fixes possible errors like line breaks or some special japanese katakana with \"\n";
	print "--doublequote-pre-clean\tClean double quote (\\\") errors before the main clean loop\n";
	print "--verbose|-v[-v[..]]\t\n";
	print "\n";
	exit 0;
}

my $file = $ARGV[0] || '';
if (! -f $file)
{
	print "Please give a valid filename, or file '".$file."' could not be found\n";
	exit 1;
}

# set start time
my $csv = Text::CSV_XS->new ({
	'binary' => 1,
	'eol' => $/
});
my $start_time = time();
my $start = $start_time;
my $end;
my $encoding = 'utf8';
my $outfile = '';
my @lastline = ();
my $fix_error = 0;
my $error = 0;
my $error_pre_clean = 0;
my $count_fix_error = 0;
my $filesize;
my @last_line = ();
# build fixed filename, remove extension and add fixed.csv for it
my @parts = split(/\./, $file);
pop @parts;
foreach my $part (@parts)
{
	$outfile .= $part;
}
$outfile .= '.fixed.csv';

# file has to be utf8
my $DATA = new IO::File;
open($DATA, '<:encoding('.$encoding.')', $file) || die "Cannot open $file: $!";
open(OUT, '>:encoding('.$encoding.')', $outfile) || die "Cannot open $outfile: $!";
# read filesize
print "Get filesize ... " if ($verbose >= 1);
$DATA->seek(0, 2);
$filesize = $DATA->tell;
$DATA->seek(0, 0);
print byte_format($filesize)."\n" if ($verbose >= 1);

while (<$DATA>)
{
	chomp $_;
	my $line = $_;
	# do only something if the line is not empty
	if ($line)
	{
		# try to replace ウ" with ヴ, but only if the " is not followed by a seperating part (,) or end (\n)
		# if the ウ" is right before a ", the $1 holds the " that needs to be back replaced
		$line =~ s/ウ"([^\n|(,)])/ヴ$1/g;
		# remove any \" as they are wrong quote marks, change them to ""
		# default is off, and cleaning is done in loop
		$line =~ s/(\\")/""/g if ($double_quote_pre_clean);
		$error_pre_clean ++ if ($1);
		# reset main line
		my $new_line = '';
		# normal processing
		if ($csv->parse($line))
		{
			# if there is just some data and not valid csv, push it to the last line as it could be some additional info
			# so does not start with " or does not end with "
			if (($line !~ /^"/ || $line !~ /"$/) && $error)
			{
				print "($fix_error){$error}[".$csv->status()."] Additional line push\n";
				push(@last_line, ' '.$line);
			}
			else
			{
				# if we have no error, but we some fix errors in the list, work through the fix errors first, and then write the normal line
				if ($fix_error)
				{
					if ($error == 1)
					{
						# possible " error
						# try to find " in position, ignore start and end, and also "," combinations
						$last_line[0] =~ s/","/##SEP##/g;
						$last_line[0] =~ s/,"/##SEPSTART##/g;
						$last_line[0] =~ s/",/##SEPEND##/g;
						$last_line[0] =~ s/^"/##START##/g;
						$last_line[0] =~ s/"$/##END##/g;
						$last_line[0] =~ s/\\"/##DOUBLE_QUOTE##/g; # any \" should be "", temp replacement
						# replace any " we find left over in the line, this is a saftey precausion
						$last_line[0] =~ s/"//g;
						# counter replace the previous fond ones into correct ones
						$last_line[0] =~ s/##SEP##/","/g;
						$last_line[0] =~ s/##SEPSTART##/,"/g;
						$last_line[0] =~ s/##SEPEND##/",/g;
						$last_line[0] =~ s/##(START|END)##/"/g;
						$last_line[0] =~ s/##DOUBLE_QUOTE##/""/g;
						$new_line = $last_line[0];
					}
					elsif ($error > 1)
					{
						# clean all from $last_line_1 and then combine with $last_line_2
						foreach my $_last_line (@last_line)
						{
							chomp $_last_line;
							$_last_line =~ s/\^M//g; # if \r was copied by hand
							$_last_line =~ s/\r//g; # binary format \r (0d)
							$new_line .= $_last_line;
						}
					}

					$fix_error = 0;
					$error = 0;
					@last_line = ();
					# write clean last lein
					print "===> NEW FIX: ".$new_line.$/;
					print OUT $new_line.$/;
					$count_fix_error ++;
				}
				# write current line
#					print "SAME: ".$line.$/;
				print OUT $line.$/;
			}
		}
		else
		{
			# error, remember this line, if two errors in row, this is LB problem, if one error, possible " error
			if (!$error)
			{
				$error = 1;
				push(@last_line, $line);
			}
			elsif ($error >= 1)
			{
				$error ++;
				push(@last_line, $line);
			}
			# if the last error was "QUO character not allowed" then set combine flag to finish this one off
			$fix_error = 1 if ($csv->error_diag() eq "EIQ - QUO character not allowed");
			$fix_error = 1 if ($csv->error_diag() eq "EIF - Loose unescaped quote"); # similar as above
			# fix until we find: QUO character not allowed
			# print out the error
			print "($fix_error){$error}[".$csv->status()."] ERROR: ".$csv->error_diag().": ".$csv->error_input()."\n";
		}
	}
	else
	{
		print "*** Skip empty line\n";
	}
}

close(OUT);
close($DATA);

$end = time();

print "Fixed $count_fix_error errors".($double_quote_pre_clean ? ", cleaned $error_pre_clean double quote errors before clean loop" : '')."\n";
print "Start: ".create_time($start).", End: ".create_time($end).", Running Time: ".convert_time($end - $start)."\n";

__END__
