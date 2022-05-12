b2:
  file.absent:
    - name: /usr/local/sbin/b2

b2-files.sh:
  file.absent:
    - name: /usr/local/sbin/b2-files.sh

b2-cron-bye:
  cron.absent:
    - identifier: b2-files
    - user: root