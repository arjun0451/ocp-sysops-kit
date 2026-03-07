### ETCD Backup to a S3 Bucket 
apiVersion: batch/v1
kind: CronJob
metadata:
  annotations:
  labels:
    app.kubernetes.io/name: cronjob-etcd-backup
  name: cronjob-etcd-backup
  namespace: ocp-etcd-backup
spec:
  concurrencyPolicy: Forbid
  failedJobsHistoryLimit: 5
  jobTemplate:
    metadata:
      creationTimestamp: null
      labels:
        app.kubernetes.io/name: cronjob-etcd-backup
    spec:
      backoffLimit: 0
      template:
        metadata:
          creationTimestamp: null
          labels:
            app.kubernetes.io/name: cronjob-etcd-backup
        spec:
          activeDeadlineSeconds: 500
          containers:
          - command:
            - /bin/bash
            - -c
            - echo -e '\n\n---\nCreate etcd backup local to master\n' && chroot /host
              /usr/local/bin/cluster-backup.sh /home/core/backup/$(date "+%F_%H%M%S")
              && echo -e '\n\n---\nCreate signal file indicating backup completion\n'
              && chroot /host touch /home/core/backup/backup_done_signal && echo -e
              '\n\n---\nCleanup old local etcd backups\n' && chroot /host find /home/core/backup/
              -mindepth 1 -type d -mmin +2 -exec rm -rf {} \; 2>/dev/null ;
            image: 7719911111216.dkr.ecr.ap-southeast-1.amazonaws.com/openshift4:4.12.19-x86_64-cli
            imagePullPolicy: IfNotPresent
            name: cronjob-etcd-backup
            resources: {}
            securityContext:
              capabilities:
                add:
                - SYS_CHROOT
              privileged: true
              runAsUser: 0
            terminationMessagePath: /dev/termination-log
            terminationMessagePolicy: File
            volumeMounts:
            - mountPath: /host
              name: host
          - command:
            - /bin/bash
            - -c
            - "while true; do \n  if [[ -f /host/home/core/backup/backup_done_signal
              ]]; then\n    echo \"Backup completed, transferring files to S3...\"
              &&\n    find /host/home/core/backup/ -mindepth 1 -type d -mmin -2 -exec
              bash -c 'aws s3 cp \"$1\" s3://s3-tla-tcp-ocp-etcd-bkup/sit2-etcd-backup/$(basename
              \"$1\")/ --recursive' _ {} \\; &&\n    echo \"Data transfer complete,
              removing signal file...\" &&\n    rm /host/home/core/backup/backup_done_signal
              &&\n    sleep 2 ;\n    break;\n  fi\n  echo \"Waiting for backup to
              complete...\"\n  sleep 10\ndone"
            env:
            - name: AWS_ACCESS_KEY_ID
              valueFrom:
                secretKeyRef:
                  key: aws_access_key_id
                  name: aws-secret
            - name: AWS_SECRET_ACCESS_KEY
              valueFrom:
                secretKeyRef:
                  key: aws_secret_access_key
                  name: aws-secret
            - name: AWS_DEFAULT_REGION
              valueFrom:
                secretKeyRef:
                  key: region
                  name: aws-secret
            image: 771951223326.dkr.ecr.ap-southeast-1.amazonaws.com/aws-cli:2.22.27
            imagePullPolicy: IfNotPresent
            name: aws-cli
            resources: {}
            terminationMessagePath: /dev/termination-log
            terminationMessagePolicy: File
            volumeMounts:
            - mountPath: /host
              name: host
          dnsPolicy: ClusterFirst
          enableServiceLinks: true
          hostNetwork: true
          hostPID: true
          nodeSelector:
            node-role.kubernetes.io/master: ""
          restartPolicy: Never
          schedulerName: default-scheduler
          securityContext: {}
          serviceAccount: cronjob-etcd-backup
          serviceAccountName: cronjob-etcd-backup
          terminationGracePeriodSeconds: 30
          tolerations:
          - key: node-role.kubernetes.io/master
          volumes:
          - hostPath:
              path: /
              type: Directory
            name: host
  schedule: 0 3 * * *
  successfulJobsHistoryLimit: 5
  suspend: false
