#!/usr/bin/perl

# set ts=4,sw=4

#####################################################################
# Authofer: Clemens Schwaighofer
# Date: somewhere in mid 2001
# Description:
# checks certain ports (services) and if no reply generates an
# error msg, which is sent to one or more email addresses

use strict;
use warnings;

BEGIN
{
	# uses MIME mail class
	# sadly mail cmd can no from ...
	use MIME::Lite;
	# for connection to server & testing ...
	use IO::Socket::INET; 
	use Sys::Hostname;
	use Getopt::Long;
	use File::Basename;
	unshift(@INC, File::Basename::dirname($0).'/');
}

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
use servicemap; # <- config file with all basic conf data
use hosts; # <- all hosts to be checked

sendmail MIME::Lite "/usr/lib/sendmail", "-t", "-f".$config::from_address;
# -t To-Feld aus text, -oi kein Punkt als Mailende, -oeq Error-mode: quiet
# -odq set delivery mode to queue (put message into sendmails q)
# -F Name, -N notify
# evtl -f'<>' setzen

my $mail = '';

sub create_datetime
{
	my ($timestamp) = @_;
	my ($sec, $min, $hour, $day, $month, $year, $wday, $yday, $isdst) = localtime($timestamp);
	$year += 1900;
	$month ++;
	return sprintf('%d-%02d-%02d %02d:%02d:%02d', $year, $month, $day, $hour, $min, $sec);
}

# opens a connection to a host & checks if smth is there
sub check_port
{
	my ($host, $port, $timeout) = @_;
#print "H: $host -- P: $port\n";
	# returns 1 if success ful, or 0 for failed
#	$socket = IO::Socket::INET->new($host.":".$port) || return 0;
	my $socket = IO::Socket::INET->new(
		PeerAddr => $host,
		PeerPort => $port,
		Proto => 'tcp',
		Timeout => $timeout 
	) || return 0;
	# close after successful connect
	close($socket);
	return 1;
}

# for eacht host in "hosts" file cheack for services
foreach my $check_host (keys %hosts::host)
{
	my $check_mail = "Now Checking Server\n'".$hosts::host{$check_host}{'name'}."'\n[".$hosts::host{$check_host}{'ip'}."]:\n";
	my $errors_open = 0; # reset the error var
	my $errors_closed = 0; # reset the error var

	print "Checking: ".$check_mail if ($debug);

	# go through ALL ports
	for (my $i = 0; $i < @{$hosts::host{$check_host}{'services'}}; $i++)
	{
		my $status = 'open (?)';
		my $port;
		# if \d then do not convert to port number
		if ($hosts::host{$check_host}{'services'}[$i] =~ /\D/)
		{
			$port = $servicemap::servicemap{$hosts::host{$check_host}{'services'}[$i]};
		}
		else
		{
			$port = $hosts::host{$check_host}{'services'}[$i];
		} 
		if ($port)
		{
			print "* Open port: ".$port if ($debug);
			# if (0) -> ERROR!
			if (check_port($hosts::host{$check_host}{'ip'}, $port, $config::timeout_ok))
			{
				$status = "OK";
				# DO detailed check here if available
				print " OK\n" if ($debug);
			}
			else
			{
				my $check_value;
				# do repeat ?? to be sure it is down ? wait 3s (3x) ...
				for (my $j = 0; $j < 3; $j++)
				{
					sleep 3;
					print " recheck: $j " if ($debug);
					$check_value = check_port($hosts::host{$check_host}{'ip'}, $port, $config::timeout_ok);
					print "($check_value) " if ($debug);
				}
				if (!$check_value)
				{
					$status = "DOWN!";
					$errors_open ++;
					print "DOWN ($errors_open)\n" if ($debug);
				}
				else
				{
					# it seems it wasn't closed at all ..
					$status = "OK[~]";
					# do detailed check here if available
					print "OK[~] ($errors_open)\n" if ($debug);
				}
			}
			$check_mail .= "Open '".$hosts::host{$check_host}{'services'}[$i]."': $status\n";
		}
		else
		{
			$check_mail .= "Cannot find port number for ".$hosts::host{$check_host}{'services'}[$i]."\n";
			print "CRITICAL: cannot find port number for ".$hosts::host{$check_host}{'services'}[$i]."\n" if ($debug);
		}
	} # first for

	# go through all ports that should be closed
	for (my $i = 0; $i < @{$hosts::host{$check_host}{'not_run'}}; $i++)
	{
		my $status = "closed (?)";
		my $port;
		# if \d then do not convert to port number
		if ($hosts::host{$check_host}{'not_run'}[$i] =~ /\D/)
		{
			$port = $servicemap::servicemap{$hosts::host{$check_host}{'not_run'}[$i]};
		}
		else
		{
			$port = $hosts::host{$check_host}{'not_run'}[$i];
		}
		if ($port)
		{
			print "* Closed port: ".$port if ($debug);
			if (check_port($hosts::host{$check_host}{'ip'}, $port, $config::timeout_ng))
			{
				$status = "OPEN!";
				$errors_closed ++;
				print " OPEN ($errors_closed)\n" if ($debug);
			}
			else
			{
				$status = "OK";
				print " OK\n" if ($debug);
			}
			$check_mail .= "Closed '".$hosts::host{$check_host}{'not_run'}[$i]."': $status\n"; 
		}
		else
		{
			$check_mail .= "Cannot find port number for ".$hosts::host{$check_host}{'not_run'}[$i]."\n";
			print "CRITICAL: cannot find port number for ".$hosts::host{$check_host}{'not_run'}[$i]."\n" if ($debug);
		}
	} # 2nd for

	if ($errors_open == @{$hosts::host{$check_host}{'services'}} && @{$hosts::host{$check_host}{'services'}} > 0)
	{
		# if count is equal servces ... uups !! server down?
		$check_mail .= "!!!WARNING!!! Server\n'".$hosts::host{$check_host}{'name'}."'\nseems to be DOWN!\n";
		print " SERVER DOWN\n" if ($debug);
	} 

	if ($errors_closed == @{$hosts::host{$check_host}{'not_run'}} && @{$hosts::host{$check_host}{'not_run'}} > 0)
	{
		$check_mail .= "!!!WARNING!!! Server\n'".$hosts::host{$check_host}{'name'}."'\nhas possible FIREWALL DOWN!\n";
		print " FIREWALL DOWN\n" if ($debug);
	}
	elsif ($errors_closed > 0)
	{
		$check_mail .= "!!!WARNING!!! Server\n'".$hosts::host{$check_host}{'name'}."'\nhas possible PORT OPEN IN FIREWALL!\n";
		print " FIREWALL PORT OPEN\n" if ($debug);
	}

	if ($errors_open || $errors_closed)
	{
		$mail .= "Running check at\n".create_datetime(time())." from ".hostname."\n";
		$mail .= $check_mail."\n";
	}
} # end check foreach loop

if ($mail && !$test)
{
	# build CC mails
	my $cc_mails;
	for my $cc (@config::cc_emails)
	{
		$cc_mails .= ',' if ($cc_mails);
		$cc_mails .= $cc;
	}
	my $msg = new MIME::Lite
		To => $config::to_email,
		Cc => $cc_mails,
		From => $config::from_address,
		"Reply-To" => $config::from_address,
		"Errors-To" => '<mail@domain>', # Alias einrichten und auf /dev/null
		Subject => $config::subject,
		Type => 'TEXT',
		Encoding => 'Quoted-Printable',
		"X-Programming" =>'Gullevek',
		Data => $mail;
	$msg->replace("Return-Path" => $config::from_address);
	$msg->attr("content-type.charset" => "UTF-8");
	$msg->send;

}
elsif ($mail && !$debug)
{
	# just print out mail data
	print $mail."\n";
}

__END__
