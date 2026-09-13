"""Phase 7 workload: retain in-flight transactions for the scenario lifetime."""
import json
import os
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import psycopg2

AP = os.environ['AP_NAME']
DSN = dict(host=os.environ['DB_HOST'], user='app_user', password='app-only',
           dbname='lab', application_name=AP, connect_timeout=5)
lock = threading.Lock()
hold = threading.Event()
requests = {}


def worker(request_id):
    connection = None
    try:
        connection = psycopg2.connect(**DSN)
        with connection.cursor() as cursor:
            cursor.execute('INSERT INTO business_results(request_id,ap_name) VALUES(%s,%s)',
                           (request_id, AP))
        with lock:
            requests[request_id].update(connected=True, state='DB_CONNECTED')
        print(json.dumps({'request_id': request_id, 'ap': AP, 'event': 'DB_CONNECTED'}), flush=True)
        hold.wait(3600)
    except Exception as error:
        with lock:
            requests[request_id].update(active=False, state='CONNECTION_FAILED',
                                        error_type=type(error).__name__)
        print(json.dumps({'request_id': request_id, 'ap': AP, 'event': 'CONNECTION_FAILED',
                          'db_error': str(error).strip()}), flush=True)
    finally:
        if connection:
            connection.close()


class Handler(BaseHTTPRequestHandler):
    def reply(self, status, value):
        body = json.dumps(value).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == '/health':
            return self.reply(200, {'ready': True, 'ap': AP})
        if self.path == '/state':
            with lock:
                rows = list(requests.values())
                value = {'accepted': len(rows),
                         'connected': sum(row['connected'] for row in rows),
                         'failed': sum(row['state'] == 'CONNECTION_FAILED' for row in rows),
                         'requests': rows}
            return self.reply(200, value)
        return self.reply(404, {'error': 'not_found'})

    def do_POST(self):
        if self.path != '/batch':
            return self.reply(404, {'error': 'not_found'})
        try:
            ids = json.loads(self.rfile.read(int(self.headers.get('Content-Length', '0'))))['request_ids']
            if not 1 <= len(ids) <= 12 or len(ids) != len(set(ids)):
                raise ValueError('batch size or IDs invalid')
        except (KeyError, ValueError, json.JSONDecodeError):
            return self.reply(400, {'error': 'invalid_batch'})
        with lock:
            if requests:
                return self.reply(409, {'error': 'batch_started'})
            for request_id in ids:
                requests[request_id] = {'request_id': request_id, 'active': True,
                                        'connected': False, 'state': 'STARTING'}
        for request_id in ids:
            threading.Thread(target=worker, args=(request_id,), daemon=True).start()
        return self.reply(202, {'request_ids': ids})

    def log_message(self, *_):
        pass


ThreadingHTTPServer(('0.0.0.0', 8080), Handler).serve_forever()
