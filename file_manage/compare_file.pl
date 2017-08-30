#!/usr/bin/perl
#
# AUTHOR: Clemens Schwaighofer
# DATE:   2017/8/30
# DESC:   Compare one file to another and write found/not found entries to an output file

use strict;
use warnings;
no strict 'refs'; # I need to allow dynamic references in this script
use utf8;

BEGIN
{
	use POSIX qw(floor);
    use Text::CSV_XS;
    use Getopt::Long;
    use Time::HiRes qw(time);
    use File::Basename;
    use Number::Format qw(:subs);
    unshift(@INC, File::Basename::dirname($0).'/');
}

# converts bytes to human readable format
sub convert_number
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

# simple progres
sub progress
{
	my ($pos, $filesize, $last_percent) = @_;
	my $precision_ten_step = 10;
	# percent output
	my $_percent = sprintf("%d", ($pos / $filesize) * 100);
	# mod that to 10
	# either write this one, or write the previous, old one
	my $percent = ($_percent % $precision_ten_step) == 0 ? $_percent : $last_percent;
	if ($percent != $last_percent)
	{
		print $percent."% ";
		$last_percent = $percent;
	}
	return $last_percent;
}

# no buffering for output
$| ++;

binmode STDOUT, ":encoding(utf8)";
binmode STDIN, ":encoding(utf8)";
binmode STDERR, ":encoding(utf8)";

my $error = 0;
my %opt = ();
my $input_file = ''; # master file from which we take the data that we need to compare
my $compare_file = ''; # file that holds the data we use as a compare base
my $output_folder = ''; # target folder where to write the output
my @compare_fields = (); # single or groupings of compare data format 1,1

# add prompt bundeling (eg -qqq
Getopt::Long::Configure ("bundling");
# command line
my $result = GetOptions(\%opt,
	'input|i=s' => \$input_file,
	'compare|c=s' => \$compare_file,
	'output|o=s' => \$output_folder,
	'fields|f=s' => \@compare_fields,
	# standard sets
	'help|h|?' # just help
) || exit 1;

pod2usage(-exitval => 0, -verbose => 2) if ($opt{'man'});

if ($opt{'help'})
{
	print "Compare files script:\n";
	print "\n";
	print "--input|-i <file>\t\t\t\t\tMaster file which is the source and the result will be written to the output file\n";
	print "--compare|-c <file>\t\t\t\t\tThe compare file. All data will be compared to data in this file\n";
	print "--output|-o <folder>\t\t\t\t\tFolder where the new output file (based on the input file) will be written\n";
	print "--fields|-f <compare> [--fields|-f <compare> ...]\tCompare flags in the format of n, or n,n for data needs to be in compare or n-, n-n for data cannot be in compare.\n";
	print "                                                 \tIf only one compare position is given it will be used in both, if the compare to is different two numbers need to be given\n";
	print "\n";
	print "Sample:\n";
	print "compare_file.pl -i a.csv -c b.csv -o out/ -f 1,\t\tColumn 1 of a.csv and b.csv are compared and if it exists in b.csv it will be written to the output file\n";
	print "compare_file.pl -i a.csv -c b.csv -o out/ -f 1,3\tColumn 1 of a.csv and column 3 b.csv are compared and if it exists in b.csv it will be written to the output file\n";
	print "compare_file.pl -i a.csv -c b.csv -o out/ -f 1-3\tColumn 1 of a.csv and column 3 b.csv are compared and if it does not exists in b.csv it will be written to the output file\n";
	print "\n";
	exit 0;
}

# basic checks that file & folder exist
if ( ! -f $input_file)
{
	print "The input file is not a file or not readable: $input_file\n";
	$error = 1;
}
if ( ! -f $compare_file)
{
	print "The compare file is not a file or not readable: $compare_file\n";
	$error = 1;
}
if ( ! -d $output_folder)
{
	print "The output folder is not a folder or not writeable: $output_folder\n";
	$error = 1;
}
# we need to have at least one compare filed set
if (!@compare_fields)
{
	print "You need to set at least one compare filed\n";
	$error = 1;
}
else
{
	# check that the compare fields are correct
	foreach my $compare (@compare_fields)
	{
		# format must be either digit (for both compare)
		# or comma separate for compare n to n where input data must be in compare file
		# or minus separate for input data must not be in compare file
		if ($compare !~ /^\d{1,}[\-,]{1}(\d{1,})?/)
		{
			print "Compare block $compare is not correct. Needs to be 'n,' or 'n-' or 'n,n' or 'n-n'\n";
			$error = 1;
		}
		# check that numbers are valid (> 0)
		if ($compare =~ /^(\d{1,})[\-,]{1}(\d{1,})?/)
		{
			if (defined($1) && $1 < 1)
			{
				print "Compare block $compare number one not valid: $1. Needs to be interger 1 or higher.\n";
				$error = 1;
			}
			if (defined($2) && $2 < 1)
			{
				print "Compare block $compare number two not valid: $2. Needs to be interger 1 or higher.\n";
				$error = 1;
			}

		}
	}
}

exit 1 if ($error);

# input/output encoding
my $encoding = 'utf8';
# progress data (for % output)
my $filesize;
my $last_percent = 0;
# for counts
my $input_file_rows = 0;
my $output_file_rows = 0;
# base file io handlers
my $COMPARE;
my $OUTPUT;
my $INPUT;
# for output
my $base_folder;
my $base_file;
my $base_ext;
my $output_file;
# compare hash: pos -> entry = 1
my %compare_data = ();
# for all files same csv type
my $csv = Text::CSV_XS->new ({
	'binary' => 1,
	'eol' => "\n"
});
# start time
my $start_time = time();
my $end_time;

print "---------------------------------\n";
# open compare file and read in data into array
$COMPARE = new IO::File;
open($COMPARE, "<:encoding($encoding)", $compare_file) || die("Unable to open compare file ".$compare_file.": ".$!."\n");
print "Reading COMPARE [$compare_file: ";
# size
$COMPARE->seek(0, 2);
$filesize = $COMPARE->tell;
$COMPARE->seek(0, 0);
print convert_number($filesize)."] ";
# TODO: flag if files have header
while (<$COMPARE>)
{
	if ($csv->parse($_))
	{
		my @row = $csv->fields();
		# only read in defined position from the compare_fields, we can drop the rest
		foreach my $compare (@compare_fields)
		{
			# if single first, else second field
			if ($compare =~ /^(\d{1,})([\-,]{1})(\d{1,})?/)
			{
				# get second position if set, if not get first, if not set 0 pos
				my $pos = defined($3) ? $3 - 1 : (defined($1) ? $1 - 1 : 0);
				#print "IN $compare SET POS: $pos [FOUND: 1:$1 | 2:$2 | 3:$3 | 4:$4]\n";
				#print "Write: $compare: ".$row[$pos]."\n";
				# if we can't find it mark error, and abort script
				if (defined($row[$pos]))
				{
					$compare_data{$compare}{$row[$pos]} = 1;
				}
				else
				{
					$error ++;
				}
			}
		}
	}
	else
	{
		die "CSV SPLIT ERROR[".$csv->status()."][".$csv->error_diag()."]: ".$csv->error_input()."\n";
	}
	# percent output
	$last_percent = progress($COMPARE->tell, $filesize, $last_percent);
}
close($COMPARE);
if ($error)
{
	print "[ERROR: Could not find ".format_number($error)." data for compare pos]\n";
	exit 1;
}
else
{
	print "[DONE]\n";
}
# open output file for writing
# set output file based on input file (remove folder, split with extension add ".clean" into it
($base_file, $base_folder, $base_ext) = fileparse($input_file, qr/\.[^.]*/);
$output_file = $output_folder.$base_file.'.clean'.$base_ext;
print "Open OUTPUT [$output_file] ";
$OUTPUT = new IO::File;
open($OUTPUT, ">:encoding($encoding)", $output_file) || die("Unable to open output file ".$output_file.": ".$!."\n");
print "[DONE]\n";
print "Open INPUT [$input_file: ";
# open input file and compare
$INPUT = new IO::File;
open($INPUT, "<:encoding($encoding)", $input_file) || die("Unable to open input file ".$input_file.": ".$!."\n");
$INPUT->seek(0, 2);
$filesize = $INPUT->tell;
$INPUT->seek(0, 0);
print convert_number($filesize)."] [DONE]\n";
print "---------------------------------\n";
print "Comparing data: ";
# compare data
while (<$INPUT>)
{
	if ($csv->parse($_))
	{
		my @row = $csv->fields();
		my $match = 1; # default matches, if one fails, set to 0 and skip row
		# do compare, all must match
		foreach my $compare (@compare_fields)
		{
			# if single first, else second field
			if ($compare =~ /^(\d{1,})([\-,]{1})(\d{1,})?/)
			{
				my $input_pos = $1 - 1;
				my $compare_pos = defined($3) ? $3 - 1 : (defined($1) ? $1 - 1 : 0);
				my $compare_flag = $2;
				# we need to compare $1 to $3 (or $1 if $3 is not set)
				# and we check exist ',' or not exists '-' with $2
				# if $1 is not found in $row, we count it as not exists/not found and continue, but write out warning
				if (defined($row[$input_pos]))
				{
					# input must be in compare
					if ($compare_flag eq ',')
					{
						$match = 0 if (!$compare_data{$compare}{$row[$input_pos]});
					}
					elsif ($compare_flag eq '-')
					{
						$match = 0 if ($compare_data{$compare}{$row[$input_pos]});
					}
				}
				else
				{
					$error ++;
				}
			}
		}
		if ($match == 1)
		{
			$output_file_rows ++;
			# write to output
			$csv->combine(@row);
			print $OUTPUT $csv->string;
		}
		$input_file_rows ++;
	}
	else
	{
		die "CSV SPLIT ERROR[".$csv->status()."][".$csv->error_diag()."]: ".$csv->error_input()."\n";
	}
	# percent output
	$last_percent = progress($INPUT->tell, $filesize, $last_percent);
}
if (!$error)
{
	print "[FINISHED]\n";
}
else
{
	print "[WARNING: Some (".format_number($error).") search pos data could not be found in the input file]\n";
}
close($OUTPUT);
close($INPUT);
$end_time = time();

print "---------------------------------\n";
print "Finished compare\n";
print "Input file : ".format_number($input_file_rows)."\n";
print "Output file: ".format_number($output_file_rows)."\n";
print "Start: ".create_time($start_time).", End: ".create_time($end_time).", Running Time: ".convert_time($end_time - $start_time)."\n";
print "---------------------------------\n";

__END__
