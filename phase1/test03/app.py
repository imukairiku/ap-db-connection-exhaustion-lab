import json
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import psycopg2


DSN = {
    "host": os.environ["DB_HOST"], "user": os.environ["DB_USER"],
    "password": os.environ["DB_PASSWORD"], "dbname": os.environ["DB_NAME"],
    "application_name": "ap-server-1",
}
capacity = threading.BoundedSemaphore(12)
state_lock = threading.Lock()
active = 0


def emit(request_id, event):
    print(json.dumps({"request_id": request_id, "ap": "ap-server-1", "event": event}), flush=True)


def execute_work(request_id):
    emit(request_id, "START")
    connection = psycopg2.connect(connect_timeout=5, **DSN)
    try:
        emit(request_id, "DB_CONNECTED")
        with connection.cursor() as cursor:
            cursor.execute("INSERT INTO business_results (request_id) VALUES (%s)", (request_id,))
            cursor.execute("SELECT pg_sleep(8)")
        connection.commit()
        emit(request_id, "COMMIT")
        emit(request_id, "SUCCESS")
    except Exception:
        connection.rollback()
        emit(request_id, "ROLLBACK")
        raise
    finally:
        connection.close()


class Handler(BaseHTTPRequestHandler):
    def reply(self, status, document):
        body = json.dumps(document).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            self.reply(200, {"ready": True})
        elif self.path == "/state":
            with state_lock:
                self.reply(200, {"active": active, "capacity": 12})
        else:
            self.reply(404, {"code": "not_found"})

    def do_POST(self):
        global active
        if self.path != "/work":
            self.reply(404, {"code": "not_found"})
            return
        try:
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
            request_id = body["request_id"]
            if not isinstance(request_id, str) or not request_id:
                raise ValueError
        except (KeyError, ValueError, json.JSONDecodeError):
            self.reply(400, {"status": "FAILURE", "code": "invalid_request"})
            return
        if not capacity.acquire(blocking=False):
            self.reply(429, {"status": "REJECTED", "code": "capacity_exceeded"})
            return
        with state_lock:
            active += 1
        try:
            execute_work(request_id)
            self.reply(200, {"request_id": request_id, "status": "SUCCESS"})
        except Exception as error:
            self.reply(503, {"request_id": request_id, "status": "FAILURE", "error_type": type(error).__name__})
        finally:
            with state_lock:
                active -= 1
            capacity.release()

    def log_message(self, *_args):
        pass


ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
