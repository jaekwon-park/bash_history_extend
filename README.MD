

# 설치

```
# chmod +x Installer.sh 
# ./Installer.sh -i
```

# 삭제

```
# ./Installer.sh -d
```

# 사용법
- 설치후 쉘에 재접속해야 해당 명령어가 로그에 남음
- /var/log/bash_history.log 파일에 모든 명령어 결과가 로그로 남음
- /var/log/changed_file/ 디렉토리 아래에 수정된 파일들 변경 로그가 남음
- vim 으로 변경한 파일들에 대해서 수정된 내용이 로그로 남음

# Sample Log
```
Jan 12 23:50:41 mgmt insty: root 10.1.1.105 [7604] [/opt/harbor/common/config/nginx]: cd harbor/common/config/nginx/ [0]
Jan 12 23:50:42 mgmt insty: root 10.1.1.105 [7604] [/opt/harbor/common/config/nginx]: ls -alh  [0]
Jan 12 23:50:58 mgmt insty: Changed_the_file nginx.conf [ 7604] : /var/log/changed_file/nginx.conf-e800155fe3c501aef9d65bd0dc5bfa92
Jan 12 23:50:58 mgmt insty: root 10.1.1.105 [7604] [/opt/harbor/common/config/nginx]: vi nginx.conf  [0]
Jan 12 23:51:01 mgmt insty: root 10.1.1.105 [7604] [/opt/harbor/common/config/nginx]: docker ps [0]
Jan 12 23:51:25 mgmt insty: root 10.1.1.105 [7604] [/opt/harbor/common/config/nginx]: docker restart ced257a7de09 [0]
Jan 12 23:52:05 mgmt insty: root 10.1.1.105 [7604] [/opt/harbor/common/config/nginx]: vi nginx.conf  [0]
Jan 12 23:53:24 mgmt insty: Changed_the_file nginx.conf [ 7604] : /var/log/changed_file/nginx.conf-89a7f25228497fe52eaa47fa6da73f36
Jan 12 23:53:24 mgmt insty: root 10.1.1.105 [7604] [/opt/harbor/common/config/nginx]: vi nginx.conf  [0]
Jan 12 23:53:34 mgmt insty: root 10.1.1.105 [7604] [/opt/harbor/common/config/nginx]: docker restart ced257a7de09 [0]
```
시간 호스트이름 접속아이디: Command실행아이디 접속주소 [Bash Shell Pid] [경로]: 실행 명령어 [실행 결과 - 0 성공, 0 이외 Fail]

# 문의사항
jaekwon.park@openstack.computer


# Special Thanks to
seowon@hawaii.edu (vim 관련 변경 로그 아이디어 제공) 
