#!/usr/bin/env python3
import json
import mimetypes
import sqlite3
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

BASE_DIR = Path(__file__).parent
DB_PATH = BASE_DIR / "data.db"
STATIC_DIR = BASE_DIR / "static"


def get_conn():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def init_db():
    conn = get_conn()
    cur = conn.cursor()
    cur.executescript(
        """
        CREATE TABLE IF NOT EXISTS organizations (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        );

        CREATE TABLE IF NOT EXISTS users (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            org_id INTEGER NOT NULL,
            name TEXT NOT NULL,
            role TEXT NOT NULL CHECK(role IN ('super_admin','org_admin','teacher','student_parent','finance')),
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY(org_id) REFERENCES organizations(id)
        );

        CREATE TABLE IF NOT EXISTS courses (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            org_id INTEGER NOT NULL,
            title TEXT NOT NULL,
            teacher_id INTEGER,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY(org_id) REFERENCES organizations(id),
            FOREIGN KEY(teacher_id) REFERENCES users(id)
        );

        CREATE TABLE IF NOT EXISTS enrollments (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            course_id INTEGER NOT NULL,
            student_id INTEGER NOT NULL,
            status TEXT NOT NULL DEFAULT 'active' CHECK(status IN ('active','dropped','transferred')),
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY(course_id) REFERENCES courses(id),
            FOREIGN KEY(student_id) REFERENCES users(id)
        );

        CREATE TABLE IF NOT EXISTS homework (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            course_id INTEGER NOT NULL,
            title TEXT NOT NULL,
            description TEXT,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY(course_id) REFERENCES courses(id)
        );

        CREATE TABLE IF NOT EXISTS grades (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            enrollment_id INTEGER NOT NULL,
            score REAL NOT NULL,
            comment TEXT,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY(enrollment_id) REFERENCES enrollments(id)
        );

        CREATE TABLE IF NOT EXISTS payments (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            org_id INTEGER NOT NULL,
            student_id INTEGER NOT NULL,
            amount REAL NOT NULL,
            status TEXT NOT NULL CHECK(status IN ('paid','refund')),
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY(org_id) REFERENCES organizations(id),
            FOREIGN KEY(student_id) REFERENCES users(id)
        );
        """
    )
    conn.commit()
    conn.close()


class Handler(BaseHTTPRequestHandler):
    def _json(self, code, payload):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_json(self):
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length else b"{}"
        try:
            return json.loads(raw.decode("utf-8") or "{}")
        except json.JSONDecodeError:
            return {}

    def _serve_file(self, path: Path):
        if not path.exists() or not path.is_file():
            return self._json(404, {"error": "not found"})
        data = path.read_bytes()
        ctype = mimetypes.guess_type(str(path))[0] or "application/octet-stream"
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        q = parse_qs(parsed.query)

        if path == "/":
            return self._serve_file(STATIC_DIR / "index.html")

        if path.startswith("/static/"):
            rel = path.replace("/static/", "", 1)
            return self._serve_file(STATIC_DIR / rel)

        if path == "/health":
            return self._json(200, {"status": "ok", "db": str(DB_PATH)})

        table_map = {
            "/api/organizations": "organizations",
            "/api/users": "users",
            "/api/courses": "courses",
            "/api/enrollments": "enrollments",
            "/api/homework": "homework",
            "/api/grades": "grades",
            "/api/payments": "payments",
        }

        if path == "/api/report/revenue":
            org_id = q.get("org_id", [None])[0]
            if not org_id:
                return self._json(400, {"error": "org_id is required"})
            conn = get_conn()
            cur = conn.execute(
                "SELECT IFNULL(SUM(CASE WHEN status='paid' THEN amount WHEN status='refund' THEN -amount END),0) AS revenue FROM payments WHERE org_id=?",
                (org_id,),
            )
            row = cur.fetchone()
            conn.close()
            return self._json(200, {"org_id": int(org_id), "revenue": row["revenue"]})

        if path in table_map:
            conn = get_conn()
            rows = [dict(r) for r in conn.execute(f"SELECT * FROM {table_map[path]} ORDER BY id DESC").fetchall()]
            conn.close()
            return self._json(200, rows)

        self._json(404, {"error": "not found"})

    def do_POST(self):
        path = urlparse(self.path).path
        data = self._read_json()

        insert_map = {
            "/api/organizations": ("organizations", ["name"]),
            "/api/users": ("users", ["org_id", "name", "role"]),
            "/api/courses": ("courses", ["org_id", "title", "teacher_id"]),
            "/api/enrollments": ("enrollments", ["course_id", "student_id", "status"]),
            "/api/homework": ("homework", ["course_id", "title", "description"]),
            "/api/grades": ("grades", ["enrollment_id", "score", "comment"]),
            "/api/payments": ("payments", ["org_id", "student_id", "amount", "status"]),
        }

        if path not in insert_map:
            return self._json(404, {"error": "not found"})

        table, fields = insert_map[path]
        sanitized = {k: data.get(k) for k in fields if data.get(k) is not None}
        required = {
            "organizations": ["name"],
            "users": ["org_id", "name", "role"],
            "courses": ["org_id", "title"],
            "enrollments": ["course_id", "student_id"],
            "homework": ["course_id", "title"],
            "grades": ["enrollment_id", "score"],
            "payments": ["org_id", "student_id", "amount", "status"],
        }[table]

        miss = [k for k in required if k not in sanitized]
        if miss:
            return self._json(400, {"error": f"missing fields: {', '.join(miss)}"})

        cols = ", ".join(sanitized.keys())
        placeholders = ", ".join(["?" for _ in sanitized])
        values = tuple(sanitized.values())

        conn = get_conn()
        cur = conn.execute(f"INSERT INTO {table} ({cols}) VALUES ({placeholders})", values)
        conn.commit()
        row = conn.execute(f"SELECT * FROM {table} WHERE id=?", (cur.lastrowid,)).fetchone()
        conn.close()
        self._json(201, dict(row))


def run():
    init_db()
    server = ThreadingHTTPServer(("0.0.0.0", 8000), Handler)
    print("Server started at http://0.0.0.0:8000")
    server.serve_forever()


if __name__ == "__main__":
    run()
