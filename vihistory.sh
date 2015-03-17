#!/bin/bash
if [ -e $1 ]
then
	var1=$(mktemp) # make temporay file
	cp -p $1 $var1 # copy original file
	vim $1
	temp_IFS=$IFS
	IFS=$'\n'
	for i in $( diff -uNr $var1 $1 |  tail -n$(expr $(diff -uNr $var1 $1 | wc -l) - 1) ) 
	do
		logger -p local6.debug "Changed the file $1 : $i"
	done
	IFS=$temp_IFS
	rm $var1 
else
	vim $1
	logger -p local6.debug "created New file $1"
fi
