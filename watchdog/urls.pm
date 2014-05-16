package urls;

# each block has:
# url: the url to check
# string: if this string exists -> fire alert
# error: error content to send
# override_email_reciver -> if this is set, mail does not go to normal watchdog email, but to this email (but CCs, are still sent)

# list of urls to check
#$url{'<id>'} = ( {
#	'name' => '<name>',
#	'url' => 'http://<host>/<script>',
#	'string' => '<read string for matching error>',
#	'error' => '<error message to send>',
#	'override_email_reciver' => '<email@host>'
#} );

1;
