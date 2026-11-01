# 이유식 큐브 공동관리 앱 배포 가이드

## 구성
- `index.html`: 웹 앱
- `supabase.sql`: 테이블, 접근 정책(RLS), 실시간 동기화 설정
- 무료 배포 조합: GitHub Pages + Supabase Free

## 1. Supabase 프로젝트 만들기
1. https://supabase.com 에서 가입하고 New project를 만듭니다.
2. 프로젝트가 준비되면 왼쪽 SQL Editor에서 `supabase.sql` 전체를 붙여넣고 Run 합니다.
3. Authentication > Providers > Email에서 Email provider가 활성화되어 있는지 확인합니다.
4. Authentication > Users에서 공동 계정으로 쓸 이메일 사용자를 생성합니다. (Add user / Create new user)
   - 두 분이 같은 이메일과 비밀번호로 로그인합니다.
   - 가능하면 앱 전용 이메일 계정을 사용하고, 다른 서비스와 비밀번호를 재사용하지 마세요.
5. Project Settings > API (또는 Connect 화면)에서 Project URL과 anon/public key를 복사합니다.
   - `service_role` 또는 secret key는 절대 브라우저에 입력하거나 GitHub에 올리지 마세요.

## 2. GitHub Pages에 올리기
1. https://github.com 에 로그인하고 New repository를 만듭니다. 예: `baby-cube`
2. 이 폴더의 `index.html` 파일을 저장소 최상위(root)에 업로드합니다.
3. 저장소 Settings > Pages로 이동합니다.
4. Build and deployment에서 Deploy from a branch를 선택합니다.
5. Branch를 `main`, 폴더를 `/ (root)`로 지정하고 Save 합니다.
6. 잠시 후 `https://깃허브아이디.github.io/baby-cube/` 주소가 생성됩니다.

## 3. 최초 접속 및 공동 사용
1. 배포된 주소를 엽니다.
2. Supabase Project URL과 anon/public key를 입력하고 연결 설정을 저장합니다. 이 설정은 해당 브라우저에 저장됩니다.
3. 공동 이메일과 비밀번호로 로그인합니다.
4. 아내 휴대폰에서도 같은 주소를 열고 동일한 URL/key 및 공동 계정으로 로그인합니다.
5. 두 기기에서 재고 등록/수량 변경을 하면 Realtime 이벤트로 화면이 갱신됩니다.
6. 휴대폰 브라우저 메뉴에서 '홈 화면에 추가'를 선택하면 앱처럼 실행할 수 있습니다.

## 4. 기존 앱 데이터 가져오기
기존에 사용하던 앱이 열린 브라우저에서 개발자 도구를 쓸 수 있다면:
- 기존 앱의 큐브 배열이 `localStorage`의 `babyCubeItems`에 저장되어 있습니다.
- 기존 앱 화면에서 데이터 내보내기 기능이 없으므로, 개발자 도구 Console에서 아래 코드를 실행해 JSON 파일을 받을 수 있습니다.

```js
const data = JSON.parse(localStorage.getItem('babyCubeItems') || '[]');
const blob = new Blob([JSON.stringify({items:data}, null, 2)], {type:'application/json'});
const a = document.createElement('a');
a.href = URL.createObjectURL(blob);
a.download = 'baby-cube-old-data.json';
a.click();
```

새 앱에 로그인한 뒤 'JSON 가져오기'를 눌러 이 파일을 선택합니다.
가져오기는 서버 재고에 추가하며 기존 서버 데이터를 덮어쓰지 않습니다. 같은 파일을 두 번 가져오면 중복 등록될 수 있습니다.

## 5. 운영상 주의
- 무료 플랜은 사용량/비활성 프로젝트 관련 제한 및 정책이 바뀔 수 있습니다. Supabase 대시보드의 현재 Free 한도를 확인하세요.
- 앱은 현재 로그인한 공동 계정에 접근 권한을 줍니다. 링크만 안다고 로그인할 수 있는 것은 아닙니다.
- 공동 계정은 두 사람이 같은 계정이므로 사용자별 변경 이력/권한 분리는 제공하지 않습니다.
- 재고 차감은 현재 단순 수량 업데이트 방식입니다. 동시에 같은 큐브를 차감하면 드물게 경합이 생길 수 있습니다.
- 앱 데이터는 Supabase 서버에 저장되지만, 정기적으로 JSON 내보내기 백업을 권장합니다.
- 날짜는 식품 안전을 보증하지 않습니다. 재료별 냉동 보관 지침을 별도로 확인하세요.
