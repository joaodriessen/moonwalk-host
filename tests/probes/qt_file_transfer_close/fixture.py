#!/usr/bin/env python3
"""Exercise production Qt transport against planned, delayed TLS closure.

This is a loopback protocol fixture, not an installed-host or hardware test.
"""
import argparse
import hashlib
import json
import pathlib
import socket
import ssl
import subprocess
import tempfile
import threading
import time
import urllib.parse


def run_case(worker, certificate, key, output, name, closing_header, error_status):
    requests, uploaded = [], bytearray()
    checksum, injected_error = '', False
    stop = threading.Event()
    server = socket.socket()
    server.bind(('127.0.0.1', 0))
    server.listen()
    server.settimeout(0.2)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(certificate, key)
    context.verify_mode = ssl.CERT_REQUIRED

    def serve():
        nonlocal checksum, injected_error
        while not stop.is_set():
            try:
                raw, _ = server.accept()
            except TimeoutError:
                continue
            try:
                # Worker writes its fresh public certificate before connecting.
                context.load_verify_locations(str(certificate) + '.client.pem')
                with context.wrap_socket(raw, server_side=True) as stream:
                    stream.settimeout(3)
                    data = b''
                    while b'\r\n\r\n' not in data:
                        part = stream.recv(65536)
                        if not part:
                            raise ValueError('Incomplete request headers')
                        data += part
                    header, body = data.split(b'\r\n\r\n', 1)
                    length = 0
                    for line in header.split(b'\r\n'):
                        if line.lower().startswith(b'content-length:'):
                            length = int(line.split(b':', 1)[1])
                    while len(body) < length:
                        part = stream.recv(65536)
                        if not part:
                            raise ValueError('Incomplete request body')
                        body += part
                    target = urllib.parse.urlsplit(header.split(b' ')[1].decode())
                    query = urllib.parse.parse_qs(target.query, keep_blank_values=True)
                    operation = query.get('op', [''])[0]
                    record = dict(path=target.path, method=header.split(b' ')[0].decode(),
                                  operation=operation, bytes=len(body), status=200,
                                  connection_close=closing_header, tls=stream.version())
                    requests.append(record)
                    content_type = b'application/json'
                    if target.path == '/serverinfo':
                        reply = b'<root status_code="200"><FileTransferSupported>1</FileTransferSupported></root>'
                        reply += b' ' * (1031 - len(reply))
                    elif operation == 'beginUpload' and error_status and not injected_error:
                        injected_error = True
                        record['status'] = error_status
                        content_type = b'text/plain; charset=utf-8'
                        reply = ('fixture HTTP ' + str(error_status)).encode()
                    elif operation == 'beginUpload':
                        assert query['name'] == ['worker-☃-café.bin']
                        checksum = query['sha256'][0]
                        reply = json.dumps(dict(id='upload', chunkBytes=1048576)).encode()
                    elif operation == 'chunk':
                        assert int(query['offset'][0]) == len(uploaded)
                        uploaded.extend(body)
                        reply = b'{}'
                    elif operation == 'beginDownload':
                        reply = json.dumps(dict(id='download', size=len(uploaded), chunkBytes=1048576)).encode()
                    elif operation == 'read':
                        offset = int(query['offset'][0])
                        reply = uploaded[offset:offset + 1048576]
                    elif operation == 'finish':
                        assert hashlib.sha256(uploaded).hexdigest() == checksum
                        reply = json.dumps(dict(sha256=checksum)).encode()
                    elif operation == 'cancel':
                        reply = b'{}'
                    else:
                        raise ValueError('Unexpected operation: ' + operation)
                    response = ('HTTP/1.1 %d Fixture\r\n' % record['status']).encode()
                    response += b'Content-Type: ' + content_type + b'\r\nContent-Length: ' + str(len(reply)).encode()
                    if closing_header:
                        response += b'\r\nConnection: close'
                    stream.sendall(response + b'\r\n\r\n' + reply)
                    # Keep the planned close asynchronous relative to Qt's response completion.
                    time.sleep(0.010)
            except Exception as error:
                requests.append(dict(error=str(error)))
                raw.close()

    thread = threading.Thread(target=serve)
    thread.start()
    try:
        command = [str(worker), str(certificate), str(server.getsockname()[1])]
        if error_status:
            command.append(str(error_status))
        result = subprocess.run(command, capture_output=True, text=True, timeout=30)
    finally:
        stop.set()
        thread.join(timeout=5)
        server.close()
    if thread.is_alive():
        raise RuntimeError('Owned fixture thread did not exit')
    (output / (name + '.log')).write_text(result.stdout + result.stderr)
    record = dict(exit=result.returncode, requests=requests, uploaded_bytes=len(uploaded),
                  sha256=hashlib.sha256(uploaded).hexdigest())
    (output / (name + '.json')).write_text(json.dumps(record, indent=2) + '\n')
    return record, result.stdout + result.stderr


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--worker', required=True, type=pathlib.Path)
    parser.add_argument('--output', required=True, type=pathlib.Path)
    parser.add_argument('--require-red', action='store_true', help='Require legacy close timing to reproduce')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    with tempfile.TemporaryDirectory(prefix='qt-transfer-close-') as directory:
        private = pathlib.Path(directory)
        certificate, key = private / 'server.pem', private / 'server.key'
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-subj',
                        '/CN=Private-loopback-transfer-fixture', '-days', '1', '-keyout', str(key),
                        '-out', str(certificate)], check=True, capture_output=True)
        key.chmod(0o600)
        legacy, text = run_case(args.worker.resolve(), certificate, key, args.output, 'legacy', False, 0)
        reproduced = legacy['exit'] != 0 and 'Connection closed' in text
        if args.require_red and not reproduced:
            raise AssertionError('Legacy timing did not reproduce on this Qt/TLS build')
        cases = []
        for status in (0, 403, 409, 500, 503):
            record, _ = run_case(args.worker.resolve(), certificate, key, args.output,
                                 'close-' + str(status), True, status)
            assert record['exit'] == 0, 'Closing response case failed: ' + str(status)
            assert record['uploaded_bytes'] == 2097189
            assert record['sha256'] == '33bb73dc272b9699a61f9284c0fb21075a5913d7985b55b684cd21bd6c7b3b09'
            assert any(v.get('path') == '/serverinfo' for v in record['requests'])
            if status:
                assert any(v.get('status') == status for v in record['requests'])
            cases.append(status)
        result = dict(passed=True, legacy_reproduced=reproduced, closing_cases=cases,
                      transport='actual production FileTransfer/NvHTTP with private loopback mTLS fixture',
                      installed_host_test=False)
        (args.output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
