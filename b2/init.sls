b2:
  file.managed:
    - name: /usr/local/sbin/b2
    - source: https://github.com/Backblaze/B2_Command_Line_Tool/releases/download/v3.4.0/b2-linux
    - user: root
    - group: root
    - mode: '0744'
    - source_hash: 4c3f7b39477c9502717aac4698477e15
