#!/usr/bin/perl

# set ts=4,sw=4

#####################################################################
# $HeadURL: svn://svn/html/mailing_tool/branches/version-4/bin/send_mailing.pl $
# $LastChangedBy: gullevek $
# $LastChangedDate: 2013-02-21 21:04:13 +0900 (Thu, 21 Feb 2013) $
# $LastChangedRevision: 4390 $
######################################################################
# Author: Clemens Schwaighofer
# Date: 2004/05/11
# Last Change: 2013/2/28
# Subject:
# script reads URL and checks if a certain string exists in the return page, if yes, fires an alert
# History:
# 2013/2/28 (cs) updated with getopt, strict, debug output

use strict;
use warnings;
# email class
use MIME::Lite;
# html get class
use LWP::Simple;
use Getopt::Long;
use File::Basename;
unshift(@INC, File::Basename::dirname($0).'/');

my $debug = 0;
my $test = 0;
my %opt = ();

# add prompt bundeling (eg -qqq)
Getopt::Long::Configure ("bundling");
# command line
my $result = GetOptions(\%opt,
	'debug' => \$debug, # show debug messages
	'test' => \$test # no real run
) || exit 1;

$| ++;

use config; # <- config file with all basic conf data
use urls; # the urls to check

# the "send" command
sendmail MIME::Lite "/usr/lib/sendmail", "-t", "-oi", "-oeq", "-Fwatchdog", "-f".$config::from_address;

# the mail itself
my $mail = '';
my $cc_mails;

# cc emails
for my $cc (@config::cc_emails)
{
	$cc_mails .= ',' if ($cc_mails);
	$cc_mails .= $cc;
}

sub create_datetime
{
	my($timestamp) = @_;
	my($sec, $min, $hour, $day, $month, $year, $wday, $yday, $isdst) = mytime($timestamp);
	$year += 1900;
	$month++;
	return sprintf ('%d-%02d-%02d %02d:%02d:%02d', $year, $month, $day, $hour, $min, $sec);
}

# for each url check for the return string
foreach my $check_url (keys %urls::url)
{
	my $errors = 0;
	my $check_mail = "Now Checking Server\n'".$urls::url{$check_url}{'name'}."'\n(".$urls::url{$check_url}{'url'}."):\n";

	# call the lynx to get the page
	my $content = get($urls::url{$check_url}{'url'});
	my $string = $urls::url{$check_url}{'string'};

	print "Checking: ".$check_mail." for ".$string." in ".$content if ($debug);
#	my $string = "TestError";
	if ($content =~ /$string/)
	{
		# we have an error, make alert
		$check_mail .= "ERROR: ".$urls::url{$check_url}{'error'}."\n";
		print " ERRROR (".$urls::url{$check_url}{'error'}.")\n" if ($debug); 
		$errors = 1;
	} 
	else
	{
		print " OK\n" if ($debug);
#		print "okay\n";
	}

	# if errors put into email
	if ($errors)
	{
		my $to_email;
		$mail .= "Running check at\n".create_datetime(time())."\n";
		$mail .= $check_mail."\n";
		# check if other to email
		if ($urls::url{$check_url}{'override_email_reciver'})
		{
			$to_email = $urls::url{$check_url}{'override_email_reciver'};
		}
		else
		{
			$to_email = $config::to_email;
		}
		if ($mail && !$test)
		{
			my $msg = new MIME::Lite
			To => $to_email,
			Cc => $cc_mails,
			From => $config::from_address,
			"Reply-To" => $config::from_address,
			"Errors-To" => 'error@tequila.co.jp', # Alias einrichten und auf /dev/null
			Subject => $config::subject_url,
			Type => 'TEXT',
			Encoding => 'Quoted-Printable',
			"X-Programming" => 'Gullevek',
			Data => $mail;
			$msg->replace("Return-Path" => $config::from_address);
			$msg->attr("content-type.charset" => "iso-8859-15");
			$msg->send;
		}
		elsif ($mail && !$debug)
		{
			print $mail."\n";
		}
	}
}

__END__
