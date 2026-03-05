#!/usr/bin/env bash
set -euo pipefail

BASE="http://127.0.0.1:8000"

curl -fsS "$BASE/health" >/dev/null
ORG=$(curl -fsS -X POST "$BASE/api/organizations" -H 'Content-Type: application/json' -d '{"name":"示例机构"}')
ORG_ID=$(python3 -c "import json,sys; print(json.load(sys.stdin)['id'])" <<<"$ORG")

TEACHER=$(curl -fsS -X POST "$BASE/api/users" -H 'Content-Type: application/json' -d "{\"org_id\":$ORG_ID,\"name\":\"张老师\",\"role\":\"teacher\"}")
TEACHER_ID=$(python3 -c "import json,sys; print(json.load(sys.stdin)['id'])" <<<"$TEACHER")

STUDENT=$(curl -fsS -X POST "$BASE/api/users" -H 'Content-Type: application/json' -d "{\"org_id\":$ORG_ID,\"name\":\"李同学家长\",\"role\":\"student_parent\"}")
STUDENT_ID=$(python3 -c "import json,sys; print(json.load(sys.stdin)['id'])" <<<"$STUDENT")

COURSE=$(curl -fsS -X POST "$BASE/api/courses" -H 'Content-Type: application/json' -d "{\"org_id\":$ORG_ID,\"title\":\"数学提高班\",\"teacher_id\":$TEACHER_ID}")
COURSE_ID=$(python3 -c "import json,sys; print(json.load(sys.stdin)['id'])" <<<"$COURSE")

ENR=$(curl -fsS -X POST "$BASE/api/enrollments" -H 'Content-Type: application/json' -d "{\"course_id\":$COURSE_ID,\"student_id\":$STUDENT_ID}")
ENR_ID=$(python3 -c "import json,sys; print(json.load(sys.stdin)['id'])" <<<"$ENR")

curl -fsS -X POST "$BASE/api/homework" -H 'Content-Type: application/json' -d "{\"course_id\":$COURSE_ID,\"title\":\"第1周作业\",\"description\":\"完成练习册P1-P3\"}" >/dev/null
curl -fsS -X POST "$BASE/api/grades" -H 'Content-Type: application/json' -d "{\"enrollment_id\":$ENR_ID,\"score\":95,\"comment\":\"完成良好\"}" >/dev/null
curl -fsS -X POST "$BASE/api/payments" -H 'Content-Type: application/json' -d "{\"org_id\":$ORG_ID,\"student_id\":$STUDENT_ID,\"amount\":3000,\"status\":\"paid\"}" >/dev/null

curl -fsS "$BASE/api/report/revenue?org_id=$ORG_ID" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['revenue']==3000, d; print('smoke ok')"
