#!/usr/bin/env python3
"""프로토타입 데이터 조립.

일정·미리알림: CalendarBridge.app 이 EventKit 에서 뽑은 ek.json
운동·일기 노트: 옵시디언 볼트 직접 파싱

사용:
    python3 refresh.py          # 추출부터 다시 (권장)
    python3 build_data.py       # 이미 있는 ek.json 으로 조립만
"""
import datetime as dt
import json, re, subprocess, sys
from collections import defaultdict
from pathlib import Path

HERE = Path(__file__).parent
JOURNAL = Path.home() / "Library/Mobile Documents/iCloud~md~obsidian/Documents/Amethyst/2. Daily Journal"

# 캘린더 -> 표시 그룹. 구글이 준 색은 쓰지 않는다. umwelt 와 creation 이 둘 다
# #9FE1E7 라 계정 구분이 아예 안 되고 흰 배경에서 대비도 모자란다.
GROUPS = {
    "personal": {"label": "Personal", "account": "eunbi.umwelt · racheleunbi · 공유 2", "kind": "Google"},
    "coaching": {"label": "Coaching", "account": "eunbi.creation@gmail.com",            "kind": "Google"},
    "work":     {"label": "Work",     "account": "rachel.shin@pkroffshore.com",         "kind": "Exchange"},
    "holiday":  {"label": "Holidays", "account": "구독 캘린더 4종",                       "kind": "Subscribed"},
}


def group_for(cal):
    t, src = cal["title"], cal["source"]
    if "holiday" in t.lower():          return "holiday"
    if t == "eunbi.creation@gmail.com": return "coaching"
    if src == "Exchange":               return "work"
    return "personal"   # umwelt, racheleunbi(FS8·결제·생일), parvati, yobo 전부 개인


# 달력에 올리는 미리 알림은 Pinboard 하나뿐이다. Cooking 은 해보고 싶은 요리 목록이고
# Books/노래방/Golf 등은 백로그라 날짜에 흩뿌리면 안 된다.
NOTE_LISTS = {"Pinboard"}


def strip_md(s):
    s = re.sub(r"\*+", "", s)
    s = re.sub(r"\[\[([^\]|]+)(?:\|[^\]]+)?\]\]", r"\1", s)
    return re.sub(r"\s+", " ", s).strip(" .·-")


def key(s):
    return re.sub(r"[^0-9a-z가-힣]", "", s.lower())[:34]


def journal_notes(path):
    b = path.read_text(encoding="utf-8", errors="replace")
    out = []
    m = re.search(r"^##\s*\*{0,2}핀보드[^\n]*\n(.*?)(?=^##\s|\Z)", b, re.S | re.M)
    if m:
        for line in m.group(1).splitlines():
            t = strip_md(line)
            if t:
                tm = re.match(r"^(\d{1,2}:\d{2})\s*(.*)", t)
                out.append({"kind": "pin", "label": "Pinboard",
                            "time": tm.group(1) if tm else None,
                            "text": tm.group(2) if tm else t})
    todo = re.search(r"^##\s*\*{0,2}Todo list[^\n]*\n(.*?)(?=^##\s|\Z)", b, re.S | re.M)
    if todo:
        for t in re.findall(r"^\s*-\s*\[[xX]\]\s*(.+)$", todo.group(1), re.M):
            out.append({"kind": "done", "label": "Done", "time": None, "text": strip_md(t)})
    return out


def main():
    ek = json.loads((HERE / "ek.json").read_text(encoding="utf-8"))
    byid = {c["id"]: c for c in ek["calendars"]}

    # ── 일정 ──────────────────────────────────────────
    events, seen = [], set()
    for e in ek["events"]:
        cal = byid[e["cal"]]
        # 싱가포르 공휴일을 캘린더 4개에서 구독 중이라 같은 날이 세 번씩 들어온다
        k = (e["date"], e["time"], key(e["title"]))
        if k in seen:
            continue
        seen.add(k)
        ev = {"date": e["date"], "time": e["time"], "title": e["title"].strip(),
              "source": group_for(cal), "cal": cal["title"],
              "end": e["endDate"] if e["endDate"] != e["date"] else None}
        if e["time"] and e["endTime"]:
            ev["endTime"] = e["endTime"]
        events.append(ev)

    # ── 미리 알림 (Pinboard 만, 생성일 기준) ─────────────
    # 완료일은 pinboard_pull.py 가 처리한 시각일 뿐이라 캡처 시각이 아니다.
    # 마감일은 단축어가 캡처 시각을 복사해 넣었거나 진짜 데드라인이다.
    notes = defaultdict(list)
    rem_keys = defaultdict(set)
    for r in ek["reminders"]:
        if r["list"] not in NOTE_LISTS or not r["created"]:
            continue
        d, t = r["created"].split(" ")
        notes[d].append({"kind": "reminder", "label": r["list"],
                         "time": None if t == "00:00" else t,
                         "text": r["title"].strip(), "done": r["done"]})
        rem_keys[d].add(key(r["title"]))
        # 마감일을 따로 잡아둔 건 진짜 데드라인이다. 캡처한 날과 다르면 마감일에도 한 번 더.
        if r["due"]:
            dd, dtime = r["due"].split(" ")
            if dd != d:
                notes[dd].append({"kind": "due", "label": "Due",
                                  "time": None if dtime == "00:00" else dtime,
                                  "text": r["title"].strip(), "done": r["done"]})

    # ── 일기 (운동 + 노트) ──────────────────────────────
    workouts = json.loads(subprocess.run(
        [sys.executable, str(HERE / "workout_parse.py")],
        capture_output=True, text=True, check=True).stdout)

    for p in sorted(JOURNAL.glob("*.md")):
        m = re.match(r"(\d{4}-\d{2}-\d{2})", p.name)
        if not m:
            continue
        d = m.group(1)
        for n in journal_notes(p):
            # pinboard_pull.py 가 리마인더를 일기로 옮기므로 같은 글이 두 번 들어온다
            if n["kind"] == "pin" and key(n["text"]) in rem_keys[d]:
                continue
            notes[d].append(n)

    for d in notes:
        # 마감일 항목을 맨 앞에. 그날 가장 중요한 줄이다.
        notes[d].sort(key=lambda n: (n["kind"] != "due", n["time"] is None, n["time"] or ""))

    data = {"sources": GROUPS, "events": events, "workouts": workouts,
            "notes": dict(notes), "today": dt.date.today().isoformat()}   # 오늘 칸 반전이 실제 날짜를 따라가야 한다
    (HERE / "data.json").write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")

    per = defaultdict(int)
    for e in events:
        per[e["source"]] += 1
    print("일정 %d건 (중복 %d건 제거) · 노트 %d건 / %d일 · 운동 %d일"
          % (len(events), len(ek["events"]) - len(events),
             sum(len(v) for v in notes.values()), len(notes), len(workouts)))
    for k2, v in sorted(per.items(), key=lambda x: -x[1]):
        print("   %-10s %d" % (GROUPS[k2]["label"], v))


if __name__ == "__main__":
    main()
