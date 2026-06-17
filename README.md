# 3-Tier 폐쇄망 인프라 구축 및 AWS 이관

Rocky Linux 8.10 기반 3-Tier 웹 서비스 인프라를 폐쇄망 환경에서 수동 구축하고,
이중화 및 자동화를 적용한 뒤 AWS로 이관하는 프로젝트입니다.

## 아키텍처

```
[사용자] → VIP(keepalived) → Apache(로드밸런서) → Tomcat(WAS) × 2 → PostgreSQL + Redis
```

### 온프레미스 (VirtualBox)

| 서버 | 역할 | 서비스망 IP |
|------|------|------------|
| web01 | Apache, DNF Repo, NTP, keepalived(MASTER) | 10.10.10.11 |
| web02 | Apache, keepalived(BACKUP) | 10.10.10.14 |
| was01 | Tomcat 9, JDK 17 | 10.10.10.12 |
| was02 | Tomcat 9, JDK 17 | 10.10.10.15 |
| db01 | PostgreSQL 15, Redis | 10.10.10.13 |

### AWS 이관 구성

| 온프레미스 | AWS |
|-----------|-----|
| Apache + keepalived | ALB |
| Tomcat × 2 (고정) | EC2 Auto Scaling Group (2~5대) |
| PostgreSQL | RDS Multi-AZ |
| Redis | ElastiCache |
| 서비스망/관리망 | VPC + Public/Private Subnet |
| firewalld | Security Group |

## 구성 요소

### Phase 1 — 수동 구축
- Rocky Linux 8.10 최소 설치 (GUI 없음)
- LVM 파티셔닝 (DB 데이터 디스크 분리: pgdata/pgwal/pgbackup)
- 네트워크 본딩 (active-backup)
- 폐쇄망 DNF 저장소 (DVD 기반, httpd로 서비스)
- chrony NTP 동기화
- PostgreSQL 15 (비기본 데이터 경로, SCRAM 인증)
- Tomcat 9 + AJP 연동
- Apache mod_proxy_ajp
- SELinux Enforcing 유지 (postgresql_db_t, httpd_can_network_connect, tomcat_can_network_connect_db)
- 역할별 커널 튜닝 (sysctl)

### Phase 2 — 이중화 + 자동화
- keepalived VRRP (VIP 자동 전환)
- Apache mod_proxy_balancer (WAS 로드밸런싱)
- Redis (세션 공유)
- Ansible 플레이북 (site.yml)

### Phase 3 — AWS 이관
- Terraform (main.tf) — VPC, ALB, ASG, RDS Multi-AZ, ElastiCache
- terraform plan 검증 완료

## 파일 구조

```
├── README.md
├── site.yml          # Ansible 플레이북
├── inventory.ini     # Ansible 인벤토리
└── main.tf           # Terraform AWS 구성
```

## 트러블슈팅 기록

| 증상 | 원인 | 해결 |
|------|------|------|
| PostgreSQL initdb 후 Permission denied | SELinux 컨텍스트 미설정 | semanage fcontext + restorecon |
| Apache → Tomcat AJP 503 | SELinux httpd 네트워크 차단 | setsebool httpd_can_network_connect on |
| Tomcat → PostgreSQL connection refused | SELinux tomcat DB 연결 차단 | setsebool tomcat_can_network_connect_db on |
| Tomcat JDBC SCRAM 인증 실패 | ongres-scram jar 미배치 | common.jar, client.jar을 Tomcat lib에 복사 |
| Tomcat AJP 커넥터 구문 오류 | XML 주석 닫는 태그 누락 | xmllint로 진단, --> 삽입 |
