#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import os
import pytest
import logging
import tempfile
import py
import tarantool
import time

from subprocess import Popen, PIPE, STDOUT
from threading import Thread

script_dir = os.path.dirname(os.path.realpath(__file__))
logging.basicConfig(format='%(name)s > %(message)s')

TARANTOOL_CONNECTION_TIMEOUT = 10.0
MEMBERSHIP_UPDATE_TIMEOUT = 3.0

class Helpers:
    @staticmethod
    def wait_for(fn, args=[], kwargs={}, timeout=MEMBERSHIP_UPDATE_TIMEOUT):
        """Repeatedly call fn(*args, **kwargs)
        until it returns something or timeout occurs"""
        time_start = time.time()
        while True:
            now = time.time()
            if now > time_start + timeout:
                break

            try:
                return fn(*args, **kwargs)
            except:
                time.sleep(0.1)

        # after timeout call fn once more to propagate exception
        return fn(*args, **kwargs)

@pytest.fixture(scope='session')
def helpers():
    return Helpers

@pytest.fixture(scope='module')
def module_tmpdir(request):
    dir = py.path.local(tempfile.mkdtemp())
    logging.warning("Create module_tmpdir: {}".format(str(dir)))
    request.addfinalizer(lambda: dir.remove(rec=1))
    return str(dir)

class Server(object):
    def __init__(self, hostname, port, tmpdir):
        self.logger = logging.getLogger('localhost:{}'.format(port))
        self.hostname = hostname
        self.port = port
        self.tmpdir = tmpdir
        self.conn = None
        self.thread = None
        self.process = None
        self.seen_traceback = False
        pass

    def start(self):
        env = os.environ.copy()
        env['TARANTOOL_HOSTNAME'] = str(self.hostname)
        env['TARANTOOL_LISTEN'] = str(self.port)
        env['TARANTOOL_WORKDIR'] = "{}/localhost-{}".format(self.tmpdir, self.port)

        cmd = ["tarantool", os.path.join(script_dir, 'instance.lua')]
        self.process = Popen(cmd, stdout=PIPE, stderr=STDOUT, env=env, bufsize=1)
        self.thread = Thread(
            target=self.consume_lines
        ).start()

    def consume_lines(self):
        with self.process.stdout as pipe:
            for line in iter(pipe.readline, b''):
                l = line.strip().decode('utf-8')
                self.logger.warning(l)
                if 'stack traceback:' in l:
                    self.seen_traceback = True


    def connect(self):
        assert self.process.poll() is None
        if self.conn == None:
            self.conn = tarantool.connect('127.0.0.1', self.port)
        assert self.conn.eval('return is_initialized')[0]

    def kill(self):
        if self.conn != None:
            # logging.warning('Closing connection to {}'.format(self.port))
            self.conn.close()
            self.conn = None
        self.process.kill()
        logging.warning('localhost:{} killed'.format(self.port))
        if self.thread != None:
            self.thread.join()

    def add_member(self, uri):
        cmd = "return membership.add_member('{}')".format(uri)
        # returns: true/false
        return self.conn.eval(cmd)[0]

    def probe_uri(self, uri):
        cmd = "return membership.probe_uri('{}')".format(uri)
        # returns: true/false
        return self.conn.eval(cmd)[0]

    def broadcast(self, port):
        cmd = "return membership.broadcast({})".format(port)
        # returns: true/false
        return self.conn.eval(cmd)[0]

    def members(self):
        cmd = "return membership.members()"
        return self.conn.eval(cmd)[0]

    def myself(self):
        cmd = "return membership.myself()"
        return self.conn.eval(cmd)[0]

@pytest.fixture(scope="module")
def servers(request, module_tmpdir, helpers):
    servers = {}
    hostname = getattr(request.module, "hostname", "localhost")
    for port in getattr(request.module, "servers_list"):
        srv = Server(hostname, port, module_tmpdir)
        srv.start()
        request.addfinalizer(srv.kill)
        helpers.wait_for(srv.connect, timeout=TARANTOOL_CONNECTION_TIMEOUT)
        # srv.wait()
        servers[port] = srv
    yield servers

    servers_with_errors = [srv for srv in servers.values() if srv.seen_traceback]
    for srv in iter(servers_with_errors):
        logging.warning("Seen traceback on localhost:{}".format(srv.port))
    if servers_with_errors:
        pytest.fail("Seen traceback")
