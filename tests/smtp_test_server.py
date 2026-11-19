"""A test SMTP server on 127.0.0.1 for the tests of the SMTP client and of
what sends through it.

One session per server, recorded: the commands with the layer they came over
(plain text or TLS), the lines of the message, and whether the message was
taken. Nothing is relayed and no real e-mail is sent. The server authenticates
USER with PASSWORD, by AUTH PLAIN or, when asked to offer it, by CRAM-MD5
compared as a strict server compares it.
"""
import base64
import hmac
import socket
import ssl
import threading

SESSION_TIMEOUT = 8.0
USER, PASSWORD = 'tim', 'synthetic-password'
CHALLENGE = '<1896.697170952@test.localhost>'


class LineSocket:
    """CRLF lines over a socket, plain or TLS."""

    def __init__(self, sock):
        self.sock = sock
        self.buffer = b''

    def readline(self):
        while b'\r\n' not in self.buffer:
            chunk = self.sock.recv(4096)
            if not chunk:
                return None
            self.buffer += chunk
        line, self.buffer = self.buffer.split(b'\r\n', 1)
        return line.decode('utf-8', 'replace')

    def send(self, line):
        self.sock.sendall(line.encode() + b'\r\n')


class TestSMTPServer:
    """One session on 127.0.0.1, recorded; nothing is relayed.

    mode: 'plain' (no STARTTLS), 'starttls' (offers it) or 'implicit' (TLS
    from the first byte). auth: offer AUTH PLAIN LOGIN on EHLO, or, 'cram',
    AUTH CRAM-MD5 PLAIN LOGIN, with a CRAM-MD5 answer compared as a string
    with the RFC 2195 digest in lower-case hexadecimal, as a strict server
    does. The lines of the message are kept in `data`."""

    def __init__(self, mode, context, auth=False):
        self.mode = mode
        self.context = context
        self.auth = auth
        self.listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.listener.bind(('127.0.0.1', 0))
        self.listener.listen(1)
        self.listener.settimeout(SESSION_TIMEOUT)
        self.port = self.listener.getsockname()[1]
        self.commands = []  # (layer, command)
        self.data = []
        self.delivered = False
        self.done = threading.Event()
        threading.Thread(target=self.serve, daemon=True).start()

    def serve(self):
        try:
            connection, _ = self.listener.accept()
        except OSError:
            self.done.set()
            return
        connection.settimeout(SESSION_TIMEOUT)
        layer = 'plain'
        try:
            if self.mode == 'implicit':
                connection = self.context.wrap_socket(connection, server_side=True)
                layer = 'tls'
            io = LineSocket(connection)
            io.send('220 test.localhost ESMTP')
            in_data = False
            cram = False
            while True:
                line = io.readline()
                if line is None:
                    break
                if in_data:
                    if line == '.':
                        in_data = False
                        self.delivered = True
                        io.send('250 2.0.0 dropped, nothing relayed')
                    else:
                        self.data.append(line)
                    continue
                if cram:
                    cram = False
                    self.commands.append((layer, line))
                    digest = hmac.new(PASSWORD.encode(), CHALLENGE.encode(), 'md5').hexdigest()
                    if base64.b64decode(line).decode() == f'{USER} {digest}':
                        io.send('235 2.7.0 accepted')
                    else:
                        io.send('535 5.7.8 Authentication credentials invalid')
                    continue
                verb = line.split(' ', 1)[0].upper()
                self.commands.append((layer, 'HELO' if verb == 'HELO' else 'EHLO' if verb == 'EHLO' else line))
                if verb == 'EHLO':
                    io.send('250-test.localhost')
                    if self.mode == 'starttls' and layer == 'plain':
                        io.send('250-STARTTLS')
                    if self.auth == 'cram':
                        io.send('250-AUTH CRAM-MD5 PLAIN LOGIN')
                    elif self.auth:
                        io.send('250-AUTH PLAIN LOGIN')
                    io.send('250 8BITMIME')
                elif verb == 'STARTTLS' and self.mode == 'starttls' and layer == 'plain':
                    io.send('220 2.0.0 ready to start TLS')
                    connection = self.context.wrap_socket(connection, server_side=True)
                    io = LineSocket(connection)
                    layer = 'tls'
                elif verb == 'AUTH' and line == 'AUTH CRAM-MD5':
                    cram = True
                    io.send('334 ' + base64.b64encode(CHALLENGE.encode()).decode())
                elif verb == 'AUTH' and line.startswith('AUTH PLAIN '):
                    given = base64.b64decode(line[len('AUTH PLAIN '):]).split(b'\0')
                    if given[1:] == [USER.encode(), PASSWORD.encode()]:
                        io.send('235 2.7.0 accepted')
                    else:
                        io.send('535 5.7.8 Authentication credentials invalid')
                elif verb in ('HELO', 'MAIL', 'RCPT'):
                    io.send('250 ok')
                elif verb == 'DATA':
                    in_data = True
                    io.send('354 go on')
                elif verb == 'QUIT':
                    io.send('221 bye')
                    break
                else:
                    io.send('502 not here')
        except (OSError, ssl.SSLError):
            pass
        finally:
            connection.close()
            self.listener.close()
            self.done.set()


def closed_port():
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.bind(('127.0.0.1', 0))
    port = sock.getsockname()[1]
    sock.close()
    return port
