

#설치

```
# chmod +x Installer.sh 
# ./Installer.sh -i
```

#삭제

```
# ./Installer.sh -d
```

#사용법
- 설치후 쉘에 재접속해야 해당 명령어가 로그에 남음
- /var/log/bash_history.log 파일에 모든 명령어 결과가 로그로 남음
- /var/log/changed_file/ 디렉토리 아래에 수정된 파일들 변경 로그가 남음
- vim 으로 변경한 파일들에 대해서 수정된 내용이 로그로 남음


#문의사항
jaekwon.park@openstack.computer


#Special Thanks to
seowon@hawaii.edu (vim 관련 변경 로그 아이디어 제공) 