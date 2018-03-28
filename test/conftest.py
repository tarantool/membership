#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import os
import pytest
import logging
import tempfile
import py
import tarantool
import time
import requests

from subprocess import Popen, PIPE, STDOUT
from threading import Thread

script_dir = os.path.dirname(os.path.realpath(__file__))

TARANTOOL_CONNECTION_TIMEOUT = 1.0

class Helpers:
    @staticmethod
    def wait_for(fn, args=[], kwargs={}, timeout=10):
        """Repeatedly call fn(*args, **kwargs)
        until it returns True or timeout occurs"""
        time_start = time.time()
        exception = None
        while True:
            now = time.time()
            if now > time_start + timeout:
                raise Exception("Operation timed out: {}".format(exception))

            try:
                if fn(*args, **kwargs):
                    break
                else:
                    raise Exception("function returns false")
            except Exception as e:
                exception = e
                time.sleep(0.1)

@pytest.fixture(scope='session')
def helpers():
    return Helpers

def consume_lines(port, pipe):
    with pipe:
        for line in iter(pipe.readline, b''):
            logging.warn("server {}: {}".format(port, line.strip().decode('utf-8')))

@pytest.fixture(scope='module')
def module_tmpdir(request):
    dir = py.path.local(tempfile.mkdtemp())
    logging.warn("Create module_tmpdir: {}".format(str(dir)))
    request.addfinalizer(lambda: dir.remove(rec=1))
    return str(dir)

class Server(object):
    def __init__(self, port, tmpdir):
        self.port = port
        self.tmpdir = tmpdir
        self.conn = None
        pass

    def start(self):
        env = os.environ.copy()
        env['TARANTOOL_LISTEN'] = str(self.port)
        env['TARANTOOL_WORKDIR'] = "{}/localhost-{}".format(self.tmpdir, self.port)

        cmd = ["tarantool", os.path.join(script_dir, 'instance.lua')]
        self.process = Popen(cmd, stdout=PIPE, stderr=STDOUT, env=env, bufsize=1)
        Thread(target=consume_lines, args=[self.port, self.process.stdout]).start()

    def connect(self):
        if self.conn == None:
            self.conn = tarantool.connect('127.0.0.1', self.port)
        return self.conn.eval('return is_initialized')[0]

    def kill(self):
        if self.conn != None:
            # logging.warn('Closing connection to {}'.format(self.port))
            self.conn.close()
            self.conn = None
        self.process.kill()

    def add_member(self, uri):
        cmd = "return membership.add_member('{}')".format(uri)
        # returns: true/false
        return self.conn.eval(cmd)[0]

    def members(self):
        cmd = "return membership.members()"
        return self.conn.eval(cmd)[0]

@pytest.fixture(scope="module")
def servers(request, module_tmpdir, helpers):
    servers = {}
    for port in getattr(request.module, "servers_list"):
        srv = Server(port, module_tmpdir)
        srv.start()
        request.addfinalizer(srv.kill)
        helpers.wait_for(srv.connect, timeout=TARANTOOL_CONNECTION_TIMEOUT)
        # srv.wait()
        servers[port] = srv
    return servers