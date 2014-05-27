#!/bin/bash

function byte_size
{
	echo -n `echo $1 | awk 'function human(x) {
		s=" B  KB MB GB TB EB PB YB ZB"
		while (x>=1024 && length(s)>1)
		{x/=1024; s=substr(s,4)}
		s=substr(s,1,4)
		xf=(s==" B  ")?"%d   ":"%.2f"
		return sprintf( xf"%s\n", x, s)
		}
		{gsub(/^[0-9]+/, human($1)); print}'`;
}

du -b -d 1 | sort -nr |
while read size folder;
do
	size=$(byte_size $size);
	length=`echo $size | wc -c`;
	echo -n $size;
	echo -e -n "\t"
	if [ $length -le 8 ];
	then
		echo -e -n "\t"
	fi;
	echo $folder;
done;
