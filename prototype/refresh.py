#!/usr/bin/env python3
"""추출 → 조립 → calendar.html 까지 한 번에.

CalendarBridge 는 반드시 .app 으로 `open -a` 해야 한다. 커맨드라인 바이너리로
직접 돌리면 macOS 가 권한 요청을 부모 앱(터미널/VS Code)에 귀속시켜서
다이얼로그도 못 띄우고 조용히 denied 가 된다.
"""
import json, os, subprocess, sys, time
from pathlib import Path

HERE = Path(__file__).parent
APP = Path.home() / ".local/share/calendar-bridge/CalendarBridge.app"


def extract(timeout=180):
    out = HERE / "ek.json"
    if out.exists():
        out.unlink()
    subprocess.run(["open", "-a", str(APP), "--args", "calendar", str(out)], check=True)
    waited = 0
    while waited < timeout:
        if out.exists() and out.stat().st_size > 0:
            return json.loads(out.read_text(encoding="utf-8"))
        time.sleep(2)
        waited += 2
    sys.exit("CalendarBridge 응답 없음. 권한 다이얼로그를 확인할 것.")


def main():
    if "--no-extract" not in sys.argv:
        ek = extract()
        print("추출: 캘린더 %d개 · 일정 %d건 · 미리알림 %d건"
              % (len(ek["calendars"]), len(ek["events"]), len(ek["reminders"])))
    subprocess.run([sys.executable, str(HERE / "build_data.py")], check=True)
    tpl = (HERE / "template.html").read_text(encoding="utf-8")
    data = (HERE / "data.json").read_text(encoding="utf-8")
    (HERE / "calendar.html").write_text(tpl.replace("__DATA__", data), encoding="utf-8")
    print("calendar.html 갱신됨")


if __name__ == "__main__":
    main()
