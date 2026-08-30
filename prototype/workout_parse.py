#!/usr/bin/env python3
"""옵시디언 Daily Journal 에서 하루치 운동 기록을 뽑는다.

계획과 실행을 반드시 구분해서 낸다. Templater 템플릿이 `**오늘 세션: 하체 B**` 를
매일 자동 주입하기 때문에, 계획만 보면 매일 운동한 것처럼 보인다. 실제 근거는
`- 기록:` 줄과 체크박스뿐이고 8월 기준 26일 중 11일만 채워져 있었다.
"""
import json, re, sys
from pathlib import Path

VAULT = Path.home() / "Library/Mobile Documents/iCloud~md~obsidian/Documents/Amethyst"
JOURNAL = VAULT / "2. Daily Journal"

# 세션명은 가중치 3, 종목명은 1. 기록 줄에는 세션명("하체 A") 대신
# 종목명("squat 52.5kg")만 적는 날이 더 많아서 종목 사전이 반드시 필요하다.
SESSION = [
    ("하체A",     r"하체\s*A"),
    ("하체B",     r"하체\s*B"),
    ("상체당기기", r"상체[^.\n]{0,12}당기|당기기\s*우선"),
    ("상체밀기",   r"상체[^.\n]{0,12}밀|밀기"),
    ("코어",      r"코어|core"),
    ("필라테스",   r"필라테스|pilates"),
    ("골프",      r"골프|golf"),
    ("유산소",    r"zone\s*2|러닝|달리기|인터벌|4x4|스테어마스터|stairmaster"),
    ("자세교정",   r"직각어깨|자세\s*교정"),
    ("휴식",      r"휴식|rest\b"),
]
# 보조 종목 이름에 오탐하지 않도록 'pull' 'push' 같은 맨 단어는 넣지 않는다.
# ("Face pull" 때문에 상체밀기 날이 상체당기기로 분류된 적이 있다.)
EXERCISE = [
    ("하체A",     r"squat|스쿼트|leg\s*press|레그\s*프레스|leg\s*extension|레그\s*익스|bulgarian|불가리안|hip\s*abduction"),
    ("하체B",     r"hip\s*thrust|힙\s*스러스트|rdl|루마니안|leg\s*curl|레그\s*컬|farmer\s*carry|파머스|deadlift|데드"),
    ("상체당기기", r"\bchin|친업|풀업|pull[\s-]*up|\brow\b|로우|lat\s*pull|랫풀|face\s*pull|bicep|이두"),
    ("상체밀기",   r"bench|벤치|incline|인클라인|\bohp\b|shoulder\s*press|숄더|\bdip\b|딥스|lateral\s*raise|사레레|프레스"),
    ("코어",      r"플랭크|plank|데드버그|dead\s*bug|크런치"),
    ("자세교정",   r"prone\s*y|wall\s*slide|월\s*슬라이드|supine\s*db"),
]


def strip_md(s):
    s = re.sub(r"\*+", "", s)
    s = re.sub(r"\[\[([^\]|]+)(?:\|[^\]]+)?\]\]", r"\1", s)
    return re.sub(r"\s+", " ", s).strip(" .·-")


def classify(text):
    """세션명 3점 + 종목명 1점. 최고점 태그들만 돌려준다."""
    if not text:
        return []
    score = {}
    for name, pat in SESSION:
        if re.search(pat, text, re.I):
            score[name] = score.get(name, 0) + 3
    for name, pat in EXERCISE:
        score[name] = score.get(name, 0) + len(re.findall(pat, text, re.I))
    score = {k: v for k, v in score.items() if v > 0}
    # "하체 B (하체 A 아님)" 같은 부정 표현은 그 태그를 떨군다
    for name in list(score):
        if re.search(r"%s\s*%s\s*아님" % (name[:2], name[2:]), text):
            del score[name]
    if not score:
        return []
    top = max(score.values())
    # 골프·유산소·필라테스는 다른 세션과 같은 날 병행하는 일이 잦아 점수가 낮아도 살린다
    return [k for k, v in sorted(score.items(), key=lambda x: -x[1])
            if v == top or k in ("골프", "유산소", "필라테스")]


def section(body, heading_pat):
    m = re.search(r"^##\s*\*{0,2}" + heading_pat + r"[^\n]*\n(.*?)(?=^##\s|\Z)", body, re.S | re.M)
    return m.group(1) if m else ""


def subsection(sec, name):
    m = re.search(r"^\*" + name + r"\*[^\n]*\n(.*?)(?=^\*\S|\Z)", sec, re.S | re.M)
    return m.group(1) if m else ""


def checked(text):
    return [strip_md(t) for mark, t in re.findall(r"^\s*-\s*\[([ xX])\]\s*(.+)$", text, re.M)
            if mark.lower() == "x"]


def parse_note(path):
    body = path.read_text(encoding="utf-8", errors="replace")
    sec = section(body, "운동")            # "운동" 또는 "운동 & 스트레칭"
    if not sec:
        return None

    planned = ""
    m = re.search(r"오늘 세션:[ \t]*(.*)", sec)
    if m:
        planned = strip_md(m.group(1))

    # "- 기록:" 부터 빈 줄 또는 다음 불릿/인용/헤딩 전까지.
    # 콜론 뒤에 \s* 를 쓰면 개행까지 먹어서 다음 섹션 제목을 기록으로 잘못 집는다.
    actual = ""
    m = re.search(r"^[ \t]*-[ \t]*기록[ \t]*:[ \t]*(.*(?:\n(?![ \t]*(?:[-*>#]|$)).*)*)", sec, re.M)
    if m:
        actual = strip_md(m.group(1))

    recovery = None
    m = re.search(r"Recovery:\s*_*\s*(\d{1,3})\s*%", sec)
    if m:
        recovery = int(m.group(1))

    planned_tags = classify(planned)
    actual_tags = classify(actual)
    posture = checked(subsection(sec, "자세 교정 강화"))
    stretch = checked(subsection(sec, "스트레칭"))

    return {
        "planned": planned,
        "planned_tags": planned_tags,
        "actual": actual,
        # 기록은 있는데 태그가 안 잡히면 계획을 물려받되 추정 표시를 남긴다
        "actual_tags": actual_tags or (planned_tags if actual else []),
        "actual_tags_inferred": bool(actual) and not actual_tags,
        "posture_done": posture,
        "stretch_done": stretch,
        "did_main": bool(actual),
        "did_any": bool(actual or posture or stretch),
        "recovery": recovery,
    }


def main():
    out = {}
    for p in sorted(JOURNAL.glob("*.md")):
        m = re.match(r"(\d{4}-\d{2}-\d{2})", p.name)
        if not m:
            continue
        r = parse_note(p)
        if r:
            r["note_title"] = strip_md(p.stem[11:])
            out[m.group(1)] = r
    json.dump(out, sys.stdout, ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main()
