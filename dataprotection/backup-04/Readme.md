User → Route → Service → Multi-Pod Deployment (3 replicas)
                               |
                               ↓
                             RWX PVC (NFS / ODF)
                               |
         ┌───────────────┬───────────────┬───────────────┐
         | Pod-1         | Pod-2         | Pod-3         |
         | /data         | /data         | /data         |
         | Writes logs & counters           |              |
         └───────────────┴───────────────┴───────────────┘
NodeJS Application Logic

Requirements:

Multiple pods can write independently to same RWX volume

Log file per pod to avoid collision

Write counter maintained per pod
