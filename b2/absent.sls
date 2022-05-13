b2:
  file.absent:
    - name: /usr/bin/b2

b2-files.sh:
  file.absent:
    - name: /usr/local/sbin/b2-files.sh

mysql-dump.sh:
  file.absent:
    - name: /usr/local/sbin/mysql-dump.sh

b2-mysql.sh:
  file.absent:
    - name: /usr/local/sbin/b2-mysql.sh

b2-files-cron-bye:
  cron.absent:
    - identifier: b2-files
    - user: root

b2-mysql-cron-bye:
  cron.absent:
    - identifier: b2-mysql
    - user: root
