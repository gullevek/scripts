package config;

BEGIN
{
	require Exporter;
	our @cc_emails; 
	@ISA = qw( Exporter );
	@EXPORT = qw( @cc_emails );
};

# basic config stuff

# config basic

# from address
$from_address = "<user\@domain>";
# recivers
$to_email = "<target\@domain>";
#@cc_emails = ("<other\@domain>", "<another\@domain>"); # possible cc email
@cc_emails = ();
# subject
$subject = "watchdog reports ...";
$subject_url = "url check reports ...";
# mobile email
$mobile = "<user\@domain>";

# timeout settings
$timeout_ok = 5; # timout in 5 seconds for ports that should be open
$timeout_ng = 1; # timeout in 1 second for ports that should be closed

1;
