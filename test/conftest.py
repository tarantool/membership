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


TARANTOOL_CONNECTION_TIMEOUT = 5.0


def consume_lines(pipe):
    with pipe:
        for line in iter(pipe.readline, b''):
            logging.warn("server: " + line.strip().decode('utf-8'))


@pytest.fixture(scope='module')
def module_tmpdir(request):
    dir = py.path.local(tempfile.mkdtemp())
    logging.warn("Create module_tmpdir: {}".format(str(dir)))
    request.addfinalizer(lambda: dir.remove(rec=1))
    return str(dir)

@pytest.fixture(scope='module')
def confdir(request):
    dir = os.path.join(request.fspath.dirname, 'config')
    logging.warn("Create confdir: {}".format(str(dir)))

    return str(dir)

class Server(object):
    def __init__(self, port, tmpdir):
        self.port = port
        self.tmpdir = tmpdir
        pass

    def start(self):
        env = os.environ.copy()
        env['TARANTOOL_LISTEN'] = str(self.port)
        env['TARANTOOL_WORKDIR'] = "{}/localhost-{}".format(self.tmpdir, self.port)

        cmd = ["tarantool", os.path.join(script_dir, 'instance.lua')]
        self.process = Popen(cmd, stdout=PIPE, stderr=STDOUT, env=env, bufsize=1)
        Thread(target=consume_lines, args=[self.process.stdout]).start()

    def wait(self):
        logging.warn("Waiting for 'localhost:{}'".format(self.port))

        time_start = time.time()
        while True:
            now = time.time()

            if now - time_start > TARANTOOL_CONNECTION_TIMEOUT:
                raise Exception("Timed out while connecting to Tarantool instance")

            try:
                conn = tarantool.connect('127.0.0.1', self.port)
            except:
                time.sleep(0.1)
                continue

            try:
                if conn.eval('return is_initialized')[0]:
                    break
            except:
                pass

            conn.close()
            time.sleep(0.1)

        logging.warn("Ready.")

    def kill(self):
        self.process.kill()


    def post(self, path, data=None, json=None):
        if data is not None:
            data = data.encode('utf-8')

        url = self.baseurl + '/' + path.lstrip('/')
        r = requests.post(url, data=data, json=json)
        r.raise_for_status()

        return r.text

    def soap(self, data=None):
        if data is not None:
            data = data.encode('utf-8')

        url = self.baseurl + '/soap'
        headers = {'Content-Type': 'application/xml'}
        r = requests.post(url, data=data, headers=headers)
        r.raise_for_status()

        return r.text


    def graphql(self, query):
        url = self.baseurl + '/graphql'

        request = {"query": query}

        r = requests.post(url, json=request)

        r.raise_for_status()

        return r.json()


@pytest.fixture(scope="module")
def server(request, confdir, module_tmpdir):
    server = Server(3301)
    server.start()
    request.addfinalizer(server.kill)
    server.wait()
    return server

@pytest.fixture(scope="module")
def servers(request, module_tmpdir):
    servers = {}
    for port in getattr(request.module, "servers_list"):
        srv = Server(port, module_tmpdir)
        srv.start()
        request.addfinalizer(srv.kill)
        srv.wait()
        servers[port] = srv
    return servers