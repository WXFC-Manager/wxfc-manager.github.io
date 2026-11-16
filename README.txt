WXFC 축구회 시스템 - 설치 안내 (휴대폰으로 가능, 약 10분)
※ 휴대폰 브라우저 메뉴에서 '데스크톱 사이트'를 켜면 버튼이 잘 보입니다.

──────── 1단계. 데이터베이스 만들기 (Supabase) ────────
1) supabase.com/dashboard → wxfc 프로젝트 열기
2) 왼쪽 메뉴 'SQL Editor' → 'New query'
3) setup.sql 파일 내용을 전부 복사해서 붙여넣기 → 'Run' 버튼
4) 아래 결과에 '설치 완료'가 나오면 성공
   (경고 창이 뜨면 'Run this query' 눌러서 진행)

──────── 2단계. 사이트 올리기 (GitHub) ────────
1) github.com/WXFC-Manager 접속 → 'New' (새 저장소)
2) Repository name: wxfc-manager.github.io   ← 정확히 이대로
   Public 선택 → 'Create repository'
3) 'uploading an existing file' 링크 (또는 Add file → Upload files)
   → index.html 선택 → 아래 'Commit changes'
4) 저장소 Settings → 왼쪽 Pages → Source: 'Deploy from a branch'
   → Branch: main / (root) → Save
5) 1~3분 뒤 접속: https://wxfc-manager.github.io

──────── 3단계. 자동 켜짐 유지 (한 번만) ────────
Supabase 무료는 7일 동안 사용이 없으면 잠깁니다. GitHub이 3일마다 자동으로 깨우게 합니다.
1) 저장소에서 Add file → Create new file
2) 파일 이름 칸에 정확히 입력:  .github/workflows/keepalive.yml
3) keepalive.yml 파일 내용을 붙여넣기 → 'Commit changes'
4) 저장소 Actions 탭 → keepalive → 'Run workflow' 한 번 눌러 초록색 ✓ 확인

──────── 4단계. 첫 사용 ────────
1) 사이트에서 '가입 신청' → 맨 처음 가입한 사람이 자동으로 '회장'
   (그래서 회장이 될 사람이 가장 먼저 가입하세요)
2) 위챗 단톡방에 주소 공유 → 회원들이 가입 신청
3) 회장: 내정보 → 회원 관리 → 승인, 부회장·총무 지정

──────── 사용 흐름 ────────
• 결제: 회원 결제안 → 회장 승인 → 총무 위챗 송금 + 캡처 첨부 → 지급완료
• 회의: 안건+파일 → 부회장 승인 → 회장 승인 → 전체 공개 → 회의록 등록
• 알림: 앱 안 🔔 (내정보 탭 빨간 숫자). 상세 화면의 '공유 문구 복사'로 위챗 단톡방에 알리기
• 비밀번호 분실: 회장이 회원 관리 → ⋯ → 비밀번호 초기화

──────── 인계 (탈퇴할 때) ────────
• 프로그램 권한: 내정보 → 회장 인계 (버튼 하나)
• 사이트 관리 계정: GitHub 조직 WXFC-Manager, Supabase 조직에
  새 담당자를 Owner로 초대 → 본인은 Leave

──────── 문제가 생기면 ────────
• 사이트가 안 열림/오류: supabase.com/dashboard → 프로젝트가 'Paused'면 'Restore' 버튼
• 그 외: 아무것도 고칠 필요 없음 (서버 없음)
• 데이터 백업: 내정보 → 결제 내역 엑셀(CSV) 내려받기
