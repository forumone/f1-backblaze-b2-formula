b2:
  file.managed:
    - name: /usr/bin/b2
    - source: https://github.com/Backblaze/B2_Command_Line_Tool/releases/download/v3.4.0/b2-linux
    - user: root
    - group: root
    - mode: '0744'
    - source_hash: 4c3f7b39477c9502717aac4698477e15

{% if pillar.client is defined %}
{% set project = pillar.client %}
{% else %}
{% set project = pillar.project %}
{% endif %}

b2-files.sh:
  file.managed:
    - name: /usr/local/sbin/b2-files.sh
    - source: salt://b2/files/b2-files.sh
    - user: root
    - group: root
    - mode: '0744'
    - template: jinja
    - context:
        b2_keep_days: {{ salt['pillar.get']("b2:keep_days", 1) }}
        b2_threads: {{ salt['pillar.get']("b2:threads", 4) }}
        b2_ssm_prefix: /forumone/{{ project }}/backblaze
        mail_to: "sysadmins@forumone.com"
        mail_from: "b2-backups@byf1.dev"

export AWS_DEFAULT_REGION="us-east-2"; /usr/local/sbin/b2-files.sh:
  cron.present:
    - identifier: b2-files
    - user: root
    - hour: 6
    - minute: random
    - require:
        - b2-files.sh
        - b2
