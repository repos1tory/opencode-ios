"""Exercise the real native PTY helper: framing, resizing, process exit and EOF."""
import os
import pathlib
import select
import struct
import subprocess
import unittest

HELPER = os.environ['PTY_HELPER']
SHELL = os.environ.get('PTY_TEST_SHELL', '/bin/sh')

class PtyTests(unittest.TestCase):
    def start(self, command):
        proc = subprocess.Popen([HELPER, '80', '24', SHELL, '-c', command], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.addCleanup(self.cleanup, proc)
        return proc

    @staticmethod
    def cleanup(proc):
        if proc.poll() is None:
            proc.kill()
            proc.wait(timeout=5)
        for stream in (proc.stdin, proc.stdout, proc.stderr):
            if stream: stream.close()

    def read_until(self, proc, marker):
        data = b''
        for _ in range(20):
            ready, _, _ = select.select([proc.stdout], [], [], .5)
            if ready:
                chunk = os.read(proc.stdout.fileno(), 16384)
                data += chunk
                if marker in data: return data
                if not chunk: break
        self.fail('PTY did not emit expected marker: '+repr(data))

    def frame(self, proc, kind, payload):
        proc.stdin.write(struct.pack('!I', len(payload)+1)+kind+payload)
        proc.stdin.flush()

    def test_output_and_exit_status(self):
        proc = self.start("printf 'PTY_OK\\n'; exit 7")
        self.assertIn(b'PTY_OK', self.read_until(proc, b'PTY_OK'))
        self.assertEqual(proc.wait(timeout=5), 7)

    def test_input_and_resize(self):
        proc = self.start("read value; stty size; printf 'GOT:%s\\n' \"$value\"")
        self.frame(proc,b'R',struct.pack('!HH',100,40))
        self.frame(proc,b'I',b'hello\n')
        result=self.read_until(proc,b'GOT:hello')
        self.assertIn(b'40 100',result)
        self.assertEqual(proc.wait(timeout=5),0)

    def test_invalid_frame_stops_child(self):
        proc=self.start('sleep 60')
        proc.stdin.write(struct.pack('!I',70000));proc.stdin.flush()
        self.assertNotEqual(proc.wait(timeout=5),0)

    def test_parent_eof_stops_child(self):
        proc=self.start('sleep 60')
        proc.stdin.close();proc.stdin=None
        self.assertNotEqual(proc.wait(timeout=5),0)

if __name__=='__main__':unittest.main()
