#!/bin/bash


# check vim and vi editor. default value is vim 
if [  -z $(whereis vim | awk '{print $2}') ] 
then
	vim=$(whereis vi | awk '{print $2}')
else
	vim=$(whereis vim | awk '{print $2}')
fi


if [ -e $1 ]
then
	if [ $(du -b $1 | cut -f 1) -gt "2048000" ] # except Logging over 2Mbytes File
	then
		$vim $1
		logger -p local6.notice "$(whoami) [$$] [$PWD]: $vim $1"
		logger -p local6.notice "file $1 is bigger then 2Mb. so this file doesn't remain the change log." 
	else
		logger -p local6.notice "$(whoami) [$$] [$PWD]: $vim $1"
		var1=$(mktemp) # make temporay file
		cp -p $1 $var1 # copy original file
		$vim $1
		temp_IFS=$IFS
		IFS=$'\n'
		for i in $( diff -uNr $var1 $1 |  tail -n$(expr $(diff -uNr $var1 $1 | wc -l) - 1) ) 
		do
			logger -p local6.notice"Changed the file $1 : $i"
		done
		IFS=$temp_IFS
		rm $var1 
	fi
else
	$vim $1
	logger -p local6.notice "$(whoami) [$$] [$PWD]: $vim $1"
	logger -p local6.notice "created New file $1"
fi
