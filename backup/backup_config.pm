package config;

use 5.000_000;
use strict;
use warnings;
our ($email, @backup, %excludes, %ext_fs, @acl_dump, $backup_target, $backup_device, $full_used, $incr_used, $compress_type, $keep_incr, $keep_full);

# config vars
$config::email = "<user\@domain>"; # email address to send mail to
# what to backup
@config::backup = (
	'/<folder a>',
	'/<folder b>/<sub a>',
); # what to bk
# what to exclude for each backup group
%config::excludes = (
#	'/<folder>' => [ '/<folder>/<exclude a>', '/<folder>/<exclude b>' ]
);
# include external filesystems
%config::ext_fs = (
#	'/mnt/hdd' => 1
);
# dump acl data on those
@config::acl_dump = (
#   '/mnt/acl',
);

$config::backup_target = '/<target>/'; # target directury
$config::backup_device = '/dev/sda1'; # backup device (for free) (can be mountpoint too)
# init sizes for full & incr if first time run, size in kilobytes
$config::full_used = 2300000; #~23GB
$config::incr_used = 60000; #~60MB
# use bzip od gzip (gzip is better because much fater)
$config::compress_type = 'gzip';
# Override standard full/incr set here. Default is 6 for incr, and 0 for full
$config::keep_incr = 6;
$config::keep_full = 0;

1;
