#!/usr/bin/perl

#####################################################################
# AUTHOR: Clemens "Gullevek" Schwaighofer (www.gullevek.org)
# CREATED: 2011/4/21
# DESCRIPTION:
# nice output format for iptables log parsed via STDIN
# the normal output is wide with all detail data, optional a compact output can be set
# currently no additional info besides protocol, card, ip and port is read
#####################################################################

use strict;
use warnings;

BEGIN
{
	use Getopt::Long;
	use Net::IP;
	use POSIX qw(floor);
}

sub convert_time
{
	my ($timestamp, $show_micro, $round) = @_;
	my $ms;
	$round = 2 if (!$round);
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
	return (($output[0]) ? $output[0]."d " : "").(($output[1] || $output[0]) ? $output[1]."h " : "").(($output[2] ||$output[1] || $output[0]) ? $output[2]."m " : "").$output[3]."s".(($show_micro) ? " ".((!$ms) ? 0 : substr($ms, 0, $round))."ms" : "");
}


my %opt = ();
my $compact = 0;
my $lines;
# add prompt bundeling (eg -qqq
Getopt::Long::Configure ("bundling");
# command line
my $result = GetOptions(\%opt,
	'compact|c' => \$compact,
	'lines|l' => \$lines
) || exit 0;


my $rin = '';
my $rout = '';
vec($rin, fileno(STDIN), 1) = 1;
if (!select($rout = $rin, undef, undef, 0))
{
	print "Use this script with either:\n";
	print "cat <file> | tailfilter.pl\n";
	print "or\n";
	print "tail (-F) <file> | tailfilter.pl\n";
	print "\n";
	print "Use -c flag to use compact layout\n";
	exit 0;
}

my %iptlog = ();
my $datetime;
my $ethin;
my $ethout;
my $proto;
my $sourceip = '';
my $srcpt;
my $targetip = '';
my $trgpt;
my $kernel;
my $timestamp;
my $info;
# later have to formats, one wide and one for 72 chars
# 72 char needs only date/time, in/out eth, type, in/out ip + port
if ($compact)
{
	format MYLINE_SMALL =
 @<<<<<<<<<<<<<< | @<<<<< | @<<<<< | @<<< | @>>>>>>>>>>>>>> | @>>>> | @>>>>>>>>>>>>>> | @>>>>
$datetime,        $ethin,  $ethout, $proto,$sourceip,        $srcpt, $targetip,       $trgpt
.
	format MYLINE_TOP_SMALL =
Page: @>>>>
  $%
 Date/Time       | InEth  | OutEth | Type | Source          | S Prt | Target          | T Prt
-----------------+--------+--------+------+-----------------+-------+-----------------+-------
.
#........1.........2.........3.........4........5........6.........7.|.......8.........9.....9
#                                                                                            7

	$^ = 'MYLINE_TOP_SMALL';
	$~ = 'MYLINE_SMALL';
}
else
{
	# output format
	format MYLINE =
 @<<<<<<<<<<<<<< | @<<<<<<<<<< | @>>>>>>>>>>>>>>>>>>>>>>> | @<<<<<<<<<<<<<<<<<<<<<<<<<< | @<<<<< | @<<<<< | @<<< | @>>>>>>>>>>>>>>>>>>>> | @>>>> | @>>>>>>>>>>>>>>>>>>>> | @>>>>
$datetime,         $kernel,      $timestamp,               $info,                        $ethin,  $ethout, $proto,$sourceip,              $srcpt, $targetip,              $trgpt
.
	format MYLINE_TOP =
Page: @>>>>
  $%
 Date/Time       | Kernel      | Timestamp (uptime)       | IP Tables Info              | InEth  | OutEth | Type | Source                | S Prt | Target                | T Prt
-----------------+-------------+--------------------------+-----------------------------+--------+--------+------+-----------------------+-------+-----------------------+-------
.
#........1.........2.........3.........4........5........6.........7.|.......8.........9.........1.........2.........3.........4.........5.........6.........7.........8.........9
#                                                                                                0         0         0         0         0         0         0         0         0
#                                                                                                                                                                      
	$^ = 'MYLINE_TOP';
	$~ = 'MYLINE';
}	

$= = $lines || 50; # how many lines to print between headers

# open from STDIN
while (<STDIN>)
{
	# if we do not have any IN, we do not process
	if ($_ =~ / IN=/)
	{
		# first get via regex the formost part: date, kernel name, timestamp since start, iptables log name
		# format:
		# date, time, kernel name, optional timestamp, iptables msg, iptables data block
		$_ =~ /(\w+[\ ]+\d{1,2}) (\d{2}:\d{2}:\d{2}) ([\w-]+) kernel:( \[\ *([\d\.]+)\])? \[?([\w\ :-]+)\]? IN=(\w*) OUT=(\w*) (MAC=[\w:]* )?SRC=([\w\.:]+) DST=([\w\.:]+) LEN=(\d+) (TOS=\w+ PREC=\w+ TTL=\w+ ID=\d+ (DF )?)?(TC=\d+ HOPLIMIT=\d+ FLOWLBL=\d+ )?PROTO=(\w+) (SPT=(\d+) )?(DPT=(\d+))?/;

		# write the array
		%iptlog = (
			'date' => $1,
			'time' => $2,
			'kernel' => $3,
			'timestamp' => $5,
			'info' => $6,
			'IN' => $7,
			'OUT' => $8,
			'SRC' => $10,
			'DST' => $11,
			'PROTO' => $16,
			'SPT' => $18,
			'DPT' => $20
		);

		# init the convert interface for ip addresses
		# if this is an ip6 address we need to see if we can shorten it
		# eg: 0000:0000:0000:0000:0000:0000:0000:0001 -> ::1
		my $SRC = new Net::IP($iptlog{'SRC'}) if ($iptlog{'SRC'});
		my $DST = new Net::IP($iptlog{'DST'}) if ($iptlog{'DST'});
		# then write to the interface vars
		$datetime = ($iptlog{'date'} && $iptlog{'time'}) ? $iptlog{'date'}.' '.$iptlog{'time'} : ''; 
		$kernel = $iptlog{'kernel'}  || '' if (!$compact);
		$timestamp = ($iptlog{'timestamp'} ? convert_time($iptlog{'timestamp'}, 1, 4) : 'n/a') if (!$compact);
		$info = $iptlog{'info'} || '' if (!$compact);
		$ethin = $iptlog{'IN'} || '';
		$ethout = $iptlog{'OUT'} || '';
		$proto = $iptlog{'PROTO'} || '';
		$sourceip = $SRC->short() if ($iptlog{'SRC'});
		$srcpt = $iptlog{'SPT'} || 'n/a';
		$targetip = $DST->short() if ($iptlog{'DST'});
		$trgpt = $iptlog{'DPT'} || 'n/a';

		write;
	}
}

__END__
