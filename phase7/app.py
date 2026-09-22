"""Phase 7 workload: retain in-flight transactions for the scenario lifetime."""
import json
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import psycopg2

AP = os.environ['AP_NAME']
DSN = dict(host=os.environ['DB_HOST'], user='app_user', password='app-only',
           dbname='lab', application_name=AP, connect_timeout=5)
lock = threading.Lock()
hold = threading.Event()
requests = {}


def worker(request_id):
    attempt = 0
    while True:
        attempt += 1
        connection = None
        with lock:
            requests[request_id].update(state='CONNECTING', attempt=attempt)
        print(json.dumps({'request_id': request_id, 'ap': AP, 'event': 'CONNECT_ATTEMPT',
                          'attempt': attempt, 'connect_timeout': 5}), flush=True)
        try:
            connection = psycopg2.connect(**DSN)
            with connection.cursor() as cursor:
                cursor.execute('INSERT INTO business_results(request_id,ap_name) VALUES(%s,%s)',
                               (request_id, AP))
            if AP == 'ap-server-2':
                connection.commit()
                print(json.dumps({'request_id': request_id, 'ap': AP,
                                  'event': 'BUSINESS_COMMITTED', 'attempt': attempt}), flush=True)
            with lock:
                failures = requests[request_id]['connection_failures']
                requests[request_id].update(connected=True, state='DB_CONNECTED',
                                            recovered=failures > 0, next_retry_seconds=None)
            print(json.dumps({'request_id': request_id, 'ap': AP, 'event': 'DB_CONNECTED',
                              'attempt': attempt, 'recovered': failures > 0}), flush=True)
            hold.wait(3600)
            return
        except psycopg2.OperationalError as error:
            if connection:
                connection.close()
                connection = None
            delay = min(2 ** (attempt - 1), 4)
            with lock:
                row = requests[request_id]
                row['connection_failures'] += 1
                row['backoffs'].append(delay)
                row.update(connected=False, state='RETRY_WAIT', error_type=type(error).__name__,
                           last_error=str(error).strip(), next_retry_seconds=delay)
            print(json.dumps({'request_id': request_id, 'ap': AP, 'event': 'CONNECTION_FAILED',
                              'attempt': attempt, 'connect_timeout': 5,
                              'db_error': str(error).strip()}), flush=True)
            print(json.dumps({'request_id': request_id, 'ap': AP, 'event': 'RETRY_SCHEDULED',
                              'attempt': attempt, 'backoff_seconds': delay}), flush=True)
            time.sleep(delay)
        except Exception as error:
            with lock:
                requests[request_id].update(active=False, connected=False, state='REQUEST_FAILED',
                                            error_type=type(error).__name__, last_error=str(error).strip())
            print(json.dumps({'request_id': request_id, 'ap': AP, 'event': 'REQUEST_FAILED',
                              'attempt': attempt, 'error_type': type(error).__name__,
                              'error': str(error).strip()}), flush=True)
            return
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
                         'failed': sum(row['connection_failures'] > 0 for row in rows),
                         'connection_failures': sum(row['connection_failures'] for row in rows),
                         'retrying': sum(row['state'] == 'RETRY_WAIT' for row in rows),
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
                                        'connected': False, 'state': 'STARTING', 'attempt': 0,
                                        'connection_failures': 0, 'backoffs': [],
                                        'recovered': False, 'next_retry_seconds': None}
        for request_id in ids:
            threading.Thread(target=worker, args=(request_id,), daemon=True).start()
        return self.reply(202, {'request_ids': ids})

    def log_message(self, *_):
        pass


ThreadingHTTPServer(('0.0.0.0', 8080), Handler).serve_forever()
