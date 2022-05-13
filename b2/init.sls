b2:
  file.managed:
    - name: /usr/bin/b2
    - source: https://github.com/Backblaze/B2_Command_Line_Tool/releases/download/v3.4.0/b2-linux
    - user: root
    - group: root
    - mode: '0744'
    - source_hash: 4c3f7b39477c9502717aac4698477e15

{% set project = salt['pillar.get']('client', pillar.project) %}

{% set b2_keep_days = salt['pillar.get']('b2:keep_days', 1) %}
{% set b2_threads = salt['pillar.get']('b2:threads', 4) %}
{% set b2_ssm_prefix = "/forumone/" + project + "/backblaze" %}

{% set mysql_backup_dir = salt['pillar.get']('b2:mysql:backup_dir', '/var/backups/mysql') %}
{% set mysql_host = salt['pillar.get']('b2:mysql:host', 'mysql-ro') %}
{% set mysql_port = salt['pillar.get']('b2:mysql:port', 3306) %}

{% set mail_to = "sysadmins@forumone.com" %}
{% set mail_from = "backups@byf1.dev" %}

b2-files.sh:
  file.managed:
    - name: /usr/local/sbin/b2-files.sh
    - source: salt://b2/files/b2-files.sh
    - user: root
    - group: root
    - mode: '0744'
    - template: jinja
    - context:
        b2_keep_days: {{ b2_keep_days }}
        b2_threads: {{ b2_threads }}
        b2_ssm_prefix: {{ b2_ssm_prefix }}
        mail_to: {{ mail_to }}
        mail_from: {{ mail_from }}

mysql-dump.sh:
  file.managed:
    - name: /usr/local/sbin/mysql-dump.sh
    - source: salt://b2/files/mysql-dump.sh
    - user: root
    - group: root
    - mode: '0744'
    - template: jinja
    - context:
        mysql_backup_dir: {{ mysql_backup_dir }}
        mysql_host: {{ mysql_host }}
        mysql_port: {{ mysql_port }}
        mail_to: {{ mail_to }}
        mail_from: {{ mail_from }}

b2-mysql.sh:
  file.managed:
    - name: /usr/local/sbin/mysql-dump.sh
    - source: salt://b2/files/mysql-dump.sh
    - user: root
    - group: root
    - mode: '0744'
    - template: jinja
    - context:
        b2_keep_days: {{ b2_keep_days }}
        b2_threads: {{ b2_threads }}
        b2_ssm_prefix: {{ b2_ssm_prefix }}
        mysql_backup_dir: {{ mysql_backup_dir }}
        mail_to: {{ mail_to }}
        mail_from: {{ mail_from }}
    - require:
      - mysql-dump.sh

export AWS_DEFAULT_REGION="us-east-2"; /usr/local/sbin/b2-files.sh:
  cron.present:
    - identifier: b2-files
    - user: root
    - hour: 6
    - minute: random
    - require:
        - b2-files.sh
        - b2

export AWS_DEFAULT_REGION="us-east-2"; /usr/local/sbin/b2-mysql.sh:
  cron.present:
    - identifier: b2-mysql
    - user: root
    - hour: 5
    - minute: random
    - require:
      - b2-mysql.sh
      - b2
